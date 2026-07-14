#!/usr/bin/env bash
#
# Install a complete Wi-Fi reset hook for the "schuler" account.
#
# Run as the administrator:
#   sudo ./install_schuler_session_wifi_reset.sh
#
# Behaviour:
#   1. itm may connect to Wi-Fi normally.
#   2. When schuler starts a graphical login, all active Wi-Fi connections
#      are disconnected and all saved Wi-Fi profiles are deleted.
#   3. NetworkManager is restarted.
#   4. schuler begins the session with Wi-Fi enabled but disconnected.
#   5. The same cleanup is attempted again when schuler logs out.
#
# IMPORTANT:
# Wi-Fi is system-wide on a normal Linux desktop. This reset disconnects every
# account on the computer, including itm if itm still has an active session.
#
set -Eeuo pipefail

TARGET_USER="schuler"
RESET_COMMAND="/usr/local/sbin/reset-wifi-for-schuler-session"
MARKER_BEGIN="# BEGIN SCHULER SESSION WIFI RESET"
MARKER_END="# END SCHULER SESSION WIFI RESET"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    printf '\n==> %s\n' "$*"
}

[[ $EUID -eq 0 ]] || die "Run this installer with sudo."
id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."
log "Checking required packages"

MISSING_PACKAGES=()

command -v nmcli >/dev/null 2>&1 || MISSING_PACKAGES+=(network-manager)

if ! find /usr/lib /lib \
    -type f -path '*/security/pam_exec.so' \
    -print -quit 2>/dev/null | grep -q .; then
    MISSING_PACKAGES+=(libpam-modules)
fi

if (( ${#MISSING_PACKAGES[@]} > 0 )); then
    log "Installing missing packages: ${MISSING_PACKAGES[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_PACKAGES[@]}"
fi

command -v nmcli >/dev/null 2>&1 || \
    die "nmcli is still unavailable after installing network-manager."

PAM_EXEC_PATH="$(
    find /usr/lib /lib \
        -type f -path '*/security/pam_exec.so' \
        -print -quit 2>/dev/null
)"

[[ -n "$PAM_EXEC_PATH" ]] || \
    die "pam_exec.so is still unavailable after installing libpam-modules."

log "Found pam_exec module: $PAM_EXEC_PATH"

log "Installing the Wi-Fi reset command"

cat > "$RESET_COMMAND" <<'RESET_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_USER="schuler"
LOCK_FILE="/run/lock/schuler-session-wifi-reset.lock"
TAG="schuler-wifi-reset"

log() {
    logger -t "$TAG" -- "$*"
}

# PAM executes this for all users in the selected display-manager stack.
# Other accounts must remain completely untouched.
if [[ "${PAM_USER:-$TARGET_USER}" != "$TARGET_USER" ]]; then
    exit 0
fi

case "${PAM_TYPE:-manual}" in
    open_session|close_session|manual)
        ;;
    *)
        exit 0
        ;;
esac

if [[ $EUID -ne 0 ]]; then
    log "Reset refused because the command is not running as root."
    exit 1
fi

install -d -m 0755 /run/lock
exec 9>"$LOCK_FILE"

if ! flock -w 30 9; then
    log "Could not acquire the Wi-Fi reset lock."
    exit 1
fi

log "Starting complete Wi-Fi reset for PAM type ${PAM_TYPE:-manual}."

# NetworkManager may be inactive on systems using another network service.
# In that case, still erase known keyfiles and iwd credentials below.
if systemctl is-active --quiet NetworkManager.service; then
    # Disable autoconnect first, preventing a profile from reconnecting while
    # the other profiles are being removed.
    while IFS=: read -r uuid type; do
        case "$type" in
            wifi|802-11-wireless)
                nmcli connection modify uuid "$uuid" connection.autoconnect no \
                    >/dev/null 2>&1 || true
                ;;
        esac
    done < <(nmcli --terse --escape no --fields UUID,TYPE connection show 2>/dev/null || true)

    # Disconnect every currently active Wi-Fi interface.
    while IFS=: read -r device type; do
        case "$type" in
            wifi|802-11-wireless)
                log "Disconnecting Wi-Fi device $device."
                nmcli device disconnect "$device" >/dev/null 2>&1 || true
                ;;
        esac
    done < <(nmcli --terse --escape no --fields DEVICE,TYPE device status 2>/dev/null || true)

    # Delete all persistent and in-memory Wi-Fi connection profiles known by
    # NetworkManager. Wired Ethernet and VPN profiles are not selected.
    while IFS=: read -r uuid type; do
        case "$type" in
            wifi|802-11-wireless)
                log "Deleting NetworkManager Wi-Fi profile $uuid."
                nmcli connection delete uuid "$uuid" >/dev/null 2>&1 || true
                ;;
        esac
    done < <(nmcli --terse --escape no --fields UUID,TYPE connection show 2>/dev/null || true)
fi

# Fallback cleanup for NetworkManager keyfiles. This catches a profile that
# exists on disk but was not loaded into the running daemon.
for directory in \
    /etc/NetworkManager/system-connections \
    /run/NetworkManager/system-connections
