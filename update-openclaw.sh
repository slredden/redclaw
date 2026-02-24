#!/bin/bash
set -euo pipefail

# ============================================================================
# Openclaw System-Wide Update Script
# Updates the system Openclaw binary and restarts all bot user gateways.
# Must be run with sudo (or as root).
# ============================================================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()  { echo -e "\n${GREEN}==>${NC} ${BOLD}$1${NC}"; }

# --- Defaults ---
TARGET_VERSION="latest"
DRY_RUN=false
SKIP_BACKUP=false
ROLLBACK_VERSION=""

# --- Argument parsing ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Updates Openclaw system-wide and restarts all bot user gateways.
Requires sudo.

Options:
  --version <ver>    Install specific version (default: latest)
  --dry-run          Show what would be done without making changes
  --skip-backup      Skip per-user config backups
  --rollback <ver>   Rollback to a specific version
  --help             Show this help message

Examples:
  sudo ./update-openclaw.sh                  # Update to latest
  sudo ./update-openclaw.sh --version 1.2.3  # Install specific version
  sudo ./update-openclaw.sh --dry-run        # Preview changes
  sudo ./update-openclaw.sh --rollback 1.1.0 # Rollback to 1.1.0
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)   TARGET_VERSION="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --skip-backup) SKIP_BACKUP=true; shift ;;
        --rollback)  ROLLBACK_VERSION="$2"; shift 2 ;;
        --help)      usage ;;
        *)           err "Unknown option: $1"; usage ;;
    esac
done

# Use rollback version if specified
if [ -n "$ROLLBACK_VERSION" ]; then
    TARGET_VERSION="$ROLLBACK_VERSION"
    info "Rollback mode: targeting version ${TARGET_VERSION}"
fi

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run with sudo (or as root)."
    echo "  sudo $0 $*"
    exit 1
fi

# --- Helper ---
run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# ============================================================================
# DISCOVER BOT USERS
# ============================================================================

step "Discovering bot users"

BOT_USERS=()
for home_dir in /home/*/; do
    username=$(basename "$home_dir")
    if [ -d "${home_dir}.openclaw" ]; then
        BOT_USERS+=("$username")
    fi
done

if [ ${#BOT_USERS[@]} -eq 0 ]; then
    warn "No bot users found (no /home/*/.openclaw/ directories)"
    echo "  Nothing to update."
    exit 0
fi

ok "Found ${#BOT_USERS[@]} bot user(s): ${BOT_USERS[*]}"

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

step "Pre-flight checks"

# Current version
if command -v openclaw &>/dev/null; then
    CURRENT_VERSION=$(openclaw --version 2>/dev/null | head -1)
    ok "Current Openclaw version: ${CURRENT_VERSION}"
else
    warn "Openclaw not currently installed"
    CURRENT_VERSION="(not installed)"
fi

# Verify npm is available
if ! command -v npm &>/dev/null; then
    err "npm not found — cannot update Openclaw"
    exit 1
fi
ok "npm: $(npm --version)"

# Check the expected entrypoint path
ENTRYPOINT="/usr/lib/node_modules/openclaw/dist/index.js"
if [ -f "$ENTRYPOINT" ]; then
    ok "Entrypoint exists: ${ENTRYPOINT}"
else
    warn "Expected entrypoint not found: ${ENTRYPOINT}"
    warn "This may be normal if Openclaw is installed elsewhere"
fi

# ============================================================================
# BACKUP CONFIGS
# ============================================================================

if ! $SKIP_BACKUP; then
    step "Backing up user configs"

    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    for user in "${BOT_USERS[@]}"; do
        home="/home/${user}"
        backup_file="${home}/openclaw-backup-${TIMESTAMP}.tar.gz"

        if $DRY_RUN; then
            echo "  [dry-run] Would backup ${home}/.openclaw/ → ${backup_file}"
        else
            tar -czf "$backup_file" -C "$home" .openclaw/ 2>/dev/null && {
                chown "${user}:${user}" "$backup_file"
                ok "${user}: backed up to $(basename "$backup_file")"
            } || {
                warn "${user}: backup failed (continuing anyway)"
            }
        fi
    done
else
    info "Skipping backups (--skip-backup)"
fi

# ============================================================================
# STOP GATEWAYS
# ============================================================================

step "Stopping bot gateways"

declare -A USER_WAS_RUNNING

for user in "${BOT_USERS[@]}"; do
    uid=$(id -u "$user" 2>/dev/null || true)
    if [ -z "$uid" ]; then
        warn "${user}: could not determine UID — skipping"
        continue
    fi

    runtime_dir="/run/user/${uid}"
    bus_path="${runtime_dir}/bus"

    if [ -S "$bus_path" ]; then
        was_active=false
        if sudo -u "$user" \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${bus_path}" \
            systemctl --user is-active openclaw-gateway.service &>/dev/null 2>&1; then
            was_active=true
        fi

        USER_WAS_RUNNING[$user]=$was_active

        if $was_active; then
            if $DRY_RUN; then
                echo "  [dry-run] Would stop gateway for ${user}"
            else
                sudo -u "$user" \
                    XDG_RUNTIME_DIR="$runtime_dir" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=${bus_path}" \
                    systemctl --user stop openclaw-gateway.service 2>/dev/null || true
                ok "${user}: gateway stopped"
            fi
        else
            info "${user}: gateway was not running"
        fi
    else
        USER_WAS_RUNNING[$user]=false
        info "${user}: no D-Bus socket — gateway not managed by systemd"
    fi
