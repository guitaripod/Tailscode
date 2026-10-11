#!/usr/bin/env python3
"""The framed, vertical cut of the preview, for the landing page and social: 1080x1920.

Same take, same score, same beats as `scripts/preview-video.py`, but where the store's preview is the
bare screen (a store preview that is not the app is a rejection), this one is the phone: the `frames`
CLI puts the recording in its real bezel, and each beat has the panel treatment — its own colour
behind it and its headline, with one phrase lit — so a cut of the video and a store panel are
recognisably one campaign.

  scripts/promo-video.py <clean-take.mp4> [out.mp4]

`<clean-take.mp4>` is the take trimmed to the preview's start and length with no captions on it.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

import AppKit
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG = "/opt/homebrew/bin/ffmpeg"
W, H = 1080, 1920

spec = importlib.util.spec_from_file_location("compose", os.path.join(ROOT, "scripts/market-compose.py"))
compose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compose)

BEATS = [
    ("Every machine,\none board", "one board", "#546BFF", 0.0, 4.6),
    ("Send a task in\none sentence", "one sentence", "#A855F7", 4.6, 8.4),
    ("Watch it\nwork, live", "work, live", "#30D158", 8.4, 14.6),
    ("Set how hard\nit thinks", "how hard", "#A855F7", 14.6, 17.8),
    ("Approve it from\nanywhere", "anywhere", "#FFB020", 17.8, 23.2),
    ("Know your limits\nbefore you hit them", "before you hit them", "#FF7A29", 23.2, 29.4),
]


def headline_png(text, highlight, accent, path):
    image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    lit = compose.mix(accent, (255, 255, 255), 0.30)
    block = compose.fitted(text, 108, AppKit.NSFontWeightBold, compose.HEADLINE_INK, W - 160, "left", 0.98, 2,
                           highlight, lit, kern=-1.8, floor=64)
    image.paste(block, (80, 120), block)
    image.save(path)


def main():
    clean = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "marketing/video/tailscode-promo-1080x1920.mp4")
    with open(os.path.join(ROOT, "marketing/video/preview.json")) as f:
        length = json.load(f)["duration"]
    work = tempfile.mkdtemp(prefix="tailscode-promo-")
    score = os.path.join(work, "score.wav")
    subprocess.run([sys.executable, os.path.join(ROOT, "scripts/preview-score.py"), score, str(length)], check=True)
    framed_dir = os.path.join(work, "framed")
    os.makedirs(framed_dir)
    subprocess.run(["frames", "video", clean, "--color", "Silver", "--background", "transparent",
                    "--codec", "prores", "--alpha", "--strip-audio", "-o", framed_dir], check=True)
    framed = os.path.join(framed_dir, sorted(os.listdir(framed_dir))[0])

    inputs, filters = [], []
    last = "base"
    filters.append(f"color=c=0x0a0b10:s={W}x{H}:r=30:d={length}[base]")
    index = 0
    for number, (text, highlight, accent_hex, start, end) in enumerate(BEATS):
        accent = compose.hexc(accent_hex)
        ground = compose.backdrop(W, H, accent).convert("RGB")
        ground_path = os.path.join(work, f"ground{number}.png")
        ground.save(ground_path)
        inputs += ["-loop", "1", "-t", str(length), "-i", ground_path]
        fade = f"fade=t=in:st={start}:d=0.7:alpha=1" if number else "null"
        filters.append(f"[{index}:v]format=rgba,{fade}[g{number}]")
        filters.append(f"[{last}][g{number}]overlay=0:0:eof_action=pass:format=auto[b{number}]")
        last = f"b{number}"
        index += 1
    for number, (text, highlight, accent_hex, start, end) in enumerate(BEATS):
        path = os.path.join(work, f"head{number}.png")
        headline_png(text, highlight, compose.hexc(accent_hex), path)
        inputs += ["-loop", "1", "-t", str(length), "-i", path]
        fade_in = f"fade=t=in:st={start + 0.1}:d=0.4:alpha=1"
        fade_out = f",fade=t=out:st={end - 0.4}:d=0.4:alpha=1" if number < len(BEATS) - 1 else ""
        filters.append(f"[{index}:v]format=rgba,{fade_in}{fade_out}[h{number}]")
        filters.append(f"[{last}][h{number}]overlay=0:0:eof_action=pass:format=auto[t{number}]")
        last = f"t{number}"
        index += 1
    inputs += ["-i", framed]
    device = index
    index += 1
    filters.append(f"[{device}:v]scale=-1:1500:flags=lanczos,format=rgba[phone]")
    filters.append(f"[{last}][phone]overlay=(W-w)/2:380:eof_action=pass:format=auto,fade=t=out:st={length - 0.6}:d=0.6[v]")
    inputs += ["-i", score]
    filters.append(f"[{index}:a]loudnorm=I=-16:TP=-1.5:LRA=9,afade=t=out:st={length - 1.2}:d=1.2,aresample=48000[a]")
    command = [FFMPEG, "-y", "-v", "error", *inputs, "-filter_complex", ";".join(filters),
               "-map", "[v]", "-map", "[a]", "-t", str(length),
               "-c:v", "libx264", "-profile:v", "high", "-crf", "18", "-preset", "slow", "-r", "30",
               "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k", "-ac", "2", "-movflags", "+faststart", out]
    subprocess.run(command, check=True)
    print(out)


if __name__ == "__main__":
    main()
