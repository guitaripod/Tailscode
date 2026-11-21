#!/usr/bin/env python3
"""Turn the Outer Rim masters into the figures midgarcorp.cc/tailscode shows.

    scripts/landing-figures.py <shots folder> <site checkout (web/midgarcorp)>

The shots folder holds what the reshoot wrote, night and day side by side:

    iphone/, iphone-day/   scripts/shots.sh with TAILSCODE_SHOT_THEME=outerrim, once per appearance
    ipad/, ipad-day/       scripts/shots.sh --ipad, the same way
    mac/                   <name>.png and <name>-day.png from a --shot-live pass on a 1512x982 display
    linux/                 scripts/landing-linux/outer-rim.sh

Phones, iPads and Macs are framed with the `frames` CLI; a Linux window is shown as it is and, once
more, on a Studio Display for the line-up. Each figure is written as or-n-<name>.webp, or-d-<name>.webp
when its day master exists, and a 4K master under full/ for the desk shots, and the site's
src/data/tailscode-figures.json is rewritten to say which of them exist.
"""
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image

SHOTS = sys.argv[1]
SITE = sys.argv[2]
OUT = os.path.join(SITE, "public/screenshots/tailscode")
FACTS = os.path.join(SITE, "src/data/tailscode-figures.json")

PHONES = {
    "agents": "fl-agents", "wall": "fl-wall", "models": "fl-models", "peek": "fl-peek", "setup": "fl-setup",
    "steer": "fl-steer", "gpu": "fl-gpu", "carry": "fl-carry", "party": "fl-party", "costs": "08-usage",
    "home": "07-home", "master": "fl-master", "debrief": "fl-debrief", "hermes": "fl-hermes",
    "later": "fl-later", "scheduled": "fl-scheduled", "approval": "03-approval", "terminal": "fl-terminal",
}
PADS = {"wall": "fl-wall", "terminal": "fl-terminal", "live": "01-live"}
MACS = {"terminal": "mac-terminal", "megatron": "mac-megatron", "split": "mac-split"}
DESKS = {"split": "linux-split", "terminal": "linux-terminal"}


def framed(path, color=None, upscale=None):
    """The capture inside its device's bezel; `upscale` first, for a window shown on a display it is smaller than."""
    work = tempfile.mkdtemp()
    source = path
    if upscale:
        source = os.path.join(work, "up.png")
        Image.open(path).convert("RGB").resize(upscale, Image.Resampling.LANCZOS).save(source)
    command = ["frames", "-o", work]
    if color:
        command += ["-c", color]
    subprocess.run(command + [source], check=True, capture_output=True)
    name = os.path.splitext(os.path.basename(source))[0] + "_framed.png"
    return Image.open(os.path.join(work, name)).convert("RGBA")


def save(image, name, width, quality=86):
    """Writes one webp no wider than `width` and answers its size."""
    if image.width > width:
        image = image.resize((width, round(image.height * width / image.width)), Image.Resampling.LANCZOS)
    path = os.path.join(OUT, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path, "WEBP", quality=quality, method=6)
    return image.size


facts = {}


def figure(name, night, day, make, width, full=False):
    """One figure in every face its masters exist in, recorded in the facts the page reads."""
    if not os.path.exists(night):
        print("missing", night)
        return
    size = save(make(night), f"or-n-{name}.webp", width)
    fact = {"w": size[0], "h": size[1]}
    if full:
        save(Image.open(night).convert("RGB"), f"full/or-n-{name}.webp", 3840, 82)
        fact["full"] = True
    if os.path.exists(day):
        save(make(day), f"or-d-{name}.webp", width)
        fact["day"] = True
        if full:
            save(Image.open(day).convert("RGB"), f"full/or-d-{name}.webp", 3840, 82)
    facts[name] = fact


for role, raw in PHONES.items():
    figure(f"phone-{role}", f"{SHOTS}/iphone/{raw}.png", f"{SHOTS}/iphone-day/{raw}.png",
           lambda p: framed(p, "Silver"), 900)
for role, raw in PADS.items():
    figure(f"pad-{role}", f"{SHOTS}/ipad/{raw}.png", f"{SHOTS}/ipad-day/{raw}.png", framed, 1800)
for role, raw in MACS.items():
    figure(f"mac-{role}", f"{SHOTS}/mac/{raw}.png", f"{SHOTS}/mac/{raw}-day.png", framed, 2000)
for role, raw in DESKS.items():
    figure(f"desk-{role}", f"{SHOTS}/linux/{raw}.png", f"{SHOTS}/linux/{raw}-day.png",
           lambda p: Image.open(p).convert("RGB"), 1920, full=True)
figure("display-terminal", f"{SHOTS}/linux/linux-terminal.png", f"{SHOTS}/linux/linux-terminal-day.png",
       lambda p: framed(p, upscale=(5120, 2880)), 2200)

json.dump(dict(sorted(facts.items())), open(FACTS, "w"), indent=2)
open(FACTS, "a").write("\n")
print(len(facts), "figures;", sum(1 for f in facts.values() if f.get("day")), "with a day face")
