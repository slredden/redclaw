#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Openclaw System-Wide Update
#
# One entry point to: (1) update the system-wide Openclaw npm package,
# (2) verify every account running Openclaw is still configured correctly,
# and (3) restart each account's gateway and surface/auto-fix any errors
# that show up afterward.
#
# Must be run with sudo/root (it needs to `npm install -g` and `sudo -iu`
# into each bot account).
#
# Bot accounts are auto-discovered as every /home/<user> that has a real
# ~/.openclaw/openclaw.json — not a hardcoded list, so a new bot user added
# via add-bot.sh is picked up automatically. The admin account (whoever
# invoked sudo, via $SUDO_USER) is excluded by default, since an admin's
# own ~/.openclaw is typically a personal instance, not a managed bot
# account -- override with --only/--exclude if that's not true for you.
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()  { echo -e "\n${GREEN}==>${NC} ${BOLD}$1${NC}"; }

# --- Defaults ---
TARGET_VERSION="latest"
DRY_RUN=false
SKIP_BACKUP=false
NO_FIX=false
ONLY_USERS=()
# Auto-exclude whoever invoked sudo (the admin account) -- no hardcoded
# username, so this works for any deployer, not just this server.
EXCLUDE_USERS=()
[ -n "${SUDO_USER:-}" ] && EXCLUDE_USERS+=("$SUDO_USER")
LOG_DIR="/var/log/openclaw-admin"

usage() {
    cat <<EOF
Usage: sudo $(basename "$0") [OPTIONS]

Updates Openclaw system-wide (npm), then for every bot account:
validates its config, restarts its gateway, and checks/fixes errors.

Options:
  --version <ver>     Install openclaw@<ver> (default: latest)
  --rollback <ver>    Alias for --version, named for rollback use
  --only <u1,u2>      Only operate on these accounts (skip auto-discovery)
  --exclude <u1,u2>   Additionally exclude these accounts from discovery
  --dry-run           Discover + validate only; no npm install, no restarts,
                      no --fix, no backups
  --skip-backup       Skip per-user ~/.openclaw backups before updating
  --no-fix            Report doctor findings but don't run 'openclaw doctor --fix'
  --help              Show this help

Examples:
  sudo ./update-openclaw.sh
  sudo ./update-openclaw.sh --dry-run
  sudo ./update-openclaw.sh --version 2026.7.2-beta.1
  sudo ./update-openclaw.sh --rollback 2026.7.1
  sudo ./update-openclaw.sh --only outfitai
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)     TARGET_VERSION="$2"; shift 2 ;;
        --rollback)     TARGET_VERSION="$2"; shift 2 ;;
        --only)         IFS=',' read -r -a ONLY_USERS <<< "$2"; shift 2 ;;
        --exclude)      IFS=',' read -r -a extra <<< "$2"; EXCLUDE_USERS+=("${extra[@]}"); shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --skip-backup)  SKIP_BACKUP=true; shift ;;
        --no-fix)       NO_FIX=true; shift ;;
        --help|-h)      usage ;;
        *)              err "Unknown option: $1"; usage ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run with sudo (or as root)."
    echo "  sudo $0 $*"
    exit 1
fi

mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/global-update-${STAMP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Logging to ${LOG_FILE}"

# ============================================================================
# DISCOVER BOT ACCOUNTS
# ============================================================================

step "Discovering Openclaw accounts"

BOT_USERS=()
if [ ${#ONLY_USERS[@]} -gt 0 ]; then
    BOT_USERS=("${ONLY_USERS[@]}")
else
    for home_dir in /home/*/; do
        u="$(basename "$home_dir")"
        excluded=false
        for e in "${EXCLUDE_USERS[@]}"; do
            [ "$u" = "$e" ] && excluded=true && break
        done
        $excluded && continue
        if [ -f "${home_dir}.openclaw/openclaw.json" ]; then
            BOT_USERS+=("$u")
        fi
    done
fi

if [ ${#BOT_USERS[@]} -eq 0 ]; then
    warn "No Openclaw accounts found (looked for /home/*/.openclaw/openclaw.json)"
    exit 0
fi
ok "Found ${#BOT_USERS[@]} account(s): ${BOT_USERS[*]}"

# ============================================================================
# PRE-FLIGHT
# ============================================================================

step "Pre-flight checks"

if command -v openclaw &>/dev/null; then
    CURRENT_VERSION="$(openclaw --version 2>/dev/null | head -1)"
else
    CURRENT_VERSION="(not installed)"
fi
ok "Current Openclaw version: ${CURRENT_VERSION}"

if ! command -v npm &>/dev/null; then
    err "npm not found -- cannot update Openclaw"
    exit 1
fi
ok "npm: $(npm --version)"

if ! command -v jq &>/dev/null; then
    warn "jq not found -- per-user finding counts/details will be degraded"
fi

# ============================================================================
# BACKUPS
# ============================================================================

if ! $SKIP_BACKUP && ! $DRY_RUN; then
    step "Backing up ~/.openclaw for each account"
    for user in "${BOT_USERS[@]}"; do
        backup_file="/home/${user}/openclaw-backup-${STAMP}.tar.gz"
        if tar -czf "$backup_file" -C "/home/${user}" .openclaw 2>/dev/null; then
            chown "${user}:${user}" "$backup_file"
            ok "${user}: backed up to $(basename "$backup_file")"
        else
            warn "${user}: backup failed (continuing anyway)"
        fi
    done
else
    info "Skipping backups"
fi

# ============================================================================
# PER-USER CHECK FUNCTION (reused for both baseline and post-update passes)
# ============================================================================

# Runs entirely as the target account via `sudo -iu`. Prints tagged lines
# ([OK]/[WARN]/[ERROR]/[ACTION NEEDED]/[SKIP]) and exits with a status code
# the caller interprets:
#   0 = healthy / nothing to do
#   1 = gateway failed to (re)start
#   2 = doctor errors remain after --fix (or after report-only check)
#   3 = gateway service installed but disabled -- needs manual enable
#   4 = no config file / CLI -- account skipped
run_check_for_user() {
    local user="$1" phase="$2" do_restart="$3" do_fix="$4"

    sudo -iu "$user" \
        OC_PHASE="$phase" OC_DO_RESTART="$do_restart" OC_DO_FIX="$do_fix" \
        bash -s <<'PERUSER'
set -uo pipefail
me="$(whoami)"
phase="${OC_PHASE}"
echo "--- ${me} (${phase}) ---"

if ! command -v openclaw >/dev/null 2>&1; then
    echo "  [SKIP] openclaw CLI not on PATH for ${me}"
    exit 4
fi

CFG_RAW="$(openclaw config file 2>/dev/null | tail -n1)"
CFG="${CFG_RAW/#\~/$HOME}"
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then
    echo "  [SKIP] no config file found for ${me} (raw: '${CFG_RAW}')"
    exit 4
fi
echo "  config: ${CFG}"

echo "  -- config validate --"
if openclaw config validate >/tmp/oc-validate.$$.log 2>&1; then
    echo "  [OK] config valid"
else
    echo "  [ERROR] config validate FAILED:"
    sed 's/^/    /' /tmp/oc-validate.$$.log
fi
rm -f /tmp/oc-validate.$$.log

echo "  -- doctor --lint --"
lint_json="$(openclaw doctor --lint --json 2>/dev/null)"
if command -v jq >/dev/null 2>&1 && [ -n "$lint_json" ]; then
    errs="$(echo "$lint_json" | jq -r '[.findings[]? | select(.severity=="error")] | length' 2>/dev/null)"
    warns="$(echo "$lint_json" | jq -r '[.findings[]? | select(.severity=="warning")] | length' 2>/dev/null)"
    echo "  doctor --lint: ${errs:-?} error(s), ${warns:-?} warning(s)"
    if [ "${errs:-0}" != "0" ] && [ -n "${errs:-}" ]; then
        echo "$lint_json" | jq -r '.findings[]? | select(.severity=="error") | "    - [\(.checkId)] \(.message)"' 2>/dev/null
    fi
else
    errs="?"
    echo "  doctor --lint: (jq unavailable or no output; raw below)"
    echo "$lint_json" | sed 's/^/    /'
fi

if [ "$phase" = "baseline" ]; then
    # Baseline pass: report-only, no restarts or fixes.
    if [ "${errs:-0}" != "0" ]; then
        exit 2
    fi
    exit 0
fi

echo "  -- daemon status (before restart) --"
status_before="$(openclaw daemon status 2>&1)"
echo "$status_before" | sed 's/^/    /'
service_line="$(echo "$status_before" | grep -E '^Service:')"
runtime_line="$(echo "$status_before" | grep -E '^Runtime:')"

if echo "$service_line" | grep -qi "not installed"; then
    echo "  [NOTE] gateway service not installed for ${me} -- nothing to restart"
    exit 0
fi

if echo "$service_line" | grep -qi "disabled"; then
    echo "  [ACTION NEEDED] gateway service installed but disabled for ${me}."
    echo "    Run manually as ${me}: openclaw daemon start   (or: openclaw daemon install)"
    exit 3
fi

if [ "${OC_DO_RESTART}" = "1" ]; then
    echo "  -- restarting gateway --"
    if echo "$runtime_line" | grep -qi "running"; then
        openclaw daemon restart
    else
        openclaw daemon start
    fi
    sleep 4
else
    echo "  [dry-run] would restart gateway here"
fi

status_after="$(openclaw daemon status 2>&1)"
echo "$status_after" | sed 's/^/    /'
runtime_after="$(echo "$status_after" | grep -E '^Runtime:')"

if [ "${OC_DO_RESTART}" = "1" ]; then
    if ! echo "$runtime_after" | grep -qi "running"; then
        echo "  [ERROR] gateway NOT running for ${me} after restart"
        exit 1
    fi
    echo "  [OK] gateway running"
fi

echo "  -- doctor --post-upgrade --"
pu_json="$(openclaw doctor --post-upgrade --json 2>/dev/null)"
if command -v jq >/dev/null 2>&1 && [ -n "$pu_json" ]; then
    pu_findings="$(echo "$pu_json" | jq -r '.findings? | length' 2>/dev/null)"
else
    pu_findings="?"
fi
if [ "${pu_findings:-0}" != "0" ] && [ -n "${pu_findings:-}" ]; then
    echo "  [WARN] post-upgrade findings for ${me}:"
    echo "$pu_json" | jq -r '.findings[]? | "    - [\(.level)] \(.code): \(.message)"' 2>/dev/null
else
    echo "  [OK] no post-upgrade plugin-compat findings"
fi

needs_fix=false
[ "${errs:-0}" != "0" ] && [ -n "${errs:-}" ] && needs_fix=true
[ "${pu_findings:-0}" != "0" ] && [ -n "${pu_findings:-}" ] && needs_fix=true

if $needs_fix && [ "${OC_DO_FIX}" = "1" ]; then
    echo "  -- attempting openclaw doctor --fix --"
    openclaw doctor --fix --non-interactive 2>&1 | sed 's/^/    /'
fi

echo "  -- final doctor --lint --"
lint_final="$(openclaw doctor --lint --json 2>/dev/null)"
if command -v jq >/dev/null 2>&1 && [ -n "$lint_final" ]; then
    final_errs="$(echo "$lint_final" | jq -r '[.findings[]? | select(.severity=="error")] | length' 2>/dev/null)"
else
    final_errs="?"
fi
echo "  final error count: ${final_errs:-?}"

if [ "${final_errs:-0}" != "0" ] && [ -n "${final_errs:-}" ]; then
    exit 2
fi
exit 0
PERUSER
    return $?
}

# ============================================================================
# BASELINE (pre-update) PASS
# ============================================================================

step "Baseline check (before update)"

declare -A BASELINE_STATUS
for user in "${BOT_USERS[@]}"; do
    if run_check_for_user "$user" "baseline" "0" "0"; then
        BASELINE_STATUS[$user]=0
    else
        BASELINE_STATUS[$user]=$?
    fi
done

# ============================================================================
# UPDATE SYSTEM PACKAGE
# ============================================================================

step "Updating Openclaw (npm install -g openclaw@${TARGET_VERSION})"

if $DRY_RUN; then
    echo "  [dry-run] Would run: npm install -g openclaw@${TARGET_VERSION}"
    NEW_VERSION="(dry-run)"
else
    npm install -g "openclaw@${TARGET_VERSION}" 2>&1 | tail -10
    NEW_VERSION="$(openclaw --version 2>/dev/null | head -1)"
    ok "New Openclaw version: ${NEW_VERSION}"
fi

step "Verifying global install"
if $DRY_RUN; then
    echo "  [dry-run] Would verify /usr/bin/openclaw and its target"
else
    if [ -x /usr/bin/openclaw ] || [ -e /usr/bin/openclaw ]; then
        target="$(readlink -f /usr/bin/openclaw 2>/dev/null)"
        if [ -n "$target" ] && [ -f "$target" ]; then
            ok "/usr/bin/openclaw -> ${target} (exists)"
        else
            err "/usr/bin/openclaw does not resolve to a real file"
            exit 1
        fi
    else
        err "/usr/bin/openclaw is missing after update"
        exit 1
    fi
    if ! openclaw --version >/dev/null 2>&1; then
        err "openclaw --version failed after update"
        exit 1
    fi
fi

# ============================================================================
# PER-USER POST-UPDATE PASS: validate, restart, check/fix
# ============================================================================

step "Per-account validate + restart + fix"

RESTART_FLAG="1"; $DRY_RUN && RESTART_FLAG="0"
FIX_FLAG="1"; { $NO_FIX || $DRY_RUN; } && FIX_FLAG="0"

declare -A FINAL_STATUS
for user in "${BOT_USERS[@]}"; do
    if run_check_for_user "$user" "post-update" "$RESTART_FLAG" "$FIX_FLAG"; then
        FINAL_STATUS[$user]=0
    else
        FINAL_STATUS[$user]=$?
    fi
done

# ============================================================================
# SUMMARY
# ============================================================================

status_label() {
    case "$1" in
        0) echo "HEALTHY" ;;
        1) echo "GATEWAY DOWN" ;;
        2) echo "DOCTOR ERRORS" ;;
        3) echo "SERVICE DISABLED" ;;
        4) echo "SKIPPED (no config)" ;;
        *) echo "UNKNOWN ($1)" ;;
    esac
}

