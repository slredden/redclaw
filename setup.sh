#!/bin/bash
set -euo pipefail

# ============================================================================
# Openclaw Bot Provisioning Script
# Bootstraps a complete Openclaw personal AI assistant on a fresh machine.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
DRY_RUN=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()  { echo -e "\n${GREEN}==>${NC} $1"; }

# --- Argument parsing ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --env-file PATH   Path to .env file (default: .env in script directory)
  --dry-run         Show what would be done without making changes
  --help            Show this help message

Example:
  cp .env.example .env
  # Fill in your API keys and settings in .env
  ./setup.sh
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --env-file)  ENV_FILE="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --help)      usage ;;
        *)           err "Unknown option: $1"; usage ;;
    esac
done

# --- Source .env file ---
if [ ! -f "$ENV_FILE" ]; then
    err "No .env file found at: $ENV_FILE"
    echo "  Copy .env.example to .env and fill in your values:"
    echo "    cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
    exit 1
fi

# Load .env safely — auto-quote unquoted values so spaces don't break sourcing
# (e.g. USER_NAME=Stephen Redden → USER_NAME="Stephen Redden")
_safe_env=$(mktemp)
while IFS= read -r line || [[ -n "$line" ]]; do
    # Pass through blank lines and comments
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
        echo "$line" >> "$_safe_env"
        continue
    fi
    # Extract key and raw value
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
        key="${BASH_REMATCH[1]}"
        raw="${BASH_REMATCH[2]}"
        # Already quoted — pass through as-is
        if [[ "$raw" =~ ^\".*\" ]] || [[ "$raw" =~ ^\'.*\' ]]; then
            echo "${key}=${raw}" >> "$_safe_env"
        else
            # Strip inline comment (# preceded by whitespace) and trim
            val=$(echo "$raw" | sed 's/[[:space:]]\+#.*$//; s/[[:space:]]*$//')
            echo "${key}=\"${val}\"" >> "$_safe_env"
        fi
    else
        echo "$line" >> "$_safe_env"
    fi
done < "$ENV_FILE"
# shellcheck disable=SC1090
source "$_safe_env"
rm -f "$_safe_env"

# --- Validate required variables ---
REQUIRED_VARS=(
    BOT_NAME BOT_USER BOT_EMOJI
    USER_NAME USER_TIMEZONE USER_LOCATION USER_EMAIL
    NVIDIA_API_KEY MEM0_API_KEY BRAVE_SEARCH_KEY VERCEL_AI_KEY
)

missing=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing+=("$var")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    err "Missing required variables in .env:"
    for var in "${missing[@]}"; do
        echo "  - $var"
    done
    exit 1
fi

# --- Derived variables ---
export BOT_NAME BOT_USER BOT_EMOJI
export USER_NAME USER_TIMEZONE USER_LOCATION USER_EMAIL
export NVIDIA_API_KEY MEM0_API_KEY BRAVE_SEARCH_KEY VERCEL_AI_KEY
export TELEGRAM_BOT_TOKEN TELEGRAM_USER_ID
export GATEWAY_PORT="${GATEWAY_PORT:-18789}"
export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:-redbot}"

# Auto-generate gateway token if blank
if [ -z "${GATEWAY_TOKEN:-}" ]; then
    GATEWAY_TOKEN=$(openssl rand -hex 24)
    info "Auto-generated GATEWAY_TOKEN"
fi
export GATEWAY_TOKEN

# Derive lowercase bot name (spaces → hyphens for use in paths/identifiers)
BOT_NAME_LOWER=$(echo "$BOT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
export BOT_NAME_LOWER

if $DRY_RUN; then
    step "DRY RUN MODE — no changes will be made"
    echo "  BOT_NAME=$BOT_NAME"
    echo "  BOT_USER=$BOT_USER"
    echo "  BOT_NAME_LOWER=$BOT_NAME_LOWER"
    echo "  GATEWAY_PORT=$GATEWAY_PORT"
    echo "  GATEWAY_TOKEN=${GATEWAY_TOKEN:0:8}..."
    echo ""
fi

HOME_DIR="/home/${BOT_USER}"

# --- Helper: run or print command ---
run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# --- Helper: envsubst a template to a destination ---
render_template() {
    local src="$1"
    local dst="$2"
    if $DRY_RUN; then
        echo "  [dry-run] envsubst < $src > $dst"
    else
        envsubst < "$src" > "$dst"
    fi
}

# ============================================================================
# PREREQUISITES (must be installed by admin via prereqs.sh)
# ============================================================================

step "Checking prerequisites"

PREREQ_MISSING=false

# Check Node.js >= 22
if command -v node &> /dev/null; then
    NODE_VER=$(node --version)
    NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v\([0-9]*\).*/\1/')
    if [ "$NODE_MAJOR" -ge 22 ]; then
        ok "Node.js: $NODE_VER"
    else
        err "Node.js $NODE_VER found but v22+ required"
        PREREQ_MISSING=true
    fi
else
    err "Node.js not found"
    PREREQ_MISSING=true
fi

# Check npm
if command -v npm &> /dev/null; then
    ok "npm: $(npm --version)"
else
    err "npm not found"
    PREREQ_MISSING=true
fi

# Check required tools
for tool in jq curl envsubst openssl; do
    if command -v "$tool" &> /dev/null; then
        ok "$tool: available"
    else
        err "$tool not found"
        PREREQ_MISSING=true
    fi
done

if $PREREQ_MISSING; then
    echo ""
    err "Missing prerequisites. Run prereqs.sh as an admin user first:"
    echo "  sudo -u <admin> ${SCRIPT_DIR}/prereqs.sh"
    echo "  (or: log in as admin and run ./prereqs.sh)"
    exit 1
fi

# ============================================================================
# OPENCLAW INSTALLATION
# ============================================================================

step "Installing Openclaw"

# Ensure user-local npm prefix is on PATH
NPM_GLOBAL="${HOME_DIR}/.npm-global"
export PATH="${NPM_GLOBAL}/bin:${PATH}"

if command -v openclaw &> /dev/null; then
    ok "Openclaw already installed: $(openclaw --version 2>/dev/null | head -1)"
else
    run npm install -g --prefix "${NPM_GLOBAL}" openclaw@latest
    if ! $DRY_RUN; then
        ok "Openclaw installed: $(openclaw --version 2>/dev/null | head -1)"
    fi
fi

# Skip interactive onboarding — our config generation handles everything.
# Just create the directory structure that onboarding would create.
run mkdir -p "${HOME_DIR}/.openclaw/workspace"
run mkdir -p "${HOME_DIR}/.openclaw/agents/main/sessions"
ok "Openclaw directory structure created"

# ============================================================================
# CONFIGURATION
# ============================================================================

step "Generating configuration"

# Create directory structure
run mkdir -p "${HOME_DIR}/.openclaw"
run mkdir -p "${HOME_DIR}/.openclaw/agents/main/agent"
run mkdir -p "${HOME_DIR}/.openclaw/credentials"
run mkdir -p "${HOME_DIR}/.openclaw/cron"

# Main config
render_template "${SCRIPT_DIR}/templates/openclaw.json.tmpl" "${HOME_DIR}/.openclaw/openclaw.json"
if ! $DRY_RUN; then
    chmod 600 "${HOME_DIR}/.openclaw/openclaw.json"
    ok "openclaw.json generated (mode 600)"

    # Disable Telegram in config if token not provided
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
        jq '.channels.telegram.enabled = false | .plugins.entries.telegram.enabled = false' \
            "${HOME_DIR}/.openclaw/openclaw.json" > "${HOME_DIR}/.openclaw/openclaw.json.tmp" \
            && mv "${HOME_DIR}/.openclaw/openclaw.json.tmp" "${HOME_DIR}/.openclaw/openclaw.json"
        chmod 600 "${HOME_DIR}/.openclaw/openclaw.json"
        info "Telegram not configured -- disabled in config (add token later to enable)"
    fi
fi

# Auth profiles
render_template "${SCRIPT_DIR}/templates/auth-profiles.json.tmpl" \
    "${HOME_DIR}/.openclaw/agents/main/agent/auth-profiles.json"
if ! $DRY_RUN; then
    chmod 600 "${HOME_DIR}/.openclaw/agents/main/agent/auth-profiles.json"
    ok "auth-profiles.json generated (mode 600)"
fi

# ============================================================================
# EXTENSIONS
# ============================================================================

step "Installing extensions"

EXTENSIONS=(
    "@mem0/openclaw-mem0"
)

for ext in "${EXTENSIONS[@]}"; do
    ext_name=$(echo "$ext" | sed 's/.*\///')
    if [ -d "${HOME_DIR}/.openclaw/extensions/${ext_name}" ]; then
        ok "${ext_name}: already installed"
    else
        info "Installing ${ext_name}..."
        if ! run openclaw plugins install "$ext" 2>/dev/null; then
            warn "${ext_name}: install failed — removing from config"
            # Remove plugin references so config stays valid
            jq 'del(.plugins.entries["openclaw-mem0"]) |
                if .plugins.slots.memory == "openclaw-mem0" then del(.plugins.slots.memory) else . end' \
                "${HOME_DIR}/.openclaw/openclaw.json" > "${HOME_DIR}/.openclaw/openclaw.json.tmp" \
                && mv "${HOME_DIR}/.openclaw/openclaw.json.tmp" "${HOME_DIR}/.openclaw/openclaw.json"
            chmod 600 "${HOME_DIR}/.openclaw/openclaw.json"
        fi
    fi
done

# ============================================================================
# GOG (Google Workspace CLI)
# ============================================================================

step "Installing gog (Google Workspace CLI)"

GOG_VERSION="0.10.0"
GOG_BIN="${HOME_DIR}/.npm-global/bin/gog"

if [ -x "$GOG_BIN" ]; then
    ok "gog already installed: $($GOG_BIN --version 2>/dev/null | head -1)"
else
    GOG_ARCH=$(uname -m)
    case "$GOG_ARCH" in
        x86_64)  GOG_ARCH="amd64" ;;
        aarch64) GOG_ARCH="arm64" ;;
        *)       err "Unsupported architecture: $GOG_ARCH"; exit 1 ;;
    esac
    GOG_URL="https://github.com/steipete/gogcli/releases/download/v${GOG_VERSION}/gogcli_${GOG_VERSION}_linux_${GOG_ARCH}.tar.gz"
    if $DRY_RUN; then
        echo "  [dry-run] Would download gog from ${GOG_URL}"
    else
        info "Downloading gog v${GOG_VERSION}..."
        curl -fsSL "$GOG_URL" -o /tmp/gogcli.tar.gz
        tar -xzf /tmp/gogcli.tar.gz -C /tmp/ gog
        mv /tmp/gog "$GOG_BIN"
        chmod +x "$GOG_BIN"
        rm -f /tmp/gogcli.tar.gz
        ok "gog installed: $($GOG_BIN --version 2>/dev/null | head -1)"
    fi
