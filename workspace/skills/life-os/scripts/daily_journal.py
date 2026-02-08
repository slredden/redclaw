#!/usr/bin/env python3
"""
Daily Journal Runner

Prompts for daily reflection and saves entries.
"""

import os
import yaml
from datetime import datetime
from pathlib import Path

MEMORY_DIR = Path.home() / ".openclaw" / "workspace" / "memory"
CONFIG_PATH = Path.home() / ".openclaw" / "workspace" / "life-os-config.yaml"

DEFAULT_PROMPTS = [
    "Three things you're grateful for:",
    "What energized you today?",
    "What drained your energy?",
    "One thing to prioritize tomorrow:",
]


def get_config():
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            return yaml.safe_load(f) or {}
    return {}


def generate_entry(responses):
    """Generate the journal markdown."""
    today = datetime.now()
    
    lines = [
        f"# Daily Journal: {today.strftime('%A, %B %d, %Y')}",
        "",
        f"**Date:** {today.strftime('%Y-%m-%d')}",
        f"**Time:** {today.strftime('%H:%M')}",
        "",
    ]
    
    # Mood/energy (if provided)
    if "mood" in responses:
        lines.extend([
            f"**Mood:** {responses['mood']}/10",
            "",
        ])
    if "energy" in responses:
        lines.extend([
            f"**Energy:** {responses['energy']}/10",
            "",
        ])
    
    lines.append("---")
    lines.append("")
    
    # Responses
    for question, answer in responses.items():
        if question not in ["mood", "energy"]:
            lines.extend([
                f"## {question}",
                "",
                answer,
                "",
            ])
    
    return "\n".join(lines)


def main():
    config = get_config()
    daily_config = config.get("daily", {})
    prompts = daily_config.get("prompts", DEFAULT_PROMPTS)
    
    print("🦊 Daily Journal - Evening Reflection")
    print("=" * 40)
    
    # Quick mood check
    print("\nQuick check-in:")
    mood = input("Mood (1-10): ").strip() or "5"
    energy = input("Energy level (1-10): ").strip() or "5"
    
    responses = {"mood": mood, "energy": energy}
    
    print("\n---")
    
    # Run through prompts
    for prompt in prompts:
        print(f"\n{prompt}")
        answer = input("> ").strip()
        if answer:
            responses[prompt] = answer
    
    # Generate and save
    entry = generate_entry(responses)
    
    journal_dir = MEMORY_DIR / "journal"
    journal_dir.mkdir(parents=True, exist_ok=True)
    
    today = datetime.now()
    filename = journal_dir / f"{today.strftime('%Y-%m-%d')}.md"
    filename.write_text(entry)
    
    print(f"\n✅ Journal entry saved to: {filename}")


if __name__ == "__main__":
    main()
