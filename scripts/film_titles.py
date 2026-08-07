"""The type over the picture: the app's own palette, drawn as a 4K overlay plate.

A caption on a screen recording has nowhere to stand — the interface underneath is already
information, in the same colours, at a smaller size. So none of these are boxes: each is a plate
the full size of the frame, mostly transparent, with a gradient that fades the app out toward the
edge the type sits on. The accent rule, the mono kicker and the keycap chips are the app's own
furniture, so the caption reads as part of the product rather than a sticker on top of it.
"""
from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 3840, 2160

CANVAS = (3, 8, 6)
RULE = (14, 42, 32)
ACCENT = (57, 255, 136)
TEXT = (184, 255, 208)
DIM = (91, 156, 118)

SANS = "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf"
MONO = "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf"
MONO_BOLD = "/usr/share/fonts/Adwaita/AdwaitaMono-Bold.ttf"


def font(path, size, weight=None):
    """Adwaita Sans is variable — optical size first, weight second, or the axes land wrong."""
    face = ImageFont.truetype(path, size)
    if weight is not None:
        try:
            axes = [axis["name"] for axis in face.get_variation_axes()]
            values = [32 if b"Optical" in name else weight for name in axes]
            face.set_variation_by_axes(values)
        except (OSError, AttributeError, KeyError):
            pass
    return face


def rounded(draw, box, radius, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def tracked(draw, xy, text, face, fill, tracking=0):
    """Letterspacing is the difference between a label and a caption that looks designed."""
    x, y = xy
    for character in text:
        draw.text((x, y), character, font=face, fill=fill)
        x += draw.textlength(character, font=face) + tracking
    return x - xy[0]


def measure(text, face, tracking=0):
    image = Image.new("RGBA", (8, 8))
    draw = ImageDraw.Draw(image)
    return sum(draw.textlength(c, font=face) for c in text) + tracking * max(0, len(text) - 1)


def scrim(height, peak=0.94, curve=0.62):
    """Type over a UI needs ground to stand on: a band that fades the app out, not a box."""
    band = Image.new("RGBA", (1, height))
    pixels = band.load()
    for y in range(height):
        eased = (y / (height - 1)) ** curve
        pixels[0, y] = CANVAS + (int(255 * peak * eased),)
    return band.resize((WIDTH, height))


def caption_card(kicker, line, keys=None, anchor="bottom"):
    """A caption in the app's own palette: accent rule, mono label, one sentence.

    `anchor="top"` flips the plate for the shots whose subject lives at the bottom of the window —
    a terminal docked under the transcript, a composer being typed into. The scrim has to fade the
    app out toward the edge the type sits on, so it is mirrored rather than moved.
    """
    image = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    if anchor == "top":
        image.paste(scrim(660, peak=0.95, curve=0.48).transpose(Image.FLIP_TOP_BOTTOM), (0, 0))
    else:
        image.paste(scrim(820, peak=0.95, curve=0.48), (0, HEIGHT - 820))
    draw = ImageDraw.Draw(image)
    kicker_face = font(MONO_BOLD, 42)
    line_face = font(SANS, 104, weight=600)
    key_face = font(MONO_BOLD, 48)

    x = 210
    top = 140 if anchor == "top" else HEIGHT - 366
    draw.rounded_rectangle((x, top - 6, x + 10, top + 216), radius=5, fill=ACCENT + (255,))
    text_x = x + 54

    if keys:
        chip_x = text_x
        for key in keys:
            chip_w = measure(key, key_face) + 48
            rounded(
                draw,
                (chip_x, top - 8, chip_x + chip_w, top + 62),
                14,
                fill=(14, 42, 32, 235),
                outline=ACCENT + (165,),
                width=3,
            )
            draw.text((chip_x + 24, top + 2), key, font=key_face, fill=ACCENT + (255,))
            chip_x += chip_w + 20
    else:
        tracked(draw, (text_x, top), kicker.upper(), kicker_face, ACCENT + (240,), tracking=9)
    draw.text((text_x - 4, top + 92), line, font=line_face, fill=TEXT + (255,))
    return image


def title_card(mark="REMOTE CODING AGENTS", name="Tailscode",
               tag="Claude Code and opencode, anywhere on your tailnet."):
    image = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    image.paste(scrim(1240, peak=0.97, curve=0.40), (0, HEIGHT - 1240))
    draw = ImageDraw.Draw(image)
    name_face = font(SANS, 190, weight=700)
    tag_face = font(SANS, 84, weight=400)
    mark_face = font(MONO_BOLD, 46)
    x, y = 210, HEIGHT - 620
    draw.rounded_rectangle((x, y, x + 10, y + 386), radius=5, fill=ACCENT + (255,))
    tracked(draw, (x + 58, y), mark, mark_face, ACCENT + (235,), tracking=11)
    draw.text((x + 52, y + 78), name, font=name_face, fill=TEXT + (255,))
    draw.text((x + 58, y + 300), tag, font=tag_face, fill=DIM + (255,))
    return image


def end_card(name="Tailscode", tag="One window for every machine you code on.",
             platforms="iOS · macOS · Linux"):
    image = Image.new("RGBA", (WIDTH, HEIGHT), CANVAS + (243,))
    draw = ImageDraw.Draw(image)
    name_face = font(SANS, 226, weight=700)
    tag_face = font(SANS, 86, weight=400)
    mark_face = font(MONO_BOLD, 50)

    name_w = measure(name, name_face)
    draw.text(((WIDTH - name_w) / 2, HEIGHT / 2 - 264), name, font=name_face, fill=TEXT + (255,))
    tag_w = measure(tag, tag_face)
    draw.text(((WIDTH - tag_w) / 2, HEIGHT / 2 + 34), tag, font=tag_face, fill=DIM + (255,))
    line_y = HEIGHT / 2 + 186
    draw.rectangle((WIDTH / 2 - 190, line_y, WIDTH / 2 + 190, line_y + 3), fill=RULE + (255,))
    plat_w = measure(platforms, mark_face, tracking=14)
    tracked(draw, ((WIDTH - plat_w) / 2, line_y + 66), platforms, mark_face,
            ACCENT + (235,), tracking=14)
    return image
