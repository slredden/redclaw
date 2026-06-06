# Openclaw Compliance Modernisation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bring all redclaw provisioning scripts into compliance with the current Openclaw release, removing obsolete custom workarounds and wiring in the new built-in features for auth, plugin management, gateway persistence, health monitoring, backup, and restore.

**Architecture:** Each task targets a specific file or closely related pair of files so changes are reviewable in isolation. The sequence follows data-flow order: remove what is no longer needed → update what changed → add what is new. No test framework exists; verification is done by dry-running scripts and validating rendered output with `openclaw config validate`.

**Tech Stack:** Bash, systemd user services, Openclaw CLI (`openclaw onboard`, `openclaw gateway install`, `openclaw models auth login`, `openclaw plugins install`, `openclaw config validate`), jq, envsubst, Node 24 LTS.

---

## Background: What Changed in Openclaw

| Area | Old (redclaw) | New (current Openclaw) |
|---|---|---|
| OpenAI OAuth | Manual JWT extraction → `.codex/auth.json` + `codex-refresh.sh` | `openclaw models auth login --provider openai` (built-in PKCE flow, auto-refresh) |
| Auth storage | `~/.codex/auth.json` + `auth-profiles.json` template | `~/.openclaw/agents/main/agent/auth-profiles.json` (managed by Openclaw) |
| Plugin install | Manual JSON config edits | `openclaw plugins install` + config entries |
| Gateway daemon | Hand-rolled `openclaw-gateway.service.tmpl` | `openclaw gateway install` generates the service unit |
| Node requirement | Node 22+ | Node 24 recommended (22.19+ still supported) |
| Slack/Discord/Brave | Manual env vars + config stanzas | Require explicit `openclaw plugins install @openclaw/slack` etc. |
| Named profiles | One config per user dir | `--profile <name>` flag cleanly isolates multi-instance on same user |
| Health CLI | `openclaw health --timeout` | Same (still valid); also `openclaw status --deep`, `openclaw channels status --probe` |

---

## Files to Remove (Obsolete)

- `scripts/codex-refresh.sh.tmpl` — Openclaw handles token refresh automatically
- `templates/auth-profiles.json.tmpl` — created by `openclaw onboard`
- `templates/openclaw-gateway.service.tmpl` — created by `openclaw gateway install`
- `extensions/` directory — already superseded by gog CLI (docs/GOG-MIGRATION.md confirms this)

## Files to Update

- `.env.example` — remove OAuth token fields; add onboarding instruction
- `prereqs.sh` — bump Node to 24, use official Openclaw install script
- `add-bot.sh` — remove service template step, note `openclaw gateway install` now used
- `setup.sh` — major rewrite of auth, plugin, and gateway sections
- `templates/openclaw.json.tmpl` — verify against current JSON5 schema; update plugin entries
- `cron/jobs.json.tmpl` — verify cron field names against current schema
- `scripts/backup.sh` — update backup paths for new state dir layout
- `scripts/watchdog.sh` — update health-check command set
- `scripts/status.sh` — add `openclaw status --deep` output
- `README.md` + `RUNBOOK.md` — reflect new setup flow

---

## Task 1: Remove Obsolete Files

**Files:**
- Delete: `scripts/codex-refresh.sh.tmpl`
- Delete: `templates/auth-profiles.json.tmpl`
- Delete: `templates/openclaw-gateway.service.tmpl`
- Delete: `extensions/` (entire directory)

**Step 1: Confirm nothing references auth-profiles.json.tmpl or codex-refresh in setup.sh beyond what we will replace**

```bash
grep -n "codex-refresh\|auth-profiles.json.tmpl\|openclaw-gateway.service.tmpl\|extensions/" setup.sh
```

Expected: lines that install/render those files — note the line numbers for Task 4.

**Step 2: Remove the files**

```bash
rm scripts/codex-refresh.sh.tmpl
rm templates/auth-profiles.json.tmpl
rm templates/openclaw-gateway.service.tmpl
rm -rf extensions/
```

**Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove obsolete auth-token, service-template, and extension files"
```

---

## Task 2: Update `.env.example`

**Files:**
- Modify: `.env.example`

**What to change:**
1. Remove `OPENAI_ACCESS_TOKEN` and `OPENAI_REFRESH_TOKEN` (and all their comments)
2. Add `OPENAI_API_KEY` as an optional fallback field with a comment explaining that the primary auth path is `openclaw models auth login --provider openai` (run interactively after setup)
3. Remove `GOG_KEYRING_PASSWORD` from the commented-out section explaining it — keep the field itself since gog still needs it, but update the comment to explain it is auto-generated if blank
4. Add a brief comment block at the top: "OAuth for OpenAI is set up interactively — see README for the onboard step"

**Step 1: Open the file and make edits**

Remove this block (and equivalent comments):
```
OPENAI_ACCESS_TOKEN=
OPENAI_REFRESH_TOKEN=
```

Replace with:
```bash
# Optional: OpenAI API key fallback (only if not using OAuth)
# Primary auth: run 'openclaw models auth login --provider openai' after setup.
# OPENAI_API_KEY=sk-...
```

**Step 2: Verify .env.example loads cleanly**

```bash
grep -n "ACCESS_TOKEN\|REFRESH_TOKEN" .env.example
```

Expected: zero matches.

**Step 3: Commit**

```bash
git add .env.example
git commit -m "chore: remove obsolete Codex token fields from .env.example"
```

---

## Task 3: Update `prereqs.sh`

**Files:**
- Modify: `prereqs.sh`

**What to change:**

1. **Node version gate:** Change `>= 22` to `>= 22.19` minimum, `24` preferred. The current check is already numeric — update the threshold constant and the warning message.

2. **Openclaw install method:** The current script runs `sudo npm install -g openclaw@latest`. This still works, but the official recommended method is now `curl -fsSL https://openclaw.ai/install.sh | bash`. Because the repo targets server provisioning where curl-piping may be undesirable, keep the npm method but add a comment noting the alternative and verify it still writes to `/usr/lib/node_modules/openclaw`.

3. **Entrypoint path check:** After install, verify `/usr/lib/node_modules/openclaw/dist/index.js` exists. If not, probe `$(npm prefix -g)/lib/node_modules/openclaw/dist/index.js` and warn with the actual path (this matters for the systemd service ExecStart).

**Step 1: Find the Node version check line**

```bash
grep -n "22\|node_version\|NODE" prereqs.sh | head -20
```

**Step 2: Update the minimum check**

Find the line like:
```bash
if [[ "$NODE_MAJOR" -lt 22 ]]; then
```

Change to:
```bash
if [[ "$NODE_MAJOR" -lt 22 ]]; then
  error "Node.js 22.19+ is required (24 LTS recommended). Found: $NODE_VERSION"
  exit 1
elif [[ "$NODE_MAJOR" -eq 22 ]]; then
  # Check minor for 22.19+
  NODE_MINOR=$(node -e "process.stdout.write(process.versions.node.split('.')[1])")
  if [[ "$NODE_MINOR" -lt 19 ]]; then
    error "Node.js 22.19+ is required (24 LTS recommended). Found: $NODE_VERSION"
    exit 1
  fi
  warn "Node.js 24 LTS is recommended for best Openclaw compatibility. Found: $NODE_VERSION"
fi
```

**Step 3: Add entrypoint verification after npm install**

After the `npm install -g openclaw@latest` line, add:
```bash
OPENCLAW_ENTRY="/usr/lib/node_modules/openclaw/dist/index.js"
if [[ ! -f "$OPENCLAW_ENTRY" ]]; then
  ALT_ENTRY="$(npm prefix -g)/lib/node_modules/openclaw/dist/index.js"
  if [[ -f "$ALT_ENTRY" ]]; then
    warn "Openclaw installed at non-standard path: $ALT_ENTRY"
    warn "Update OPENCLAW_ENTRY in setup.sh if it differs from $OPENCLAW_ENTRY"
  else
    warn "Could not locate openclaw/dist/index.js — run 'openclaw --version' to verify"
  fi
else
  ok "Openclaw entrypoint: $OPENCLAW_ENTRY"
fi
```

