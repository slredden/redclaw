# Openclaw Provisioning Runbook

Operational reference for managing Openclaw bot users on a shared server.

---

## Architecture Overview

```
┌─────────────────────────────────────────┐
│              Ubuntu Server              │
│                                         │
│  /usr/bin/openclaw          ← shared    │
│  /usr/lib/node_modules/openclaw/        │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ bot1 (~/.openclaw/)             │   │
│  │   gateway → port 18789          │   │
│  │   cron jobs / watchdog          │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ bot2 (~/.openclaw/)             │   │
│  │   gateway → port 18989          │   │
│  │   cron jobs / watchdog          │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

- **System-wide binary:** `sudo npm install -g openclaw` installs once, all users share it
- **Per-user config:** Each bot user has their own `~/.openclaw/` — credentials, workspace, sessions
- **Per-user gateway:** Each user runs their own gateway process via `systemd --user` on a unique port
- **Per-user gog:** `gog` binary installed to `~/.npm-global/bin/gog` for each user separately
- **Remote desktop preserved:** Gateway hardening only changes `openclaw-gateway.service`.
  Do not disable or clean up xrdp, Chrome Remote Desktop, GNOME, PipeWire,
  WirePlumber, xdg portal, or snap desktop integration services on accounts
  that need a graphical remote desktop session.

---

## First Server Setup

### 1. Get the repo and install system prerequisites (admin, once)

```bash
# Option A — Git clone:
git clone git@github.com:slredden/redclaw.git ~/redclaw

# Option B — Download as zip (no git required):
curl -L https://github.com/slredden/redclaw/archive/refs/heads/main.zip -o /tmp/redclaw.zip
unzip /tmp/redclaw.zip -d ~/ && mv ~/redclaw-main ~/redclaw

# Then install prerequisites:
cd ~/redclaw
sudo ./prereqs.sh
```

Installs Node.js, system tools, and Openclaw system-wide.
Safe to re-run — skips steps already completed.

### 2. Create and prepare the bot user account (admin)

```bash
sudo adduser botname
sudo ./add-bot.sh --bot-user botname
```

Or in one step:
```bash
sudo ./add-bot.sh --bot-user botname --create-user
```

This copies the repo to `/home/botname/redbot-provision/` and enables systemd lingering.

### 3. Log in as the bot user (fresh session required)

```bash
# Do NOT use: sudo su - botname
# Lingering + D-Bus only work with a genuine login session:
ssh botname@localhost
# or log out of admin and SSH back in as botname
```

### 4. Get Codex tokens

```bash
openclaw onboard --auth-choice openai-codex --skip-daemon
# Follow the OAuth flow in your browser.
```

### 5. Configure and run setup.sh

```bash
cd ~/redbot-provision
cp .env.example .env
```

OpenAI OAuth is configured interactively — run `openclaw models auth login --provider openai` after setup.sh completes.

Open `.env` and fill in all fields. See `README.md` Step 6 for a full table
of required, optional, and default fields. If you want Telegram or Brave
Search, fill those in now — they're just `.env` fields, not post-setup steps.

```bash
nano .env
./setup.sh
```

**Save the gateway URL printed at the end** — it contains your auth token for
dashboard access. If you left `GATEWAY_TOKEN` blank, copy the generated token
back into `.env` so it stays the same on future runs.

### 6. Post-setup verification

```bash
source ~/.bashrc
openclaw health
~/status.sh
```

If you configured Telegram: `openclaw telegram pair`

For Google Workspace setup, see README.md → "After Setup → Google Workspace".

---

## Adding a Second Bot User

When the server already has Node.js, system tools, and Openclaw installed:

### 1. Prepare the new bot user account (admin)

```bash
sudo ./add-bot.sh --bot-user botname2 --create-user
```

### 2. Choose a unique gateway port

Each bot user must have a different `GATEWAY_PORT`. Check what's in use:

```bash
ss -tuln | grep 187
```

### 3. Log in as bot2 and run setup.sh

```bash
ssh botname2@localhost
cd ~/redbot-provision

# Get Codex tokens first:
openclaw onboard --auth-choice openai-codex --skip-daemon

cp .env.example .env
nano .env   # Set GATEWAY_PORT=18989 (or next 200-port increment), fill in all other values
./setup.sh
```

---

## Port Allocation

Openclaw uses adjacent ports relative to the gateway base port:

- **Base port** — gateway listens here
- **Base + 2** — browser control port
- **Base + 9 through Base + 108** — Chrome DevTools Protocol (CDP) range

This means each bot instance occupies a range of **110 ports** minimum. Use a
spacing of **200 ports** between bot instances to leave headroom:

| Bot User | Port  |
|----------|-------|
| bot1     | 18789 |
| bot2     | 18989 |
| bot3     | 19189 |
| bot4     | 19389 |

> **Minimum spacing is 110 ports; 200 is recommended.** Using adjacent ports
> (e.g. 18789, 18790) will cause CDP port collisions between bot instances.

To see what's currently in use:

```bash
ss -tuln | grep 18
```

`setup.sh` will abort with an error if the chosen port is already bound.

---

## Updating Openclaw

Openclaw is installed system-wide — updating it affects **all bot users** simultaneously.

```bash
# As admin:
sudo npm install -g openclaw@latest

