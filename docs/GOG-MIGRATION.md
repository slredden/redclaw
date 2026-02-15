# Google Workspace Migration: Plugins to gog CLI

## 1. Overview

This guide replaces **three separate Node.js Openclaw plugins** with a **single unified CLI tool**:

| Removed                | Replaced by        |
|------------------------|-------------------|
| `openclaw-gmail`       | `gog gmail ...`   |
| `openclaw-gcal`        | `gog calendar ...`|
| `openclaw-gdrive`      | `gog drive ...`   |

**gog** (v0.10.0) is a single Go binary that covers Gmail, Calendar, and Drive — plus three additional services not previously available:

- **Contacts** (`gog contacts ...`)
- **Sheets** (`gog sheets ...`)
- **Docs** (`gog docs ...`)

After migration, the agent invokes Google services via shell commands (`gog gmail send ...`) instead of native Openclaw tool calls (`gmail_send`).

---

## 2. Pre-flight Checks

Before starting, verify the following:

### Confirm existing plugins are configured
Open `~/.openclaw/openclaw.json` and check that `plugins.entries` contains these three entries:
- `openclaw-gmail`
- `openclaw-gcal`
- `openclaw-gdrive`

If any are missing, they were never configured and you can skip their removal in step 6.

### Note your Google OAuth client secret path
The plugins typically reference a client secret file. Look for the `clientSecretPath` value in each plugin's config block. The default location is:
```
~/.openclaw/credentials/gmail-client-secret.json
```

### Note the user's email address
Find the email address used with the plugins (visible in token files or plugin config). You'll need it for gog authentication.

---

## 3. Install gog Binary

```bash
GOG_VERSION="0.10.0"
GOG_ARCH=$(uname -m)
case "$GOG_ARCH" in
    x86_64)  GOG_ARCH="amd64" ;;
    aarch64) GOG_ARCH="arm64" ;;
esac
curl -fsSL "https://github.com/steipete/gogcli/releases/download/v${GOG_VERSION}/gogcli_${GOG_VERSION}_linux_${GOG_ARCH}.tar.gz" -o /tmp/gogcli.tar.gz
tar -xzf /tmp/gogcli.tar.gz -C /tmp/ gog
mv /tmp/gog ~/.npm-global/bin/gog
chmod +x ~/.npm-global/bin/gog
rm -f /tmp/gogcli.tar.gz
gog --version
```

Verify the output shows `gog version 0.10.0` (or similar).

---

## 4. Configure gog Authentication

### 4a. Set up file keyring (required for headless servers)

```bash
gog auth keyring file
```

