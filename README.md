# Redclaw — Openclaw Bot Provisioning Toolkit

Reproducible setup for a personal AI assistant powered by [Openclaw](https://openclaw.dev) using your ChatGPT Plus, Pro, or Business subscription. Includes Telegram integration, Google Workspace access, automated health monitoring, and daily backups.

---

## Prerequisites

- **Server:** Ubuntu 22.04+ or Debian 12+, 512MB+ RAM, outbound HTTPS access
- **ChatGPT subscription:** Plus, Pro, or Business (required for OpenAI Codex model access)
- **Two user accounts on the server:** an admin user (with sudo) and a dedicated bot user

---

## Quick Start

### 1. Clone the repo (as admin)

```bash
git clone git@github.com:slredden/redclaw.git ~/redclaw
cd ~/redclaw
```

### 2. Install system prerequisites (as admin, once per server)

```bash
sudo ./prereqs.sh
```

Installs Node.js 22+, npm, jq, curl, envsubst, openssl, and Openclaw system-wide.
Safe to re-run — skips steps already done.

### 3. Create the bot user and prepare their account (as admin)

```bash
sudo adduser <bot-user>
sudo ./add-bot.sh --bot-user <bot-user>
```

Or in one step if the user doesn't exist yet:
```bash
sudo ./add-bot.sh --bot-user <bot-user> --create-user
```

This enables systemd lingering and copies the repo to `~<bot-user>/redbot-provision/`.

### 4. Log in as the bot user (fresh SSH session required)

```bash
ssh <bot-user>@localhost
```

> **Important:** Use a fresh SSH login — do not use `su`. Systemd user services require a genuine login session for D-Bus access.

### 5. Get your Codex tokens

Run the OpenAI OAuth flow as the bot user:

```bash
openclaw onboard --auth-choice openai-codex --skip-daemon
```

Follow the browser prompt (or open the URL on another machine if headless). When done:

```bash
# Extract the tokens and save them somewhere safe (password manager recommended)
jq -r '.tokens.access_token' ~/.codex/auth.json
jq -r '.tokens.refresh_token' ~/.codex/auth.json
```

### 6. Configure and run setup

```bash
cd ~/redbot-provision
cp .env.example .env
nano .env       # Fill in tokens, bot identity, email, gateway port
./setup.sh
```

Setup generates config, installs the gateway as a systemd service, sets up cron jobs, and starts the bot. The gateway URL with your auth token is printed at the end — **save it in a password manager**.

---

## Optional: Telegram

1. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram — get a token like `1234567890:ABCdef...`
2. Get your numeric user ID from [@userinfobot](https://t.me/userinfobot)
3. Add to `.env`: `TELEGRAM_BOT_TOKEN=...` and `TELEGRAM_USER_ID=...`
4. Re-run `./setup.sh` if already installed, then pair: `openclaw telegram pair`

---

## Optional: Brave Search

Enables web search for the bot. Free tier: 2000 queries/month.

1. Get a key at [brave.com/search/api](https://brave.com/search/api)
2. Add to `.env`: `BRAVE_SEARCH_KEY=BSA...`
3. Re-run `./setup.sh` if already installed

---

## Optional: Slack

1. Create a Slack app with bot token and signing secret
2. Uncomment and fill in `SLACK_BOT_TOKEN` and `SLACK_SIGNING_SECRET` in `.env`
3. Re-run `./setup.sh`

---

## Google Workspace Setup

After `./setup.sh` completes, set up Google Workspace OAuth to give the bot access to Gmail, Calendar, and Drive.

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

---

## Adding a Second Bot

Each bot user needs their own account and a unique gateway port.

```bash
# As admin:
sudo ./add-bot.sh --bot-user <bot-user2> --create-user

# As bot-user2 (fresh SSH session):
cd ~/redbot-provision
cp .env.example .env
# Set GATEWAY_PORT=18790 (or next available — check: ss -tuln | grep 187)
# Fill in all other values
./setup.sh
```

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

See `RUNBOOK.md` for full operational details.

---

## Security Notes

- **`.env` is gitignored** — secrets never enter version control
- **Config files are `chmod 600`** — only the bot user can read them
- **Gateway binds to loopback only** (`127.0.0.1`) — not exposed to the network
- **Gateway auth uses a token** — 48-char hex, auto-generated if not set
- **Telegram uses pairing** — only paired users can interact with the bot
- **Shell history** ignores lines containing keys/tokens (`HISTIGNORE`)

### What to Keep Secret

- The `.env` file (contains tokens and credentials)
- `~/.openclaw/openclaw.json` (contains gateway token)
- `~/.openclaw/agents/main/agent/auth-profiles.json` (contains API keys)
- `~/.openclaw/credentials/` (Google OAuth tokens)

---

## License

MIT
