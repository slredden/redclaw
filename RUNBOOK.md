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
│  │   gateway → port 18790          │   │
│  │   cron jobs / watchdog          │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

- **System-wide binary:** `sudo npm install -g openclaw` installs once, all users share it
- **Per-user config:** Each bot user has their own `~/.openclaw/` — credentials, workspace, sessions
- **Per-user gateway:** Each user runs their own gateway process via `systemd --user` on a unique port
- **Per-user gog:** `gog` binary installed to `~/.npm-global/bin/gog` for each user separately

---

## First Server Setup

### 1. Create the bot user

```bash
sudo adduser botname
# Set a strong password (or use --disabled-password for key-only access)
```

### 2. Run prereqs.sh as admin

```bash
# As an admin user (with sudo):
cd ~/redbot-provision
sudo ./prereqs.sh --bot-user botname
```

This installs Node.js, system tools, and Openclaw system-wide, then copies the repo
to `/home/botname/redbot-provision/` and enables systemd lingering.

### 3. Log in as the bot user (fresh session required)

```bash
# Do NOT use: sudo su - botname
# Lingering + D-Bus only work with a genuine login session:
ssh botname@localhost
# or log out of admin and SSH back in as botname
```

### 4. Configure and run setup.sh

```bash
cd ~/redbot-provision
cp .env.example .env
nano .env          # Fill in API keys, bot name, email, gateway port, etc.
./setup.sh
```

### 5. Complete manual steps

Follow the instructions printed by `setup.sh`:
- Google OAuth via gog (place client secret, run `gog auth add`)
- Telegram pairing (if configured)
- Reload shell: `source ~/.bashrc`
- Verify: `openclaw health` and `~/status.sh`

---

## Adding a Second Bot User

When the server already has Node.js, system tools, and Openclaw installed:

### 1. Create the new bot user

```bash
sudo adduser botname2
```

### 2. Run prereqs.sh with --skip-system

```bash
# As admin — skip Node.js/tools/openclaw install, only enable lingering + copy repo:
sudo ./prereqs.sh --bot-user botname2 --skip-system
```

### 3. Choose a unique gateway port

Before running setup.sh, edit `.env` and pick a port not in use:

```bash
# Check what's already bound:
ss -tuln | grep 187
```

Use the next available port in the 18789+ range (see Port Allocation below).

### 4. Log in as bot2 and run setup.sh

```bash
ssh botname2@localhost
cd ~/redbot-provision
cp .env.example .env
nano .env   # Set GATEWAY_PORT=18790 (or next available), fill in all other values
./setup.sh
```

---

## Port Allocation

Each bot user's gateway must bind to a unique port. Convention:

| Bot User | Port  |
|----------|-------|
| bot1     | 18789 |
| bot2     | 18790 |
| bot3     | 18791 |
| bot4     | 18792 |

To see what's currently in use:

```bash
ss -tuln | grep 187
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
If Openclaw changes its entrypoint location, update `templates/openclaw-gateway.service.tmpl`
and re-run `setup.sh` for each affected user.

---

## Rollback After a Bad Update

Install a specific version:

```bash
sudo npm install -g openclaw@X.Y.Z
```

Then restart each bot user's gateway (see above).

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
ssh -L 18789:127.0.0.1:18789 -L 18790:127.0.0.1:18790 admin@server-ip
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

If the user just had lingering enabled by prereqs.sh, they must log out and back in
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

# If it changed, update templates/openclaw-gateway.service.tmpl,
# then re-render and reload:
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
