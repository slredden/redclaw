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
echo "Next steps:"
echo "  1. Switch to the standard user that will run Openclaw:"
echo "     su - <bot-user>"
echo "  2. Run the setup script:"
echo "     cd $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) && ./setup.sh"
echo ""