done

# ============================================================================
# UPDATE SYSTEM BINARY
# ============================================================================

step "Updating Openclaw (npm install -g openclaw@${TARGET_VERSION})"

if $DRY_RUN; then
    echo "  [dry-run] Would run: npm install -g openclaw@${TARGET_VERSION}"
else
    npm install -g "openclaw@${TARGET_VERSION}" 2>&1 | tail -5
fi

# Verify the update
if ! $DRY_RUN; then
    NEW_VERSION=$(openclaw --version 2>/dev/null | head -1)
    ok "New Openclaw version: ${NEW_VERSION}"
else
    NEW_VERSION="(dry-run)"
fi

# ============================================================================
# VERIFY ENTRYPOINT
# ============================================================================

step "Verifying entrypoint"

if $DRY_RUN; then
    echo "  [dry-run] Would check ${ENTRYPOINT}"
else
    if [ -f "$ENTRYPOINT" ]; then
        ok "Entrypoint intact: ${ENTRYPOINT}"
    else
        warn "Entrypoint NOT found at expected path: ${ENTRYPOINT}"
        warn "Bot user systemd services may need ExecStart updated!"
        # Try to find the actual entrypoint
        actual=$(find /usr/lib/node_modules/openclaw/ -name "index.js" -path "*/dist/*" 2>/dev/null | head -1)
        if [ -n "$actual" ]; then
            warn "Possible entrypoint: ${actual}"
        fi
    fi
fi

# ============================================================================
# RESTART GATEWAYS
# ============================================================================

step "Restarting bot gateways"

for user in "${BOT_USERS[@]}"; do
    uid=$(id -u "$user" 2>/dev/null || true)
    if [ -z "$uid" ]; then
        continue
    fi

    runtime_dir="/run/user/${uid}"
    bus_path="${runtime_dir}/bus"

    if [ ! -S "$bus_path" ]; then
        warn "${user}: no D-Bus socket — cannot restart via systemd"
        continue
    fi

    was_running="${USER_WAS_RUNNING[$user]:-false}"

    if $was_running || true; then
        if $DRY_RUN; then
            echo "  [dry-run] Would restart gateway for ${user}"
        else
            sudo -u "$user" \
                XDG_RUNTIME_DIR="$runtime_dir" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=${bus_path}" \
                systemctl --user daemon-reload 2>/dev/null || true

            sudo -u "$user" \
                XDG_RUNTIME_DIR="$runtime_dir" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=${bus_path}" \
                systemctl --user restart openclaw-gateway.service 2>/dev/null && {
                ok "${user}: gateway restarted"
            } || {
                warn "${user}: failed to restart gateway"
            }
        fi
    fi
done

# Allow gateways to start up
if ! $DRY_RUN; then
    info "Waiting for gateways to start up..."
    sleep 5
fi

# ============================================================================
# HEALTH CHECKS
# ============================================================================

step "Health checks"

declare -A USER_STATUS

for user in "${BOT_USERS[@]}"; do
    uid=$(id -u "$user" 2>/dev/null || true)
    if [ -z "$uid" ]; then
        USER_STATUS[$user]="SKIP (no UID)"
        continue
    fi

    runtime_dir="/run/user/${uid}"
    bus_path="${runtime_dir}/bus"

    if $DRY_RUN; then
        USER_STATUS[$user]="(dry-run)"
        echo "  [dry-run] Would check health for ${user}"
        continue
    fi

    # Check if service is active
    if [ -S "$bus_path" ]; then
        active=$(sudo -u "$user" \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${bus_path}" \
            timeout 5 systemctl --user is-active openclaw-gateway.service 2>/dev/null || echo "inactive")

        if [ "$active" = "active" ]; then
            # Try health check
            if sudo -u "$user" timeout 15 openclaw health --timeout 10000 &>/dev/null 2>&1; then
                USER_STATUS[$user]="HEALTHY"
                ok "${user}: healthy"
            else
                USER_STATUS[$user]="RUNNING (health check failed)"
                warn "${user}: running but health check failed — may still be starting"
            fi
        else
            USER_STATUS[$user]="NOT RUNNING"
            warn "${user}: gateway is not running (status: ${active})"
        fi
    else
        USER_STATUS[$user]="NO D-BUS"
        warn "${user}: no D-Bus socket"
    fi
done

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                  Update Summary                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
printf "  %-20s %s\n" "Previous version:" "$CURRENT_VERSION"
printf "  %-20s %s\n" "New version:" "$NEW_VERSION"
echo ""
printf "  ${BOLD}%-20s %-15s${NC}\n" "USER" "STATUS"
printf "  %-20s %-15s\n" "----" "------"
for user in "${BOT_USERS[@]}"; do
    status="${USER_STATUS[$user]:-UNKNOWN}"
    case "$status" in
        HEALTHY)     color="$GREEN" ;;
        *dry-run*)   color="$CYAN" ;;
        *)           color="$YELLOW" ;;
    esac
    printf "  %-20s ${color}%-15s${NC}\n" "$user" "$status"
done
echo ""

if ! $SKIP_BACKUP && ! $DRY_RUN; then
    info "Backups saved as ~/openclaw-backup-${TIMESTAMP}.tar.gz in each user's home"
fi

if $DRY_RUN; then
    echo ""
    info "This was a dry run — no changes were made"
fi
