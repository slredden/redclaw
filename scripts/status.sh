#!/bin/bash

echo "╔════════════════════════════════════════╗"
echo "║       ${BOT_NAME} Status Dashboard          ║"
echo "╚════════════════════════════════════════╝"
echo ""

# Gateway process status (use systemd as source of truth)
GW_PID=$(systemctl --user show openclaw-gateway.service -p MainPID --value 2>/dev/null)
GW_STATE=$(systemctl --user show openclaw-gateway.service -p ActiveState --value 2>/dev/null)
if [ "$GW_STATE" = "active" ] && [ "$GW_PID" != "0" ]; then
    UPTIME=$(ps -p "$GW_PID" -o etime= 2>/dev/null | tr -d ' ')
    echo "✓ Gateway: RUNNING (PID: $GW_PID, Uptime: $UPTIME)"
else
    echo "✗ Gateway: $GW_STATE"
fi

# Health probe
echo ""
echo "Health:"
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:${GATEWAY_PORT}/ 2>/dev/null)
if [ "$http_code" = "200" ]; then
    echo "  ✓ HTTP probe: OK (port ${GATEWAY_PORT})"
else
    echo "  ✗ HTTP probe: FAILED (port ${GATEWAY_PORT})"
fi

# Watchdog status
if crontab -l 2>/dev/null | grep -q "${BOT_NAME_LOWER}-watchdog"; then
    LAST_RESTART=$(tail -1 /home/${BOT_USER}/${BOT_NAME_LOWER}-watchdog.log 2>/dev/null)
    echo "  ✓ Watchdog: active (cron every 5m)"
    if [ -n "$LAST_RESTART" ]; then
        echo "  Last log: $LAST_RESTART"
    fi
else
    echo "  ⚠ Watchdog: not installed"
fi

# Backup status
echo ""
echo "Backups:"
BACKUP_COUNT=$(find ~/${BOT_NAME_LOWER}-backups -type d -name "auto-*" 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt 0 ]; then
    LATEST=$(ls -td ~/${BOT_NAME_LOWER}-backups/auto-* 2>/dev/null | head -1 | xargs basename)
    echo "  Count: $BACKUP_COUNT"
    echo "  Latest: $LATEST"
else
    echo "  ⚠ No automated backups found"
fi

# Disk usage
echo ""
echo "Storage:"
echo "  Openclaw: $(du -sh ~/.openclaw 2>/dev/null | cut -f1)"
echo "  Backups: $(du -sh ~/${BOT_NAME_LOWER}-backups 2>/dev/null | cut -f1 || echo 'N/A')"
echo "  Available: $(df -h ~ | tail -1 | awk '{print $4}')"

# Config integrity
echo ""
echo "Config:"
if [ -f ~/.openclaw/openclaw.json ]; then
    PERMS=$(stat -c %a ~/.openclaw/openclaw.json)
    if [ "$PERMS" = "600" ]; then
        echo "  ✓ Permissions: $PERMS (secure)"
    else
        echo "  ⚠ Permissions: $PERMS (should be 600)"
    fi

    TOKEN=$(jq -r '.gateway.auth.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        echo "  Token length: ${#TOKEN} chars"
    else
        echo "  ⚠ No gateway token found"
    fi
fi

echo ""
echo "Last updated: $(date)"
