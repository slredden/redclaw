#!/usr/bin/env python3
"""
Weekly Check-in Runner

Generates the weekly reflection dashboard.
"""

import os
import sys
import yaml
from datetime import datetime, timedelta
from pathlib import Path

MEMORY_DIR = Path.home() / ".openclaw" / "workspace" / "memory"
CONFIG_PATH = Path.home() / ".openclaw" / "workspace" / "life-os-config.yaml"


def get_config():
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            return yaml.safe_load(f) or {}
    return {}


def get_last_week_data():
    """Get last week's metrics for comparison."""
    last_week = datetime.now() - timedelta(days=7)
    filename = MEMORY_DIR / "weekly" / f"{last_week.strftime('%Y-%m-%d')}.md"
    if filename.exists():
        return filename.read_text()
    return None


def generate_dashboard(metrics_data):
    """Generate the markdown dashboard."""
    today = datetime.now()
    week_start = today - timedelta(days=today.weekday())
    week_end = week_start + timedelta(days=6)
    
    lines = [
        f"# Weekly Check-in: {week_start.strftime('%b %d')} - {week_end.strftime('%b %d, %Y')}",
        "",
        "## 📊 Metrics",
        "",
    ]
    
    for name, value in metrics_data.items():
        lines.append(f"- **{name.replace('_', ' ').title()}:** {value}")
    
    lines.extend([
        "",
        "## 🎯 Reflections",
        "",
    ])
    
    config = get_config()
    prompts = config.get("weekly", {}).get("prompts", [])
    
    for prompt in prompts:
        lines.extend([
            f"### {prompt}",
            "",
            "*(Your response here)*",
            "",
        ])
    
    lines.extend([
        "",
        "## 📈 Trends",
        "",
        "_Compare with last week (manual or automated)_",
        "",
        "---",
        "",
        f"*Logged: {today.strftime('%Y-%m-%d %H:%M')}*",
    ])
    
    return "\n".join(lines)


def main():
    config = get_config()
    weekly_config = config.get("weekly", {})
    
    # Collect metrics
    metrics_data = {}
    for metric in weekly_config.get("metrics", []):
        print(f"🦊 {metric['prompt']}")
        value = input("> ").strip()
        if value:
            metrics_data[metric['name']] = value
    
    # Generate dashboard
    dashboard = generate_dashboard(metrics_data)
    
    # Save to memory
    today = datetime.now()
    weekly_dir = MEMORY_DIR / "weekly"
    weekly_dir.mkdir(parents=True, exist_ok=True)
    
    filename = weekly_dir / f"{today.strftime('%Y-%m-%d')}.md"
    filename.write_text(dashboard)
    
    print(f"\n✅ Weekly check-in saved to: {filename}")
    print("\n" + "=" * 40)
    print(dashboard)


if __name__ == "__main__":
    main()