# Verify installation:
which openclaw && openclaw --version

# Verify the ExecStart path still matches the actual entrypoint:
ls /usr/lib/node_modules/openclaw/dist/index.js

# As each bot user — reload and restart their gateway:
systemctl --user daemon-reload
openclaw gateway restart
openclaw health
```

**Important:** `openclaw update` does **not** work for npm installs. Always use
`sudo npm install -g openclaw@latest`.

After updating, check that each user's service `ExecStart` path is still valid.
If Openclaw changes its entrypoint location, the service unit is managed by `openclaw gateway install` — to customize, run `openclaw gateway install` and then edit `~/.config/systemd/user/openclaw-gateway.service` directly, or adjust parameters in `openclaw.json`.

**Provider config safety:** Openclaw upgrades sometimes change built-in provider defaults
(e.g. the `openai-codex` provider's `api` type and `baseUrl`). Instance configs in
`~/.openclaw/openclaw.json` are never modified by an upgrade — but if a config
hardcodes `api` or `baseUrl` under `models.providers`, those values will go stale.
The canonical template uses `"providers": {}` (empty) so the built-in defaults always
apply. Never add `api` or `baseUrl` to a custom provider entry unless you have a
specific reason to override the built-in.

### Shared admin scripts

This repo includes shared-server helpers in `scripts/`:

```bash
# Status for the known shared Openclaw users:
./scripts/openclaw-users-status

# Apply current gateway unit limits to existing users and restart gateways:
sudo ./scripts/openclaw-apply-gateway-limits

# Restart all known gateways after a Node.js or config change:
sudo ./scripts/openclaw-users-restart

# Full global update flow with backups, discovery, and health checks:
sudo ./update-openclaw.sh
```

Default managed users for the helper scripts are `marrowagent:18789`,
`infolkai:18800`, `outfitai:18900`, and `rebarai:18793`. Override that list
for one command with:

```bash
OPENCLAW_USERS='alice:18810 bob:18820' ./scripts/openclaw-users-status
```

The restart and limit scripts only target `openclaw-gateway.service`; they do
not alter graphical remote desktop services.

---

## Rollback After a Bad Update

Install a specific version:

```bash
sudo npm install -g openclaw@X.Y.Z
```

Then restart each bot user's gateway (see above).

---

## Service Management

The systemd user service (`openclaw-gateway.service`) is created by
`openclaw gateway install`, which is called automatically during `setup.sh`.
You do not need to create or edit the unit file manually.

Standard systemctl commands remain the same:

```bash
systemctl --user start   openclaw-gateway.service
systemctl --user stop    openclaw-gateway.service
systemctl --user restart openclaw-gateway.service
systemctl --user status  openclaw-gateway.service
```

To reinstall the service (e.g., after restoring from backup):

```bash
openclaw gateway install
```

---

## Restoring from Backup

```
1. Install prerequisites (if new server): sudo bash prereqs.sh
2. Extract backup: tar -xzf <backup-file>.tar.gz -C ~/
3. Register service: openclaw gateway install
4. Start gateway: systemctl --user start openclaw-gateway.service
5. Repair config: openclaw doctor --fix
6. Verify: openclaw status --deep
7. Re-auth if needed: openclaw models auth login --provider openai
```

---

## Node.js Upgrade Impact

After `sudo apt upgrade nodejs` or a Node.js major version change, all gateway
processes need a restart since they use the `/usr/bin/node` binary directly:

```bash
# As each bot user:
systemctl --user restart openclaw-gateway.service
openclaw health
```

---

## Remote Access (SSH Tunneling)

Gateways bind to `127.0.0.1` (loopback only). To access the dashboard remotely:

```bash
# Forward bot1's gateway to your local machine:
ssh -L 18789:127.0.0.1:18789 botname@server-ip