**Step 4: Run a dry-run verification**

```bash
bash --norc -n prereqs.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

**Step 5: Commit**

```bash
git add prereqs.sh
git commit -m "fix: update Node version gate to 22.19+/24 and add entrypoint path check"
```

---

## Task 4: Update `add-bot.sh`

**Files:**
- Modify: `add-bot.sh`

**What to change:**

The script's primary job (create user, enable linger, copy repo) remains correct. Two changes:

1. **Remove any reference to the systemd service template** — the old script may have mentioned copying `openclaw-gateway.service.tmpl`. If it does, remove that step. `openclaw gateway install` (run during setup.sh) now creates the service.

2. **Update the printed "next steps"** to say:
   - "Log in as `<bot-user>`, fill in `.env`, then run `./setup.sh`"
   - "After setup.sh completes, run `openclaw models auth login --provider openai` to complete OpenAI OAuth"
   - Remove any mention of manually pasting tokens

**Step 1: Check for service template references**

```bash
grep -n "service.tmpl\|OPENAI_ACCESS\|OPENAI_REFRESH" add-bot.sh
```

**Step 2: Remove or update any found references**

If the service template copy exists, remove those lines. Update the printed next-steps block accordingly.

**Step 3: Syntax check**

```bash
bash --norc -n add-bot.sh && echo "Syntax OK"
```

**Step 4: Commit**

```bash
git add add-bot.sh
git commit -m "fix: remove service-template step; update next-steps for new auth flow"
```

---

## Task 5: Rewrite `setup.sh` — Auth Section

**Files:**
- Modify: `setup.sh` (auth/credential generation section, approx lines 306-407 and 600-644)

This is the largest change. The old approach:
1. Wrote `~/.codex/auth.json` with extracted tokens
2. Created/merged `auth-profiles.json` with OAuth tokens
3. Installed and cron-scheduled `codex-refresh.sh`

The new approach:
1. Skip writing token files (Openclaw manages them)
2. After gateway starts, print a clear instruction: "Run `openclaw models auth login --provider openai` to complete OpenAI OAuth setup"
3. Remove the codex-refresh cron job installation
4. Keep the `OPENAI_API_KEY` env var write to `~/.openclaw/.env` as an optional fallback

**Step 1: Remove codex/auth.json write block**

Find the block (search for `~/.codex/auth.json` or `codex_dir`):
```bash
grep -n "codex\|auth\.json\|auth-profiles" setup.sh | head -30
```

Delete the lines that:
- Create `~/.codex/` directory
- Write `~/.codex/auth.json`
- Write or merge `auth-profiles.json`
- Validate `OPENAI_ACCESS_TOKEN` and `OPENAI_REFRESH_TOKEN` as required fields

**Step 2: Update required variable validation**

In the validation section (approx lines 90-110), remove `OPENAI_ACCESS_TOKEN` and `OPENAI_REFRESH_TOKEN` from the `REQUIRED_VARS` array.

Add optional check:
```bash
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  info "No OPENAI_API_KEY set — OpenAI OAuth will be configured via 'openclaw models auth login' after setup."
fi
```

**Step 3: Write OPENAI_API_KEY to ~/.openclaw/.env (optional fallback)**

After the config generation section, add:
```bash
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  OPENCLAW_ENV_FILE="${HOME}/.openclaw/.env"
  touch "$OPENCLAW_ENV_FILE"
  chmod 600 "$OPENCLAW_ENV_FILE"
  # Add or update OPENAI_API_KEY without duplicating
  if grep -q "^OPENAI_API_KEY=" "$OPENCLAW_ENV_FILE" 2>/dev/null; then
    sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=${OPENAI_API_KEY}|" "$OPENCLAW_ENV_FILE"
  else
    echo "OPENAI_API_KEY=${OPENAI_API_KEY}" >> "$OPENCLAW_ENV_FILE"
  fi
  ok "Wrote OPENAI_API_KEY to ~/.openclaw/.env"
