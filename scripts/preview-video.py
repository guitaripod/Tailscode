#!/usr/bin/env python3
"""Cut the App Store app preview from a screen take of the app's own `--preview-tour`.

`scripts/film-capture.sh` records the thirty-second scripted tour off a dedicated simulator
(`TOUR_ARG=--preview-tour`). This trims it to the first frame of the app, scales it to the store's
886x1920 portrait size at 30 fps, lays a few words over each beat — set in the system face, on a
dark capsule, near the top where nothing the viewer needs to read is — scores it with
`scripts/preview-score.py` and writes an H.264/AAC file the store accepts: at most thirty seconds, an
audio track (the store requires one), faststart.

The captions and the cut points are in marketing/video/preview.json, because they are written against
one specific take and move when the take does.

  scripts/preview-video.py <take.mov> [out.mp4]
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG = "/opt/homebrew/bin/ffmpeg"
CONFIG = os.path.join(ROOT, "marketing/video/preview.json")
W, H = 886, 1920

spec = importlib.util.spec_from_file_location("compose", os.path.join(ROOT, "scripts/market-compose.py"))
compose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compose)
import AppKit  # noqa: E402


def caption_image(text, accent, path, top=250):
    """One caption as a transparent full-frame PNG: the words on a dark capsule with a hairline in the
    beat's colour, centred, near the top."""
    words = compose.render_text(text, 52, AppKit.NSFontWeightBold, (255, 255, 255), 760, "center", 1.0)
    box = words.getbbox()
    words = words.crop(box)
    pad_x, pad_y = 46, 26
    width, height = words.width + pad_x * 2, words.height + pad_y * 2
    pill = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(pill)
    draw.rounded_rectangle([0, 0, width - 1, height - 1], radius=height // 2, fill=(12, 14, 22, 232))
    draw.rounded_rectangle([0, 0, width - 1, height - 1], radius=height // 2,
                           outline=compose.mix(accent, (255, 255, 255), 0.25) + (210,), width=3)
    pill.paste(words, (pad_x, pad_y), words)
    frame = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    frame.paste(pill, ((W - width) // 2, top), pill)
    frame.save(path)


def main():
    take = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "marketing/video/tailscode-preview-886x1920.mp4")
    with open(CONFIG) as f:
        config = json.load(f)
    start, length = config["start"], config["duration"]
    score = os.path.join(tempfile.gettempdir(), "tailscode-score.wav")
    subprocess.run([sys.executable, os.path.join(ROOT, "scripts/preview-score.py"), score, str(length)], check=True)

    work = tempfile.mkdtemp(prefix="tailscode-preview-")
    inputs = ["-ss", str(start), "-t", str(length), "-i", take]
    filters = [f"[0:v]setpts=PTS-STARTPTS,scale={W}:{H}:flags=lanczos,fps=30,format=yuv420p[base]"]
    last = "base"
    for index, cap in enumerate(config["captions"], start=1):
        png = os.path.join(work, f"cap{index}.png")
        caption_image(cap["text"], compose.hexc(cap["accent"]), png, cap.get("top", 250))
        inputs += ["-loop", "1", "-t", str(length), "-i", png]
        a, b = cap["start"], cap["end"]
        filters.append(
            f"[{index}:v]format=rgba,fade=t=in:st={a}:d=0.3:alpha=1,fade=t=out:st={b - 0.3}:d=0.3:alpha=1[c{index}]")
        filters.append(f"[{last}][c{index}]overlay=0:0:eof_action=pass:format=auto[o{index}]")
        last = f"o{index}"
    filters.append(f"[{last}]fade=t=out:st={length - 0.6}:d=0.6[v]")
    audio_index = len(config["captions"]) + 1
    inputs += ["-i", score]
    filters.append(
        f"[{audio_index}:a]loudnorm=I=-16:TP=-1.5:LRA=9,afade=t=out:st={length - 1.2}:d=1.2,aresample=48000[a]")
    command = [FFMPEG, "-y", "-v", "error", *inputs, "-filter_complex", ";".join(filters),
               "-map", "[v]", "-map", "[a]", "-t", str(length),
               "-c:v", "libx264", "-profile:v", "high", "-level", "4.2", "-crf", "17", "-preset", "slow",
               "-r", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k", "-ac", "2",
               "-movflags", "+faststart", out]
    subprocess.run(command, check=True)
    print(out)


if __name__ == "__main__":
    main()
