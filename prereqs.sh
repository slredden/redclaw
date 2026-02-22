#!/bin/bash
set -euo pipefail

# ============================================================================
# Openclaw System Prerequisites
# Run as an admin user (sudo required). Installs system-level dependencies
# once per server. Run add-bot.sh to set up individual bot user accounts.
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
    echo "Usage: $(basename "$0") [--force]"
    echo ""
    echo "Installs system prerequisites for Openclaw (Node.js, tools, openclaw)."
    echo "Safe to run multiple times — skips steps already completed."
    echo ""
    echo "Options:"
    echo "  --force     Re-run even if prerequisites were already installed"
    echo "  -h, --help  Show this help message"
    echo ""
    echo "After this completes, use add-bot.sh to set up each bot user account:"
    echo "  sudo ./add-bot.sh --bot-user <username>"
    exit 1
}

FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=true; shift ;;
        --bot-user|--skip-system)
            err "'$1' is no longer a valid option for prereqs.sh."
            err "Per-user setup has moved to add-bot.sh:"
            err "  sudo ./add-bot.sh --bot-user <username>"
            exit 1 ;;
        -h|--help)
            usage ;;
        *)
            err "Unknown argument: $1"; usage ;;
    esac
done

# --- Check sudo access ---
if ! sudo -v 2>/dev/null; then
    err "This script requires sudo access. Run as an admin user."
    exit 1
fi

# --- Idempotency sentinel ---
SENTINEL="/etc/openclaw-prereqs-done"
SENTINEL_VERSION="1"

if [ -f "$SENTINEL" ] && ! $FORCE; then
    echo ""
    echo "System prerequisites already installed."
    grep -E "version|date" "$SENTINEL" 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "  openclaw: $(openclaw --version 2>/dev/null | head -1)"
    echo "  node:     $(node --version 2>/dev/null)"
    echo ""
    echo "To re-run anyway: sudo ./prereqs.sh --force"
    echo ""
    echo "Next: set up a bot user account:"
    echo "  sudo ./add-bot.sh --bot-user <username>"
    echo ""
    exit 0
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
# Openclaw system-wide install
# ============================================================================
#
# Openclaw is installed ONCE as root, shared across all bot users.
# Each user still gets their own config at ~/.openclaw/ and their own
# gateway process via systemd --user.
#
# NOTE: `openclaw update` does NOT work for npm installs. To update, run:
#   sudo npm install -g openclaw@latest
#   (then restart each user's gateway: openclaw gateway restart)

step "Installing Openclaw system-wide"

if command -v openclaw &> /dev/null; then
    ok "Openclaw already installed: $(openclaw --version 2>/dev/null | head -1)"
    info "To update Openclaw: sudo npm install -g openclaw@latest"
    info "  (Do NOT use 'openclaw update' — it doesn't work for npm installs)"
else
    sudo npm install -g openclaw@latest
    ok "Openclaw installed: $(openclaw --version 2>/dev/null | head -1)"
fi

# --- Write sentinel ---
sudo tee "$SENTINEL" > /dev/null <<EOF
version=${SENTINEL_VERSION}
date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
node=$(node --version)
openclaw=$(openclaw --version 2>/dev/null | head -1)
EOF

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         System Prerequisites Installed                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Node.js:   $(node --version)"
echo "  npm:       $(npm --version)"
echo "  openclaw:  $(openclaw --version 2>/dev/null | head -1) (system-wide)"
echo "  jq:        $(jq --version 2>/dev/null)"
echo "  curl:      $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
echo "  envsubst:  $(envsubst --version 2>/dev/null | head -1 || echo 'available')"
echo "  openssl:   $(openssl version 2>/dev/null)"
echo ""
echo "Next: set up each bot user account:"
echo "  sudo ./add-bot.sh --bot-user <username>"
echo ""
echo "To add a user that doesn't exist yet:"
echo "  sudo ./add-bot.sh --bot-user <username> --create-user"
echo ""