fi
```

**Step 4: Remove codex-refresh cron job installation**

Find and remove the block that:
- Renders `codex-refresh.sh` from template
- Installs `codex-refresh.sh` to home dir
- Adds the `0 4 * * *` cron entry for it

```bash
grep -n "codex-refresh\|0 4 \* \* \*" setup.sh
```

Delete those lines entirely.

**Step 5: Update the final summary output**

In the summary section (approx lines 722-798), after the gateway URL, add:
```bash
echo ""
echo "  IMPORTANT: Complete OpenAI OAuth setup:"
echo "  Run: openclaw models auth login --provider openai"
echo "  (Skip if you are using OPENAI_API_KEY instead)"
```

**Step 6: Syntax check**

```bash
bash --norc -n setup.sh && echo "Syntax OK"
```

**Step 7: Commit**

```bash
git add setup.sh
git commit -m "fix: replace manual Codex token extraction with built-in openclaw OAuth flow"
```

---

## Task 6: Rewrite `setup.sh` — Gateway Section

**Files:**
- Modify: `setup.sh` (systemd/gateway section, approx lines 533-594)

The old approach manually rendered `openclaw-gateway.service.tmpl` and enabled it. The new approach uses `openclaw gateway install`.

**Step 1: Find the service installation block**

```bash
grep -n "gateway.service\|systemctl.*enable\|service.tmpl\|loginctl" setup.sh
```

**Step 2: Replace the manual service creation block**

Remove lines that:
- Render `openclaw-gateway.service.tmpl` via envsubst
- Write to `~/.config/systemd/user/openclaw-gateway.service`
- Run `systemctl --user daemon-reload`
- Run `systemctl --user enable openclaw-gateway`

Replace with:
```bash
step "Installing gateway as persistent systemd service..."
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  info "[dry-run] Would run: openclaw gateway install"
else
  # openclaw gateway install creates the systemd user unit and enables it.
  # It reads port and token from the config file we just wrote.
  openclaw gateway install || {
    warn "openclaw gateway install failed — gateway will not auto-start on login."
    warn "Run 'openclaw gateway install' manually once Openclaw is fully configured."
  }
fi
```

**Step 3: Update the gateway start block**

The start block (approx lines 682-717) may call `systemctl --user start openclaw-gateway.service`. This remains correct — keep it but ensure the service name is what `openclaw gateway install` creates (it uses `openclaw-gateway.service` for the default profile, or `openclaw-gateway-<profile>.service` for named profiles). Since we use default, the name is unchanged.

**Step 4: Port uniqueness check**

Keep the existing port-in-use check (`ss -tln` or `lsof -i`). This is still required since `openclaw gateway install` does not validate port conflicts. Just ensure the check runs before `openclaw gateway install`.

**Step 5: Syntax check**

```bash
bash --norc -n setup.sh && echo "Syntax OK"
```

**Step 6: Commit**

```bash
git add setup.sh
git commit -m "fix: use 'openclaw gateway install' instead of hand-rolled systemd template"
```

---

## Task 7: Update `setup.sh` — Plugin Installation

**Files:**
- Modify: `setup.sh` (plugin setup section)
- Modify: `templates/openclaw.json.tmpl`

Openclaw now requires plugins to be explicitly installed before they can be referenced in config. Telegram is built-in (no install needed). Slack, Brave Search, and Discord require `openclaw plugins install`.

**Step 1: Add plugin install block to setup.sh**

After the Openclaw config is written and before the gateway starts, add:
```bash
step "Installing required plugins..."

# Brave Search — only if API key provided
if [[ -n "${BRAVE_SEARCH_KEY:-}" ]]; then
  openclaw plugins install clawhub:brave 2>/dev/null \
    || warn "Brave Search plugin install failed — web search may be unavailable"
fi

# Slack — only if tokens provided
if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
  openclaw plugins install @openclaw/slack 2>/dev/null \
    || warn "Slack plugin install failed — Slack channel will be unavailable"