do
    [[ -d "$directory" ]] || continue

    while IFS= read -r -d '' profile; do
        if grep -Eiq \
            '^[[:space:]]*type[[:space:]]*=[[:space:]]*(wifi|802-11-wireless)[[:space:]]*$' \
            "$profile"; then
            log "Deleting Wi-Fi keyfile $profile."
            rm -f -- "$profile"
        fi
    done < <(
        find "$directory" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null
    )
done

# If NetworkManager uses iwd as its Wi-Fi backend, iwd may also retain
# credentials under /var/lib/iwd.
if [[ -d /var/lib/iwd ]]; then
    find /var/lib/iwd -mindepth 1 -maxdepth 1 -type f \
        \( -name '*.psk' -o -name '*.8021x' -o -name '*.open' \) \
        -print -delete 2>/dev/null \
        | while IFS= read -r credential; do
            log "Deleting iwd credential $credential."
        done
fi

# This file contains remembered access-point/BSSID history, not a connection
# profile, but removing it makes the reset more complete.
rm -f /var/lib/NetworkManager/seen-bssids

if systemctl is-active --quiet NetworkManager.service; then
    log "Restarting NetworkManager."
    systemctl restart NetworkManager.service

    # Leave the radio usable for schuler, but without any saved or active
    # connection. An unknown network will require a new connection/password.
    nmcli radio wifi on >/dev/null 2>&1 || true

    # Give NetworkManager a short period to settle, then ensure it did not
    # reactivate a remaining Wi-Fi profile.
    sleep 2

    while IFS=: read -r name type; do
        case "$type" in
            wifi|802-11-wireless)
                log "Unexpected active Wi-Fi connection '$name'; deactivating it."
                nmcli connection down "$name" >/dev/null 2>&1 || true
                ;;
        esac
    done < <(
        nmcli --terse --escape no --fields NAME,TYPE connection show --active \
            2>/dev/null || true
    )
fi

log "Complete Wi-Fi reset finished."
exit 0
RESET_SCRIPT

chmod 0755 "$RESET_COMMAND"
chown root:root "$RESET_COMMAND"

# Prevent schuler's systemd user manager from being deliberately kept alive
# after logout. This does not affect the administrator account.
loginctl disable-linger "$TARGET_USER" >/dev/null 2>&1 || true

PAM_FILES=(
    /etc/pam.d/gdm-password
    /etc/pam.d/lightdm
    /etc/pam.d/sddm
)

FOUND_PAM_FILE=false

install_hook() {
    local pam_file="$1"
    local temporary

    [[ -f "$pam_file" ]] || return 0
    FOUND_PAM_FILE=true

    log "Installing the login/logout hook in $pam_file"

    cp -a "$pam_file" "${pam_file}.before-schuler-wifi-reset"

    temporary="$(mktemp)"

    # Remove an older copy of our marked block, making the installer safe
    # to run more than once.
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
        $0 == begin {skip=1; next}
        $0 == end   {skip=0; next}
        !skip       {print}
    ' "$pam_file" > "$temporary"

    cat >> "$temporary" <<EOF

$MARKER_BEGIN
# The open-session hook is required: schuler should not enter the desktop
# when the required network cleanup fails.
session required pam_exec.so quiet type=open_session $RESET_COMMAND

# The close-session hook is best-effort, so a cleanup error cannot prevent
# the user from logging out.
session optional pam_exec.so quiet type=close_session $RESET_COMMAND
$MARKER_END
EOF

    install -o root -g root -m 0644 "$temporary" "$pam_file"
    rm -f "$temporary"
}

for pam_file in "${PAM_FILES[@]}"; do
    install_hook "$pam_file"
done

if [[ "$FOUND_PAM_FILE" != true ]]; then
    die "No supported graphical-login PAM file was found. Expected GDM, LightDM, or SDDM."
fi

log "Checking the PAM files"
if command -v pam-auth-update >/dev/null 2>&1; then
    pam-auth-update --package >/dev/null 2>&1 || true
fi

cat <<'EOF'

Installation completed.

New behaviour:
  itm connects to Wi-Fi
  -> itm logs out
  -> schuler starts graphical login
  -> Wi-Fi is disconnected
  -> all saved Wi-Fi profiles are deleted
  -> NetworkManager restarts
  -> schuler enters the desktop disconnected

The reset also runs when schuler logs out.

Reboot once before testing:
  sudo reboot

View reset logs:
  journalctl -t schuler-wifi-reset -b

List saved connections:
  sudo nmcli -f NAME,UUID,TYPE connection show

Manually test the reset from itm (this immediately disconnects Wi-Fi):
  sudo env PAM_USER=schuler PAM_TYPE=manual \
    /usr/local/sbin/reset-wifi-for-schuler-session

To remove the hook, restore the PAM backup for the display manager in use.
For GDM:
  sudo cp /etc/pam.d/gdm-password.before-schuler-wifi-reset \
          /etc/pam.d/gdm-password

For LightDM:
  sudo cp /etc/pam.d/lightdm.before-schuler-wifi-reset \
          /etc/pam.d/lightdm

For SDDM:
  sudo cp /etc/pam.d/sddm.before-schuler-wifi-reset \
          /etc/pam.d/sddm

Then remove the command:
  sudo rm -f /usr/local/sbin/reset-wifi-for-schuler-session

IMPORTANT:
A normal Linux desktop has one system network state shared by all logged-in
users. If itm remains logged in while schuler logs in, itm will also lose the
Wi-Fi connection.
EOF
