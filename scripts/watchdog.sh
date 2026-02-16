#!/bin/bash
# ${BOT_NAME} Gateway Watchdog
# Verifies the Openclaw gateway is healthy and restarts it if not.
# Intended to run via cron every 5 minutes.

LOG="/home/${BOT_USER}/${BOT_NAME_LOWER}-watchdog.log"
RESTART_TRACKER="/tmp/${BOT_NAME_LOWER}-watchdog-restarts"
MAX_RESTARTS_PER_HOUR=3
SERVICE="openclaw-gateway.service"

# --- Environment for cron (systemctl --user needs D-Bus, openclaw needs PATH) ---
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
export PATH="$HOME/.npm-global/bin:$PATH"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# Trim log if it exceeds 1000 lines
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
    tail -500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

# --- Rate limiting: prevent restart loops ---
# Each restart appends a timestamp. We count how many are within the last hour.
check_restart_limit() {
    if [ ! -f "$RESTART_TRACKER" ]; then
        return 0  # no restarts yet, OK to proceed
    fi
    cutoff=$(date -d '1 hour ago' '+%s')
    recent=0
    # Rewrite tracker with only recent entries
    tmpfile=$(mktemp)
    while read -r ts; do
        if [ "$ts" -ge "$cutoff" ] 2>/dev/null; then
            echo "$ts" >> "$tmpfile"
            recent=$((recent + 1))
        fi
    done < "$RESTART_TRACKER"
    mv "$tmpfile" "$RESTART_TRACKER"

    if [ "$recent" -ge "$MAX_RESTARTS_PER_HOUR" ]; then
        return 1  # limit reached
    fi
    return 0
}

record_restart() {
    date '+%s' >> "$RESTART_TRACKER"
}

# --- Health checks ---

# Primary: use openclaw's built-in health probe (exits non-zero on failure)
health_check_cli() {
    openclaw health --json --timeout 15000 > /dev/null 2>&1
    return $?
}

# Fallback: simple HTTP probe on the gateway port
health_check_http() {
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:${GATEWAY_PORT}/ 2>/dev/null)
    [ "$http_code" = "200" ]
    return $?
}

# Check if the systemd service is in a failed state
service_is_failed() {
    systemctl --user is-failed --quiet "$SERVICE"
    return $?
}

# --- Main ---

# Check if service is in failed state (systemd gave up)
if service_is_failed; then
    log "[WARN] Service is in failed state"
    if check_restart_limit; then
        log "[ACTION] Resetting failed state and starting service"
        systemctl --user reset-failed "$SERVICE"
        if systemctl --user start "$SERVICE"; then
            record_restart
        else
            log "[ERROR] systemctl --user start failed (exit $?)"
        fi
        sleep 5
        if health_check_http; then
            log "[OK] Service recovered after reset-failed + start"
        else
            log "[ERROR] Service did not recover after reset-failed + start"
        fi
    else
        log "[RATE-LIMITED] Too many restarts in the last hour ($MAX_RESTARTS_PER_HOUR max). Manual intervention needed."
    fi
    exit 0
fi

# Primary health check
if health_check_cli; then
    exit 0  # healthy, nothing to do (silent success)
fi

# CLI check failed — try HTTP fallback before restarting
log "[WARN] CLI health check failed, trying HTTP fallback"
if health_check_http; then
    log "[OK] HTTP probe succeeded (CLI may have had a transient issue)"
    exit 0
fi

# Both checks failed — gateway is down or unresponsive
log "[ALERT] Gateway is unhealthy (both CLI and HTTP checks failed)"

# Check systemd service state for diagnostics
svc_state=$(systemctl --user show -p ActiveState --value "$SERVICE")
svc_sub=$(systemctl --user show -p SubState --value "$SERVICE")
log "[DIAG] Service state: $svc_state/$svc_sub"

if check_restart_limit; then
    log "[ACTION] Restarting $SERVICE"
    if systemctl --user restart "$SERVICE"; then
        record_restart
    else
        log "[ERROR] systemctl --user restart failed (exit $?)"
    fi

    # Wait for startup and verify
    sleep 8
    if health_check_http; then
        log "[OK] Gateway recovered after restart"
    else
        log "[ERROR] Gateway still unhealthy after restart"
    fi
else
    log "[RATE-LIMITED] Too many restarts in the last hour ($MAX_RESTARTS_PER_HOUR max). Manual intervention needed."
fi