fi
```

**Step 2: Update `openclaw.json.tmpl` plugin allow list**

Open `templates/openclaw.json.tmpl`. Find the `plugins` section. Update the `allow` list to only list plugins that are actually used, and add entries only when the relevant env var is set. Since this is a template, use conditional env vars:

Replace the static allow list:
```json
"allow": ["telegram"]
```

With a dynamically handled approach — keep `telegram` always in the allow list. Brave and Slack should only be in the entries if their keys exist. Since envsubst cannot do conditional logic, handle this differently: always list all possible plugins in the allow list but set `enabled: false` by default; setup.sh will patch the config with `openclaw config set` after the fact.

Simpler approach: keep the current template structure (always `allow: ["telegram"]`), and after rendering the template in setup.sh, use `openclaw config set` to add Brave and Slack entries:
```bash
if [[ -n "${BRAVE_SEARCH_KEY:-}" ]]; then
  openclaw config set tools.webSearch.enabled true
  openclaw config set tools.webSearch.provider brave
  openclaw config set secrets.brave.key "${BRAVE_SEARCH_KEY}"
fi

if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
  openclaw config set plugins.allow '["telegram","slack"]'
  openclaw config set plugins.entries.slack.enabled true
fi
```

**Step 3: Verify config validates**

```bash
openclaw config validate
```

Expected: no errors. If errors occur, check the JSON5 path syntax for `openclaw config set`.

**Step 4: Commit**

```bash
git add setup.sh templates/openclaw.json.tmpl
git commit -m "fix: use openclaw plugins install for Brave/Slack; config set for integration keys"
```

---

## Task 8: Update `templates/openclaw.json.tmpl`

**Files:**
- Modify: `templates/openclaw.json.tmpl`

The template needs verification against the current Openclaw JSON5 schema. Key items to check and fix:

**Step 1: Validate the current template structure**

```bash
# Render with test values to check syntax
export BOT_USER=testbot BOT_NAME=TestBot BOT_EMOJI="🤖" USER_EMAIL=test@test.com
export GATEWAY_PORT=18789 GATEWAY_TOKEN=abc123 BRAVE_SEARCH_KEY="" TELEGRAM_BOT_TOKEN=""
export GOG_KEYRING_PASSWORD=pass
envsubst < templates/openclaw.json.tmpl > /tmp/test-openclaw.json
# If openclaw is installed, validate:
OPENCLAW_CONFIG_PATH=/tmp/test-openclaw.json openclaw config validate 2>&1 || true
```

**Step 2: Fix known schema changes**

Based on the current docs, verify these fields are correct (update if they differ):

- `agents.defaults.workspace` path — should be `/home/${BOT_USER}/.openclaw/workspace` ✓
- `agents.defaults.compaction` — field name may have changed; check schema with `openclaw config schema | jq '.properties.agents'`
- `gateway.mode` — docs show `gateway.bind` (loopback/lan/tailnet), not `mode`. If template uses `"mode": "local"`, change to `"bind": "loopback"`
- `gateway.auth` — verify structure: `{ "mode": "token", "token": "..." }` is still current
- `channels.telegram` structure — verify `dmPolicy` is still `"pairing"` (docs confirm: pairing | allowlist | open | disabled)
- `plugins.entries` — remove the `memory-core/lancedb` entry if it's explicitly disabled; unnecessary noise

**Step 3: Update the model identifier**

The template currently uses `openai-codex/gpt-5.3-codex`. Run:
```bash
openclaw models list --json 2>/dev/null | jq '.[].id' | head -20
```

Update the default model in the template to match what `openclaw models list` returns for the OpenAI Codex subscription model (currently appears to be `openai-codex/gpt-5.3-codex` — verify and update if changed).

**Step 4: Commit**

```bash
git add templates/openclaw.json.tmpl
git commit -m "fix: align openclaw.json.tmpl with current Openclaw JSON5 schema"
```

---

## Task 9: Update `scripts/backup.sh`

**Files:**
- Modify: `scripts/backup.sh`

The backup script needs to capture the updated state directory layout.

**What to change:**

1. **Auth profiles path:** The primary credential file is now `~/.openclaw/agents/main/agent/auth-profiles.json`. Ensure this is backed up (it likely already is via `~/.openclaw` recursive backup, but verify).

2. **Remove codex backup:** Any reference to `~/.codex/auth.json` should be removed (or kept as opportunistic: `[ -d ~/.codex ] && ...`).

3. **Add stability bundles:** Add `~/.openclaw/logs/stability/` to the backup list.

4. **Add `.openclaw/.env`:** The gateway token and API keys now live in `~/.openclaw/.env`. Ensure this is included (with a note: this file contains secrets — backup should be encrypted or owner-read-only).

5. **Update restore documentation comment** at the top of the script:
```bash
# Restore procedure:
#   1. tar -xzf <backup>.tar.gz -C ~/
#   2. openclaw gateway install   (re-registers the systemd service)
#   3. systemctl --user start openclaw-gateway
#   4. openclaw doctor --fix      (repairs any config issues after restore)
#   5. openclaw models auth login --provider openai  (if OAuth tokens expired)
```

**Step 1: Check current backup targets**

```bash
grep -n "codex\|auth-profiles\|\.env\|stability" scripts/backup.sh
```

**Step 2: Update accordingly**

Remove any `~/.codex` backup target. Add `~/.openclaw/.env` and `~/.openclaw/logs/stability/` explicitly if not already captured.

**Step 3: Verify backup completeness mentally**

Minimum backup set for a full restore:
- `~/.openclaw/openclaw.json` ✓ (in ~/.openclaw)
- `~/.openclaw/.env` ✓ (add explicitly)
- `~/.openclaw/agents/main/agent/auth-profiles.json` ✓ (in ~/.openclaw)
- `~/.openclaw/workspace/` ✓ (in ~/.openclaw)
- `~/.openclaw/credentials/` ✓ (in ~/.openclaw)
- `~/.openclaw/logs/stability/` ✓ (add explicitly)
- `~/.ssh/` ✓ (already backed up)
- `~/.config/gogcli/` ✓ (already backed up)
- Crontab ✓ (already backed up)

**Step 4: Commit**

```bash
git add scripts/backup.sh
git commit -m "fix: update backup targets for new openclaw state layout; add restore doc"
```

---

## Task 10: Update `scripts/watchdog.sh`

**Files:**
- Modify: `scripts/watchdog.sh`

**What to change:**

1. **Expand health check commands:** Add `openclaw status --deep` as a secondary check after `openclaw health --json` fails. `openclaw channels status --probe` is useful for diagnosing channel-specific issues but too slow for 5-min cron; keep optional.

2. **Service name:** Confirm the service name is still `openclaw-gateway.service` (now generated by `openclaw gateway install`). It is — no change needed.

3. **Restart command:** After `openclaw gateway install`, the correct restart path is still `systemctl --user restart openclaw-gateway.service`. No change.

4. **Add startup notification:** After a successful restart, log the `openclaw status` output so the log contains the health snapshot.

**Step 1: Find the health check block**

```bash
grep -n "openclaw health\|openclaw status\|health_check" scripts/watchdog.sh
```

**Step 2: Update the check sequence**

Replace the fallback curl check with `openclaw status --all --json` (exits non-zero if unhealthy):
```bash
# Primary check
if openclaw health --json --timeout 15000 > /tmp/watchdog-health.json 2>&1; then
  log "Gateway healthy"
  exit 0
