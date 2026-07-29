"""Check every rendered frame of the launch film before it is encoded.

A 100-second film is 6000+ frames; eyeballing a contact sheet only samples it.
This walks all of them and reports, with timecodes, the four ways a frame can be
bad: the device drifting out of frame, the copy colliding with it, a frame that
is simply too dark to read, and a lurch in the motion that reads as a stutter.

  python3 scripts/film-qc.py --frames /tmp/film-v4
"""
import argparse
import os
import statistics
import sys

import numpy as np
from PIL import Image, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MONO = "/System/Library/Fonts/SFNSMono.ttf"
DISPLAY = "/Library/Fonts/SF-Pro-Display-Semibold.otf"


def card_right_edge(width, height, cards):
    """How far right the widest line of copy reaches, in pixels."""
    edge = 0.0
    for card in cards:
        hero = card.get("hero", False)
        size = int(height * (0.088 if hero else 0.032))
        face = ImageFont.truetype(DISPLAY if hero else MONO, size)
        for line in card["head"].split("\n"):
            edge = max(edge, width * 0.055 + face.getlength(line))
        if card.get("sub"):
            sub = ImageFont.truetype("/Library/Fonts/SF-Pro-Display-Regular.otf",
                                     int(height * 0.030))
            edge = max(edge, width * 0.055 + sub.getlength(card["sub"]))
    return edge


def load_cards():
    import importlib.util

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "film-post.py")
    source = open(path).read()
    namespace = {}
    start = source.index("CARDS = [")
    end = source.index("]\n", start) + 1
    exec(source[start:end], namespace)
    return namespace["CARDS"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", required=True)
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--dark-floor", type=float, default=6.0)
    args = parser.parse_args()

    cards = load_cards()
    files = sorted(f for f in os.listdir(args.frames) if f.endswith(".png"))
    if not files:
        sys.exit(f"no PNGs in {args.frames}")
    width, height = Image.open(os.path.join(args.frames, files[0])).size
    type_edge = card_right_edge(width, height, cards)
    print(f"{len(files)} frames at {width}x{height}; copy reaches x={type_edge:.0f}px")

    issues = {"dark": [], "missing": [], "clipped": [], "collision": [], "lurch": []}
    deltas = []
    previous = None
    lefts, rights, means = [], [], []

    for index, name in enumerate(files):
        image = Image.open(os.path.join(args.frames, name)).convert("L")
        full = np.asarray(image, dtype=np.uint8)
        small = np.asarray(image.resize((96, 54)), dtype=np.int16)
        if previous is not None:
            deltas.append(float(np.abs(small - previous).mean()))
        previous = small

        means.append(float(full.mean()))
        columns = np.where((full > 120).sum(axis=0) > 4)[0]
        if len(columns) == 0:
            lefts.append(-1)
            rights.append(-1)
            issues["missing"].append(index)
            continue
        left, right = int(columns.min()), int(columns.max())
        lefts.append(left)
        rights.append(right)

        t = index / args.fps
        showing = any(c["start"] <= t <= c["end"] for c in cards)
        if showing and left < type_edge + 12:
            issues["collision"].append(index)
        if left < width * 0.02 or right > width * 0.985:
            issues["clipped"].append(index)
        if means[-1] < args.dark_floor:
            issues["dark"].append(index)

    window = 14
    array = np.array(deltas)
    for i in range(window, len(array) - window):
        if array[i] < 1.5:
            continue
        local = float(np.median(array[i - window:i + window + 1]))
        if local > 0.4 and array[i] > 3.5 * local and array[i] > 5.0:
            issues["lurch"].append(i)

    def collapse(frames, gap=10):
        runs = []
        for f in frames:
            if runs and f - runs[-1][1] <= gap:
                runs[-1][1] = f
            else:
                runs.append([f, f])
        return runs

    ok = True
    for kind, frames in issues.items():
        if not frames:
            print(f"  {kind:<10} clean")
            continue
        ok = False
        runs = collapse(frames)
        spans = ", ".join(
            f"{a / args.fps:.1f}s" if a == b else f"{a / args.fps:.1f}–{b / args.fps:.1f}s"
            for a, b in runs[:14])
        print(f"  {kind:<10} {len(frames)} frames in {len(runs)} runs: {spans}")

    print(f"\nluma  min {min(means):.1f}  median {statistics.median(means):.1f}")
    valid = [x for x in lefts if x >= 0]
    print(f"phone left edge  min {min(valid)}px  median {statistics.median(valid):.0f}px")
    print("VERDICT:", "clean" if ok else "issues above")


main()