fi

# ============================================================================
# WORKSPACE
# ============================================================================

step "Setting up workspace"

WORKSPACE="${HOME_DIR}/.openclaw/workspace"
run mkdir -p "${WORKSPACE}/memory"
run mkdir -p "${WORKSPACE}/skills"

# Templated files
render_template "${SCRIPT_DIR}/workspace/USER.md.tmpl" "${WORKSPACE}/USER.md"
render_template "${SCRIPT_DIR}/workspace/IDENTITY.md.tmpl" "${WORKSPACE}/IDENTITY.md"

# Copy static files (only if not already present, to preserve customizations)
for file in SOUL.md AGENTS.md TOOLS.md HEARTBEAT.md; do
    if [ ! -f "${WORKSPACE}/${file}" ]; then
        run cp "${SCRIPT_DIR}/workspace/${file}" "${WORKSPACE}/${file}"
        ok "${file}: copied"
    else
        ok "${file}: already exists (preserved)"
    fi
done

# Copy skills
if [ -d "${SCRIPT_DIR}/workspace/skills/" ]; then
    run cp -r "${SCRIPT_DIR}/workspace/skills/"* "${WORKSPACE}/skills/" 2>/dev/null || true
    ok "Skills copied"
fi

ok "Workspace ready"

# ============================================================================
# AUTOMATION SCRIPTS
# ============================================================================

