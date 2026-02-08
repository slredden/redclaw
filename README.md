# Openclaw Bot Provisioning Toolkit

Reproducible setup for a personal AI assistant powered by [Openclaw](https://openclaw.dev) with free model routing, Telegram integration, mem0 memory, Google Workspace plugins, and automated health monitoring.

## What You Get

- **Free AI models**: Kimi K2.5 via Nvidia NIM (primary) + DeepSeek V3.2 via Vercel AI Gateway (fallback)
- **Telegram bot**: DM-based personal assistant with pairing security
- **Google Workspace**: Gmail, Calendar, Drive integration via OAuth
- **Persistent memory**: mem0 cloud memory across sessions
- **Workspace system**: Personality, identity, and behavioral instructions
- **Automation**: Daily backups, gateway watchdog, config rotation, cron jobs
- **Status dashboard**: Single command to check everything

## Prerequisites

1. **Fresh Ubuntu/Debian machine** (22.04+ recommended)
2. **Free API keys** (all free tier):
   - [Nvidia NIM API](https://build.nvidia.com) — for Kimi K2.5
   - [mem0](https://mem0.ai) — for persistent memory
   - [Brave Search](https://brave.com/search/api) — for web search
   - [Vercel AI Gateway](https://sdk.vercel.ai/gateway) — for fallback models
3. **Telegram Bot Token** from [@BotFather](https://t.me/BotFather)
4. **Google Cloud OAuth client secret** (for Gmail/Calendar/Drive)

## Quick Start

```bash
# 1. Clone this repo
git clone <your-repo-url> ~/redbot-provision
cd ~/redbot-provision

# 2. Create your .env file
cp .env.example .env

# 3. Fill in all API keys and settings
nano .env

# 4. Run setup (preview first)
./setup.sh --dry-run

# 5. Run for real
./setup.sh
```

## Configuration

### `.env` Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `BOT_NAME` | Yes | Display name (e.g., "RedBot") |
| `BOT_USER` | Yes | Linux username |
| `BOT_EMOJI` | Yes | Bot's emoji identity |
| `USER_NAME` | Yes | Your name |
| `USER_TIMEZONE` | Yes | Timezone (e.g., "MST") |
| `USER_LOCATION` | Yes | City, State (e.g., "Denver, CO") |
| `USER_EMAIL` | Yes | Your email for digests |
| `NVIDIA_API_KEY` | Yes | Nvidia NIM API key |
| `MEM0_API_KEY` | Yes | mem0 API key |
| `BRAVE_SEARCH_KEY` | Yes | Brave Search API key |
| `VERCEL_AI_KEY` | Yes | Vercel AI Gateway key |
| `TELEGRAM_BOT_TOKEN` | Yes | Telegram bot token |
| `TELEGRAM_USER_ID` | No | Your Telegram user ID |
| `GATEWAY_PORT` | No | Gateway port (default: 18789) |
| `GATEWAY_TOKEN` | No | Auto-generated if blank |

## Post-Setup (Interactive Steps)

These require manual interaction and cannot be automated:

### 1. Google OAuth

Place your Google Cloud client secret JSON at:
```
~/.openclaw/credentials/gmail-client-secret.json
```

Then authenticate each service:
```bash
openclaw gmail auth    # Opens browser for OAuth
openclaw gcal auth
openclaw gdrive auth
```

### 2. Telegram Pairing

```bash
# Message your bot on Telegram first, then:
openclaw telegram pair
```

## Verification

```bash
# Gateway health
openclaw health

# Service status
openclaw gateway status
systemctl --user status openclaw-gateway

# Full dashboard
~/status.sh

# Cron jobs
crontab -l

# Extensions
openclaw plugins list

# Config check
cat ~/.openclaw/openclaw.json | jq .models.providers.nvidia
```

## File Structure

```
~/redbot-provision/
├── README.md                          # This file
├── setup.sh                           # Main provisioning script
├── .env.example                       # Secret template
├── .gitignore                         # Excludes .env
│
├── templates/
│   ├── openclaw.json.tmpl             # Main config template
│   ├── auth-profiles.json.tmpl        # Vercel auth profile
│   └── openclaw-gateway.service.tmpl  # Systemd unit
│
├── workspace/
│   ├── USER.md.tmpl                   # Per-instance user profile
│   ├── IDENTITY.md.tmpl              # Per-instance bot identity
│   ├── SOUL.md                        # Personality framework
│   ├── AGENTS.md                      # Session bootstrap
│   ├── TOOLS.md                       # Tool notes
│   ├── HEARTBEAT.md                   # Heartbeat config
│   └── skills/                        # Skill packages
│
├── scripts/
│   ├── backup.sh                      # Daily backup
│   ├── watchdog.sh                    # Gateway health watchdog
│   ├── status.sh                      # Status dashboard
│   └── rotate-config.sh              # Config rotation
│
└── cron/
    └── jobs.json.tmpl                 # Openclaw cron jobs
```

## Automation

The setup installs three cron jobs:

| Schedule | Script | Purpose |
|----------|--------|---------|
| Daily 3 AM | `backup.sh` | Full config backup (14-day retention) |
| Sundays 2 AM | `rotate-config.sh` | Config version history (10 versions) |
| Every 5 min | `watchdog.sh` | Gateway health check + auto-restart |

And three Openclaw internal cron jobs:

| Schedule | Job | Purpose |
|----------|-----|---------|
| Every 15 min (8AM-10PM) | Email check | Read & act on emails |
| Hourly (10PM-8AM) | Email check | Nighttime email monitoring |
| Daily 8 AM | Morning digest | News + calendar email summary |

## Customization

### Workspace Files

After setup, customize these in `~/.openclaw/workspace/`:

- **SOUL.md** — Core personality and behavioral rules
- **USER.md** — Your personal info and preferences
- **IDENTITY.md** — Bot's name, emoji, and character
- **TOOLS.md** — Environment-specific notes (cameras, SSH hosts, etc.)
- **HEARTBEAT.md** — Periodic check tasks

### Adding Models

Edit `~/.openclaw/openclaw.json` to add providers under `models.providers`. Use the format:

```json
{
  "models": {
    "providers": {
      "provider-name": {
        "baseUrl": "https://api.example.com/v1",
        "apiKey": "${API_KEY}",
        "api": "openai-completions",
        "models": [...]
      }
    }
  }
}
```

Reference models as `provider-name/model-id` in `agents.defaults.model.primary` or `fallbacks`.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Gateway won't start | Check `journalctl --user -u openclaw-gateway -n 50` |
| Health check fails | Wait 30s after start, then `openclaw health` |
| Extension install fails | `openclaw plugins install <name>` manually |
| Google auth expired | `openclaw gmail auth` (repeat for gcal/gdrive) |
| Telegram not responding | `openclaw telegram pair` + check bot token |
| Config validation error | `openclaw doctor` for diagnostics |

## License

MIT
