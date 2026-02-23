#!/bin/bash
set -euo pipefail

# ============================================================================
# Add Bot User
# Run as an admin user (sudo required). Prepares a user account to run
# an Openclaw bot. Requires prereqs.sh to have been run first.
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
    echo "Usage: $(basename "$0") --bot-user <username> [--create-user]"
    echo ""
    echo "Prepares a user account to run an Openclaw bot."
    echo "Requires prereqs.sh to have been run first (system-wide install)."
    echo ""
    echo "Options:"
    echo "  --bot-user <username>   Bot user account to prepare (required)"
    echo "  --create-user           Create the user account if it doesn't exist"
    echo "  -h, --help              Show this help message"
    exit 1
}

BOT_USER=""
CREATE_USER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bot-user)
            [[ -z "${2:-}" ]] && { err "--bot-user requires a username"; usage; }
            BOT_USER="$2"; shift 2 ;;
        --create-user)
            CREATE_USER=true; shift ;;
        -h|--help)
            usage ;;
        *)
            err "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$BOT_USER" ]] && { err "Missing required argument: --bot-user <username>"; usage; }

# --- Check sudo access ---
if ! sudo -v 2>/dev/null; then
    err "This script requires sudo access. Run as an admin user."
    exit 1
fi

# --- Check Openclaw is installed system-wide ---
step "Checking system-wide Openclaw"

if ! command -v openclaw &> /dev/null; then
    err "Openclaw not found. Run prereqs.sh first:"
    err "  sudo ./prereqs.sh"
    exit 1
fi
ok "Openclaw: $(openclaw --version 2>/dev/null | head -1) ($(which openclaw))"

# --- Optionally create user ---
if $CREATE_USER; then
    step "Creating user: ${BOT_USER}"
    if id "$BOT_USER" &>/dev/null; then
        ok "User '${BOT_USER}' already exists"
    else
        sudo adduser --disabled-password --gecos "" "$BOT_USER"
        ok "User '${BOT_USER}' created"
    fi
fi

# --- Verify user exists ---
if ! id "$BOT_USER" &>/dev/null; then
    err "User '${BOT_USER}' does not exist."
    err "Create it first (sudo adduser ${BOT_USER}), or pass --create-user."
    exit 1
fi

BOT_USER_HOME=$(getent passwd "$BOT_USER" | cut -d: -f6)

# --- Enable systemd lingering ---
step "Enabling systemd lingering for ${BOT_USER}"

if loginctl show-user "$BOT_USER" --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
    ok "Lingering already enabled for ${BOT_USER}"
else
    sudo loginctl enable-linger "$BOT_USER"
    ok "Lingering enabled for ${BOT_USER} (systemd user services will persist across logouts)"
fi

# --- Copy repo to bot user's home ---
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

# --- Summary ---
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Bot User Ready                                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Bot user:  ${BOT_USER}"
echo "  Repo:      ${DEST_DIR}"
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                   IMPORTANT                                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Systemd lingering was just enabled for ${BOT_USER}."
echo "For systemd user services to work, ${BOT_USER} must log in"
echo "via a fresh SSH session (not su) before running setup.sh."
echo ""
echo "Next steps:"
echo "  1. Log in as the bot user (fresh SSH session — not 'su'):"
echo "       ssh ${BOT_USER}@localhost"
echo ""
echo "  2. Authenticate with OpenAI:"
echo "       openclaw onboard --auth-choice openai-codex --skip-daemon"
echo ""
echo "  3. Set up your .env config:"
echo "       cd ~/redbot-provision"
echo "       cp .env.example .env"
echo "       nano .env"
echo ""
echo "     Fill in bot name, email, and your tokens. To extract tokens:"
echo "       jq -r '.profiles[\"openai-codex:default\"].access' \\"
echo "         ~/.openclaw/agents/main/agent/auth-profiles.json"
echo "       jq -r '.profiles[\"openai-codex:default\"].refresh' \\"
echo "         ~/.openclaw/agents/main/agent/auth-profiles.json"
echo "     Copy each output into OPENAI_ACCESS_TOKEN / OPENAI_REFRESH_TOKEN in .env."
echo ""
echo "     Optional: fill in TELEGRAM_BOT_TOKEN, TELEGRAM_USER_ID, and"
echo "     BRAVE_SEARCH_KEY in .env now if you want those features."
echo ""
echo "  4. Run setup:"
echo "       ./setup.sh"
echo "     Save the gateway URL printed at the end — it has your dashboard password."
echo ""
echo "  NOTE: If this is an additional bot user, GATEWAY_PORT must be unique."
echo "  Check what's already in use: ss -tuln | grep 187"
echo "  Use the next available port (e.g., 18790, 18791, ...)"
echo ""