echo ""
echo "======================================================================"
echo "                        Update Summary"
echo "======================================================================"
printf "  %-20s %s\n" "Previous version:" "$CURRENT_VERSION"
printf "  %-20s %s\n" "New version:" "$NEW_VERSION"
echo ""
printf "  ${BOLD}%-16s %-14s %-16s${NC}\n" "USER" "BASELINE" "AFTER UPDATE"
printf "  %-16s %-14s %-16s\n" "----" "--------" "------------"

bad_count=0
for user in "${BOT_USERS[@]}"; do
    b="$(status_label "${BASELINE_STATUS[$user]:-99}")"
    a_code="${FINAL_STATUS[$user]:-99}"
    a="$(status_label "$a_code")"
    color="$YELLOW"
    [ "$a_code" = "0" ] && color="$GREEN"
    [ "$a_code" = "0" ] || bad_count=$((bad_count + 1))
    printf "  %-16s %-14s ${color}%-16s${NC}\n" "$user" "$b" "$a"
done
echo ""

if ! $SKIP_BACKUP && ! $DRY_RUN; then
    info "Backups saved as ~/openclaw-backup-${STAMP}.tar.gz in each account's home"
fi
info "Full log: ${LOG_FILE}"

if $DRY_RUN; then
    echo ""
    info "This was a dry run -- no changes were made."
    exit 0
fi

if [ "$bad_count" -gt 0 ]; then
    err "${bad_count} account(s) need attention -- see log for [ACTION NEEDED]/[ERROR] lines."
    exit 1
fi

ok "All accounts healthy after update."
exit 0
