"""Title, grade and encode the rendered launch film.

Reads the Blender PNG sequence, composites the on-screen copy with PIL, and pipes
raw frames straight into ffmpeg — no intermediate image sequence on disk.

  python3 scripts/film-post.py --frames /tmp/film-master --out /tmp/tailscode-launch.mp4
"""
import argparse
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

DISPLAY_SEMIBOLD = "/Library/Fonts/SF-Pro-Display-Semibold.otf"
DISPLAY_REGULAR = "/Library/Fonts/SF-Pro-Display-Regular.otf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
ACCENT = (51, 115, 242)

# The name is set in SF Pro Display and the annotations in SF Mono: the film is
# selling a developer tool, and the screen behind them is already full of code.
# Every line is timed to be true while it is on screen, and holds for ~4s — long
# enough to read twice — with the camera parked still underneath it.
CARDS = [
    dict(start=0.6, end=4.4, head="Tailscode",
         sub="A remote for your coding agents", hero=True),
    dict(start=5.2, end=9.0, head="Every agent, one board."),
    dict(start=10.4, end=14.4, head="Watch it work, live."),
    dict(start=15.4, end=19.6, head="Keep typing. It queues."),
    dict(start=20.6, end=24.8, head="Reasoning you can read."),
    dict(start=25.8, end=29.6, head="Any model, mid-conversation."),
    dict(start=31.6, end=36.4, head="Keep the ones that matter."),
    dict(start=42.6, end=46.8, head="Your machines.\nYour tailnet."),
    dict(start=50.2, end=54.6, head="It asks before it edits."),
    dict(start=59.8, end=64.0, head="Subagents open in place."),
    dict(start=65.0, end=69.0, head="They report back inline."),
    dict(start=71.4, end=75.0, head="Every chat, both machines."),
    dict(start=75.8, end=80.0, head="Questions you can answer."),
    dict(start=84.6, end=89.0, head="Context compacted, not lost."),
    dict(start=89.6, end=93.4, head="Read what it kept."),
    dict(start=97.4, end=101.6, head="Every budget, one screen."),
    dict(start=103.0, end=107.0, head="Tailscode", sub="On the App Store", hero=True),
]

FADE_IN = 0.55
FADE_OUT = 0.45
DRIFT = 0.022


def ease_out(x):
    return 1.0 - (1.0 - x) ** 3.0


def font(path, size):
    return ImageFont.truetype(path, size)


def card_alpha(card, t):
    """Opacity and the residual upward drift for a card at film time t."""
    if t < card["start"] or t > card["end"]:
        return 0.0, 0.0
    into = t - card["start"]
    left = card["end"] - t
    if into < FADE_IN:
        progress = ease_out(into / FADE_IN)
        return progress, 1.0 - progress
    if left < FADE_OUT:
        return max(0.0, left / FADE_OUT), 0.0
    return 1.0, 0.0


def wrap(text, text_font, limit):
    """Keep the copy inside the left column so it never collides with the phone.

    Explicit newlines win: some lines are broken for rhythm, not for width.
    """
    lines = []
    for paragraph in text.split("\n"):
        current = ""
        for word in paragraph.split():
            candidate = f"{current} {word}".strip()
            if current and text_font.getlength(candidate) > limit:
                lines.append(current)
                current = word
            else:
                current = candidate
        lines.append(current)
    return lines


def draw_card(base, card, alpha, drift, width, height):
    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    hero = card.get("hero", False)
    head_size = int(height * (0.088 if hero else 0.032))
    sub_size = int(height * 0.030)
    head_font = font(DISPLAY_SEMIBOLD if hero else MONO, head_size)
    sub_font = font(DISPLAY_REGULAR, sub_size)

    x = int(width * 0.055)
    y = int(height * (0.40 if hero else 0.44) + drift * height * DRIFT)
    wrapped = wrap(card["head"], head_font, int(width * 0.28))

    rule_width = int(width * 0.05 * ease_out(min(1.0, alpha * 1.4)))
    rule_y = y - int(head_size * 0.66)
    draw.rectangle([x, rule_y, x + rule_width, rule_y + max(3, height // 420)],
                   fill=(*ACCENT, int(240 * alpha)))

    line_step = int(head_size * (1.16 if hero else 1.5))
    for index, line in enumerate(wrapped):
        draw.text((x, y + index * line_step), line, font=head_font,
                  fill=(255, 255, 255, int(252 * alpha)))
    if card.get("sub"):
        draw.text((x, y + len(wrapped) * line_step + int(head_size * 0.24)), card.get("sub"),
                  font=sub_font, fill=(255, 255, 255, int(165 * alpha)))

    return Image.alpha_composite(base, layer)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--scale", default="", help="e.g. 1920x1080 to downscale on encode")
    parser.add_argument("--crf", type=int, default=17)
    args = parser.parse_args()

    files = sorted(f for f in os.listdir(args.frames) if f.endswith(".png"))
    if not files:
        sys.exit(f"no PNGs in {args.frames}")
    first = Image.open(os.path.join(args.frames, files[0]))
    width, height = first.size
    print(f"{len(files)} frames at {width}x{height}")

    # format=gbrp is load-bearing: without it ffmpeg blends in yuv420p, and a screen
    # blend over the chroma planes (which are centred on 128, not 0) turns the whole
    # film magenta.
    grade = (
        "[0:v]format=gbrp,split=2[base][bl];"
        "[bl]eq=brightness=-0.34:contrast=2.7,gblur=sigma=20,format=gbrp[glow];"
        "[base][glow]blend=all_mode=screen:all_opacity=0.26,format=gbrp,"
        "eq=contrast=1.04:saturation=1.06:brightness=0.015,"
        "vignette=angle=PI/4.2"
    )
    if args.scale:
        grade += f",scale={args.scale.replace('x', ':')}:flags=lanczos"
    duration = len(files) / args.fps
    grade += f",fade=t=in:st=0:d=0.45,fade=t=out:st={duration - 0.7:.2f}:d=0.7[v]"

    command = [
        "ffmpeg", "-v", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{width}x{height}", "-r", str(args.fps), "-i", "-",
        "-filter_complex", grade, "-map", "[v]",
        "-c:v", "libx264", "-preset", "slow", "-crf", str(args.crf),
        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        args.out,
    ]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)

    for index, name in enumerate(files):
        t = index / args.fps
        frame = Image.open(os.path.join(args.frames, name)).convert("RGBA")
        for card in CARDS:
            alpha, drift = card_alpha(card, t)
            if alpha > 0.002:
                frame = draw_card(frame, card, alpha, drift, width, height)
        process.stdin.write(frame.convert("RGB").tobytes())
        if index % 200 == 0:
            print(f"  {index}/{len(files)}", flush=True)

    process.stdin.close()
    if process.wait() != 0:
        sys.exit("ffmpeg failed")
    print(f"wrote {args.out}")


main()