fi

# Secondary check
if openclaw status --all 2>&1 | grep -q "ONLINE"; then
  log "Gateway status OK (secondary check)"
  exit 0
fi

log "Gateway unhealthy — restarting"
# ... restart logic ...
```

**Step 3: Commit**

```bash
git add scripts/watchdog.sh
git commit -m "fix: expand watchdog health checks with openclaw status --all fallback"
```

---

## Task 11: Update `scripts/status.sh`

**Files:**
- Modify: `scripts/status.sh`

**What to change:**

Add a section that runs `openclaw status --deep` and displays the output. This gives the operator a single-command view that includes both our script's local checks and Openclaw's own channel/gateway diagnostics.

**Step 1: Find the end of the existing status output**

```bash
grep -n "^echo\|health probe\|Last updated" scripts/status.sh | tail -10
```

**Step 2: Append openclaw status block**

Near the end of the script, add:
```bash
echo ""
echo "=== Openclaw Diagnostics ==="
openclaw status --all 2>&1 || echo "(openclaw status unavailable)"
```

**Step 3: Commit**

```bash
git add scripts/status.sh
git commit -m "feat: add 'openclaw status --all' section to status dashboard"
```

---

## Task 12: Update `cron/jobs.json.tmpl`

**Files:**
- Modify: `cron/jobs.json.tmpl`

**Step 1: Verify the cron schema field names are current**

The docs show cron jobs have: `cron`, `prompt`, `sessionTarget`, `wakeMode`. Verify our template uses the same field names:

```bash
cat cron/jobs.json.tmpl | jq 'keys'
```

If the template is not valid JSON5 (because of `${VAR}` substitutions), inspect manually:
```bash
grep -n "sessionTarget\|wakeMode\|session_target\|wake_mode" cron/jobs.json.tmpl
```

If field names differ from the current schema (e.g., `session_target` instead of `sessionTarget`), rename them.

**Step 2: Validate after rendering**

```bash
export USER_EMAIL=test@test.com BOT_USER=testbot
envsubst < cron/jobs.json.tmpl > /tmp/test-jobs.json
jq . /tmp/test-jobs.json > /dev/null && echo "Valid JSON"
```

Expected: "Valid JSON"

**Step 3: Commit**

```bash
git add cron/jobs.json.tmpl
git commit -m "fix: verify cron job field names match current Openclaw schema"
```

---

## Task 13: Update `README.md`

**Files:**
- Modify: `README.md`

**What to change:**

1. **Remove token extraction section:** Delete any steps about extracting `OPENAI_ACCESS_TOKEN` / `OPENAI_REFRESH_TOKEN` from browser dev tools or the Codex CLI. Replace with: "After setup.sh completes, run `openclaw models auth login --provider openai` to authenticate with OpenAI."

2. **Update setup flow summary:** New canonical flow:
   ```
   Admin:   bash prereqs.sh
   Admin:   bash add-bot.sh --bot-user <name> --create-user
   BotUser: cp .env.example .env && nano .env   # fill in GATEWAY_PORT, BOT_NAME, etc.
   BotUser: bash setup.sh
   BotUser: openclaw models auth login --provider openai   # OpenAI OAuth
   BotUser: openclaw channels login --channel whatsapp     # if using WhatsApp
   ```

3. **Update plugin setup:** Remove instructions for manually configuring Telegram/Slack/Brave in JSON. Replace with `openclaw plugins install` commands and note that `setup.sh` handles this for configured keys.

4. **Add restore section:** Brief bullet points pointing to `backup.sh` restore instructions.

**Step 1: Make the edits**

**Step 2: Read README.md before editing to avoid missing context**

```bash
grep -n "ACCESS_TOKEN\|REFRESH_TOKEN\|token.*extract\|dev tools\|browser.*console" README.md
```

Remove those sections and replace with the new auth instructions.

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update setup flow for built-in OAuth; remove manual token extraction steps"
```

