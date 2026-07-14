#!/usr/bin/env bash
#
# Install an automatic "reset user home at every boot" service on Debian.
#
# Account layout expected by this version:
#   itm      = administrator account; never reset by this script
#   schuler  = student account; restored at every boot
#
# System-wide Wi-Fi profiles are preserved by default because deleting files
# under /etc/NetworkManager/system-connections would also affect the itm admin.

# Usage:
#   sudo ./install_schuler_home_reset.sh
#
# Example:
#   sudo ./install_schuler_home_reset.sh
#
# Optional: use a different prepared directory as the default home:
#   sudo ./install_schuler_home_reset.sh /path/to/prepared-default-home
#
# IMPORTANT:
#   The selected user's home directory will be restored from the saved
#   template at every boot. Any changes made after login will be erased
#   at the next restart.
#
set -Eeuo pipefail

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    printf '\n==> %s\n' "$*"
}

[[ $EUID -eq 0 ]] || die "Run this installer with sudo."

USERNAME_TO_RESET="${1:-schuler}"
SOURCE_DIR="${2:-}"

[[ -n "$USERNAME_TO_RESET" ]] || {
    echo "Usage: sudo $0 [USERNAME] [DEFAULT_HOME_SOURCE]" >&2
    exit 2
}

[[ "$USERNAME_TO_RESET" != "root" ]] || die "Refusing to configure this for root."
[[ "$USERNAME_TO_RESET" != "itm" ]] || die "Refusing to reset the administrator account 'itm'."

PASSWD_ENTRY="$(getent passwd "$USERNAME_TO_RESET" || true)"
[[ -n "$PASSWD_ENTRY" ]] || die "User '$USERNAME_TO_RESET' does not exist."

USER_UID="$(cut -d: -f3 <<<"$PASSWD_ENTRY")"
USER_GID="$(cut -d: -f4 <<<"$PASSWD_ENTRY")"
USER_HOME="$(cut -d: -f6 <<<"$PASSWD_ENTRY")"
PRIMARY_GROUP="$(getent group "$USER_GID" | cut -d: -f1)"

[[ -n "$USER_HOME" && "$USER_HOME" != "/" ]] || die "Unsafe home directory: '$USER_HOME'"
[[ -d "$USER_HOME" ]] || die "Home directory does not exist: $USER_HOME"

if [[ -z "$SOURCE_DIR" ]]; then
    SOURCE_DIR="$USER_HOME"
fi

SOURCE_DIR="$(realpath -e "$SOURCE_DIR")"
USER_HOME_REAL="$(realpath -e "$USER_HOME")"

[[ -d "$SOURCE_DIR" ]] || die "Default-home source is not a directory: $SOURCE_DIR"

TEMPLATE_DIR="/var/lib/home-reset/$USERNAME_TO_RESET"
CONFIG_FILE="/etc/default/reset-user-home"
RESET_PROGRAM="/usr/local/sbin/reset-user-home-at-boot"
SAVE_PROGRAM="/usr/local/sbin/save-user-home-default"
SERVICE_FILE="/etc/systemd/system/reset-user-home.service"

log "Installing rsync if necessary"
if ! command -v rsync >/dev/null 2>&1; then
    apt-get update
    apt-get install -y rsync
fi

log "Creating pristine home template at $TEMPLATE_DIR"
install -d -m 0700 -o root -g root /var/lib/home-reset
install -d -m 0700 -o root -g root "$TEMPLATE_DIR"

# Copy the prepared home to the protected template.
# -aHAX preserves normal metadata, hard links, ACLs and extended attributes.
# -x avoids crossing into separately mounted filesystems.
rsync -aHAXx --delete --delete-excluded \
    "$SOURCE_DIR"/ "$TEMPLATE_DIR"/

# The template is protected from the normal user.
chown -R root:root "$TEMPLATE_DIR"
chmod 0700 "$TEMPLATE_DIR"

log "Writing configuration"
cat > "$CONFIG_FILE" <<EOF
USER_NAME="$USERNAME_TO_RESET"
USER_HOME="$USER_HOME_REAL"
TEMPLATE_DIR="$TEMPLATE_DIR"
RESET_WIFI="no"
EOF
chmod 0600 "$CONFIG_FILE"

log "Installing the boot reset program"
cat > "$RESET_PROGRAM" <<'RESET_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/default/reset-user-home"
DISABLE_FILE="/etc/home-reset.disabled"

log() {
    printf '%s\n' "reset-user-home: $*"
}

[[ -r "$CONFIG_FILE" ]] || {
    log "Configuration not found; refusing to continue."
    exit 1
}

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -e "$DISABLE_FILE" ]]; then
    log "Reset disabled because $DISABLE_FILE exists."
    exit 0
fi

: "${USER_NAME:?Missing USER_NAME}"
: "${USER_HOME:?Missing USER_HOME}"
: "${TEMPLATE_DIR:?Missing TEMPLATE_DIR}"
: "${RESET_WIFI:=yes}"

