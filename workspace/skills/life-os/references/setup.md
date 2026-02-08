# Life OS Setup Guide

Complete configuration guide for the Life OS skill.

## Initial Setup

### Step 1: Weekly Check-in Configuration

Edit `~/.openclaw/workspace/life-os-config.yaml` or run the setup script.

**Example configuration:**
```yaml
# Weekly check-in settings
weekly:
  day: "sunday"
  time: "19:00"
  timezone: "MST"
  
  # Metrics you want to track
  metrics:
    - name: "newsletter_subscribers"
      prompt: "Current newsletter subscriber count?"
      type: "number"
    - name: "youtube_subscribers"
      prompt: "Current YouTube subscribers?"
      type: "number"
    - name: "projects_completed"
      prompt: "Projects completed this week?"
      type: "number"
    - name: "focus_area"
      prompt: "What was your main focus this week?"
      type: "text"
  
  # Reflection prompts
  prompts:
    - "Biggest win this week?"
    - "What didn't go as planned?"
    - "One thing you learned?"
    - "Focus for next week?"
```

### Step 2: Daily Journal Configuration

```yaml
# Daily journal settings
daily:
  # Morning or evening (or both)
  time: "21:00"  # Evening reflection
  
  # Prompt categories
  prompts:
    gratitude:
      - "Three things you're grateful for?"
      - "Someone who helped you today?"
    reflection:
      - "What energized you today?"
      - "What drained you?"
    tomorrow:
      - "One thing to prioritize tomorrow?"
  
  # Mood tracking scale
  mood_scale: 1-10
  energy_scale: 1-10
```

### Step 3: Content Research Setup

```yaml
# Sources to monitor
research:
  newsletters:
    - "https://example-newsletter.com"
  youtube_channels:
    - channel_id: "UCxxx"
      name: "Alex Finn"
  rss_feeds:
    - "https://blog.example.com/rss.xml"
  
  # Topics to focus on
  interests:
    - "AI tools"
    - "Productivity systems"
    - "Content creation"
  
  # Schedule
  run_days: ["monday", "thursday"]
  time: "08:00"
```

### Step 4: Brain Dump Configuration

```yaml
# Brain dump settings
brain_dump:
  categories:
    - "ideas"
    - "questions"
    - "projects"
    - "resources"
    - "random"
  
  # Auto-extract actions
  extract_todos: true
  
  # Search and link related topics
  cross_reference: true
```

## Scheduling with Cron

Life OS uses OpenClaw's cron system for scheduling.

### Weekly Check-in
```bash
openclaw cron add --name "weekly-checkin" \
  --schedule "0 19 * * 0" \
  --command "weekly-checkin"
```

### Daily Journal
```bash
openclaw cron add --name "daily-journal" \
  --schedule "0 21 * * *" \
  --command "daily-journal"
```

### Research
```bash
openclaw cron add --name "content-research" \
  --schedule "0 8 * * 1,4" \
  --command "run-research"
```

## File Structure

Life OS creates this structure in `memory/`:

```
memory/
├── weekly/
│   ├── 2026-02-02.md   # Weekly dashboard
│   └── ...
├── journal/
│   ├── 2026-02-06.md   # Daily entries
│   └── ...
├── research/
│   ├── 2026-02-06-findings.md
│   └── ...
├── brain-dumps/
│   ├── 2026-02-06-morning.md
│   └── ...
└── life-os/
    └── config.yaml     # Your settings
```

## Customization

### Adding Custom Metrics

Edit the weekly configuration and add new metrics. They'll appear in prompts automatically.

### Changing Reflection Prompts

Modify the prompt lists in the configuration. The system will use whatever prompts you define.

### Adjusting Cadence

Change the cron schedules to match your preferences (daily, weekly, bi-weekly, etc.)

## Troubleshooting

### Cron jobs not firing?
- Check `openclaw cron list` for active jobs
- Verify timezone settings
- Check OpenClaw logs: `openclaw logs`

### Missing data?
- Ensure memory/ directory has write permissions
- Check configuration file syntax

### Not getting prompts?
- Verify the skill is loaded
- Check that SESSION.md or memory files aren't corrupted
