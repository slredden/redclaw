# Redclaw — Openclaw Bot Provisioning Toolkit

Reproducible setup for a personal AI assistant powered by [Openclaw](https://openclaw.dev) with free model routing, Telegram integration, mem0 memory, Google Workspace plugins, and automated health monitoring.

One script. One `.env` file. A fully operational AI assistant.

---

## Table of Contents

- [What You Get](#what-you-get)
- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Getting Your API Keys](#getting-your-api-keys)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [Post-Setup: Interactive Steps](#post-setup-interactive-steps)
- [Verification Checklist](#verification-checklist)
- [How It Works](#how-it-works)
- [Customization](#customization)
- [Maintenance & Operations](#maintenance--operations)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)
- [Security Notes](#security-notes)
- [License](#license)

---

## What You Get

- **Free AI models**: Kimi K2.5 via Nvidia NIM (primary) + DeepSeek V3.2 via Vercel AI Gateway (fallback)
- **Telegram bot**: DM-based personal assistant with pairing security
- **Google Workspace**: Gmail, Calendar, Drive integration via OAuth
- **Persistent memory**: mem0 cloud memory across sessions
- **Workspace system**: Personality, identity, and behavioral instructions the bot loads every session
- **Automation**: Daily backups, gateway watchdog (auto-restart), config rotation, internal cron jobs
- **Status dashboard**: Single command to check gateway, health, backups, storage, and config
- **Zero ongoing cost**: Every API used has a free tier sufficient for personal use

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    Your Machine                      │
│                                                      │
│  ┌──────────────┐     ┌──────────────────────────┐  │
│  │   Telegram    │────▶│   Openclaw Gateway       │  │
│  │   (chat UI)   │     │   (systemd service)      │  │
│  └──────────────┘     │                          │  │
│                        │  ┌─────────┐ ┌────────┐ │  │
│                        │  │ Plugins │ │ Skills │ │  │
│                        │  │ mem0    │ │ LifeOS │ │  │
│                        │  │ gmail   │ └────────┘ │  │
│                        │  │ gcal    │            │  │
│                        │  │ gdrive  │            │  │
│                        │  └─────────┘            │  │
│                        └──────────┬───────────────┘  │
│                                   │                  │
│  ┌────────────┐  ┌────────────┐  │  ┌────────────┐  │
│  │  Watchdog  │  │  Backups   │  │  │  Cron Jobs │  │
│  │ (5 min)    │  │ (daily)    │  │  │ (email,    │  │
│  │            │  │            │  │  │  digest)   │  │
│  └────────────┘  └────────────┘  │  └────────────┘  │
└──────────────────────────────────┼───────────────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
              ┌──────────┐  ┌──────────┐  ┌──────────┐
              │ Nvidia   │  │ Vercel   │  │ mem0     │
              │ NIM API  │  │ AI GW    │  │ Cloud    │
              │ (Kimi)   │  │(fallback)│  │ (memory) │
              └──────────┘  └──────────┘  └──────────┘
```

**How it flows:**
1. You message the bot on Telegram
2. The Openclaw gateway receives the message
3. It routes to Kimi K2.5 (free, via Nvidia). If that fails, it falls back to DeepSeek V3.2 (via Vercel)
4. The bot reads its workspace files (personality, your preferences) each session
5. It can check Gmail, manage your calendar, search the web, and remember things via mem0
6. Automation scripts keep it healthy and backed up

---

## Prerequisites

### System Requirements
- **OS**: Ubuntu 22.04+ or Debian 12+ (other Linux distros may work with adjustments)
- **Node.js**: v22+ (setup script will install if missing)
- **RAM**: 512MB+ free (the gateway is lightweight)
- **Disk**: ~500MB for Openclaw + extensions
- **Network**: Outbound HTTPS access (no inbound ports needed)

### Accounts & API Keys (All Free)

You need 5 API keys before running setup. All are free tier:

| Service | What It Does | Free Tier Limits |
|---------|-------------|-----------------|
| [Nvidia NIM](https://build.nvidia.com) | Primary AI model (Kimi K2.5) | 1000 req/day |
| [mem0](https://mem0.ai) | Persistent memory across sessions | 1000 memories |
| [Brave Search](https://brave.com/search/api) | Web search | 2000 queries/month |
| [Vercel AI Gateway](https://sdk.vercel.ai/gateway) | Fallback models (DeepSeek, Claude) | Usage-based |
| [Telegram BotFather](https://t.me/BotFather) | Chat interface | Unlimited |

Plus a **Google Cloud project** for Gmail/Calendar/Drive (free, but requires setup).

---

## Getting Your API Keys

### 1. Nvidia NIM API Key

1. Go to [build.nvidia.com](https://build.nvidia.com)
2. Sign in or create a free account
3. Navigate to any model page (e.g., search for "Kimi K2.5")
4. Click **"Get API Key"** in the top right
5. Copy the key — it starts with `nvapi-`

### 2. mem0 API Key

1. Go to [app.mem0.ai](https://app.mem0.ai)
2. Sign up for a free account
3. Go to **Settings** → **API Keys**
4. Create a new key — it starts with `m0-`

### 3. Brave Search API Key

1. Go to [brave.com/search/api](https://brave.com/search/api)
2. Click **"Get Started"** → select the **Free** plan
3. Create an account and verify your email
4. Your API key will be on the dashboard — starts with `BSA`

### 4. Vercel AI Gateway Key

1. Go to [sdk.vercel.ai/gateway](https://sdk.vercel.ai/gateway)
2. Sign in with your Vercel account (or create one free)
3. Generate an API key — starts with `vck_`

### 5. Telegram Bot Token

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot`
3. Choose a display name (e.g., "MyBot")
4. Choose a username (must end in `bot`, e.g., `my_helper_bot`)
5. BotFather gives you a token like `1234567890:ABCdefGHIjklMNOpqrSTUvwxYZ`
6. **Optional:** Send `/setdescription` and `/setabouttext` to customize your bot's profile

**Finding your Telegram User ID:** Message [@userinfobot](https://t.me/userinfobot) on Telegram — it replies with your numeric ID.

### 6. Google Cloud OAuth Setup

This is the most involved step. You need a Google Cloud project with OAuth credentials.

1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Create a new project (e.g., "My Bot")
3. **Enable APIs** — go to "APIs & Services" → "Library" and enable:
   - Gmail API
   - Google Calendar API
   - Google Drive API
4. **Configure OAuth consent screen:**
   - Go to "APIs & Services" → "OAuth consent screen"
   - Choose **External** user type
   - Fill in app name, support email
   - Add scopes: `gmail.modify`, `calendar`, `drive`
   - Add your email as a test user
   - **Important:** While in "Testing" status, only test users can authenticate
5. **Create OAuth credentials:**
   - Go to "APIs & Services" → "Credentials"
   - Click **"Create Credentials"** → **"OAuth 2.0 Client IDs"**
   - Application type: **Desktop app**
   - Download the JSON file
   - **Save it as** `gmail-client-secret.json` (you'll place it during post-setup)

> **Note:** You don't need to place this file until after `setup.sh` runs. The setup script creates the credentials directory; you just drop the file in afterward.

---

## Quick Start

```bash
# 1. Clone this repo
git clone <your-repo-url> ~/redclaw
cd ~/redclaw

# 2. Create your .env file from the template
cp .env.example .env

# 3. Fill in all your API keys and settings
nano .env    # or vim, or whatever you prefer

# 4. Preview what will happen (recommended first time)
./setup.sh --dry-run

# 5. Run the actual setup
./setup.sh
```

The script takes about 2-5 minutes. It will:
- Install Node.js if missing
- Install Openclaw globally
- Generate all config files from your `.env` values
- Install 4 extensions (mem0, gmail, gcal, gdrive)
- Set up the systemd gateway service
- Install cron jobs for backup, watchdog, and config rotation
- Copy workspace files (personality, behavior, tools)
- Start the gateway and verify health

### Command-Line Options

```
./setup.sh                    # Run with .env in script directory
./setup.sh --env-file /path   # Use a different .env file
./setup.sh --dry-run          # Preview without making changes
./setup.sh --help             # Show usage
```

---

## Configuration Reference

### `.env` Variables

#### Bot Identity
| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BOT_NAME` | Yes | — | Display name for your bot (e.g., "RedBot", "Jarvis"). Used in dashboard, workspace |
| `BOT_USER` | Yes | — | Linux username the bot runs as |
| `BOT_EMOJI` | Yes | — | Emoji used in identity file and dashboard |

#### User Info
| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `USER_NAME` | Yes | — | Your name — bot uses this in workspace context |
| `USER_TIMEZONE` | Yes | — | Timezone code (e.g., "MST", "EST", "UTC") |
| `USER_LOCATION` | Yes | — | City, State — used for weather, local news defaults |
| `USER_EMAIL` | Yes | — | Your email — used for morning digests and email monitoring |

#### API Keys
| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NVIDIA_API_KEY` | Yes | — | Nvidia NIM key (starts with `nvapi-`) |
| `MEM0_API_KEY` | Yes | — | mem0 key (starts with `m0-`) |
| `BRAVE_SEARCH_KEY` | Yes | — | Brave Search key (starts with `BSA`) |
| `VERCEL_AI_KEY` | Yes | — | Vercel AI Gateway key (starts with `vck_`) |

#### Telegram
| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TELEGRAM_BOT_TOKEN` | Yes | — | Token from @BotFather |
| `TELEGRAM_USER_ID` | No | — | Your numeric Telegram ID (for pairing) |

#### Gateway
| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GATEWAY_PORT` | No | `18789` | Local port for the gateway HTTP server |
| `GATEWAY_TOKEN` | No | auto-generated | Auth token for gateway API calls |

---

## Post-Setup: Interactive Steps

These steps require a browser or interactive terminal and cannot be automated by `setup.sh`. The script prints reminders at the end.

### Step 1: Place Google OAuth Credentials

Copy the `gmail-client-secret.json` you downloaded from Google Cloud Console:

```bash
cp ~/Downloads/client_secret_*.json ~/.openclaw/credentials/gmail-client-secret.json
```

### Step 2: Authenticate Google Services

Each command opens a browser for OAuth consent. Run them one at a time:

```bash
openclaw gmail auth     # Authenticate Gmail
openclaw gcal auth      # Authenticate Google Calendar
openclaw gdrive auth    # Authenticate Google Drive
```

**If you're on a headless server** (no browser), the auth command will print a URL. Open it on any machine with a browser, authorize, and paste the code back.

### Step 3: Test Gmail

```bash
openclaw gmail test
```

If this returns your inbox summary, Gmail is working.

### Step 4: Pair Telegram

1. Open Telegram and send any message to your bot
2. On the server, run:
   ```bash
   openclaw telegram pair
   ```
3. Follow the pairing prompts — this links your Telegram user ID to the bot

### Step 5: Verify Everything

Run the status dashboard:

```bash
~/status.sh
```

You should see green checks for gateway, health probe, watchdog, and config.

---

## Verification Checklist

After setup + interactive steps, verify each component:

```bash
# 1. Gateway health
openclaw health
# Expected: "healthy" or JSON with status: ok

# 2. Service status
openclaw gateway status
systemctl --user status openclaw-gateway
# Expected: active (running)

# 3. Full dashboard
~/status.sh
# Expected: Green checks across the board

# 4. Cron jobs installed
crontab -l
# Expected: 3 entries (backup, rotation, watchdog)

# 5. Extensions loaded
openclaw plugins list
# Expected: 4 extensions (mem0, gmail, gcal, gdrive)

# 6. Model config
cat ~/.openclaw/openclaw.json | jq '.models.providers.nvidia.models[0]'
# Expected: Kimi K2.5 model definition

# 7. Workspace files
ls ~/.openclaw/workspace/
# Expected: AGENTS.md, HEARTBEAT.md, IDENTITY.md, SOUL.md, TOOLS.md, USER.md, memory/, skills/

# 8. Gmail (after auth)
openclaw gmail test
# Expected: Inbox summary

# 9. Send a Telegram message to your bot
# Expected: Bot responds using Kimi K2.5
```

---

## How It Works

### Model Routing

The bot uses a **free model stack** with automatic fallback:

1. **Primary:** Kimi K2.5 via [Nvidia NIM API](https://build.nvidia.com) — fast, capable, free (1000 req/day)
2. **Fallback:** DeepSeek V3.2 (thinking) via [Vercel AI Gateway](https://sdk.vercel.ai/gateway) — used when Nvidia is down or rate-limited
3. **Optional:** Claude Opus 4.5 via Vercel — available but not in the default chain (can be switched to manually)

If the primary model fails, Openclaw automatically tries the next fallback. You never notice unless you check the logs.

### Workspace System

Every session, the bot reads its workspace files before responding:

| File | Purpose | Updated By |
|------|---------|-----------|
| `SOUL.md` | Core personality — "be helpful, not performative," have opinions, be resourceful | You (rarely) |
| `USER.md` | Your name, timezone, location, interests, preferences | You |
| `IDENTITY.md` | Bot's name, emoji, character description | You |
| `AGENTS.md` | Session bootstrap instructions, memory rules, safety guidelines, heartbeat behavior | You or bot |
| `TOOLS.md` | Environment-specific notes (API limits, tool usage tips) | Bot |
| `HEARTBEAT.md` | Periodic task checklist — bot checks this on heartbeat polls | Bot |
| `memory/` | Daily logs (`YYYY-MM-DD.md`) and curated long-term memory (`MEMORY.md`) | Bot |

The bot treats these files as its persistent identity. It reads them, updates them, and evolves them over time.

### Gateway & Systemd

The Openclaw gateway runs as a **systemd user service** (`openclaw-gateway.service`):

- Starts on boot (`WantedBy=default.target`)
- Auto-restarts on crash (`Restart=always`, 5s delay)
- Binds to `127.0.0.1:18789` (loopback only, not exposed to network)
- Authenticated via token in config

Manage it with standard systemd commands:
```bash
systemctl --user status openclaw-gateway
systemctl --user restart openclaw-gateway
journalctl --user -u openclaw-gateway -f    # Live logs
```

### Watchdog

The watchdog script (`watchdog.sh`) runs via cron every 5 minutes:

1. Checks gateway health via `openclaw health` CLI
2. If CLI fails, tries an HTTP probe on the gateway port
3. If both fail, restarts the systemd service
4. Rate-limited to 3 restarts per hour to prevent restart loops
5. Logs all actions to `~/<botname>-watchdog.log`
6. Auto-trims its own log at 1000 lines

### Backups

Daily at 3 AM, `backup.sh` runs:

- Copies the entire `~/.openclaw/` directory (config, workspace, credentials, extensions)
- Creates a sanitized config copy (gateway token stripped) for safe reference
- Retains 14 days of backups, auto-deletes older ones
- Logs to `~/<botname>-backups/backup.log`

### Internal Cron Jobs

Openclaw has its own cron system (separate from system crontab). Three jobs are pre-configured:

| Job | Schedule | What It Does |
|-----|----------|-------------|
| Email check (daytime) | Every 15 min, 8AM-10PM | Reads Gmail, follows instructions in emails |
| Email check (nighttime) | Hourly, 10PM-8AM | Reads Gmail, only notifies if urgent |
| Morning digest | Daily 8 AM | Emails you a summary: unread emails, news, sports, calendar |

---

## Customization

### Changing the Bot's Personality

Edit `~/.openclaw/workspace/SOUL.md`. This is the core behavioral framework. The default encourages:
- Being genuinely helpful (no filler phrases)
- Having opinions
- Being resourceful before asking questions
- Respecting privacy boundaries

### Changing Your Preferences

Edit `~/.openclaw/workspace/USER.md`. Update your interests, sports teams, news preferences, communication style.

### Adding or Swapping Models

Edit `~/.openclaw/openclaw.json`. To add a new provider:

```json
{
  "models": {
    "providers": {
      "my-provider": {
        "baseUrl": "https://api.example.com/v1",
        "apiKey": "${MY_API_KEY}",
        "api": "openai-completions",
        "models": [
          {
            "id": "model-name",
            "name": "Display Name",
            "contextWindow": 128000,
            "maxTokens": 8192,
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
          }
        ]
      }
    }
  }
}
```

Then reference it in `agents.defaults.model`:
```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "my-provider/model-name",
        "fallbacks": ["nvidia/moonshotai/kimi-k2.5"]
      }
    }
  }
}
```

**Important:** The key is `fallbacks` (plural array), not `fallback`.

Restart the gateway after config changes:
```bash
openclaw gateway restart
```

### Adding New Extensions

```bash
openclaw plugins install @scope/plugin-name
```

Extensions are configured in `openclaw.json` under `plugins.entries`.

### Adjusting Cron Schedules

**System cron** (backup, watchdog, rotation):
```bash
crontab -e
```

**Openclaw internal cron** (email checks, digest):
Edit `~/.openclaw/cron/jobs.json` — change `schedule.expr` values using standard cron syntax.

---

## Maintenance & Operations

### Daily Operations

Most things are automated. The bot checks email, monitors its own health, and backs itself up. You mostly just chat with it on Telegram.

### Useful Commands

```bash
# Check health
openclaw health

# Full status dashboard
~/status.sh

# View recent watchdog activity
tail -20 ~/<botname>-watchdog.log

# View gateway logs
journalctl --user -u openclaw-gateway --since "1 hour ago"

# Restart gateway
openclaw gateway restart

# Run diagnostics
openclaw doctor

# Manual backup
~/backup.sh

# Check backup history
ls -la ~/<botname>-backups/
```

### Updating Openclaw

```bash
sudo npm install -g openclaw@latest
openclaw gateway restart
openclaw doctor    # Verify everything still works
```

### Restoring from Backup

```bash
# List available backups
ls ~/<botname>-backups/

# Restore a specific backup (stop gateway first)
systemctl --user stop openclaw-gateway
cp -r ~/<botname>-backups/auto-YYYYMMDD-HHMMSS/.openclaw ~/
systemctl --user start openclaw-gateway
```

---

## Troubleshooting

### Gateway Issues

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| Gateway won't start | Check logs | `journalctl --user -u openclaw-gateway -n 50` |
| Health check fails after start | Still booting | Wait 30s, retry `openclaw health` |
| "Config validation error" | Bad JSON or unknown keys | `openclaw doctor` — check for typos in `openclaw.json` |
| Gateway keeps restarting | Check watchdog log | `tail -50 ~/<botname>-watchdog.log` |
| Port already in use | Another process on 18789 | `lsof -i :18789` to find it |

### Extension Issues

| Symptom | Fix |
|---------|-----|
| Plugin install fails | `openclaw plugins install <name>` manually, check network |
| Gmail auth expired | `openclaw gmail auth` (repeat for gcal/gdrive) |
| "No credentials" error | Verify `gmail-client-secret.json` exists in `~/.openclaw/credentials/` |
| OAuth consent error | Check Google Cloud Console — is the app still in "Testing"? Is your email added as a test user? |

### Telegram Issues

| Symptom | Fix |
|---------|-----|
| Bot doesn't respond | Check gateway is running: `openclaw health` |
| "Not paired" error | `openclaw telegram pair` |
| Bot responds very slowly | Primary model may be down — check fallback is working |

### Config Issues

| Symptom | Fix |
|---------|-----|
| `fallback` vs `fallbacks` error | Must be `fallbacks` (plural, array of strings) |
| Unknown config key error | Openclaw uses strict Zod validation — remove unrecognized keys |
| API key not working | Check key format: Nvidia=`nvapi-`, mem0=`m0-`, Brave=`BSA`, Vercel=`vck_` |

---

## File Structure

```
~/redclaw/
├── README.md                          # This file
├── setup.sh                           # Main provisioning script
├── .env.example                       # Secret template (copy to .env)
├── .gitignore                         # Excludes .env from version control
│
├── templates/                         # Config templates with ${VAR} placeholders
│   ├── openclaw.json.tmpl             # Main Openclaw config
│   ├── auth-profiles.json.tmpl        # Vercel AI Gateway auth
│   └── openclaw-gateway.service.tmpl  # Systemd unit file
│
├── workspace/                         # Agent workspace files
│   ├── USER.md.tmpl                   # Per-instance user profile (templated)
│   ├── IDENTITY.md.tmpl              # Per-instance bot identity (templated)
│   ├── SOUL.md                        # Personality framework (reusable as-is)
│   ├── AGENTS.md                      # Session bootstrap instructions
│   ├── TOOLS.md                       # Tool usage notes and API limits
│   ├── HEARTBEAT.md                   # Periodic task config (starts empty)
│   └── skills/                        # Skill packages
│       ├── life-os.skill              # Life OS skill archive
│       └── life-os/                   # Life OS skill source
│
├── scripts/                           # Automation scripts (templated)
│   ├── backup.sh                      # Daily backup with 14-day retention
│   ├── watchdog.sh                    # Gateway health watchdog (rate-limited)
│   ├── status.sh                      # Status dashboard
│   └── rotate-config.sh              # Config version rotation
│
└── cron/
    └── jobs.json.tmpl                 # Openclaw internal cron jobs (email, digest)
```

### What Gets Installed Where

| Source (this repo) | Destination (on target machine) |
|---|---|
| `templates/openclaw.json.tmpl` | `~/.openclaw/openclaw.json` |
| `templates/auth-profiles.json.tmpl` | `~/.openclaw/agents/main/agent/auth-profiles.json` |
| `templates/openclaw-gateway.service.tmpl` | `~/.config/systemd/user/openclaw-gateway.service` |
| `workspace/*.tmpl` | `~/.openclaw/workspace/*.md` (rendered) |
| `workspace/*.md` | `~/.openclaw/workspace/*.md` (copied) |
| `workspace/skills/*` | `~/.openclaw/workspace/skills/*` (copied) |
| `scripts/*.sh` | `~/*.sh` (rendered, executable) |
| `scripts/rotate-config.sh` | `~/.openclaw/rotate-config.sh` (rendered) |
| `cron/jobs.json.tmpl` | `~/.openclaw/cron/jobs.json` (rendered) |

---

## Security Notes

- **`.env` is gitignored** — your secrets never enter version control
- **Config files are `chmod 600`** — only your user can read them
- **Gateway binds to loopback only** (`127.0.0.1`) — not exposed to the network
- **Gateway auth uses a token** — auto-generated if not provided (48-char hex)
- **Telegram uses pairing** — only paired users can interact with the bot
- **Google OAuth tokens** are stored locally in `~/.openclaw/credentials/` and auto-refresh
- **Shell history** is configured to ignore lines containing API keys/tokens (`HISTIGNORE`)
- **Backups include a sanitized config** copy with the gateway token stripped

### What to Keep Secret

- The `.env` file — contains all API keys
- `~/.openclaw/openclaw.json` — contains API keys and gateway token
- `~/.openclaw/agents/main/agent/auth-profiles.json` — contains Vercel key
- `~/.openclaw/credentials/` — contains Google OAuth tokens
- Never commit these to a public repo

---

## License

MIT
