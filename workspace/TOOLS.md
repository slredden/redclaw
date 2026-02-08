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

### Gmail (openclaw-gmail plugin)
**Auth:** OAuth2 (auto-refreshes). If auth errors occur, run `openclaw gmail auth`.

**Available tools:**
- `gmail_profile` — Get account info (email, message/thread count)
- `gmail_list` — Search/list messages. Supports Gmail query syntax: `is:unread`, `from:user@example.com`, `subject:invoice`, `newer_than:7d`, `has:attachment`, etc.
- `gmail_read` — Read full message by ID (headers, body, attachments)
- `gmail_send` — Send a new email (to, cc, bcc, subject, body)
- `gmail_reply` — Reply to a message (auto-sets threading headers). Supports replyAll.
- `gmail_label` — Add/remove labels on a message, or list all labels
- `gmail_trash` — Move a message to trash
- `gmail_drafts` — List, create, read, or send drafts
- `gmail_threads` — List or read full conversation threads

**Workflow tips:**
- Use `gmail_list` first to find messages, then `gmail_read` with the message ID
- For conversations, `gmail_threads` with action "read" shows the full thread
- Always confirm with your human before sending emails or trashing messages

### Google Calendar (openclaw-gcal plugin)
**Auth:** OAuth2 (auto-refreshes). If auth errors occur, run `openclaw gcal auth`.

**Available tools:**
- `gcal_calendars` — List all calendars the user has access to
- `gcal_list` — List/search upcoming events. Defaults to next 7 days. Supports timeMin/timeMax (ISO 8601), text query.
- `gcal_get` — Get full details of a specific event by ID
- `gcal_create` — Create a new event (timed or all-day, with attendees, location, recurrence)
- `gcal_update` — Update an existing event (partial update — only send changed fields)
- `gcal_delete` — Delete an event by ID
- `gcal_freebusy` — Check free/busy status for a time range (useful for finding open slots)

**Workflow tips:**
- Use `gcal_list` to see upcoming events, then `gcal_get` for details
- For scheduling, use `gcal_freebusy` first to find open slots
- Default calendarId is "primary" — use `gcal_calendars` to see others
- Always confirm with your human before creating, updating, or deleting events

### Google Drive (openclaw-gdrive plugin)
**Auth:** OAuth2 (auto-refreshes). If auth errors occur, run `openclaw gdrive auth`.

**Available tools:**
- `gdrive_list` — List files/folders. Can filter by folder. Supports ordering (modifiedTime desc, name, etc.)
- `gdrive_search` — Search files by name or content. Supports simple text or Drive query syntax (`name contains 'budget'`, `mimeType = 'application/pdf'`).
- `gdrive_read` — Read file content. Google Docs export as plain text, Sheets as CSV. Truncates at 50K chars.
- `gdrive_info` — Get file metadata (size, owner, dates, link) or account storage info (omit fileId).
- `gdrive_upload` — Create a new text file in Drive (name, content, optional folder)
- `gdrive_mkdir` — Create a new folder
- `gdrive_trash` — Move a file/folder to trash
- `gdrive_share` — Share a file (grant access by email) or list current permissions

**Workflow tips:**
- Use `gdrive_search` to find files, then `gdrive_read` for content or `gdrive_info` for metadata
- `gdrive_list` with a folderId browses folder contents
- Always confirm with your human before uploading, trashing, or sharing files
