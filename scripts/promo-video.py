#!/usr/bin/env python3
"""The framed, vertical cut of the preview, for the landing page and social: 1080x1920.

Where the store's preview is the bare screen (a store preview that is not the app is a rejection),
this one is the phone: the `frames` CLI puts the store cut in its real bezel on the campaign's ink
ground, and each beat has the panel treatment — a claim of six words or fewer, one phrase lit in the
amber — so a cut of the video and a store panel read as one campaign. It is never uploaded to the
store.

  scripts/promo-video.py --rec <folder of .mov takes> [--store <store-cut.mp4>] [--out out.mp4]

The picture is the preview's own cut re-rendered at the phone's native 1320x2868 (the `frames` CLI picks
the bezel from the screen's size) and framed; the sound is the store cut's. The claims and when they
show are in marketing/video/preview.json.
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import shutil
import tempfile

import AppKit
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
W, H = 1080, 1920
INK = (11, 13, 17)
AMBER = (255, 181, 71)
HEADLINE = (250, 244, 235)
PHONE_HEIGHT = 1510
PHONE_TOP = 392
CROSSFADE = 0.3

spec = importlib.util.spec_from_file_location("compose", os.path.join(ROOT, "scripts/market-compose.py"))
compose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compose)


def ground_png(path):
    """The one ground the whole cut sits on: ink, with the amber pooled faintly where the claim is and
    a lifted patch behind the phone so its bezel has something to be seen against."""
    canvas = Image.new("RGB", (W, H), INK)
    compose.glow(canvas, (round(W * 0.1), -240), 800, 15, AMBER)
    compose.glow(canvas, (round(W * 0.5), round(H * 0.66)), 820, 22, (40, 48, 70))
    canvas.save(path)


def headline_png(text, highlight, path):
    """One claim as a transparent full-frame PNG: warm white, with the lit phrase in amber."""
    image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    lit = AMBER
    block = compose.fitted(text, 104, AppKit.NSFontWeightBold, HEADLINE, W - 160, "left", 0.98, 2,
                           highlight, lit, kern=-1.8, floor=64)
    image.paste(block, (80, 96), block)
    image.save(path)


def duration(path):
    out = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         capture_output=True, text=True, check=True)
    return float(out.stdout.strip())


def frame_phone(clean, work):
    environment = dict(os.environ, PATH="/opt/homebrew/bin:" + os.environ.get("PATH", ""))
    folder = os.path.join(work, "framed")
    os.makedirs(folder)
    frames = shutil.which("frames", path=environment["PATH"])
    subprocess.run([sys.executable, frames, "video", clean, "--color", "Silver", "--background", "transparent",
                    "--codec", "prores", "--alpha", "--strip-audio", "-o", folder], check=True, env=environment)
    return os.path.join(folder, sorted(os.listdir(folder))[0])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rec", required=True)
    parser.add_argument("--store", default=os.path.join(ROOT, "marketing/video/tailscode-preview-886x1920.mp4"))
    parser.add_argument("--out", default=os.path.join(ROOT, "marketing/video/tailscode-promo-1080x1920.mp4"))
    parser.add_argument("--config", default=os.path.join(ROOT, "marketing/video/preview.json"))
    args = parser.parse_args()
    clean, out = args.store, args.out
    with open(args.config) as f:
        claims = json.load(f)["captions"]
    length = duration(clean)
    work = tempfile.mkdtemp(prefix="tailscode-promo-")
    native = os.path.join(work, "native.mp4")
    subprocess.run([sys.executable, os.path.join(ROOT, "scripts/preview-video.py"), "--rec", args.rec, "--out", native,
                    "--poster", "", "--size", "1320x2868", "--silent",
                    "--config", args.config], check=True)
    framed = frame_phone(native, work)

    ground = os.path.join(work, "ground.png")
    ground_png(ground)
    inputs = ["-loop", "1", "-t", f"{length:.3f}", "-i", ground]
    filters = ["[0:v]format=rgba[base]"]
    last = "base"
    for number, claim in enumerate(claims, start=1):
        path = os.path.join(work, f"head{number}.png")
        headline_png(claim["text"], claim.get("highlight"), path)
        inputs += ["-loop", "1", "-t", f"{length:.3f}", "-i", path]
        start, end = claim["start"], claim["end"]
        fade_out = f",fade=t=out:st={end - CROSSFADE:.2f}:d={CROSSFADE}:alpha=1" if end < length - 0.05 else ""
        fade_in = f"fade=t=in:st={start:.2f}:d={CROSSFADE}:alpha=1" if start > 0.05 else "null"
        filters.append(f"[{number}:v]format=rgba,{fade_in}{fade_out}[h{number}]")
        filters.append(f"[{last}][h{number}]overlay=0:0:eof_action=pass:format=auto[t{number}]")
        last = f"t{number}"
    inputs += ["-i", framed, "-i", clean]
    device, sound = len(claims) + 1, len(claims) + 2
    filters.append(f"[{device}:v]scale=-1:{PHONE_HEIGHT}:flags=lanczos,format=rgba[phone]")
    filters.append(f"[{last}][phone]overlay=(W-w)/2:{PHONE_TOP}:eof_action=pass:format=auto,format=yuv420p[v]")
    command = [FFMPEG, "-y", "-v", "error", *inputs, "-filter_complex", ";".join(filters),
               "-map", "[v]", "-map", f"{sound}:a", "-t", f"{length:.3f}",
               "-c:v", "libx264", "-profile:v", "high", "-crf", "17", "-preset", "slow", "-r", "30",
               "-pix_fmt", "yuv420p", "-c:a", "copy", "-movflags", "+faststart", out]
    subprocess.run(command, check=True)
    shutil.rmtree(work, ignore_errors=True)
    print(out)


if __name__ == "__main__":
    main()
