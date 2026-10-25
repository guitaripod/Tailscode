#!/usr/bin/env python3
"""Cut the App Store app preview from plain simulator recordings of the app.

A store preview is the app and nothing else: no frame, no caption, no overlay, no hand. This joins
the takes named in marketing/video/preview.json into one 886x1920, 30 fps, H.264 file of at most
thirty seconds, with an original quiet bed under it (written from sine tones, so nobody owns it),
and writes the poster frame beside it. Segments that belong to different takes dissolve into each
other for `dissolve` seconds; a segment marked `"cut": true` joins the one before it without a
dissolve, for two moments of one continuous take.

  scripts/preview-video.py --rec <folder of .mov takes> [--out out.mp4] [--poster poster.png]

A simulator recording only writes a frame when the screen changes, so a still stretch has no frames
to seek to; each take is therefore made constant-rate first and the segment trimmed from that.

The cut points are in marketing/video/preview.json, because they are written against one specific
set of takes and move when the takes do.
"""
import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG = "/opt/homebrew/bin/ffmpeg"
CONFIG = os.path.join(ROOT, "marketing/video/preview.json")
STORE_LIMIT = 30.0
CHORDS = {
    "am": (110, 164.81, 196, 261.63),
    "cmaj": (130.81, 196, 261.63, 329.63),
    "dm": (146.83, 220, 261.63, 329.63),
    "fmaj": (87.31, 130.81, 174.61, 220),
    "em": (82.41, 123.47, 164.81, 246.94),
    "gmaj": (98, 146.83, 196, 246.94),
}
GAINS = (0.5, 0.35, 0.3, 0.2)
TREMOLO = (0.2, 0.2, 0.13, 0.1)


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rec", required=True)
    parser.add_argument("--out", default=os.path.join(ROOT, "marketing/video/tailscode-preview-886x1920.mp4"))
    parser.add_argument("--poster", default=os.path.join(ROOT, "marketing/video/tailscode-preview-poster.png"))
    parser.add_argument("--size", help="output size instead of the one in the config, e.g. 1320x2868")
    parser.add_argument("--silent", action="store_true", help="write the picture alone, with no sound bed")
    parser.add_argument("--config", default=CONFIG, help="the cut points, instead of marketing/video/preview.json")
    parser.add_argument("--score", help="a wav from scripts/preview-score.py to lay under the picture instead of the sine bed")
    return parser.parse_args()


def timeline(segments, dissolve):
    """The output second each segment starts at and the total length, given how they overlap."""
    starts, cursor = [], 0.0
    for index, segment in enumerate(segments):
        length = segment["dur"] / segment.get("speed", 1.0)
        if index and not segment.get("cut"):
            cursor -= dissolve
        starts.append(cursor)
        cursor += length
    return starts, cursor


def video_graph(segments, size, dissolve):
    width, height = size.split("x")
    filters = []
    for index, segment in enumerate(segments):
        speed = segment.get("speed", 1.0)
        filters.append(
            f"[{index}:v]fps=30,trim=start={segment['t0']}:duration={segment['dur']},"
            f"setpts=(PTS-STARTPTS)/{speed},scale={width}:{height}:flags=lanczos,format=yuv420p,setsar=1[v{index}]")
    label, elapsed = "v0", segments[0]["dur"] / segments[0].get("speed", 1.0)
    for index in range(1, len(segments)):
        segment = segments[index]
        length = segment["dur"] / segment.get("speed", 1.0)
        if segment.get("cut"):
            filters.append(f"[{label}][v{index}]concat=n=2:v=1:a=0,fps=30,settb=1/30[x{index}]")
            elapsed += length
        else:
            filters.append(
                f"[{label}][v{index}]xfade=transition=fade:duration={dissolve}:offset={elapsed - dissolve:.3f}"
                f"[x{index}]")
            elapsed += length - dissolve
        label = f"x{index}"
    return filters, label


def bed_graph(first_input, chord, total):
    parts = [f"[{first_input + k}:a]volume={GAINS[k]},tremolo=f={TREMOLO[k]}:d=0.45[a{k}]" for k in range(4)]
    chain = (
        "[a0][a1][a2][a3]amix=inputs=4:normalize=0,lowpass=f=900,aecho=0.8:0.7:420|700:0.35|0.25,"
        "pan=stereo|c0=c0|c1=c0,volume=3.2,alimiter=limit=0.8:level=disabled,"
        f"afade=t=in:d=1.5,afade=t=out:st={total - 2:.2f}:d=2[aout]")
    return parts + [chain], CHORDS[chord]


def main():
    args = arguments()
    with open(args.config) as f:
        config = json.load(f)
    segments = config["segments"]
    size = args.size or config.get("size", "886x1920")
    dissolve = config.get("dissolve", 0.3)
    starts, total = timeline(segments, dissolve)
    if total > STORE_LIMIT:
        sys.exit(f"preview-video.py: {total:.2f}s is over the {STORE_LIMIT:.0f}s App Store limit")
    command = [FFMPEG, "-v", "error", "-y"]
    for segment in segments:
        command += ["-i", os.path.join(args.rec, segment["clip"])]
    filters, label = video_graph(segments, size, dissolve)
    if args.silent:
        command += ["-filter_complex", ";".join(filters), "-map", f"[{label}]", "-an"]
    elif args.score:
        command += ["-i", args.score, "-filter_complex", ";".join(filters),
                    "-map", f"[{label}]", "-map", f"{len(segments)}:a",
                    "-af", f"afade=t=out:st={total - 1.2:.2f}:d=1.2",
                    "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2"]
    else:
        audio_filters, tones = bed_graph(len(segments), config.get("chord", "gmaj"), total)
        for frequency in tones:
            command += ["-f", "lavfi", "-t", f"{total:.3f}", "-i", f"sine=frequency={frequency}:sample_rate=48000"]
        command += ["-filter_complex", ";".join(filters + audio_filters), "-map", f"[{label}]", "-map", "[aout]",
                    "-c:a", "aac", "-b:a", "256k", "-ar", "48000"]
    command += ["-t", f"{total:.3f}", "-r", "30", "-c:v", "libx264", "-profile:v", "high", "-level", "5.1" if args.silent else "4.2",
                "-crf", "15", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart", args.out]
    subprocess.run(command, check=True)
    if args.poster:
        subprocess.run([FFMPEG, "-v", "error", "-y", "-i", args.out, "-frames:v", "1", args.poster], check=True)
    print(f"{args.out} ({total:.2f}s)")
    for segment, start in zip(segments, starts):
        print(f"  {start:6.2f}  {segment['clip']} @{segment['t0']} for {segment['dur']}")


if __name__ == "__main__":
    main()
