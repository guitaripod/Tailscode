#!/usr/bin/env python3
"""The montage: everything the app does, cut to a piece of music that decides when.

`film-cut.py` shapes one continuous take into a demo. This is the other film — thirteen unrelated
moments pulled from eight separate 4K60 reels and laid onto a bar grid, so the length of a shot is
not a judgement about the shot but a fact about the music. A shot declares how many BARS it holds;
the source window it was cut from is retimed to fill exactly that, which is why the cut accelerates
where the track does instead of where the footage happens to get interesting.

The grid is the song's own: tempo and phase are measured off the onset envelope, every boundary
lands on a bar, and the last shot begins on the downbeat the drop lands on. Frame counts are
telescoped from rounded bar boundaries, so the segments sum to the audio sample-for-sample and
nothing drifts.

Nothing is faked. Every frame is a frame the app drew — the edit only chooses which ones, and the
music chooses for how long.

    scripts/film-montage.py --out build/tailscode-tour-4k60.mp4
    scripts/film-montage.py --shots          the shot list, its bars, and what each retime costs
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
SRC = "/home/marcus/Videos/hype/2026-08-07-tailscode/src"
SONG = "/home/marcus/Videos/hype/2026-08-07-tailscode/song.wav"

BPM = 128.040
BAR = 4 * 60.0 / BPM
SONG_IN = 5.205
FADE_OUT = 1.1

SIDEBAR = (1240, 698, 0, 170)
RIGHT_TOP = (2020, 1136, 1800, 60)
RIGHT_MID = (2020, 1136, 1800, 520)
MODAL = (1980, 1114, 930, 430)
TERMINAL = (2600, 1462, 400, 698)
TREE = (1500, 844, 2340, 120)
SHEET_WIDE = (3400, 1912, 260, 124)
SHEET = (2400, 1350, 720, 380)
COMPOSER = (2400, 1350, 700, 800)
ASK = (2200, 1238, 1580, 900)
ANSWER = (1700, 956, 2140, 100)
ANSWER_TIGHT = (1200, 675, 2300, 140)

SHOTS = [
    {"name": "open", "src": "flow", "win": (1.0, 8.4), "bars": 4,
     "cap": ("title", 0.55, 0.75, 0.0)},
    {"name": "list", "src": "stream", "win": (11.0, 17.0), "bars": 3, "crop": SIDEBAR,
     "cap": ("list", 0.30, 0.40, 0.45)},
    {"name": "split", "src": "grid", "win": (1.6, 7.4), "bars": 3,
     "cap": ("split", 0.30, 0.40, 0.45)},
    {"name": "chooser", "src": "grid_tokyo", "win": (4.0, 8.8), "bars": 3, "crop": RIGHT_TOP,
     "cap": ("chooser", 0.30, 0.40, 0.45)},
    {"name": "newchat", "src": "chrome_gruv", "win": (28.6, 33.4), "bars": 3, "crop": MODAL,
     "cap": ("newchat", 0.30, 0.40, 0.45)},

    {"name": "filetree", "src": "tour", "win": (1.6, 6.6), "bars": 2, "crop": TREE,
     "cap": ("filetree", 0.25, 0.35, 0.40)},
    {"name": "terminal", "src": "tour", "win": (9.2, 15.0), "bars": 2, "crop": TERMINAL,
     "cap": ("terminal", 0.25, 0.35, 0.40)},
    {"name": "keys", "src": "chrome", "win": (7.2, 11.4), "bars": 2,
     "push": (SHEET_WIDE, SHEET), "cap": ("keys", 0.25, 0.35, 0.40)},
    {"name": "zoom", "src": "chrome_gruv", "win": (15.0, 19.2), "bars": 2,
     "cap": ("zoom", 0.25, 0.35, 0.40)},
    {"name": "slash", "src": "chrome", "win": (22.4, 26.6), "bars": 2, "crop": COMPOSER,
     "cap": ("slash", 0.25, 0.35, 0.40)},
    {"name": "themes", "bars": 2, "cap": ("themes", 0.25, 0.35, 0.40),
     "parts": [("grid_tokyo", 3.2, 4.4), ("chrome_gruv", 12.0, 13.2),
               ("tour", 3.0, 4.2), ("chrome", 12.2, 13.4)]},
    {"name": "ask", "src": "flow", "win": (34.2, 41.4), "bars": 2, "crop": ASK,
     "cap": ("ask", 0.25, 0.35, 0.40)},
    {"name": "live", "src": "flow", "win": (50.8, 57.4), "bars": 2,
     "push": (ANSWER, ANSWER_TIGHT), "cap": ("live", 0.25, 0.35, 0.40)},

    {"name": "end", "src": "flow", "win": (58.0, 64.0), "bars": 2,
     "cap": ("end", 0.10, 0.45, 0.0), "fade_out": FADE_OUT},
]

CAPTIONS = {
    "title": lambda: title_card(),
    "list": lambda: caption_card("one window", "Every machine you code on, in one list."),
    "split": lambda: caption_card("", "Split the window.", keys=["ctrl", "w", "v"]),
    "chooser": lambda: caption_card("any pane, any machine", "The empty half asks which server."),
    "newchat": lambda: caption_card("new conversation", "The folders it already knows, ranked."),
    "terminal": lambda: caption_card("", "A shell on that machine, same window.",
                                     keys=["ctrl", "t"], anchor="top"),
    "filetree": lambda: caption_card("the project",
                                     "The tree is the server's, not this machine's."),
    "keys": lambda: caption_card("every key", "Printed on the screen. Rebindable."),
    "zoom": lambda: caption_card("", "Set the size you read at.", keys=["ctrl", "+"]),
    "slash": lambda: caption_card("slash", "The server's own catalog, ranked as you type."),
    "themes": lambda: caption_card("seven themes", "Light and dark of each."),
    "ask": lambda: caption_card("ask", "One prompt, on the machine that has the code.",
                                anchor="top"),
    "live": lambda: caption_card("live", "An answer is written, not pasted."),
    "end": lambda: end_card(),
}


def plan():
    """Bar boundaries rounded to frames and telescoped, so the shots sum to the audio exactly."""
    edges, bar = [0], 0
    for shot in SHOTS:
        bar += shot["bars"]
        edges.append(round(bar * BAR * FPS))
    out = []
    for index, shot in enumerate(SHOTS):
        frames = edges[index + 1] - edges[index]
        out.append((shot, frames, edges[index] / FPS, frames / FPS))
    return out, edges[-1]


def preview(out):
    """Aim the crops before spending an hour on the render: every shot's middle frame, cropped
    exactly as the renderer will crop it, seeked exactly as the renderer will seek it."""
    work = tempfile.mkdtemp(prefix="film-preview-")
    tiles = []
    for index, shot in enumerate(SHOTS):
        if shot.get("parts"):
            name, start, end = shot["parts"][0]
        else:
            name, (start, end) = shot["src"], shot["win"]
        box = shot.get("crop") or (shot.get("push") or [None])[0]
        chain = []
        if box:
            w, h, x, y = box
            chain.append(f"crop={w}:{h}:{x}:{y}")
        chain.append("scale=760:428")
        chain.append(f"drawtext=text='{index} {shot['name']} {name}':x=10:y=10:fontsize=26"
                     ":fontcolor=yellow:box=1:boxcolor=black@0.75")
        tile = os.path.join(work, f"t{index:02d}.png")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-ss", f"{(start + end) / 2:.3f}", "-i", source(name), "-frames:v", "1",
                        "-vf", ",".join(chain), tile], check=True)
        tiles.append(tile)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-pattern_type", "glob",
                    "-i", os.path.join(work, "t*.png"), "-vf", "tile=4x4", "-frames:v", "1", out],
                   check=True)
    shutil.rmtree(work, ignore_errors=True)
    print(out)


def source(name):
    return f"{SRC}/{name}.mp4"


def geometry(shot, frames):
    """A crop is a still frame within the frame; a push travels between two of them."""
    push = shot.get("push")
    if push:
        (w0, _, x0, y0), (w1, _, x1, y1) = push
        ramp = f"min(1,on/{frames})"
        ease = f"(3*pow({ramp},2)-2*pow({ramp},3))"
        z0, z1 = WIDTH / w0, WIDTH / w1
        return (f"zoompan=z='{z0:.6f}+{z1 - z0:.6f}*{ease}':x='{x0}+{x1 - x0}*{ease}'"
                f":y='{y0}+{y1 - y0}*{ease}':d=1:s={WIDTH}x{HEIGHT}:fps={FPS},"
                f"settb=1/{FPS},setpts=N/{FPS}/TB")
    if shot.get("crop"):
        w, h, x, y = shot["crop"]
        return f"crop={w}:{h}:{x}:{y},scale={WIDTH}:{HEIGHT}:flags=lanczos"
    return None


def encode(path):
    return ["-c:v", "libx264", "-preset", "slow", "-crf", "17", "-profile:v", "high",
            "-level", "5.2", "-pix_fmt", "yuv420p",
            "-x264-params", "keyint=120:min-keyint=120:scenecut=0",
            "-r", str(FPS), "-an", path]


def render_body(shot, frames, work, index):
    """The picture before the type: one window retimed to its bars, or several concatenated."""
    path = os.path.join(work, f"body{index:02d}.mp4")
    if shot.get("parts"):
        pieces, share = [], []
        for k in range(len(shot["parts"])):
            share.append(round(frames * (k + 1) / len(shot["parts"]))
                         - round(frames * k / len(shot["parts"])))
        for k, (name, start, end) in enumerate(shot["parts"]):
            piece = os.path.join(work, f"body{index:02d}-{k}.mp4")
            speed = (end - start) / (share[k] / FPS)
            subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                 "-ss", f"{start:.3f}", "-t", f"{end - start:.3f}", "-i", source(name),
                 "-vf", f"setpts=PTS/{speed:.6f},fps={FPS}", "-frames:v", str(share[k]),
                 *encode(piece)], check=True)
            pieces.append(piece)
        listing = os.path.join(work, f"body{index:02d}.txt")
        with open(listing, "w") as handle:
            for piece in pieces:
                handle.write(f"file '{piece}'\n")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat",
                        "-safe", "0", "-i", listing, "-c", "copy", path], check=True)
        return path

    start, end = shot["win"]
    speed = (end - start) / (frames / FPS)
    chain = [g for g in (geometry(shot, frames),) if g]
    chain.append(f"setpts=PTS/{speed:.6f}")
    chain.append(f"fps={FPS}")
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-ss", f"{start:.3f}", "-t", f"{end - start + 0.5:.3f}", "-i", source(shot["src"]),
         "-vf", ",".join(chain), "-frames:v", str(frames), *encode(path)], check=True)
    return path


def render_shot(shot, frames, work, index, overlays):
    body = render_body(shot, frames, work, index)
    if not shot.get("cap") and not shot.get("fade_out"):
        return body
    path = os.path.join(work, f"seg{index:02d}-{shot['name']}.mp4")
    duration = frames / FPS
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", body]
    graph, last = "[0:v]null[base]", "base"
    if shot.get("cap"):
        name, at, fade_in, fade_out = shot["cap"]
        command += ["-loop", "1", "-i", overlays[name]]
        alpha = ["format=rgba", f"fade=t=in:st={at}:d={fade_in}:alpha=1"]
        if fade_out > 0:
            alpha.append(f"fade=t=out:st={duration - fade_out:.3f}:d={fade_out}:alpha=1")
        graph += f";[1:v]{','.join(alpha)}[cap]"
        graph += f";[{last}][cap]overlay=0:0:enable='gte(t,{at})'[ov]"
        last = "ov"
    if shot.get("fade_out"):
        graph += f";[{last}]fade=t=out:st={duration - shot['fade_out']:.3f}:d={shot['fade_out']}[fo]"
        last = "fo"
    command += ["-filter_complex", graph, "-map", f"[{last}]", "-frames:v", str(frames),
                *encode(path)]
    subprocess.run(command, check=True)
    return path


def render_audio(work, frames):
    """Sample-exact: float -t is not, and a video that ends on the drop cannot end near it."""
    path = os.path.join(work, "bed.wav")
    samples = round(frames / FPS * 48000)
    start = round(SONG_IN * 48000)
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", SONG,
         "-af", (f"aresample=48000,atrim=start_sample={start}:end_sample={start + samples},"
                 f"asetpts=N/SR/TB,apad=whole_len={samples},"
                 f"afade=t=in:st=0:d=0.35,"
                 f"afade=t=out:st={frames / FPS - FADE_OUT:.3f}:d={FADE_OUT}"),
         "-ac", "2", "-c:a", "pcm_s16le", path], check=True)
    return path


def render(out, keep=None, verbose=True):
    work = keep or tempfile.mkdtemp(prefix="film-montage-")
    os.makedirs(work, exist_ok=True)
    overlays = {}
    for name, build in CAPTIONS.items():
        path = os.path.join(work, f"cap-{name}.png")
        build().save(path)
        overlays[name] = path

    schedule, total = plan()
    segments = []
    for index, (shot, frames, at, duration) in enumerate(schedule):
        if verbose:
            kind = "parts" if shot.get("parts") else (
                "push" if shot.get("push") else ("crop" if shot.get("crop") else "full"))
            print(f"  {shot['name']:9s} bar{sum(s['bars'] for s, _, _, _ in schedule[:index]):3.0f}"
                  f"  {at:5.2f}s +{duration:4.2f}s  {frames:4d}f  {kind}", flush=True)
        segments.append(render_shot(shot, frames, work, index, overlays))

    listing = os.path.join(work, "segments.txt")
    with open(listing, "w") as handle:
        for path in segments:
            handle.write(f"file '{path}'\n")
    silent = os.path.join(work, "picture.mp4")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat",
                    "-safe", "0", "-i", listing, "-c", "copy", silent], check=True)

    bed = render_audio(work, total)
    os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", silent, "-i", bed,
                    "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "320k",
                    "-movflags", "+faststart", out], check=True)
    if keep is None:
        shutil.rmtree(work, ignore_errors=True)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="build/tailscode-tour-4k60.mp4")
    parser.add_argument("--work", default=None)
    parser.add_argument("--shots", action="store_true")
    parser.add_argument("--preview", default=None, metavar="OUT.png")
    options = parser.parse_args()

    schedule, total = plan()
    if options.shots:
        bar = 0
        for shot, frames, at, duration in schedule:
            if shot.get("parts"):
                span = sum(e - s for _, s, e in shot["parts"])
            else:
                span = shot["win"][1] - shot["win"][0]
            print(f"{shot['name']:9s} bar{bar:3d}  {at:5.2f}s +{duration:4.2f}s "
                  f"{frames:4d}f  src {span:5.2f}s  ×{span / duration:4.2f}")
            bar += shot["bars"]
        print(f"{'total':9s} bar{bar:3d}  {total / FPS:5.2f}s  {total}f")
        return
    if options.preview:
        preview(options.preview)
        return
    render(options.out, keep=options.work)
    subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                    "stream=codec_type,width,height,r_frame_rate,nb_frames",
                    "-show_entries", "format=duration,size", "-of", "default=nw=1", options.out])


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