This tells gog to store credentials in an encrypted file instead of a desktop keyring (which isn't available on headless servers).

### 4b. Import existing Google OAuth credentials

```bash
gog auth credentials set ~/.openclaw/credentials/gmail-client-secret.json
```

Adjust the path if your client secret is stored elsewhere (see step 2).

### 4c. Authenticate with Google

Replace `EMAIL` with the user's actual email address:

```bash
# Step 1: Get the auth URL
gog auth add EMAIL --remote --step 1 --services gmail,calendar,drive,contacts,sheets,docs
```

Open the printed URL in a browser, sign in with the Google account, and grant access to the requested scopes. Google will redirect to a URL.

```bash
# Step 2: Complete authentication with the redirect URL
gog auth add EMAIL --manual --auth-url '<paste the full redirect URL here>'
```

### Troubleshooting auth

If the `--remote` flow fails with a state mismatch error, skip step 1 and use the `--manual` flow directly:

```bash
echo '<redirect URL>' | gog auth add EMAIL --manual
```

---

## 5. Set GOG_KEYRING_PASSWORD Environment Variable

gog encrypts its credential store with a password. Without this variable set, gog will prompt interactively — which breaks automation.

### Choose a password
Pick any string (e.g., `mysecretpassword`).

### Add to the systemd service file
Edit the gateway service file (e.g., `~/.config/systemd/user/openclaw-gateway.service`) and add:

```ini
Environment=GOG_KEYRING_PASSWORD=<your-password>
```

in the `[Service]` section.

Then reload systemd:
```bash
systemctl --user daemon-reload
```

### If using a provisioning `.env` file
Also add:
```bash
GOG_KEYRING_PASSWORD=<your-password>
```

to ensure the variable is available during provisioning and template rendering.

---

## 6. Remove Old Plugins from openclaw.json

Open `~/.openclaw/openclaw.json` and remove these three entries from the `plugins.entries` object:

```json
"openclaw-gmail": {
  "enabled": true,
  "config": {
    "clientSecretPath": "...",
    "tokenPath": "..."
  }
},
"openclaw-gcal": {
  "enabled": true,
  "config": {
    "clientSecretPath": "...",
    "tokenPath": "..."
  }
},
"openclaw-gdrive": {
  "enabled": true,
  "config": {
    "clientSecretPath": "...",
    "tokenPath": "..."
  }
}
```

**Leave all other plugin entries untouched** (telegram, mem0, memory-core, brave-search, etc.).

After editing, validate the JSON is still well-formed (no trailing commas, matching braces).

---

## 7. Update Workspace TOOLS.md

The agent needs to know how to use gog instead of the old native tools.

### Find your TOOLS.md
Typical locations:
- `~/.openclaw/workspace/TOOLS.md`
- `~/.openclaw/agents/main/agent/TOOLS.md`

### Remove old plugin documentation
Delete any references to the old plugin tool calls, such as:
- `gmail_list`, `gmail_read`, `gmail_send`, `gmail_search`
- `gcal_list`, `gcal_create`, `gcal_get`
- `gdrive_search`, `gdrive_list`, `gdrive_download`

### Add gog reference
Add the following section to TOOLS.md (replace `EMAIL` with the actual email address):

```markdown
### Google Workspace (gog skill)
**Auth:** OAuth2 via `gog auth` (file keyring). Account: EMAIL
**Services:** Gmail, Calendar, Drive, Contacts, Sheets, Docs

All gog commands support `--json` for structured output.

**Quick reference:**
- `gog gmail search '<query>' --max N` / `gog gmail read <id>` / `gog gmail send --to <addr> --subject <subj> --body <body>`
- `gog calendar list` / `gog calendar get <id>` / `gog calendar create`
- `gog drive ls` / `gog drive search '<query>'` / `gog drive download <id>`
- `gog contacts list` / `gog contacts get <id>`
- `gog sheets get <id>` / `gog sheets read <id> --range 'Sheet1!A1:D10'`
- `gog docs read <id>` / `gog docs export <id>`

**Important:** Always use `--json` for parseable output. Always confirm with user before sending emails, trashing, or modifying events/files.
```

---

## 8. Restart Gateway and Verify

### Restart the gateway

```bash
systemctl --user restart openclaw-gateway.service
```

> **Note:** If running from a non-interactive session (e.g., SSH without full login), you may need:
> ```bash
> DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" systemctl --user restart openclaw-gateway.service
> ```

### Test each service

```bash
gog gmail search 'newer_than:1d' --max 5 --json
gog calendar list --json
gog drive ls --json
```

Each command should return JSON output without errors. If you see authentication errors, revisit step 4.

---

## 9. Gotchas

- **Drive uses `ls` not `list`:** Use `gog drive ls`, not `gog drive list`.
- **`--remote` auth state mismatch:** The two-step `--remote` auth flow can fail on headless servers. If step 2 fails, use `--manual` with stdin pipe instead (see step 4 troubleshooting).
- **`GOG_KEYRING_PASSWORD` is mandatory for automation:** Without it set in the service environment, gog will prompt interactively and hang.
- **Old token files are harmless:** Files like `gmail-token.json`, `gcal-token.json`, `gdrive-token.json` in `~/.openclaw/credentials/` can be left in place or cleaned up later. They won't interfere with gog.
- **Agent instructions need updating:** The agent now uses shell commands (`gog gmail send ...`) instead of native tool calls (`gmail_send`). Update any agent instructions, prompts, or workspace files that reference the old tool names.
- **`systemctl --user` in non-interactive sessions:** May need `DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"` prefix to work correctly.
- **Uninstalling old plugins (optional):** After confirming gog works, you can optionally uninstall the old npm packages:
  ```bash
  npm uninstall -g openclaw-gmail openclaw-gcal openclaw-gdrive
  ```
