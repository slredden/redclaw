#!/bin/bash
set -uo pipefail

# ============================================================================
# Openclaw Reset Script
# Removes all Openclaw-specific files so setup.sh can be run fresh.
# Leaves system prereqs (Node.js, jq, curl, etc.) intact.
#
# Run as the bot user (no sudo required).
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

DRY_RUN=false
KEEP_BACKUPS=false
KEEP_ENV=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Wipe an Openclaw installation so setup.sh can be run fresh.
Leaves system prereqs (Node.js, jq, curl, etc.) intact.

Options:
  --dry-run         Show what would be removed without doing it
  --keep-backups    Preserve ~/\$BOT_NAME-backups/ directory
  --keep-env        Preserve .env file in the provision directory
  --help            Show this help message

Example:
  ./reset.sh                 # Full reset
  ./reset.sh --dry-run       # Preview what will be removed
  ./reset.sh --keep-backups  # Reset but keep backups
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)        DRY_RUN=true; shift ;;
        --keep-backups)   KEEP_BACKUPS=true; shift ;;
        --keep-env)       KEEP_ENV=true; shift ;;
        --help)           usage ;;
        *)                err "Unknown option: $1"; usage ;;
    esac
done

HOME_DIR="$HOME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Confirmation ---
if ! $DRY_RUN; then
    echo ""
    echo -e "${RED}WARNING: This will remove your Openclaw installation.${NC}"
    echo ""
    echo "  The following will be deleted:"
    echo "    ~/.openclaw/            (config, workspace, sessions, credentials)"
    echo "    ~/.npm-global/          (openclaw, gog, and all npm globals)"
    echo "    ~/backup.sh, ~/watchdog.sh, ~/status.sh"
    echo "    ~/.config/systemd/user/openclaw-gateway.service"
    echo "    Cron jobs for backup, watchdog, and rotate-config"
    echo "    Openclaw block in ~/.bashrc"
    if ! $KEEP_BACKUPS; then
        echo "    ~/*-backups/            (bot backup directories)"
    fi
    echo ""
    read -rp "Type YES to confirm: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

run() {
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${NC} $*"
    else
        "$@"
    fi
}

# ============================================================================
# 1. Stop gateway service
# ============================================================================

info "Stopping gateway..."

if systemctl --user is-active openclaw-gateway.service &>/dev/null; then
    run systemctl --user stop openclaw-gateway.service
    ok "Gateway stopped"
elif pgrep -f "openclaw gateway" &>/dev/null; then
    run pkill -f "openclaw gateway"
    ok "Gateway process killed"
else
    ok "Gateway not running"
fi

# Disable the service
if systemctl --user is-enabled openclaw-gateway.service &>/dev/null 2>&1; then
    run systemctl --user disable openclaw-gateway.service 2>/dev/null
    ok "Gateway service disabled"
fi

# ============================================================================
# 2. Remove systemd unit
# ============================================================================

info "Removing systemd service..."

SERVICE_FILE="${HOME_DIR}/.config/systemd/user/openclaw-gateway.service"
if [ -f "$SERVICE_FILE" ]; then
    run rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "Removed openclaw-gateway.service"
else
    ok "No systemd service found"
fi

# ============================================================================
# 3. Remove cron jobs
# ============================================================================

info "Removing cron jobs..."

if crontab -l &>/dev/null; then
    BEFORE=$(crontab -l 2>/dev/null)
    AFTER=$(echo "$BEFORE" | grep -vF "backup.sh" | grep -vF "rotate-config.sh" | grep -vF "watchdog.sh")
    if [ "$BEFORE" != "$AFTER" ]; then
        if $DRY_RUN; then
            echo -e "  ${YELLOW}[dry-run]${NC} Would remove cron entries for backup.sh, rotate-config.sh, watchdog.sh"
        else
            echo "$AFTER" | crontab -
        fi
        ok "Openclaw cron jobs removed"
    else
        ok "No Openclaw cron jobs found"
    fi
else
    ok "No crontab configured"
fi

# ============================================================================
# 4. Remove automation scripts
# ============================================================================

info "Removing automation scripts..."

for script in backup.sh watchdog.sh status.sh; do
    if [ -f "${HOME_DIR}/${script}" ]; then
        run rm -f "${HOME_DIR}/${script}"
        ok "Removed ~/${script}"
    fi
done

# ============================================================================
# 5. Remove ~/.openclaw
# ============================================================================

info "Removing ~/.openclaw..."

if [ -d "${HOME_DIR}/.openclaw" ]; then
    run rm -rf "${HOME_DIR}/.openclaw"
    ok "Removed ~/.openclaw/"
else
    ok "~/.openclaw/ not found"
fi

# ============================================================================
# 6. Remove npm globals (openclaw, gog, and everything in ~/.npm-global)
# ============================================================================

info "Removing npm global packages..."

if [ -d "${HOME_DIR}/.npm-global" ]; then
    run rm -rf "${HOME_DIR}/.npm-global"
    ok "Removed ~/.npm-global/"
else
    ok "~/.npm-global/ not found"
fi

# ============================================================================
# 7. Remove backups (unless --keep-backups)
# ============================================================================

if ! $KEEP_BACKUPS; then
    info "Removing backup directories..."
    found_backups=false
    for dir in "${HOME_DIR}"/*-backups; do
        if [ -d "$dir" ]; then
            run rm -rf "$dir"
            ok "Removed $(basename "$dir")/"
            found_backups=true
        fi
    done
    if ! $found_backups; then
        ok "No backup directories found"
    fi
else
    info "Keeping backup directories (--keep-backups)"
fi

# ============================================================================
# 8. Clean .bashrc
# ============================================================================

info "Cleaning ~/.bashrc..."

BASHRC="${HOME_DIR}/.bashrc"
MARKER="# --- openclaw-provision ---"

if [ -f "$BASHRC" ] && grep -qF "$MARKER" "$BASHRC"; then
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${NC} Would remove openclaw-provision block from ~/.bashrc"
    else
        # Remove from the marker to EOF (the block is always appended at the end)
        # Use sed to delete from the marker line through the end of file
        sed -i "/${MARKER}/,\$d" "$BASHRC"
    fi
    ok "Removed openclaw-provision block from ~/.bashrc"
else
    ok "No openclaw-provision block in ~/.bashrc"
fi

# ============================================================================
# 9. Clean .env (unless --keep-env)
# ============================================================================

if ! $KEEP_ENV; then
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        run rm -f "${SCRIPT_DIR}/.env"
        ok "Removed .env from provision directory"
    fi
else
    info "Keeping .env file (--keep-env)"
fi

# ============================================================================
# Done
# ============================================================================

echo ""
if $DRY_RUN; then
    echo -e "${YELLOW}Dry run complete — no changes were made.${NC}"
else
    echo -e "${GREEN}Reset complete.${NC} You can now re-run setup.sh for a fresh install."
fi
echo ""