---

## Task 14: Update `RUNBOOK.md`

**Files:**
- Modify: `RUNBOOK.md`

**What to change:**

1. **Token refresh section:** Remove the manual refresh procedure (8-day / 60-day lifecycle discussion). Replace with: "Token refresh is now automatic — managed by Openclaw. No manual intervention required unless OAuth is revoked."

2. **Port allocation:** Emphasize the Openclaw base-port rule: each instance needs its own base port, and the browser/CDP ports use base+2 and base+9 through base+108. The minimum spacing between bots is 20 ports (e.g., 18789, 18810, 18831...). Update the port allocation table.

3. **Service management:** Update all `systemctl` examples to note that services are now created by `openclaw gateway install`, not from our template. The service name remains `openclaw-gateway.service`.

4. **Add named profile note:** Document that `openclaw gateway --profile <name>` can be used for a rescue bot or secondary instance on the same user account.

5. **Add restore procedure section:** Document the full restore procedure:
   ```
   1. Install prereqs: bash prereqs.sh
   2. Extract backup: tar -xzf <backup>.tar.gz -C ~/
   3. Register service: openclaw gateway install
   4. Start: systemctl --user start openclaw-gateway
   5. Verify: openclaw doctor --fix && openclaw status --deep
   6. Re-auth if needed: openclaw models auth login --provider openai
   ```

