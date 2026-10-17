import sys, json, base64, io
from pathlib import Path
import numpy as np
from PIL import Image

src = Path(sys.argv[1])
out = Path(sys.argv[2])
W, H = 1536, 1008

THEMES = ["rose", "dawn", "tokyo", "phosphor"]
STAGE_KEYS = {
    "rose": ["sonnet3-rest", "fable4-rest", "sonnet3-settled", "sonnet3-hover-shell", "sonnet3-hover-act", "sonnet3-hover-sense", "sonnet3-hover-plan",
             "sonnet3-working", "sonnet3-approval", "sonnet3-dive-shell", "fable4-settled", "fable4-hover-shell", "fable4-dive-shell",
             "opus3-settled"],
    "dawn": ["sonnet3-rest", "sonnet3-settled", "sonnet3-hover-shell", "sonnet3-hover-act", "sonnet3-working", "fable4-settled"],
    "tokyo": ["sonnet3-settled", "sonnet3-hover-shell"],
    "phosphor": ["sonnet3-settled", "sonnet3-hover-shell"],
}
CARD_FACES = ["opus3", "sonnet3", "fable4"]
CARD_STATE = ["rest"]


def load(name):
    i = np.fromfile(src / f"{name}-interior.bgra", dtype=np.uint8).reshape(H, W, 4).astype(np.float32)
    if name.endswith("dive-shell"):
        s, cx, cy = 2.2, 240 / 640 * W, 284 / 420 * H
        cw, ch = W / s, H / s
        x0, y0 = int(round(cx - cw / 2)), int(round(cy - ch / 2))
        crop = Image.fromarray(i[y0:y0 + int(ch), x0:x0 + int(cw)].astype(np.uint8), "RGBA").resize((W, H), Image.BICUBIC)
        i = np.asarray(crop).astype(np.float32)
    f = np.fromfile(src / f"{name}-front.bgra", dtype=np.uint8).reshape(H, W, 4).astype(np.float32)
    a = f[..., 3:4] / 255.0
    rgb = f[..., :3] + i[..., :3] * (1 - a)
    rgb = np.clip(rgb, 0, 255)[..., ::-1]
    return Image.fromarray(rgb.astype(np.uint8), "RGB")


def uri(img, q):
    buf = io.BytesIO()
    img.save(buf, "WEBP", quality=q, method=5)
    return "data:image/webp;base64," + base64.b64encode(buf.getvalue()).decode()


stage, cards = {}, {}
for t in THEMES:
    for k in STAGE_KEYS[t]:
        name = f"{t}-{k}"
        if not (src / f"{name}-interior.bgra").exists():
            print("missing", name); continue
        im = load(name)
        stage[name] = uri(im, 80)
    for fc in CARD_FACES:
        for st in CARD_STATE:
            name = f"{t}-{fc}-{st}"
            im = load(name).resize((444, 291), Image.LANCZOS)
            cards[name] = uri(im, 84)
pal = json.loads((src / "palettes.json").read_text())
NAMES = {"rose": "Rosé Pine", "dawn": "Rosé Pine Dawn", "tokyo": "Tokyo Night", "phosphor": "Phosphor"}
for k in pal: pal[k]["name"] = NAMES[k]
js = "const STAGE=" + json.dumps(stage) + ";\nconst CARDS=" + json.dumps(cards) + ";\nconst PAL=" + json.dumps(pal) + ";\n"
out.write_text(js)
print("assets", len(stage), "stage", len(cards), "cards", round(len(js) / 1e6, 2), "MB")
