#!/usr/bin/env python3
"""
Content Research Agent

Searches configured sources and generates research summaries.
"""

import os
import yaml
from datetime import datetime
from pathlib import Path

MEMORY_DIR = Path.home() / ".openclaw" / "workspace" / "memory"
CONFIG_PATH = Path.home() / ".openclaw" / "workspace" / "life-os-config.yaml"


def get_config():
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            return yaml.safe_load(f) or {}
    return {}


def generate_research_report(findings):
    """Generate research findings markdown."""
    today = datetime.now()
    
    lines = [
        f"# Content Research: {today.strftime('%A, %B %d, %Y')}",
        "",
        "## 🔍 Research Summary",
        "",
        findings.get("summary", "_Research completed_"),
        "",
    ]
    
    # Trending topics
    if "trends" in findings:
        lines.extend([
            "## 📊 Key Trends",
            "",
        ])
        for trend in findings["trends"]:
            lines.extend([
                f"### {trend['title']}",
                "",
                trend.get("summary", ""),
                "",
                f"**Source:** {trend.get('source', 'Unknown')}",
                f"**URL:** {trend.get('url', '')}",
                "",
            ])
    
    # Content ideas
    if "ideas" in findings:
        lines.extend([
            "## 💡 Content Ideas",
            "",
        ])
        for i, idea in enumerate(findings["ideas"], 1):
            lines.extend([
                f"### Idea {i}: {idea['title']}",
                "",
                idea.get("description", ""),
                "",
            ])
    
    # Resources
    if "resources" in findings:
        lines.extend([
            "## 📚 Resources",
            "",
        ])
        for r in findings["resources"]:
            lines.append(f"- [{r['title']}]({r['url']})")
        lines.append("")
    
    lines.extend([
        "---",
        "",
        f"*Generated: {today.strftime('%Y-%m-%d %H:%M')}*",
    ])
    
    return "\n".join(lines)


def main():
    config = get_config()
    research_config = config.get("research", {})
    
    print("🦊 Content Research Agent")
    print("=" * 40)
    
    interests = research_config.get("interests", ["AI tools", "productivity"])
    print(f"\nResearching: {', '.join(interests)}")
    print("\n(Note: This is a template. Integrate with web_search, RSS feeds, or APIs for live data)")
    print("-" * 40)
    
    # Placeholder for actual research
    # In production, this would call web_search, fetch RSS feeds, etc.
    
    # Manual input option
    print("\nEnter research findings manually or use web_search integration.")
    print("Quick research: What trends did you notice?")
    
    trend = input("Trend title: ").strip()
    if trend:
        summary = input("Summary: ").strip()
        source = input("Source: ").strip()
        
        findings = {
            "summary": f"Research completed on {datetime.now().strftime('%Y-%m-%d')}",
            "trends": [{"title": trend, "summary": summary, "source": source, "url": ""}],
            "ideas": [],
            "resources": []
        }
        
        # Generate report
        report = generate_research_report(findings)
        
        # Save
        research_dir = MEMORY_DIR / "research"
        research_dir.mkdir(parents=True, exist_ok=True)
        
        today = datetime.now()
        filename = research_dir / f"{today.strftime('%Y-%m-%d')}-findings.md"
        filename.write_text(report)
        
        print(f"\n✅ Research saved to: {filename}")
    else:
        print("\nSkipping research entry. Configure sources in life-os-config.yaml for automated runs.")


if __name__ == "__main__":
    main()
