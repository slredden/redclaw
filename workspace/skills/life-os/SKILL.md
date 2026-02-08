---
name: life-os
description: Personal Life Operating System for OpenClaw — automate weekly check-ins, daily journaling, content research, and brain dump processing. Use for personal productivity workflows, habit tracking, mental wellness logging, content creation research, and thought organization. Triggers on requests for journals, check-ins, research automation, life OS, or personal dashboards.
---

# Life OS

Personal Life Operating System inspired by Alex Finn's "Claude Life" concept. Automates the repetitive parts of self-reflection, content research, and goal tracking.

## WARNING: User Customization Required

This skill requires user-specific configuration BEFORE use:
- Metrics to track (subscribers, revenue, projects, etc.)
- Content sources to monitor
- Personal goals and focus areas
- Preferred reflection prompts

See [references/SETUP.md](references/SETUP.md) for full configuration guide.

## Core Capabilities

### 1. Weekly Check-in — `/weekly-checkin`
Automated weekly reflection and metrics dashboard.

**What it does:**
- Prompts for wins, challenges, and insights from the week
- Collects metrics you care about (subscribers, revenue, projects completed)
- Generates visual dashboard showing trends over time
- Suggests adjustments for next week

**Setup:**
```bash
# Run once to configure your metrics
python3 scripts/weekly_setup.py

# Then schedule weekly (runs Sundays at 7pm by default)
python3 scripts/schedule_weekly.py
```

**Output:** `memory/weekly/YYYY-MM-DD.md` dashboard files

### 2. Daily Journal — `/daily-journal`
Structured daily reflection with mood tracking.

**What it does:**
- Asks meaningful prompts about your day
- Tracks mood/energy levels
- Identifies patterns over time
- Optionally: morning intentions or evening reflection

**Setup:**
```bash
# Configure your prompts and schedule
python3 scripts/daily_setup.py
```

**Output:** `memory/journal/YYYY-MM-DD.md` entries linked to weekly dashboards

### 3. Content Researcher — `/research`
Automated competitor analysis and content curation.

**What it does:**
- Monitors specified sources (newsletters, blogs, YouTube channels)
- Summarizes key insights with links
- Generates content ideas based on trends
- Saves research for later reference

**Setup:**
```bash
# Add sources to track
python3 scripts/research_setup.py

# Run manually or schedule
python3 scripts/run_research.py
```

**Output:** `memory/research/YYYY-MM-DD-findings.md`

### 4. Brain Dump Processor — `/brain-dump`
Transform scattered thoughts into organized insights.

**What it does:**
- Takes unstructured voice notes, quick thoughts, or ideas
- Categorizes by topic/theme
- Identifies action items
- Links related concepts across dumps

**Usage:**
```
"Process my brain dump about [topic]" → File in memory/brain-dumps/
"What were my ideas about [topic]?" → Search across all dumps
"Find action items from this week" → Extract todos
```

**Output:** Organized in `memory/brain-dumps/` with cross-references

## Quick Start

1. **Configure** → Run setup scripts to customize for your goals
2. **Schedule** → Set up cron jobs for automated check-ins
3. **Use** → Trigger workflows with natural language or scheduled runs
4. **Review** → Check `memory/` folder for dashboards and insights

## Workflow

```
User Request
    │
    ├─ "weekly check-in" ───────────→ Run weekly reflection
    ├─ "journal my day" ──────────────→ Daily entry prompt
    ├─ "research [topic]" ────────────→ Content analysis
    ├─ "brain dump" ─────────────────→ Process scattered thoughts
    └─ "setup life os" ─────────────→ Run all configuration
```

## Resources

### Scripts
- `scripts/weekly_setup.py` — Configure weekly metrics
- `scripts/daily_setup.py` — Configure journaling
- `scripts/research_setup.py` — Configure content sources
- `scripts/schedule_weekly.py` — Schedule automated jobs
- `scripts/run_research.py` — Execute research workflow
- `scripts/brain_dump.py` — Process and categorize thoughts

### References
- [setup.md](references/setup.md) — Complete configuration guide
- [templates.md](references/templates.md) — Output format templates
- [examples.md](references/examples.md) — Sample entries and dashboards