**Step 1: Make the edits**

**Step 2: Commit**

```bash
git add RUNBOOK.md
git commit -m "docs: update runbook for built-in token refresh, port rules, and restore procedure"
```

---

## Task 15: End-to-End Dry-Run Verification

**Files:** All (read-only verification pass)

**Step 1: Syntax check all shell scripts**

```bash
for f in prereqs.sh add-bot.sh setup.sh reset.sh update-openclaw.sh \
          scripts/backup.sh scripts/watchdog.sh scripts/status.sh; do
  bash --norc -n "$f" && echo "OK: $f" || echo "FAIL: $f"
done
```

Expected: all "OK"

**Step 2: Template render check**

```bash
export BOT_USER=testbot BOT_NAME="Test Bot" BOT_EMOJI="🤖"
export USER_NAME="Test User" USER_EMAIL=test@test.com USER_TIMEZONE=UTC USER_LOCATION="Test City"
export GATEWAY_PORT=18789 GATEWAY_TOKEN=$(openssl rand -hex 24)
export GOG_KEYRING_PASSWORD=$(openssl rand -hex 16)
export BRAVE_SEARCH_KEY="" TELEGRAM_BOT_TOKEN="" SLACK_BOT_TOKEN=""

envsubst < templates/openclaw.json.tmpl > /tmp/rendered-openclaw.json && echo "openclaw.json OK"
envsubst < workspace/USER.md.tmpl > /tmp/rendered-user.md && echo "USER.md OK"
envsubst < workspace/IDENTITY.md.tmpl > /tmp/rendered-identity.md && echo "IDENTITY.md OK"
envsubst < cron/jobs.json.tmpl > /tmp/rendered-jobs.json && jq . /tmp/rendered-jobs.json > /dev/null && echo "jobs.json OK"
```

Expected: all "OK"

**Step 3: Check no references to deleted files remain**

```bash
grep -rn "codex-refresh\|auth-profiles.json.tmpl\|openclaw-gateway.service.tmpl\|OPENAI_ACCESS_TOKEN\|OPENAI_REFRESH_TOKEN" \
  --include="*.sh" --include="*.md" --include="*.json" --include="*.tmpl" .
```

Expected: zero matches (or only in this plan file and git history).

**Step 4: Final commit**

```bash
git add -A
git commit -m "chore: final compliance pass — verify all obsolete references removed"
```

---

## Summary of Changes

| File | Action | Key Change |
|---|---|---|
| `scripts/codex-refresh.sh.tmpl` | DELETE | Openclaw auto-refreshes tokens |
| `templates/auth-profiles.json.tmpl` | DELETE | Created by `openclaw onboard` |
| `templates/openclaw-gateway.service.tmpl` | DELETE | Created by `openclaw gateway install` |
| `extensions/` | DELETE | Superseded by gog CLI |
| `.env.example` | UPDATE | Remove token fields; add OAuth note |
| `prereqs.sh` | UPDATE | Node 22.19+/24 gate; entrypoint check |
| `add-bot.sh` | UPDATE | Remove service template step; update next-steps |
| `setup.sh` | MAJOR UPDATE | Remove token extraction; use `openclaw gateway install`; add plugin install |
| `templates/openclaw.json.tmpl` | UPDATE | Schema alignment; gateway.bind fix |
| `cron/jobs.json.tmpl` | UPDATE | Verify field names against current schema |
| `scripts/backup.sh` | UPDATE | Add `.openclaw/.env` and stability bundles; add restore docs |
| `scripts/watchdog.sh` | UPDATE | Add `openclaw status --all` fallback |
| `scripts/status.sh` | UPDATE | Add `openclaw status --all` section |
| `README.md` | UPDATE | New auth flow; remove token extraction |
| `RUNBOOK.md` | UPDATE | Token refresh note; restore procedure; port rules |
