#!/usr/bin/env python3
"""Write the AppStream metainfo from the notes and the tags that already exist.

Every store front a Linux user meets — GNOME Software, KDE Discover, the Flathub website — reads
this file and nothing else, so a hand-maintained copy would be the one place the release notes go
stale. The prose comes from docs/release-notes.json (the same text the App Store gets) and each
release's date comes from that version's git tag, so a release cannot ship with a changelog that
disagrees with what was actually published.
"""
from __future__ import annotations

import html
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "io.github.guitaripod.Tailscode"
OUT = ROOT / "packaging" / "linux" / f"{APP_ID}.metainfo.xml"
NOTES = ROOT / "docs" / "release-notes.json"
RAW = "https://raw.githubusercontent.com/guitaripod/Tailscode/master"

SUMMARY = {
    None: "Coding agents over Tailscale",
    "de": "Coding-Agenten über Tailscale",
    "es": "Agentes de programación a través de Tailscale",
    "fr": "Des agents de code via Tailscale",
    "it": "Agenti di programmazione via Tailscale",
    "ja": "Tailscale 経由のコーディングエージェント",
    "ko": "Tailscale로 연결하는 코딩 에이전트",
    "pt_BR": "Agentes de programação via Tailscale",
    "zh_CN": "通过 Tailscale 使用编程智能体",
    "zh_TW": "透過 Tailscale 使用程式設計代理",
}

DESCRIPTION = [
    "Tailscode drives the coding agents running on your other machines. The agent stays where "
    "your code is; this is the window onto it, over your own tailnet, with nothing in between.",
    "It speaks to Claude Code (through claude-bridge) and to opencode, and it is a native GTK4 "
    "application rather than a web view.",
]

FEATURES = [
    "Watch an answer arrive at reading speed, with tool calls, diffs and images inline",
    "Approve or refuse what the agent wants to run, from the conversation",
    "Split the window into panes — several chats, a terminal, the file tree, a browser",
    "See what a conversation has cost and what the month has cost, priced per turn",
    "Read the repository the agent is working in: branch, diff, and what it has touched",
    "Keep every server up to date from inside the app, and be told honestly when it cannot",
]

SCREENSHOTS = [
    ("desktop/linux-columns@1920.png", "Two conversations side by side, with the file tree"),
    ("desktop/linux-grid@1920.png", "A grid of panes: chats, a terminal and the git surface"),
]


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args],
                          capture_output=True, text=True, check=True).stdout


def release_dates() -> dict[str, str]:
    """When each version was actually published, read from the tag that marks it and, for a version
    tagged only in the Apple projects, from the commit that stamped the number. A release entry
    without a date fails AppStream validation, so a version this repo cannot date at all is named
    rather than silently dropped."""
    dates: dict[str, str] = {}
    for line in git("log", "--format=%cs %s", "--grep=chore(release):").splitlines():
        date, _, subject = line.partition(" ")
        found = re.search(r"chore\(release\):\s*([0-9]+(?:\.[0-9]+)*)", subject)
        if found:
            dates[found.group(1)] = date
    for line in git("for-each-ref", "--format=%(refname:strip=2) %(creatordate:short)",
                    "refs/tags").splitlines():
        name, _, date = line.partition(" ")
        dates[name.lstrip("v")] = date
    return dates


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def paragraphs(text: str) -> list[str]:
    return [block.strip().replace("\n", " ") for block in text.split("\n\n") if block.strip()]


def releases() -> str:
    """Every version this repo can date, newest first — including the ones released after the App
    Store notes were last written, because a store page whose newest entry is older than the version
    the app reports reads as an app nobody has touched."""
    notes = json.loads(NOTES.read_text())
    dates = release_dates()
    undated = sorted(set(notes) - set(dates), key=version_key)
    if undated:
        print(f"!! no tag or release commit dates {', '.join(undated)} — omitted", file=sys.stderr)
    lines = ["  <releases>"]
    for version in sorted(set(dates) | set(notes), key=version_key, reverse=True):
        if version not in dates:
            continue
        lines.append(f'    <release version="{version}" date="{dates[version]}">')
        text = notes.get(version, {}).get("en-US", "")
        if text:
            lines.append("      <description>")
            for para in paragraphs(text):
                lines.append(f"        <p>{html.escape(para)}</p>")
            lines.append("      </description>")
        lines.append("    </release>")
    lines.append("  </releases>")
    return "\n".join(lines)


def summaries() -> str:
    lines = []
    for lang, text in SUMMARY.items():
        attr = "" if lang is None else f' xml:lang="{lang}"'
        lines.append(f"  <summary{attr}>{html.escape(text)}</summary>")
    return "\n".join(lines)


def document() -> str:
    features = "\n".join(f"      <li>{html.escape(item)}</li>" for item in FEATURES)
    described = "\n".join(f"    <p>{html.escape(para)}</p>" for para in DESCRIPTION)
    shots = []
    for index, (path, caption) in enumerate(SCREENSHOTS):
        kind = ' type="default"' if index == 0 else ""
        shots.append(f"    <screenshot{kind}>")
        shots.append(f"      <image>{RAW}/marketing/{path}</image>")
        shots.append(f"      <caption>{html.escape(caption)}</caption>")
        shots.append("    </screenshot>")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by scripts/gen-metainfo.py — edit that, not this. -->
<component type="desktop-application">
  <id>{APP_ID}</id>
  <launchable type="desktop-id">{APP_ID}.desktop</launchable>
  <name>Tailscode</name>
{summaries()}
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>GPL-3.0-or-later</project_license>
  <developer id="io.github.guitaripod">
    <name>Marcus Ordoñez</name>
  </developer>
  <description>
{described}
    <p>What it does:</p>
    <ul>
{features}
    </ul>
  </description>
  <categories>
    <category>Development</category>
  </categories>
  <keywords>
    <keyword>agent</keyword>
    <keyword>claude</keyword>
    <keyword>opencode</keyword>
    <keyword>tailscale</keyword>
    <keyword>terminal</keyword>
  </keywords>
  <url type="homepage">https://github.com/guitaripod/Tailscode</url>
  <url type="bugtracker">https://github.com/guitaripod/Tailscode/issues</url>
  <url type="vcs-browser">https://github.com/guitaripod/Tailscode</url>
  <branding>
    <color type="primary" scheme_preference="light">#4c8dff</color>
    <color type="primary" scheme_preference="dark">#3355e6</color>
  </branding>
  <content_rating type="oars-1.1"/>
  <supports>
    <control>pointing</control>
    <control>keyboard</control>
    <control>touch</control>
  </supports>
  <recommends>
    <display_length compare="ge">768</display_length>
  </recommends>
  <screenshots>
{chr(10).join(shots)}
  </screenshots>
{releases()}
</component>
"""


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(document())
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
