#!/usr/bin/env python3
"""
Weekly Check-in Setup Script

Configures the weekly metrics and prompts to track.
"""

import os
import yaml
from pathlib import Path

CONFIG_PATH = Path.home() / ".openclaw" / "workspace" / "life-os-config.yaml"

DEFAULT_CONFIG = {
    "weekly": {
        "day": "sunday",
        "time": "19:00",
        "metrics": [
            {"name": "projects_completed", "prompt": "Projects completed this week?", "type": "number"},
            {"name": "focus_area", "prompt": "Main focus this week?", "type": "text"},
        ],
        "prompts": [
            "Biggest win this week?",
            "What didn't go as planned?",
            "One thing you learned?",
            "Focus for next week?",
        ]
    }
}


def setup():
    print("🦊 Life OS: Weekly Check-in Setup")
    print("=" * 40)
    
    # Ensure config directory exists
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    
    # Load existing or create new
    config = DEFAULT_CONFIG.copy()
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            existing = yaml.safe_load(f) or {}
            if "weekly" in existing:
                config["weekly"] = existing["weekly"]
    
    print("\nLet's set up your weekly check-in. Enter your metrics or press Enter to skip.")
    print("Example: 'newsletter_subscribers' or 'revenue' or 'workouts'")
    print("Type 'done' when finished.\n")
    
    metrics = []
    while True:
        name = input("Metric name (or 'done'): ").strip()
        if name.lower() == 'done' or not name:
            break
        prompt = input(f"  Prompt for {name}: ") or f"Current {name}?"
        mtype = input(f"  Type [number/text]: ") or "text"
        metrics.append({"name": name, "prompt": prompt, "type": mtype})
    
    if metrics:
        config["weekly"]["metrics"] = metrics
    
    # Reflection prompts
    print("\nNow let's customize your reflection prompts.")
    print("Current prompts:")
    for i, p in enumerate(config["weekly"]["prompts"], 1):
        print(f"  {i}. {p}")
    
    custom = input("\nAdd custom prompt (or Enter to skip): ").strip()
    while custom:
        config["weekly"]["prompts"].append(custom)
        custom = input("Add another (or Enter to finish): ").strip()
    
    # Save config
    with open(CONFIG_PATH, 'w') as f:
        yaml.dump(config, f, default_flow_style=False)
    
    print(f"\n✅ Config saved to {CONFIG_PATH}")
    print("\nTo schedule your weekly check-in, run:")
    print("  openclaw cron add --name weekly-checkin --schedule '0 19 * * 0'")


if __name__ == "__main__":
    setup()
