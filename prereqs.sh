#!/bin/bash
set -euo pipefail

# ============================================================================
# Openclaw System Prerequisites
# Run as an admin user (sudo required). Installs system-level dependencies.
# After this completes, switch to the standard user and run setup.sh.
# ============================================================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()  { echo -e "\n${GREEN}==>${NC} $1"; }

# --- Argument parsing ---
usage() {
    echo "Usage: $(basename "$0") --bot-user <username>"
    echo ""
    echo "Installs system prerequisites, then copies this repo to the bot user's home."
    exit 1
}

BOT_USER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bot-user)
            [[ -z "${2:-}" ]] && { err "--bot-user requires a username"; usage; }
            BOT_USER="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            err "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$BOT_USER" ]] && { err "Missing required argument: --bot-user <username>"; usage; }

if ! id "$BOT_USER" &>/dev/null; then
    err "User '$BOT_USER' does not exist. Create it first (adduser $BOT_USER)."
    exit 1
fi

BOT_USER_HOME=$(getent passwd "$BOT_USER" | cut -d: -f6)

# --- Check sudo access ---
if ! sudo -v 2>/dev/null; then
    err "This script requires sudo access. Run as an admin user."
    exit 1
fi

# --- Check OS ---
step "Checking system"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        warn "This script is designed for Ubuntu/Debian. Detected: $PRETTY_NAME"
        warn "Proceeding anyway, but some steps may fail."
    else
        ok "OS: $PRETTY_NAME"
    fi
else
    warn "Cannot detect OS. Proceeding anyway."
fi

# --- Node.js >= 22 ---
step "Checking Node.js"

NEED_NODE=false
if command -v node &> /dev/null; then
    NODE_VER=$(node --version)
    NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v\([0-9]*\).*/\1/')
    if [ "$NODE_MAJOR" -ge 22 ]; then
        ok "Node.js: $NODE_VER (meets v22+ requirement)"
    else
        warn "Node.js $NODE_VER found but v22+ required"
        NEED_NODE=true
    fi
else
    info "Node.js not found"
    NEED_NODE=true
fi

if $NEED_NODE; then
    step "Installing Node.js v22 via NodeSource"
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
    ok "Node.js installed: $(node --version)"
fi

# --- npm (comes with Node.js) ---
step "Checking npm"

if command -v npm &> /dev/null; then
    ok "npm: $(npm --version)"
else
    err "npm not found -- it should have been installed with Node.js"
    err "Try: sudo apt-get install -y nodejs"
    exit 1
fi

# --- System tools: jq, curl, gettext-base (envsubst), openssl ---
step "Checking system tools"

TOOLS_TO_INSTALL=()

for tool in jq curl envsubst openssl; do
    if command -v "$tool" &> /dev/null; then
        case $tool in
            jq)       ok "jq: $(jq --version 2>/dev/null)" ;;
            curl)     ok "curl: $(curl --version 2>/dev/null | head -1)" ;;
            envsubst) ok "envsubst: available (gettext-base)" ;;
            openssl)  ok "openssl: $(openssl version 2>/dev/null)" ;;
        esac
    else
        info "$tool not found -- will install"
        case $tool in
            envsubst) TOOLS_TO_INSTALL+=("gettext-base") ;;
            *)        TOOLS_TO_INSTALL+=("$tool") ;;
        esac
    fi
done

if [ ${#TOOLS_TO_INSTALL[@]} -gt 0 ]; then
    step "Installing missing tools: ${TOOLS_TO_INSTALL[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${TOOLS_TO_INSTALL[@]}"
    ok "Tools installed"
fi

# ============================================================================
# Enable systemd lingering for the bot user
# ============================================================================

step "Enabling systemd lingering"

if loginctl show-user "$BOT_USER" --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
    ok "Lingering already enabled for ${BOT_USER}"
else
    sudo loginctl enable-linger "$BOT_USER"
    ok "Lingering enabled for ${BOT_USER} (systemd user services will persist across logouts)"
fi

# ============================================================================
# Copy repo to bot user's home
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${BOT_USER_HOME}/redbot-provision"

step "Copying repo to ${DEST_DIR}"

if [[ -d "$DEST_DIR" ]]; then
    warn "Destination already exists — replacing it"
    sudo rm -rf "$DEST_DIR"
fi

sudo mkdir -p "$DEST_DIR"
tar -C "$SCRIPT_DIR" --exclude='.git' --exclude='.env' --exclude='.claude' -cf - . \
    | sudo tar -C "$DEST_DIR" -xf -
sudo chown -R "${BOT_USER}:${BOT_USER}" "$DEST_DIR"
ok "Repo copied to ${DEST_DIR}"

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Prerequisites Installed                       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Node.js:   $(node --version)"
echo "  npm:       $(npm --version)"
echo "  jq:        $(jq --version 2>/dev/null)"
echo "  curl:      $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
echo "  envsubst:  $(envsubst --version 2>/dev/null | head -1 || echo 'available')"
echo "  openssl:   $(openssl version 2>/dev/null)"
echo ""
echo "Repo copied to: ${DEST_DIR}"
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                   IMPORTANT                                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Systemd lingering was just enabled for ${BOT_USER}."
echo "For systemd user services to work properly, ${BOT_USER} must"
echo "log out and back in (or reboot) before running setup.sh."
echo ""
echo "Next steps:"
echo "  1. Log in as the bot user (fresh login session):"
echo "     exit        # if currently su'd"
echo "     ssh ${BOT_USER}@localhost"
echo "     (or: log out completely and SSH back in as ${BOT_USER})"
echo ""
echo "  2. Set up the environment:"
echo "     cd ~/redbot-provision"
echo "     cp .env.example .env"
echo "     nano .env"
echo ""
echo "  3. Run the setup script:"
echo "     ./setup.sh"
echo ""
