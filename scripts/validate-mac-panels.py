#!/usr/bin/env python3
"""Checks the Mac App Store panels scripts/market-compose-mac.py wrote.

For every locale it looks for: exactly ten PNGs named by the slugs in the caption book, each 2880x1800,
RGB without an alpha channel; and, from the fit report the compose step writes beside its frame cache, a
caption that fits: no more than two headline lines and two subline lines, every line inside the safe
column, the whole block ending above the laptop, the lit phrase present in the headline, and a headline
that did not have to shrink below a readable size. The compose step already refuses to write a panel that
fails the geometry; this is the check on what is on disk.

  scripts/validate-mac-panels.py                # every locale found on disk
  scripts/validate-mac-panels.py --locale de-DE
  scripts/validate-mac-panels.py --privacy      # also read every master and panel back with tesseract

The privacy pass reads the text of every master and panel and fails on anything that looks like the
machine's owner rather than the demo world: the owner's names, a home path other than the demo's, a
tailnet address other than the staged one, the front application's name in a menu bar, an Apple Account
banner, a place name. It is a net under the eye check, not a replacement for it.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PANELS = os.path.join(ROOT, "marketing/appstore/panels")
REPORT = os.path.join(tempfile.gettempdir(), "tailscode-mac-frames", "fit-report.json")
CAPTIONS = os.environ.get("TAILSCODE_CAPTIONS", os.path.join(ROOT, "marketing/captions"))
LOCALES = ["en-US", "de-DE", "es-ES", "fr-FR", "it", "ja", "ko", "pl", "pt-BR", "zh-Hans", "zh-Hant"]
MIN_HEADLINE = 110
GAP = 10


def book(locale):
    with open(os.path.join(CAPTIONS, locale + ".json")) as f:
        return json.load(f)["mac"]


def folder(locale):
    return os.path.join(PANELS, "mac") if locale == "en-US" else os.path.join(PANELS, "l10n", locale, "mac")


def check(locale, fit):
    problems = []
    entries = book(locale)
    path = folder(locale)
    if not os.path.isdir(path):
        return [f"{locale}: no folder {path}"]
    expected = {e["slug"] + ".png" for e in entries}
    found = {f for f in os.listdir(path) if f.endswith(".png")}
    if len(entries) != 10:
        problems.append(f"{locale}: the book has {len(entries)} Mac panels, not 10")
    for name in sorted(expected - found):
        problems.append(f"{locale}: missing {name}")
    for name in sorted(found - expected):
        problems.append(f"{locale}: {name} is not in the book")
    for name in sorted(expected & found):
        image = Image.open(os.path.join(path, name))
        if image.size != (2880, 1800):
            problems.append(f"{locale}/{name}: {image.size[0]}x{image.size[1]}, not 2880x1800")
        if image.mode != "RGB" or "A" in image.getbands():
            problems.append(f"{locale}/{name}: mode {image.mode} carries alpha")
    for entry in entries:
        row = fit.get(f"{locale}/{entry['slug']}")
        if not row:
            problems.append(f"{locale}/{entry['slug']}: no fit measurement (compose it again)")
            continue
        label = f"{locale}/{entry['slug']}"
        if row["headline_lines"] > 2:
            problems.append(f"{label}: headline wraps to {row['headline_lines']} lines")
        if row["sub_lines"] > 2:
            problems.append(f"{label}: subline wraps to {row['sub_lines']} lines")
        if row["headline_widest"] > row["column"] or row["sub_widest"] > row["column"]:
            problems.append(f"{label}: a line is wider than the safe column")
        if row["text_bottom"] > row["device_top"] - GAP:
            problems.append(f"{label}: caption ends at {row['text_bottom']}, laptop starts at {row['device_top']}")
        if row["headline_size"] < MIN_HEADLINE:
            problems.append(f"{label}: headline shrank to {row['headline_size']}px")
        if not row["lit_found"]:
            problems.append(f"{label}: the lit phrase is not in the headline")
    return problems


BANNED = [
    (r"marcus", "the owner's name"),
    (r"macbook", "the machine's name"),
    (r"/Users/(?!demo)", "a home path that is not the demo's"),
    (r"\b100\.(?!101\.102\.103\b|x\.y\.z)\d{1,3}\.\d{1,3}\.\d{1,3}\b", "a tailnet address that is not the staged one"),
    (r"vivaldi|bookmarks", "the front application's menu bar"),
    (r"apple account|icloud|sign in to a new device", "an Apple Account banner"),
    (r"helsinki|uusimaa|espoo", "a place name"),
    (r"gmail|@guitaripod|guitaripod@", "an email address"),
    (r"metal hud", "a status item of the machine"),
    (r"drag to record|select a window|record a part of the screen", "the system's screen-recording overlay"),
    (r"notification centre|notification center|do not disturb", "a system banner"),
]


def read_back(path):
    result = subprocess.run(["tesseract", path, "-", "--psm", "11", "-l", "eng"],
                            capture_output=True, text=True)
    return result.stdout


def privacy(locales):
    problems = []
    paths = []
    masters = os.path.join(ROOT, "marketing/appstore/mac-masters")
    for locale in locales:
        for base in (os.path.join(masters, locale), folder(locale)):
            if os.path.isdir(base):
                paths += [os.path.join(base, f) for f in sorted(os.listdir(base)) if f.endswith(".png")]
    for path in paths:
        text = read_back(path).lower()
        for pattern, meaning in BANNED:
            hit = re.search(pattern, text)
            if hit:
                problems.append(f"{os.path.relpath(path, ROOT)}: {meaning} ({hit.group(0)!r})")
    print(f"privacy pass: read back {len(paths)} images, looked for {len(BANNED)} kinds of personal text")
    return problems


def main():
    args = sys.argv[1:]
    locales = [args[args.index("--locale") + 1]] if "--locale" in args else [
        l for l in LOCALES if os.path.isdir(folder(l))]
    if not os.path.exists(REPORT):
        sys.exit(f"no fit report at {REPORT}; run scripts/market-compose-mac.py first")
    with open(REPORT) as f:
        fit = {f"{r['locale']}/{r['slug']}": r for r in json.load(f)}
    failed = 0
    for locale in locales:
        problems = check(locale, fit)
        count = len([f for f in os.listdir(folder(locale)) if f.endswith(".png")]) if os.path.isdir(folder(locale)) else 0
        worst = max((fit[k]["headline_size"] for k in fit if k.startswith(locale + "/")), default=0)
        smallest = min((fit[k]["headline_size"] for k in fit if k.startswith(locale + "/")), default=0)
        print(f"{locale}: {count} panels, headline {smallest}-{worst}px, {'OK' if not problems else str(len(problems)) + ' problem(s)'}")
        for problem in problems:
            print("   ", problem)
        failed += len(problems)
    if "--privacy" in args:
        leaks = privacy(locales)
        for leak in leaks:
            print("   ", leak)
        failed += len(leaks)
    print(f"validated {len(locales)} locale(s): {'PASS' if not failed else 'FAIL, ' + str(failed) + ' problem(s)'}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
