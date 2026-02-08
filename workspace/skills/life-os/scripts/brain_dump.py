#!/usr/bin/env python3
"""
Brain Dump Processor

Takes unstructured thoughts and converts to organized notes.
"""

import os
import re
from datetime import datetime
from pathlib import Path

MEMORY_DIR = Path.home() / ".openclaw" / "workspace" / "memory"

CATEGORIES = ["ideas", "questions", "projects", "resources", "random"]


def categorize_thoughts(text):
    """Extract categorized thoughts from brain dump text."""
    categorized = {cat: [] for cat in CATEGORIES}
    
    # Split by common separators
    thoughts = re.split(r'[\n•\-]+', text)
    
    for thought in thoughts:
        thought = thought.strip()
        if not thought:
            continue
        
        # Simple categorization heuristics
        lower = thought.lower()
        
        # Project indicators
        if any(w in lower for w in ['build', 'create', 'app', 'website', 'launch', 'make']):
            if not any(c in categorized["projects"] for c in [thought]):
                categorized["projects"].append(thought)
            continue
        
        # Question indicators
        if '?' in thought or any(w in lower for w in ['how', 'why', 'what', 'when', 'should']):
            if not any(c in categorized["questions"] for c in [thought]):
                categorized["questions"].append(thought)
            continue
        
        # Idea indicators
        if any(w in lower for w in ['idea', 'thought', 'maybe', 'perhaps', 'consider']):
            if not any(c in categorized["ideas"] for c in [thought]):
                categorized["ideas"].append(thought)
            continue
        
        # Resource indicators
        if any(w in lower for w in ['link', 'book', 'tool', 'site', 'url', 'read']):
            if not any(c in categorized["resources"] for c in [thought]):
                categorized["resources"].append(thought)
            continue
        
        # Default to random
        categorized["random"].append(thought)
    
    return categorized


def extract_action_items(text):
    """Extract potential action items."""
    action_patterns = [
        r'(?:need to|should|must|have to|todo|task)[,:]?\s*(.+?)(?:[.\n]|$)',
        r'(?:action|next step)[,:]?\s*(.+?)(?:[.\n]|$)',
    ]
    
    actions = []
    for pattern in action_patterns:
        matches = re.findall(pattern, text, re.IGNORECASE)
        actions.extend([m.strip() for m in matches if len(m.strip()) > 3])
    
    return actions


def generate_dump_entry(text, categorized, actions):
    """Generate the brain dump markdown."""
    today = datetime.now()
    
    lines = [
        f"# Brain Dump: {today.strftime('%Y-%m-%d %H:%M')}",
        "",
        "## 📝 Raw Thoughts",
        "",
        "```",
        text,
        "```",
        "",
    ]
    
    lines.append("## 🏷️ Categorized")
    lines.append("")
    
    for category, items in categorized.items():
        if items:
            lines.append(f"### {category.title()}")
            for item in items:
                lines.append(f"- {item}")
            lines.append("")
    
    if actions:
        lines.extend([
            "## ⚡ Potential Action Items",
            "",
        ])
        for action in actions:
            lines.append(f"- [ ] {action}")
        lines.append("")
    
    lines.extend([
        "---",
        "",
        f"*Processed: {today.strftime('%Y-%m-%d %H:%M')}*",
    ])
    
    return "\n".join(lines)


def main():
    import sys
    
    print("🦊 Brain Dump Processor")
    print("=" * 40)
    print("Paste or type your thoughts. Press Ctrl+D when done.")
    print("-" * 40)
    
    if len(sys.argv) > 1:
        # Read from file
        text = Path(sys.argv[1]).read_text()
    else:
        # Read from stdin
        try:
            text = sys.stdin.read()
        except EOFError:
            text = ""
    
    if not text.strip():
        print("No content provided.")
        return
    
    # Process
    print("\nProcessing...")
    categorized = categorize_thoughts(text)
    actions = extract_action_items(text)
    
    # Generate output
    entry = generate_dump_entry(text, categorized, actions)
    
    # Save
    dump_dir = MEMORY_DIR / "brain-dumps"
    dump_dir.mkdir(parents=True, exist_ok=True)
    
    today = datetime.now()
    filename = dump_dir / f"{today.strftime('%Y-%m-%d-%H%M')}.md"
    filename.write_text(entry)
    
    print(f"\n✅ Brain dump saved to: {filename}")
    print(f"\n📊 Summary:")
    total = sum(len(items) for items in categorized.values())
    print(f"  - Total thoughts: {total}")
    for category, items in categorized.items():
        if items:
            print(f"  - {category.title()}: {len(items)}")
    if actions:
        print(f"  - Action items: {len(actions)}")


if __name__ == "__main__":
    main()