# Then open in browser:
# http://127.0.0.1:18789/?token=<GATEWAY_TOKEN>
```

For multiple bots:

```bash
ssh -L 18789:127.0.0.1:18789 -L 18989:127.0.0.1:18989 admin@server-ip
```

---

## Resetting a Single User

`reset.sh` wipes one user's Openclaw install without touching any other user:

```bash
# As the bot user:
cd ~/redbot-provision
./reset.sh           # Full reset (removes ~/.openclaw, gog, cron, service, etc.)
./reset.sh --dry-run  # Preview what will be removed
./reset.sh --keep-env # Reset but preserve .env file
```

The system-wide Openclaw binary is **not** removed. Other bot users are unaffected.

To uninstall Openclaw entirely (all users):
```bash
sudo npm uninstall -g openclaw
```

---

## Codex Token Refresh

Token refresh is now fully automatic — managed by Openclaw's built-in OAuth
handling. No manual refresh scripts or cron jobs are needed.

If OAuth is revoked (e.g., password change), run:

```bash
openclaw models auth login --provider openai
```

---

## Changing Configuration

To add or change features after initial setup, edit `.env` and re-run `setup.sh`:

```bash
cd ~/redbot-provision
nano .env          # Add TELEGRAM_BOT_TOKEN, BRAVE_SEARCH_KEY, etc.
./setup.sh
```

### What setup.sh does on re-run

| Action | Files |
|--------|-------|
| **Overwrites** (re-rendered from `.env`) | `openclaw.json`, `~/.codex/auth.json`, `USER.md`, `IDENTITY.md` |
| **Merges** (existing values preserved) | `auth-profiles.json` |
| **Preserves** (never touched) | `SOUL.md`, `AGENTS.md`, `HEARTBEAT.md`, `TOOLS.md` |
| **Idempotent** (safe to re-run) | cron jobs, `.bashrc` block, gog install, automation scripts |

### GATEWAY_TOKEN caveat

If `GATEWAY_TOKEN` is blank in `.env`, a new random token is generated each run.
This changes your dashboard URL. Save the token from the first run back into `.env`.

---

## SFTP Offsite Backups

The daily backup script (`~/backup.sh`) supports optional SFTP upload.
SFTP is configured via a separate config file (not `.env`).

**Config file:** `~/.config/<botname-lower>-backup.conf`

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

If this file doesn't exist, backups are stored locally only (7-day retention).

---

## Troubleshooting

### systemd --user fails: "D-Bus connection refused" or "Permission denied"

The bot user needs a genuine login session (not `su`):

```bash
# Wrong:
sudo su - botname
systemctl --user status   # FAILS

# Right:
ssh botname@localhost
systemctl --user status   # Works
```

If the user just had lingering enabled by add-bot.sh, they must log out and back in
before `systemctl --user` will work. This is a Linux D-Bus requirement.

Diagnose:
```bash
echo $XDG_RUNTIME_DIR        # Should be /run/user/<uid>
ls $XDG_RUNTIME_DIR/bus      # Should exist (D-Bus socket)
loginctl show-user $USER      # Should show Linger=yes
```

### Port conflict: setup.sh aborts on port already in use

```bash
# See what's using the port:
ss -tuln | grep :18789
lsof -i :18789

# Fix: set a different GATEWAY_PORT in .env and re-run setup.sh
```

### Gateway service ExecStart path after Openclaw update

If the gateway fails to start after an update, the entrypoint may have moved:

```bash
# Find the actual entry point:
ls /usr/lib/node_modules/openclaw/dist/index.js
# or:
cat $(npm root -g)/openclaw/package.json | jq '.main'

# If it changed, run `openclaw gateway install` then edit
# ~/.config/systemd/user/openclaw-gateway.service directly, or adjust
# parameters in openclaw.json, then reload:
./setup.sh --dry-run   # check what would change
./setup.sh             # re-run (existing files are preserved unless re-rendered)
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
```

### Gateway fails to start: check logs

```bash
journalctl --user -u openclaw-gateway.service -n 50
systemctl --user status openclaw-gateway.service
```

### gog authentication errors

If `gog gmail search` returns auth errors, re-authenticate:

```bash
gog auth add your@email.com --remote --step 1 --services gmail,calendar,drive,contacts
# Open the URL in browser, grant access, then:
gog auth add your@email.com --manual --auth-url '<paste redirect URL here>'
```

### Watchdog restart loop

If the watchdog keeps restarting the gateway, check:

1. Is the port unique? Another user may have the same port
2. Is the gateway actually unhealthy? `openclaw health`
3. Check gateway logs: `journalctl --user -u openclaw-gateway.service -n 100`

### Config changes lost after re-run

`openclaw.json` is re-rendered from `.env` every time `setup.sh` runs. If you
edited `openclaw.json` directly, those changes are overwritten. Always edit
`.env` instead and re-run `setup.sh`.

### Dashboard URL changed after re-run

If `GATEWAY_TOKEN` was blank in `.env`, a new random token was generated. Save
the token printed during setup back into `.env` to keep the same URL.