[[ "$USER_NAME" != "root" ]] || {
    log "Refusing to reset root."
    exit 1
}

[[ "$USER_HOME" == /home/* ]] || {
    log "Unsafe home path: $USER_HOME"
    exit 1
}

[[ -d "$TEMPLATE_DIR" ]] || {
    log "Template directory is missing: $TEMPLATE_DIR"
    exit 1
}

PASSWD_ENTRY="$(getent passwd "$USER_NAME" || true)"
[[ -n "$PASSWD_ENTRY" ]] || {
    log "User does not exist: $USER_NAME"
    exit 1
}

USER_UID="$(cut -d: -f3 <<<"$PASSWD_ENTRY")"
USER_GID="$(cut -d: -f4 <<<"$PASSWD_ENTRY")"

# This service is intended to run before user sessions are allowed.
if pgrep -u "$USER_UID" >/dev/null 2>&1; then
    log "User processes are already running; refusing an unsafe reset."
    exit 1
fi

log "Restoring $USER_HOME from $TEMPLATE_DIR"

install -d -m 0700 -o "$USER_UID" -g "$USER_GID" "$USER_HOME"

# --delete removes files created during the previous session.
# -x prevents traversal into other mounted filesystems under the home.
rsync -aHAXx --delete --delete-excluded \
    "$TEMPLATE_DIR"/ "$USER_HOME"/

# The protected template is root-owned, so assign the restored copy
# back to the selected user.
chown -R "$USER_UID:$USER_GID" "$USER_HOME"
chmod 0700 "$USER_HOME"

if [[ "$RESET_WIFI" == "yes" ]]; then
    NM_CONNECTIONS="/etc/NetworkManager/system-connections"

    if [[ -d "$NM_CONNECTIONS" ]]; then
        log "Removing saved system-wide NetworkManager connections"
        find "$NM_CONNECTIONS" -mindepth 1 -maxdepth 1 \
            -type f -delete
    fi
fi

log "Reset completed"
RESET_SCRIPT

chmod 0755 "$RESET_PROGRAM"
chown root:root "$RESET_PROGRAM"

log "Installing a command for updating the default template"
cat > "$SAVE_PROGRAM" <<'SAVE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/default/reset-user-home"

[[ $EUID -eq 0 ]] || {
    echo "Run this command with sudo." >&2
    exit 1
}

[[ -r "$CONFIG_FILE" ]] || {
    echo "Missing configuration: $CONFIG_FILE" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if pgrep -u "$(id -u "$USER_NAME")" >/dev/null 2>&1; then
    echo "The user '$USER_NAME' is logged in." >&2
    echo "Log out first, then run this command from another administrator account or a TTY." >&2
    exit 1
fi

echo "Saving $USER_HOME as the new default template..."

rsync -aHAXx --delete --delete-excluded \
    "$USER_HOME"/ "$TEMPLATE_DIR"/

chown -R root:root "$TEMPLATE_DIR"
chmod 0700 "$TEMPLATE_DIR"

echo "Default template updated."
SAVE_SCRIPT

chmod 0755 "$SAVE_PROGRAM"
chown root:root "$SAVE_PROGRAM"

log "Installing the systemd boot service"
cat > "$SERVICE_FILE" <<'UNIT'
[Unit]
Description=Restore default user home and remove saved Wi-Fi profiles
Documentation=man:rsync(1)
DefaultDependencies=no
Wants=local-fs.target
After=local-fs.target
Before=systemd-user-sessions.service
Before=display-manager.service
Before=NetworkManager.service
ConditionPathExists=/etc/default/reset-user-home

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/reset-user-home-at-boot
TimeoutStartSec=10min
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT

chmod 0644 "$SERVICE_FILE"

log "Enabling the reset service"
systemctl daemon-reload
systemctl enable reset-user-home.service

cat <<EOF

Installation completed.

User being reset:
  $USERNAME_TO_RESET

Home directory:
  $USER_HOME_REAL

Protected default template:
  $TEMPLATE_DIR

The reset will happen at the NEXT BOOT.

To temporarily disable the reset:
  sudo touch /etc/home-reset.disabled

To enable it again:
  sudo rm -f /etc/home-reset.disabled

To check its status after reboot:
  systemctl status reset-user-home.service

To view its boot log:
  journalctl -u reset-user-home.service -b

To permanently remove it:
  sudo systemctl disable --now reset-user-home.service
  sudo rm -f "$SERVICE_FILE"
  sudo rm -f "$RESET_PROGRAM"
  sudo rm -f "$SAVE_PROGRAM"
  sudo rm -f "$CONFIG_FILE"
  sudo systemctl daemon-reload

IMPORTANT:
Changes made by '$USERNAME_TO_RESET' will be deleted at every reboot.
Reboot only after verifying that the template contains everything you need.

EOF
