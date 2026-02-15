# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:
- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras
- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH
- home-server → 192.168.1.100, user: admin

### TTS
- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.

---

## API Limits & Rate Handling

### Brave Search API
**Limits:** Free tier = 1 req/sec, 2000 queries/month

**Strategy:**
- **Never parallelize searches** — sequential only
- Batch topics when possible: "US news Denver weather Arsenal" > 3 separate calls
- Prefer `web_fetch` over `web_search` for known URLs
- Consider 1-2 second delays between multiple searches

**Current quota:** Tracked in API responses (resets monthly)

### Google Workspace (gog skill)
**Auth:** OAuth2 via `gog auth` (file keyring). See the gog skill docs for full command reference.
**Services:** Gmail, Calendar, Drive, Contacts, Sheets, Docs

All gog commands support `--json` for structured output.

**Workflow tips:**
- Always use `--json` for parseable output
- Always confirm with your human before sending emails, trashing, or modifying events/files