step "Installing automation scripts"

# Scripts that go to ~/
for script in backup.sh watchdog.sh status.sh; do
    dst="${HOME_DIR}/${script}"
    if [ ! -f "$dst" ]; then
        render_template "${SCRIPT_DIR}/scripts/${script}" "$dst"
        run chmod +x "$dst"
        ok "${script} → ~/${script}"
    else
        ok "${script}: already exists (preserved)"
    fi
done

# rotate-config goes to ~/.openclaw/
dst="${HOME_DIR}/.openclaw/rotate-config.sh"
if [ ! -f "$dst" ]; then
    render_template "${SCRIPT_DIR}/scripts/rotate-config.sh" "$dst"
    run chmod +x "$dst"
    ok "rotate-config.sh → ~/.openclaw/rotate-config.sh"
else
    ok "rotate-config.sh: already exists (preserved)"
fi

# ============================================================================
# SYSTEMD SERVICE
# ============================================================================

step "Setting up systemd service"

# Ensure systemd user session variables are set (needed after loginctl enable-linger
# when the current shell predates the user manager starting)
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi

SYSTEMD_DIR="${HOME_DIR}/.config/systemd/user"
run mkdir -p "$SYSTEMD_DIR"

render_template "${SCRIPT_DIR}/templates/openclaw-gateway.service.tmpl" \
    "${SYSTEMD_DIR}/openclaw-gateway.service"

