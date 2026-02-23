# Redclaw — Openclaw Bot Provisioning Toolkit

Reproducible setup for a personal AI assistant powered by [Openclaw](https://openclaw.dev) using your ChatGPT Plus, Pro, or Business subscription. Includes Telegram integration, Google Workspace access, automated health monitoring, and daily backups.

---

## What You Need

- **Server:** Ubuntu 22.04+ or Debian 12+, 512 MB+ RAM, outbound HTTPS access
- **ChatGPT subscription:** Plus, Pro, or Business (required for the OpenAI Codex model)
- **Two user accounts on the server:** an admin user (with sudo) and a dedicated bot user

---

## Quick Start

### Step 1: Get the Repo (Admin)

**Option A — Git clone:**
```bash
git clone git@github.com:slredden/redclaw.git ~/redclaw
cd ~/redclaw
```

**Option B — Download as zip (no git required):**
```bash
curl -L https://github.com/slredden/redclaw/archive/refs/heads/main.zip -o /tmp/redclaw.zip
unzip /tmp/redclaw.zip -d ~/
mv ~/redclaw-main ~/redclaw
cd ~/redclaw
```

### Step 2: Install System Prerequisites (Admin, Once)

```bash
sudo ./prereqs.sh
```

Installs Node.js 22+, npm, jq, curl, envsubst, openssl, and Openclaw system-wide.
Safe to re-run — skips steps already done.

### Step 3: Create the Bot User (Admin)

**Two-step (if the user already exists):**
```bash
sudo adduser <bot-user>
sudo ./add-bot.sh --bot-user <bot-user>
```

**One-step (creates the user for you):**
```bash
sudo ./add-bot.sh --bot-user <bot-user> --create-user
```

This enables systemd lingering and copies the repo to `~<bot-user>/redbot-provision/`.

### Step 4: Log In as the Bot User

```bash
ssh <bot-user>@localhost
```

> **Why SSH and not `su`?** Systemd user services require a real login session for
> D-Bus access. `su` doesn't create one, so the gateway service won't start.
> Always use a fresh SSH session after `add-bot.sh`.

### Step 5: Authenticate with OpenAI

Run the OAuth flow as the bot user:

```bash
openclaw onboard --auth-choice openai-codex --skip-daemon
```

This opens a browser for OAuth login. On a headless server it prints a URL —
open it on any device, complete the login, and it finishes automatically.

### Step 6: Configure Your Bot

```bash
cd ~/redbot-provision
cp .env.example .env
nano .env
```

#### Required fields

| Field | Description | Example |
|-------|-------------|---------|
| `BOT_NAME` | Display name for your bot | `"Jarvis"` |
| `BOT_USER` | Linux username the bot runs as | `jarvis` |
| `BOT_EMOJI` | Emoji identity | `🤖` |
| `USER_NAME` | Your real name | `"Wade Watts"` |
| `USER_TIMEZONE` | Your timezone | `EST` |
| `USER_LOCATION` | Your city | `"Oklahoma City, OK"` |
| `USER_EMAIL` | Your email | `you@example.com` |
| `OPENAI_ACCESS_TOKEN` | JWT access token (see below) | *(long string)* |
| `OPENAI_REFRESH_TOKEN` | Refresh token (see below) | `rt_...` |

#### Extracting your tokens

After completing Step 5, your tokens are stored locally. Extract them and paste
each into `.env`:

```bash
# Print the access token — copy the output into OPENAI_ACCESS_TOKEN in .env:
jq -r '.profiles["openai-codex:default"].access' \
  ~/.openclaw/agents/main/agent/auth-profiles.json

# Print the refresh token — copy the output into OPENAI_REFRESH_TOKEN in .env:
jq -r '.profiles["openai-codex:default"].refresh' \
  ~/.openclaw/agents/main/agent/auth-profiles.json
```

#### Optional fields (fill in now if you want them)

These features are configured *before* running setup. Fill them in `.env` now
if you want them — or leave them blank and add them later (see
[Changing Configuration Later](#changing-configuration-later)).

| Field | What it does | How to get it |
|-------|-------------|---------------|
| `TELEGRAM_BOT_TOKEN` | Enables Telegram messaging | Create a bot via [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_USER_ID` | Your Telegram user ID | Message [@userinfobot](https://t.me/userinfobot) |
| `BRAVE_SEARCH_KEY` | Enables web search (free tier: 2000/month) | [brave.com/search/api](https://brave.com/search/api) |

#### Fields you can usually leave alone

| Field | Default | Notes |
|-------|---------|-------|
| `GATEWAY_PORT` | `18789` | Must be unique per bot user. Check existing: `ss -tuln \| grep :187` |
| `GATEWAY_TOKEN` | *(blank)* | Auto-generated if blank. **Save the printed URL after setup** — it contains your dashboard password. Copy the token back into `.env` to keep the same URL on re-runs. |
| `GOG_KEYRING_PASSWORD` | `redbot` | Encrypts Google OAuth tokens locally. Any value works. Default is fine. |

### Step 7: Run Setup

```bash
./setup.sh
```

This generates config files, writes `~/.codex/auth.json`, installs the gateway
as a systemd service, sets up cron jobs (backup, watchdog, token refresh), and
starts the bot.

> **Save the gateway URL printed at the end** — it contains your auth token
> for dashboard access. If you left `GATEWAY_TOKEN` blank, copy the generated
> token back into `.env` so it stays the same on future runs.

After setup completes:

```bash
source ~/.bashrc
openclaw health
~/status.sh
```

---

## After Setup

### Google Workspace (Optional)

Give your bot access to Gmail, Calendar, and Drive.

1. Download your Google OAuth client secret from [Google Cloud Console](https://console.cloud.google.com):
   - Create a project → enable Gmail, Calendar, Drive APIs
   - Create OAuth 2.0 credentials (Desktop app) → download JSON

2. Place the file:
   ```bash
   cp ~/Downloads/client_secret_*.json ~/.openclaw/credentials/gmail-client-secret.json
   ```

3. Authenticate:
   ```bash
   gog auth credentials set ~/.openclaw/credentials/gmail-client-secret.json
   gog auth keyring file
   gog auth add <your-email> --remote --step 1 --services gmail,calendar,drive,contacts,sheets,docs
   ```
   Open the printed URL in a browser, grant access, then:
   ```bash
   gog auth add <your-email> --manual --auth-url '<paste redirect URL here>'
   ```

4. Verify:
   ```bash
   gog gmail search 'newer_than:1d' --max 5
   gog calendar list
   ```

### Telegram Pairing (If Configured)

If you added `TELEGRAM_BOT_TOKEN` and `TELEGRAM_USER_ID` in Step 6:

```bash
openclaw telegram pair
```

Message your bot on Telegram to confirm it responds.

### Slack (Optional — Manual Configuration)

Openclaw supports Slack natively, but this toolkit doesn't auto-configure it
yet. To set it up manually:

1. Create a Slack app at [api.slack.com/apps](https://api.slack.com/apps)
2. Add a Bot Token (`xoxb-...`) and note the Signing Secret
3. Edit `~/.openclaw/agents/main/agent/openclaw.json` and add the Slack
   connection under `connections` (see Openclaw docs for the exact format)
4. Restart the gateway: `systemctl --user restart openclaw-gateway`
5. Verify: `openclaw doctor`

---

## Adding More Bots

Each bot user needs their own account and a **unique** gateway port.

```bash
# As admin:
sudo ./add-bot.sh --bot-user <bot-user2> --create-user

# As bot-user2 (fresh SSH session):
ssh <bot-user2>@localhost
openclaw onboard --auth-choice openai-codex --skip-daemon

cd ~/redbot-provision
cp .env.example .env
nano .env   # Set GATEWAY_PORT=18790 (or next available), fill in all fields
./setup.sh
```

Check which ports are already in use:
```bash
ss -tuln | grep 187
```

Convention: first bot 18789, second 18790, third 18791, etc.

---

## Updating Openclaw

Openclaw is installed system-wide — updating affects all bot users on the server.

```bash
# As admin:
sudo npm install -g openclaw@latest

# As each bot user — restart their gateway:
systemctl --user restart openclaw-gateway
openclaw health
```

> **Note:** Do NOT use `openclaw update` — it does not work for npm installs.

---

## Changing Configuration Later

To add Telegram, Brave Search, or change any setting after initial setup:

1. Edit `.env` with the new values
2. Re-run `./setup.sh`
3. Restart the gateway if setup doesn't do it automatically:
   `systemctl --user restart openclaw-gateway`

### What setup.sh does on re-run

| Action | Files |
|--------|-------|
| **Overwrites** (re-rendered from `.env`) | `openclaw.json`, `~/.codex/auth.json`, `USER.md`, `IDENTITY.md`, systemd service file |
| **Merges** (existing values preserved) | `auth-profiles.json` |
| **Preserves** (never touched) | `SOUL.md`, `AGENTS.md`, `HEARTBEAT.md`, `TOOLS.md` |
| **Idempotent** (safe to re-run) | cron jobs, `.bashrc` block, gog install, automation scripts |

### GATEWAY_TOKEN caveat

If `GATEWAY_TOKEN` is blank in `.env`, a new random token is generated each
time you run `setup.sh`. This changes your dashboard URL. To avoid this, copy
the token from the first run's output back into `.env`.

### Token files explained

- **`~/.codex/auth.json`** — Used by the Codex CLI and the refresh script
- **`~/.openclaw/agents/main/agent/auth-profiles.json`** — Used by the Openclaw gateway

Both are updated atomically by `~/codex-refresh.sh` during daily token refresh.

---

## SFTP Offsite Backups (Optional)

The daily backup script (`~/backup.sh`) supports optional SFTP upload for
offsite copies. SFTP is configured via a separate config file, not `.env`.

**Config file:** `~/.config/<botname-lower>-backup.conf`

Create the file with your SFTP settings:

```bash
# Example: ~/.config/mybot-backup.conf
SFTP_HOST=backup.example.com
SFTP_PORT=22
SFTP_USER=backupuser
SFTP_PASS=secret              # Leave blank for key-based auth
SFTP_KEY=~/.ssh/id_backup     # Leave blank for password auth
SFTP_REMOTE_PATH=/backups
SFTP_RETENTION_DAYS=30
```

If this file doesn't exist, backups are stored locally only.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Gateway won't start | `journalctl --user -u openclaw-gateway -n 50` |
| Health check fails | Wait 30s, retry `openclaw health`; check logs |
| Token expired (500 errors) | `~/codex-refresh.sh` |
| systemd fails after `su` | Exit and SSH in fresh as the bot user |
| Port already in use | `lsof -i :18789` — set different `GATEWAY_PORT` in `.env` |
| Google auth expired | `gog auth add <email> --remote --step 1 --services gmail,calendar,drive,contacts` |
| Bot doesn't respond on Telegram | Check gateway: `openclaw health`; re-pair: `openclaw telegram pair` |
| Config changes lost after re-run | `openclaw.json` is re-rendered from `.env` each time — edit `.env`, not `openclaw.json` directly |
| Dashboard URL changed | `GATEWAY_TOKEN` was blank in `.env` — save the generated token back to `.env` |

See `RUNBOOK.md` for full operational details.

---

## Security Notes

- **`.env` is gitignored** — secrets never enter version control
- **Config files are `chmod 600`** — only the bot user can read them
- **Gateway binds to loopback only** (`127.0.0.1`) — not exposed to the network
- **Gateway auth uses a token** — 48-char hex, auto-generated if blank. This is the password for the web dashboard. Treat it like a password.
- **Telegram uses pairing** — only paired users can interact with the bot
- **Shell history** ignores lines containing keys/tokens (`HISTIGNORE`)

### What to Keep Secret

- The `.env` file (contains tokens and credentials)
- `~/.openclaw/openclaw.json` (contains gateway token)
- `~/.openclaw/agents/main/agent/auth-profiles.json` (contains API keys)
- `~/.openclaw/credentials/` (Google OAuth tokens)
- The gateway URL (contains the auth token in the query string)

---

## License

MIT
