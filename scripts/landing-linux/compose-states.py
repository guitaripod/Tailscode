import sys
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1]
PANELS = sys.argv[2:6]
S = 2
W = 1920 * S
BG = (10, 16, 25)
ACCENT = (110, 231, 183)
TITLE = (242, 247, 255)
SUB = (150, 160, 190)
BORDER = (38, 54, 80)
BOLD = "/usr/share/fonts/noto/NotoSans-Bold.ttf"
REG = "/usr/share/fonts/noto/NotoSans-Regular.ttf"

CAPTIONS = [
    ("01", "Painting", "The machine narrates the render: its own sketch on the stage, the step it is on, and a line along the edge."),
    ("02", "Done", "Words, size, steps and seed read back from the picture's own file, with what a finished picture can do."),
    ("03", "Animate this", "The video lane while a clip is on its way: the sketch of the pass it is on, and one segment of the line for each pass (demo forge)."),
    ("04", "Recent clips", "Every clip the machine kept is a poster with its length on the shelf; pressing one puts it on the stage (demo clips cut from the pictures)."),
]

def font(path, size):
    return ImageFont.truetype(path, size)

margin = 37 * S
gap = 25 * S
pw = (W - 2 * margin - gap) // 2
panels = [Image.open(p).convert("RGB") for p in PANELS]
ph = round(pw * panels[0].height / panels[0].width)
top = 146 * S
row_gap = 103 * S + (ph - 475 * S) * 0
caption_h = 105 * S
height = top + ph + caption_h + ph + caption_h + 22 * S
canvas = Image.new("RGB", (W, height), BG)
d = ImageDraw.Draw(canvas)

d.text((margin, 40 * S), "Tailscode · Image studio and video forge", font=font(BOLD, 36 * S), fill=TITLE)
d.text((margin, 92 * S), "The picture in the middle, the words under it, the machine's shelf on the right. Rendered by ComfyUI on your own machine, over Tailscale.", font=font(REG, 16 * S), fill=SUB)

def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius, fill=255)
    out = Image.new("RGB", img.size, BG)
    out.paste(img, (0, 0), mask)
    return out

for i, panel in enumerate(panels):
    col, row = i % 2, i // 2
    x = margin + col * (pw + gap)
    y = top + row * (ph + caption_h)
    shot = rounded(panel.resize((pw, ph), Image.LANCZOS), 10 * S)
    canvas.paste(shot, (x, y))
    d.rounded_rectangle((x, y, x + pw - 1, y + ph - 1), 10 * S, outline=BORDER, width=S)
    num, title, text = CAPTIONS[i]
    ty = y + ph + 16 * S
    d.text((x, ty), num, font=font(BOLD, 18 * S), fill=ACCENT)
    d.text((x + 36 * S, ty), title, font=font(BOLD, 18 * S), fill=TITLE)
    d.text((x, ty + 36 * S), text, font=font(REG, 13 * S), fill=SUB)

canvas.save(OUT)
print(canvas.size)
