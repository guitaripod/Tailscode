#!/usr/bin/env python3
"""Convert a packed PNG set to the raw NTRG files NeuralAssetStore reads (magic, width, height, RGBA8).

usage: png2ntrg.py PNG_DIR OUT_DIR
"""
import struct
import sys
from pathlib import Path

from PIL import Image


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for png in sorted(src.glob("*.png")):
        im = Image.open(png).convert("RGBA")
        (out / f"{png.stem}.ntrg").write_bytes(b"NTRG" + struct.pack("<II", im.width, im.height) + im.tobytes())
        print(png.stem, im.size)


if __name__ == "__main__":
    main()
