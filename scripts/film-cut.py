#!/usr/bin/env python3
"""The cut: a screen take becomes something worth putting on a page.

A raw take is honest and slow — it holds every screen for as long as a person needed to read it,
types at a hand's speed, and waits out a model. The cut keeps all of that and none of the waiting:
each beat is held for as long as it takes to understand and no longer, the framing pushes in where
the detail is small, and a line of type says what is happening while it happens.

Nothing is faked. Every frame here is a frame the app drew — the edit only chooses which ones and
how long they last.

    scripts/film-cut.py --take /path/take.mkv --out build/tailscode-4k60.mp4
    scripts/film-cut.py --shots            what the cut is made of, and what it costs in seconds
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from film_titles import HEIGHT, WIDTH, caption_card, end_card, title_card  # noqa: E402

FPS = 60

RIGHT_TOP = (2560, 1440, 1280, 120)
RIGHT_BOTTOM = (2560, 1440, 1280, 720)
MODAL = (2560, 1440, 640, 360)
ANSWER = (2880, 1620, 960, 180)
ANSWER_WIDE = (3200, 1800, 640, 270)


SHOTS = [
    {
        "name": "open",
        "src": (1.5, 9.6),
        "speed": 1.35,
        "crop": None,
        "overlay": ("title", 0.5, 4.4, 0.7, 0.7),
        "fade_in": 0.7,
    },
    {
        "name": "split",
        "src": (9.6, 16.2),
        "speed": 1.0,
        "crop": None,
        "overlay": ("split", 3.0, 3.2, 0.35, 0.5),
    },
    {
        "name": "chooser",
        "src": (16.2, 22.6),
        "speed": 1.5,
        "crop": RIGHT_TOP,
        "overlay": ("chooser", 0.3, 3.6, 0.35, 0.5),
    },
    {
        "name": "folders",
        "src": (22.6, 28.7),
        "speed": 1.45,
        "crop": MODAL,
        "overlay": ("folders", 0.3, 3.4, 0.35, 0.5),
    },
    {"name": "born", "src": (28.7, 32.6), "speed": 1.35, "crop": None, "overlay": None},
    {
        "name": "ask",
        "src": (32.6, 48.3),
        "speed": 3.3,
        "crop": RIGHT_BOTTOM,
        "overlay": ("ask", 0.3, 3.4, 0.35, 0.5),
    },
    {
        "name": "arrives",
        "src": (48.3, 53.6),
        "speed": 1.0,
        "crop": None,
        "overlay": ("arrives", 0.7, 3.8, 0.35, 0.5),
    },
    {
        "name": "stream",
        "src": (53.6, 63.6),
        "speed": 1.9,
        "crop": ANSWER,
        "push": (ANSWER_WIDE, ANSWER),
        "overlay": None,
    },
    {
        "name": "settle",
        "src": (63.6, 69.6),
        "speed": 1.0,
        "crop": None,
        "overlay": ("end", 1.8, 4.2, 0.9, 0.0),
        "fade_out": 1.0,
    },
]

CAPTIONS = {
    "title": lambda: title_card(),
    "split": lambda: caption_card("", "Split the window.", keys=["ctrl", "w", "v"]),
    "chooser": lambda: caption_card("any pane, any machine", "The empty half asks which server."),
    "folders": lambda: caption_card("new conversation", "The folders it already knows, ranked."),
    "ask": lambda: caption_card("ask", "One prompt, on the machine that has the code."),
    "arrives": lambda: caption_card("live", "An answer is written, not pasted."),
    "end": lambda: end_card(),
}


def crop_filter(shot):
    push = shot.get("push")
    if push:
        (w0, _, x0, y0), (w1, _, x1, y1) = push
        frames = max(1, round((shot["src"][1] - shot["src"][0]) * FPS))
        ramp = f"min(1,on/{frames})"
        ease = f"(3*pow({ramp},2)-2*pow({ramp},3))"
        z0, z1 = WIDTH / w0, WIDTH / w1
        return (
            f"zoompan=z='{z0:.6f}+{z1 - z0:.6f}*{ease}'"
            f":x='{x0}+{x1 - x0}*{ease}'"
            f":y='{y0}+{y1 - y0}*{ease}'"
            f":d=1:s={WIDTH}x{HEIGHT}:fps={FPS},settb=1/{FPS},setpts=N/{FPS}/TB"
        )
    if shot.get("crop"):
        w, h, x, y = shot["crop"]
        return f"crop={w}:{h}:{x}:{y},scale={WIDTH}:{HEIGHT}:flags=lanczos"
    return None


def render(take, out, keep=None, verbose=True):
    work = keep or tempfile.mkdtemp(prefix="film-cut-")
    os.makedirs(work, exist_ok=True)
    overlays = {}
    for name, build in CAPTIONS.items():
        path = os.path.join(work, f"cap-{name}.png")
        build().save(path)
        overlays[name] = path

    segments = []
    for index, shot in enumerate(SHOTS):
        start, end = shot["src"]
        duration = (end - start) / shot["speed"]
        shot["out_dur"] = duration
        path = os.path.join(work, f"seg{index:02d}-{shot['name']}.mp4")
        chain = []
        crop = crop_filter(shot)
        if crop:
            chain.append(crop)
        chain.append(f"setpts=PTS/{shot['speed']}")
        chain.append("fps=60")

        command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
        command += ["-ss", f"{start:.3f}", "-t", f"{end - start:.3f}", "-i", take]
        graph = f"[0:v]{','.join(chain)}[base]"
        last = "base"
        if shot.get("overlay"):
            name, at, hold, fade_in, fade_out = shot["overlay"]
            command += ["-loop", "1", "-i", overlays[name]]
            alpha = [f"format=rgba", f"fade=t=in:st={at}:d={fade_in}:alpha=1"]
            if fade_out > 0:
                alpha.append(f"fade=t=out:st={at + hold - fade_out}:d={fade_out}:alpha=1")
            graph += f";[1:v]{','.join(alpha)}[cap]"
            enable = f"between(t,{at},{at + hold})" if fade_out > 0 else f"gte(t,{at})"
            graph += f";[{last}][cap]overlay=0:0:enable='{enable}'[ov]"
            last = "ov"
        tail = []
        if shot.get("fade_in"):
            tail.append(f"fade=t=in:st=0:d={shot['fade_in']}")
        if shot.get("fade_out"):
            tail.append(f"fade=t=out:st={duration - shot['fade_out']:.3f}:d={shot['fade_out']}")
        if tail:
            graph += f";[{last}]{','.join(tail)}[out]"
            last = "out"
        command += ["-filter_complex", graph, "-map", f"[{last}]"]
        command += [
            "-t", f"{duration:.3f}",
            "-c:v", "libx264", "-preset", "slow", "-crf", "17",
            "-profile:v", "high", "-level", "5.2", "-pix_fmt", "yuv420p",
            "-x264-params", "keyint=120:min-keyint=120:scenecut=0",
            "-r", "60", "-an", path,
        ]
        if verbose:
            print(f"  {shot['name']:9s} {duration:5.2f}s  {'push' if shot.get('push') else ('crop' if shot.get('crop') else 'full')}", flush=True)
        subprocess.run(command, check=True)
        segments.append(path)

    listing = os.path.join(work, "segments.txt")
    with open(listing, "w") as handle:
        for path in segments:
            handle.write(f"file '{path}'\n")
    os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
         "-i", listing, "-c", "copy", "-movflags", "+faststart", out],
        check=True,
    )
    if keep is None:
        shutil.rmtree(work, ignore_errors=True)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--take", default="/tmp/tailscode-film/78/take.mkv")
    parser.add_argument("--out", default="build/tailscode-4k60.mp4")
    parser.add_argument("--work", default=None)
    parser.add_argument("--shots", action="store_true")
    options = parser.parse_args()

    if options.shots:
        total = 0.0
        for shot in SHOTS:
            start, end = shot["src"]
            duration = (end - start) / shot["speed"]
            total += duration
            print(f"{shot['name']:9s} {start:6.1f}→{end:5.1f}  ×{shot['speed']:<4} {duration:5.2f}s")
        print(f"{'total':9s} {' ' * 20} {total:5.2f}s")
        return

    if not os.path.exists(options.take):
        raise SystemExit(f"no take at {options.take}")
    render(options.take, options.out, keep=options.work)
    subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "stream=width,height,r_frame_rate,nb_frames", "-show_entries",
         "format=duration,size", "-of", "default=nw=1", options.out]
    )


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