if ! $DRY_RUN; then
    if systemctl --user daemon-reload 2>/dev/null; then
        systemctl --user enable openclaw-gateway.service
        ok "openclaw-gateway.service enabled"
    else
        warn "systemd user services unavailable — skipping service enable"
        warn "You may need to enable lingering: sudo loginctl enable-linger ${BOT_USER}"
        warn "Then log out and back in so the systemd user manager starts"
    fi
fi

# ============================================================================
# CRON JOBS
# ============================================================================

step "Setting up cron jobs"

# System crontab entries
add_cron_if_missing() {
    local pattern="$1"
    local entry="$2"
    local existing
    existing=$(crontab -l 2>/dev/null || true)
    if echo "$existing" | grep -qF "$pattern"; then
        ok "Cron: '$pattern' already present"
    else
        if $DRY_RUN; then
            echo "  [dry-run] Would add cron: $entry"
        else
            (echo "$existing"; echo "$entry") | crontab -
            ok "Cron: added '$pattern'"
        fi
    fi
}

add_cron_if_missing "backup.sh" \
    "0 3 * * * ${HOME_DIR}/backup.sh >> ${HOME_DIR}/${BOT_NAME_LOWER}-backups/backup.log 2>&1"

add_cron_if_missing "rotate-config.sh" \
    "0 2 * * 0 ${HOME_DIR}/.openclaw/rotate-config.sh >> /dev/null 2>&1"

add_cron_if_missing "watchdog.sh" \
    "*/5 * * * * ${HOME_DIR}/watchdog.sh"

# Openclaw internal cron jobs
render_template "${SCRIPT_DIR}/cron/jobs.json.tmpl" "${HOME_DIR}/.openclaw/cron/jobs.json"
ok "Openclaw cron jobs installed"

# ============================================================================
# SHELL PROFILE
# ============================================================================

step "Configuring shell profile"

BASHRC="${HOME_DIR}/.bashrc"
MARKER="# --- openclaw-provision ---"

if ! grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
    if $DRY_RUN; then
        echo "  [dry-run] Would append Openclaw config to ~/.bashrc"
    else
        cat >> "$BASHRC" <<EOF

${MARKER}
# User-local npm global bin
export PATH="\${HOME}/.npm-global/bin:\${PATH}"

# Openclaw completions
if command -v openclaw &> /dev/null; then
    eval "\$(openclaw completions bash)"
fi

# Don't log secrets in history
export HISTIGNORE="\$HISTIGNORE:*API_KEY*:*TOKEN*:*SECRET*:*PASSWORD*"
EOF
        ok "Shell profile updated"
    fi
else
    ok "Shell profile already configured"
fi

# ============================================================================
# START & VERIFY
# ============================================================================

step "Starting gateway"

if ! $DRY_RUN; then
    if systemctl --user start openclaw-gateway.service 2>/dev/null; then
        info "Waiting for gateway startup..."
        sleep 5

        if openclaw health --timeout 15000 &>/dev/null; then
            ok "Gateway is healthy"
        else
            warn "Gateway health check failed — it may still be starting up"
            warn "Try: openclaw health (in a minute)"
        fi
    else
        warn "Could not start gateway via systemd — start manually with: openclaw gateway up"
    fi

    # Run doctor only if gateway service is running (skip check if systemctl hangs)
    GATEWAY_ACTIVE=false
    if timeout 3 systemctl --user is-active openclaw-gateway.service &>/dev/null; then
        GATEWAY_ACTIVE=true
    fi

    if $GATEWAY_ACTIVE; then
        if timeout --kill-after=5 15 openclaw doctor &>/dev/null; then
            ok "openclaw doctor: passed"
        else
            warn "openclaw doctor did not pass — run it manually: openclaw doctor"
        fi
    fi
else
    echo "  [dry-run] Would start openclaw-gateway.service and verify health"
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                  Setup Complete!                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Bot:       ${BOT_NAME} ${BOT_EMOJI}"
echo "  User:      ${BOT_USER}"
echo "  Gateway:   http://127.0.0.1:${GATEWAY_PORT}"
echo "  Config:    ${HOME_DIR}/.openclaw/openclaw.json"
echo "  Workspace: ${HOME_DIR}/.openclaw/workspace/"
echo ""
echo "Verification commands:"
echo "  openclaw health          # Gateway health"
echo "  openclaw gateway status  # Service status"
echo "  ~/${BOT_NAME_LOWER}-status.sh   # Full dashboard (once renamed)"
echo "  crontab -l               # Cron jobs"
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Interactive Steps (do manually)              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "1. Google OAuth Setup (via gog):"
echo "   - Place your Google Cloud client secret at:"
echo "     ${HOME_DIR}/.openclaw/credentials/gmail-client-secret.json"
echo "   - Import credentials and authenticate:"
echo "     gog auth credentials set ${HOME_DIR}/.openclaw/credentials/gmail-client-secret.json"
echo "     gog auth keyring file"
echo "     gog auth add ${USER_EMAIL} --remote --step 1 --services gmail,calendar,drive,contacts,sheets,docs"
echo "     # Open the URL in a browser, grant access, then:"
echo "     gog auth add ${USER_EMAIL} --manual --auth-url '<paste redirect URL>'"
echo ""
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "2. Telegram Pairing:"
    echo "   - Open Telegram and message your bot (@BotFather token already configured)"
    echo "   - Run: openclaw telegram pair"
    echo "   - Follow the pairing instructions"
    echo ""
    echo "3. Test everything:"
else
    echo "2. Telegram (skipped -- no TELEGRAM_BOT_TOKEN in .env):"
    echo "   - To add Telegram later, set TELEGRAM_BOT_TOKEN in .env and re-run setup.sh"
    echo ""
    echo "3. Test everything:"
fi
echo "   gog gmail search 'newer_than:1d' --max 5 --json"
echo "   gog calendar list --json"
echo "   gog drive ls --json"
echo "   openclaw health"
echo "   ~/status.sh"
echo ""
