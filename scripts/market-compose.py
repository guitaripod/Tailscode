#!/usr/bin/env python3
"""Compose the App Store marketing panels from the raw screenshot masters.

A raw screenshot shows a surface; a store panel has to *sell* it at thumbnail
size, where the first three images are the whole pitch. So every panel burns
its claim into the picture: a headline in the system face, a quieter subline,
and the screenshot itself framed on the app's own canvas with a breath of the
brand accent behind it.

Masters:  marketing/appstore/iphone/*.png (1320x2868), Resources/Screenshots/mac/*.png (2880x1800)
Panels:   marketing/appstore/panels/iphone/*.png, marketing/appstore/panels/mac/*.png

Panel filenames become the landing page's fallback labels, so they are the
story slugs, numbered in store order.

  scripts/market-compose.py            # everything
  scripts/market-compose.py iphone     # one platform
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IPHONE_IN = os.path.join(ROOT, "marketing/appstore/iphone")
MAC_IN = os.path.join(ROOT, "Resources/Screenshots/mac")
OUT = os.path.join(ROOT, "marketing/appstore/panels")

ACCENT = (84, 107, 255)
CANVAS_TOP = (13, 15, 21)
CANVAS_BOTTOM = (7, 8, 12)
HEADLINE_INK = (244, 246, 250)
SUBLINE_INK = (154, 163, 178)
BORDER = (255, 255, 255, 30)

IPHONE = [
    ("01-live", "01-agents-anywhere", "Your coding agents,\nin your pocket", "Claude Code and opencode, live over your own tailnet."),
    ("07-home", "02-one-board", "Every machine,\none board", "Live turns, projects, and unread — already triaged."),
    ("03-approval", "03-approve-remote", "Approve the risky\ncommand from anywhere", "Allow once, always, or deny — mid-turn."),
    ("04-question", "04-answer-blockers", "When it needs you,\nit asks", "Answer the agent's question with a tap."),
    ("02-work", "05-real-work", "Every diff, every\ncommand, inline", "Tool calls unfold with their real output."),
    ("05-subagents", "06-agent-fanout", "A fan-out of agents,\nat a glance", "Subagents dock inside the turn that spawned them."),
    ("12-git", "07-repo-truth", "Read the repo\nbefore you trust it", "Branch, staged, changed — straight from the machine."),
    ("08-usage", "08-month-in-numbers", "The month\nin numbers", "Every turn priced, every machine counted."),
    ("11-compaction", "09-compaction-seam", "Compaction is a seam,\nnot a mystery", "What was kept, and what it made room for."),
    ("setup", "10-verified-setup", "Three steps,\neach one verified", "Your tailnet, your machines, no cloud between."),
]

MAC = [
    ("01-conversation", "01-native-on-mac", "Your coding agents, native on the Mac", "Claude Code and opencode over your own tailnet — no browser, no terminal."),
    ("02-split", "02-two-machines", "Two machines, side by side", "Split panes across servers; every pane keeps its own conversation."),
    ("03-git", "03-repo-truth", "The repo, read — never operated", "Branch, staged, changed, and the real diffs, from the machine that owns them."),
    ("04-analytics", "04-month-in-numbers", "The month in numbers", "Every transcript priced turn by turn, merged across every server."),
    ("05-spend", "05-priced-turns", "A price on the whole conversation", "Where the money went: answers, cache, fresh input — turn by turn."),
    ("06-quickask", "06-one-chord-away", "One chord from anywhere", "Summon the question box over any app; the agent is already working."),
]


def font(size, weight):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    f.set_variation_by_axes([100, 96, 400, weight])
    return f


def gradient(width, height):
    base = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / max(1, height - 1)
        base.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(CANVAS_TOP, CANVAS_BOTTOM)))
    return base.resize((width, height))


def glow(canvas, center, radius, alpha):
    layer = Image.new("L", canvas.size, 0)
    draw = ImageDraw.Draw(layer)
    draw.ellipse([center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius], fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(radius / 2))
    tint = Image.new("RGB", canvas.size, ACCENT)
    canvas.paste(tint, (0, 0), layer)


def rounded(shot, radius, scale_w):
    ratio = scale_w / shot.width
    shot = shot.resize((scale_w, round(shot.height * ratio)), Image.LANCZOS)
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width - 1, shot.height - 1], radius=radius, fill=255)
    framed = Image.new("RGBA", shot.size, (0, 0, 0, 0))
    framed.paste(shot, (0, 0), mask)
    ImageDraw.Draw(framed).rounded_rectangle(
        [0, 0, shot.width - 1, shot.height - 1], radius=radius, outline=BORDER, width=2)
    return framed


def shadow_under(canvas, box, radius, blur=60, alpha=140):
    layer = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(layer).rounded_rectangle(box, radius=radius, fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    dark = Image.new("RGB", canvas.size, (0, 0, 0))
    canvas.paste(dark, (0, 0), layer)


def text_block(draw, x, y, headline, subline, head_size, sub_size, spacing, align, width):
    head = font(head_size, 640)
    sub = font(sub_size, 460)
    anchor_x = x if align == "left" else width // 2
    anchor = "la" if align == "left" else "ma"
    draw.multiline_text((anchor_x, y), headline, font=head, fill=HEADLINE_INK,
                        spacing=round(head_size * 0.16), align="left" if align == "left" else "center", anchor=anchor)
    lines = headline.count("\n") + 1
    sub_y = y + round(lines * head_size * 1.16) + spacing
    draw.multiline_text((anchor_x, sub_y), subline, font=sub, fill=SUBLINE_INK,
                        spacing=round(sub_size * 0.3), align="left" if align == "left" else "center", anchor=anchor)


def compose_iphone(master, slug, headline, subline):
    W, H = 1320, 2868
    canvas = gradient(W, H)
    glow(canvas, (W // 2, -300), 900, 26)
    draw = ImageDraw.Draw(canvas)
    text_block(draw, 96, 148, headline, subline, 104, 51, 64, "left", W)
    shot = rounded(Image.open(master).convert("RGB"), 64, 1136)
    x = (W - shot.width) // 2
    lines = headline.count("\n") + 1
    y = 148 + round(lines * 104 * 1.16) + 64 + round(51 * 1.3 * (subline.count("\n") + 1)) + 96
    shadow_under(canvas, [x + 8, y + 24, x + shot.width - 8, min(H, y + shot.height)], 64)
    canvas.paste(shot.convert("RGB"), (x, y), shot.split()[3])
    return canvas.crop((0, 0, W, H))


def compose_mac(master, slug, headline, subline):
    W, H = 2880, 1800
    canvas = gradient(W, H)
    glow(canvas, (W // 2, -500), 1400, 24)
    draw = ImageDraw.Draw(canvas)
    text_block(draw, 0, 96, headline, subline, 92, 44, 40, "center", W)
    shot = rounded(Image.open(master).convert("RGB"), 28, 2560)
    x = (W - shot.width) // 2
    y = 96 + 92 + 40 + round(44 * 1.3) + 88
    shadow_under(canvas, [x + 10, y + 20, x + shot.width - 10, H], 28)
    canvas.paste(shot.convert("RGB"), (x, y), shot.split()[3])
    return canvas.crop((0, 0, W, H))


def emit(platform, source_dir, manifest, compose):
    folder = os.path.join(OUT, platform)
    os.makedirs(folder, exist_ok=True)
    for master, slug, headline, subline in manifest:
        path = os.path.join(source_dir, master + ".png")
        if not os.path.exists(path):
            sys.exit(f"missing master {path}")
        panel = compose(path, slug, headline, subline)
        out = os.path.join(folder, slug + ".png")
        panel.save(out, optimize=True)
        print(f"  {platform}/{slug}.png")


def main():
    wanted = sys.argv[1:] or ["iphone", "mac"]
    if "iphone" in wanted:
        emit("iphone", IPHONE_IN, IPHONE, compose_iphone)
    if "mac" in wanted:
        emit("mac", MAC_IN, MAC, compose_mac)


if __name__ == "__main__":
    main()
