#!/usr/bin/env bash
#
# Reinstall selected applications on Debian 13.
#
# Run this script as your normal user:
#   chmod +x install_apps_debian13.sh
#   ./install_apps_debian13.sh
#
# Before running it, place the current Webex .deb file in ~/Downloads
# with a name such as Webex.deb or Webex-*.deb.
#
# Optional:
# Place vscode-extensions.txt beside this script to restore VS Code extensions.

set -Eeuo pipefail

trap 'echo "ERROR: Installation failed near line $LINENO." >&2' ERR

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

INSTALL_GNOME=true
INSTALL_XFCE=true
INSTALL_TELNET=true
INSTALL_VSCODE=true
INSTALL_WEBEX=true
RESTORE_VSCODE_EXTENSIONS=true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    printf '\n==> %s\n' "$1"
}

warn() {
    printf '\nWARNING: %s\n' "$1" >&2
}

if [[ ${EUID} -eq 0 ]]; then
    warn "Run this script as a normal user, not directly as root."
    warn "The script will use sudo when administrator access is required."
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is not installed. Log in as root and run:" >&2
    echo "  apt update && apt install sudo" >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Cannot determine the operating system." >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ ${ID:-} != "debian" ]]; then
    warn "This script was written for Debian. Detected: ${PRETTY_NAME:-unknown}"
fi

if [[ ${VERSION_ID:-} != "13" ]]; then
    warn "This script targets Debian 13. Detected: ${PRETTY_NAME:-unknown}"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
USER_HOME="$(getent passwd "$USER" | cut -d: -f6)"
ARCH="$(dpkg --print-architecture)"

log "Requesting administrator permission"
sudo -v

# Keep sudo credentials active while the script runs.
while true; do
    sudo -n true
    sleep 50
    kill -0 "$$" 2>/dev/null || exit
done &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Debian packages
# ---------------------------------------------------------------------------

log "Updating Debian package information"
sudo apt update

PACKAGES=(
    ca-certificates
    curl
    gnupg
    wget
    vlc
    thonny
    mc
    network-manager-openconnect-gnome
    7zip
    traceroute
    netcat-traditional
    lsof
    openssh-server
)

if [[ "$INSTALL_TELNET" == true ]]; then
    PACKAGES+=(telnet)
fi

if [[ "$INSTALL_GNOME" == true ]]; then
    PACKAGES+=(task-gnome-desktop)
fi

if [[ "$INSTALL_XFCE" == true ]]; then
    PACKAGES+=(task-xfce-desktop)
fi

log "Installing Debian applications"
sudo DEBIAN_FRONTEND=noninteractive apt install -y "${PACKAGES[@]}"

log "Enabling the SSH server"
sudo systemctl enable --now ssh

# ---------------------------------------------------------------------------
# Visual Studio Code
# ---------------------------------------------------------------------------

if [[ "$INSTALL_VSCODE" == true ]]; then
    case "$ARCH" in
        amd64|arm64|armhf)
            log "Adding the Microsoft Visual Studio Code repository"

            TMP_KEY="$(mktemp)"
            wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
                | gpg --dearmor > "$TMP_KEY"

            sudo install -D -o root -g root -m 644 \
                "$TMP_KEY" \
                /usr/share/keyrings/packages.microsoft.gpg

            rm -f "$TMP_KEY"

            printf '%s\n' \
                "deb [arch=$ARCH signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
                | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null

            sudo apt update
            sudo apt install -y code
            ;;
        *)
            warn "Visual Studio Code repository setup skipped on architecture: $ARCH"
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Restore Visual Studio Code extensions
# ---------------------------------------------------------------------------

EXTENSION_FILE="$SCRIPT_DIR/vscode-extensions.txt"

if [[ "$RESTORE_VSCODE_EXTENSIONS" == true ]] \
   && command -v code >/dev/null 2>&1 \
   && [[ -s "$EXTENSION_FILE" ]]; then

    log "Restoring Visual Studio Code extensions"

    while IFS= read -r extension || [[ -n "$extension" ]]; do
        [[ -z "$extension" ]] && continue

        if ! code --install-extension "$extension"; then
            warn "Could not install VS Code extension: $extension"
        fi
    done < "$EXTENSION_FILE"
fi

# ---------------------------------------------------------------------------
# Cisco Webex
# ---------------------------------------------------------------------------

if [[ "$INSTALL_WEBEX" == true ]]; then
    shopt -s nullglob nocaseglob
    WEBEX_FILES=(
        "$USER_HOME"/Downloads/Webex*.deb
        "$SCRIPT_DIR"/Webex*.deb
    )
    shopt -u nocaseglob nullglob

    if (( ${#WEBEX_FILES[@]} > 0 )); then
        WEBEX_DEB="${WEBEX_FILES[0]}"
        log "Installing Cisco Webex from: $WEBEX_DEB"
        sudo apt install -y "$WEBEX_DEB"
    else
        warn "Webex was not installed because no Webex .deb file was found."
        warn "Download the current Linux .deb and place it in:"
        warn "  $USER_HOME/Downloads/"
        warn "Then rerun this script."
    fi
fi

# ---------------------------------------------------------------------------
# Cleanup and summary
# ---------------------------------------------------------------------------

log "Installation summary"

for command_name in vlc thonny mc 7zz traceroute nc lsof ssh code; do
    if command -v "$command_name" >/dev/null 2>&1; then
        printf '  [installed] %s\n' "$command_name"
    else
        printf '  [not found] %s\n' "$command_name"
    fi
done

printf '\nInstallation completed.\n'
printf 'A logout or reboot is recommended after installing desktop environments.\n'
