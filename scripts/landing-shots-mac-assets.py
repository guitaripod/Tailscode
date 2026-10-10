#!/usr/bin/env python3
"""Builds the files the Mac landing shots stage from: video posters, the first-frame clip's
source frame, and the staged chat transcript. Reads the real art folder (PNGs + manifest.json)
that the landing agents rendered; nothing is drawn here.

    landing-shots-mac-assets.py <art dir> <work dir>

Writes <work>/posters/demo*.png (named by the Video demo's entry ids), <work>/clip-frame.png
(the first frame of the clip: the cat-roof picture cropped to 1280x704) and <work>/messages.json
(a transcript for `--open stage:<messages.json>`, its pictures pointing into the art folder).
"""
import json, os, sys, time
from PIL import Image

art, work = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
os.makedirs(os.path.join(work, "posters"), exist_ok=True)


def crop(name, box, width):
    picture = Image.open(os.path.join(art, name)).convert("RGB").crop(box)
    height = round(picture.height * width / picture.width)
    return picture.resize((width, height), Image.LANCZOS)


POSTERS = {
    "demo-0": ("cat-roof.png", (560, 120, 1728, 778)),
    "demo-1": ("paper-boats.png", (0, 100, 1728, 1050)),
    "demo-2": ("paper-boats.png", (500, 100, 1728, 792)),
    "demo-3": ("lighthouse.png", (0, 100, 1728, 1050)),
    "demo-4": ("cabin-interior.png", (0, 350, 1408, 1142)),
    "demo-5": ("ramen.png", (0, 100, 1728, 1050)),
}
for key, (name, box) in POSTERS.items():
    crop(name, box, 640).save(os.path.join(work, "posters", key + ".png"))

frame = crop("cat-roof.png", (0, 100, 1728, 1050), 1280).resize((1280, 704), Image.LANCZOS)
frame.save(os.path.join(work, "posters", "demo.png"))
frame.save(os.path.join(work, "clip-frame.png"))

started = time.time() - 978307200 - 3600


def message(index, role, parts, duration=5):
    made = {
        "id": f"m{index}", "role": role, "agentType": "claudeCode", "parts": parts,
        "createdAt": started + index * 90, "completedAt": started + index * 90 + duration,
        "isStreaming": False,
    }
    if role == "assistant":
        made["modelID"] = "claude-opus-5-5"
        made["providerID"] = "anthropic"
    return made


def text(mid, n, body):
    return {"id": f"{mid}-p{n}", "kind": {"tag": "text", "value": body}}


def tool(mid, n, name, arguments, output):
    call = {"id": f"{mid}-t{n}", "name": name, "status": "completed", "input": arguments, "output": output}
    return {"id": f"{mid}-p{n}", "kind": {"tag": "tool", "value": call}}


def picture(mid, n, name):
    reference = {"path": os.path.join(art, name), "mime": "image/png", "filename": name}
    return {"id": f"{mid}-p{n}", "kind": {"tag": "file", "value": reference}}


transcript = [
    message(1, "user", [text("m1", 0, "Paint three reference moods for the composer's empty state on arch, same dusk light, and find the licence for the typeface they use.")]),
    message(2, "assistant", [
        text("m2", 0, "Queuing all three on arch with one seed family so the light matches, then I'll look up the licence while they render."),
        tool("m2", 1, "Bash", {"command": "scripts/queue-moods.sh --machine arch lighthouse sauna aurora-cabin"}, "queued 3 jobs on arch (qwen_image_2.1, 1728x1152, 25 steps)"),
        tool("m2", 2, "Read", {"file_path": "design/palette.md"}, "# Palette\n\ndusk blue, ember gold, snow white"),
        text("m2", 3, "The moods use Inter, which ships under the SIL Open Font License, so there is nothing to buy. The licence is at https://github.com/rsms/inter/blob/master/LICENSE.txt, the specimen at https://fonts.google.com/specimen/Inter, and the contrast rule for the caption ink is https://www.w3.org/TR/WCAG21/#contrast-minimum."),
        tool("m2", 4, "Bash", {"command": "scripts/wait-moods.sh --machine arch"}, "3 of 3 finished"),
        picture("m2", 5, "lighthouse.png"), picture("m2", 6, "sauna.png"), picture("m2", 7, "aurora-cabin.png"),
        text("m2", 8, "All three are on the shelf. The lighthouse and the aurora cabin share the blue-gold split the notes ask for; the sauna runs a little warmer, which I left alone."),
    ], 64),
    message(3, "assistant", [{"id": "m3-p0", "kind": {"tag": "compaction", "value": {"trigger": "auto", "tokensBefore": 311600, "tokensAfter": 16400, "duration": 114}}}]),
    message(4, "user", [text("m4", 0, "Keep the sauna warm and note the licence in the palette file.")]),
    message(5, "assistant", [
        tool("m5", 0, "Edit", {"file_path": "design/palette.md", "old_string": "snow white", "new_string": "snow white\n\nType: Inter, SIL OFL 1.1"}, "ok"),
        text("m5", 1, "Done: the sauna stays as rendered, and the palette file now records Inter under SIL OFL 1.1."),
    ], 9),
]
with open(os.path.join(work, "messages.json"), "w") as handle:
    json.dump(transcript, handle, indent=1)
print("assets in", work)
