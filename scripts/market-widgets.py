#!/usr/bin/env python3
"""Cut the Home Screen widget tiles out of a `widgets-store` capture.

`scripts/shots.sh widgets-store` launches the app's widget preview in its store layout: one of each
family — large, medium, two smalls — on a flat key colour (magenta), at the widgets' real point sizes.
This finds each tile by what is not the key colour and trims it to the widget's own rounded corners,
so the store panel can set the family on its own ground the way a Home Screen sets it.

  scripts/market-widgets.py <capture.png> <locale>      # -> marketing/appstore/widgets/<locale>/
"""
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY = (255, 0, 255)
CORNER = 78
TOP_SKIP = 330


def is_key(pixel):
    return abs(pixel[0] - KEY[0]) < 40 and pixel[1] < 40 and abs(pixel[2] - KEY[2]) < 40


def bands(flags, minimum=40):
    """The runs of True in a list of flags that are at least `minimum` long."""
    runs, start = [], None
    for i, flag in enumerate(flags + [False]):
        if flag and start is None:
            start = i
        elif not flag and start is not None:
            if i - start >= minimum:
                runs.append((start, i))
            start = None
    return runs


def main():
    capture, locale = sys.argv[1], sys.argv[2]
    image = Image.open(capture).convert("RGB")
    width, height = image.size
    pixels = image.load()
    rows = [any(not is_key(pixels[x, y]) for x in range(0, width, 3)) if y >= TOP_SKIP else False
            for y in range(height)]
    tiles = []
    for top, bottom in bands(rows):
        columns = [any(not is_key(pixels[x, y]) for y in range(top, bottom, 3)) for x in range(width)]
        for left, right in bands(columns):
            tiles.append((left, top, right, bottom))
    if len(tiles) != 4:
        sys.exit(f"expected 4 tiles in {capture}, found {len(tiles)}: {tiles}")
    tiles.sort(key=lambda t: (t[1], t[0]))
    names = ["large", "medium", "small-a", "small-b"]
    folder = os.path.join(ROOT, "marketing/appstore/widgets", locale)
    os.makedirs(folder, exist_ok=True)
    for name, box in zip(names, tiles):
        tile = image.crop(box)
        mask = Image.new("L", tile.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle([1, 1, tile.width - 2, tile.height - 2], radius=CORNER, fill=255)
        out = Image.new("RGBA", tile.size, (0, 0, 0, 0))
        out.paste(tile, (0, 0), mask)
        out.save(os.path.join(folder, name + ".png"))
        print(f"  {locale}/{name}.png {tile.size}")


if __name__ == "__main__":
    main()
