#!/usr/bin/env python3
"""Pack the rendered head layers into the runtime asset set.

usage: pack.py RENDER_DIR OUT_DIR

RENDER_DIR holds chassis, interior, glass, mask_i1..3, mask_c, mask_d and bloom_* PNGs from render.sh.
OUT_DIR gets png/ (RGBA8, for the CPU compositor on Linux), ntex/ (ASTC with mips, for Metal) and manifest.json.

Channel order of the twelve packed masks (NeuralChannel): think sense act shell | delegate say link star | seam eye rib ear.
The visor backing is not shipped: the effort segments are drawn from the eye channel.
"""
import hashlib
import json
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

try:
    import astc_encoder as A
except ImportError:
    A = None

MAGIC = b"NTEX"
VERSION = 1
FORMAT_RGBA8 = 0
FORMAT_ASTC4 = 1
FORMAT_ASTC6 = 2
BLOCK = {FORMAT_ASTC4: 4, FORMAT_ASTC6: 6}

COLOUR = ("chassis", "interior", "glass")
MASKS = ("mask0", "mask1", "mask2")
BLOOMS = ("bloom0", "bloom1", "bloom2")


def load_rgba(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGBA"))


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"))


def box_resize(a: np.ndarray, w: int, h: int, packed: bool = False) -> np.ndarray:
    """Pillow premultiplies RGBA while resizing, which is right for a picture with coverage in its alpha and
    ruins four independent channels sharing one RGBA texture, so packed data is resized a channel at a time."""
    if not packed:
        return np.asarray(Image.fromarray(a).resize((w, h), Image.Resampling.BOX))
    planes = [np.asarray(Image.fromarray(np.ascontiguousarray(a[..., c])).resize((w, h), Image.Resampling.BOX)) for c in range(a.shape[2])]
    return np.dstack(planes)


def pack_masks(d: Path):
    i1, i2, i3, c, dd = (load_rgb(d / f"mask_{n}.png") for n in ("i1", "i2", "i3", "c", "d"))
    return [
        np.dstack([i1[..., 0], i1[..., 1], i1[..., 2], i2[..., 0]]),
        np.dstack([i2[..., 1], i2[..., 2], i3[..., 0], i3[..., 1]]),
        np.dstack([c[..., 0], c[..., 1], dd[..., 0], dd[..., 1]]),
    ]


def pack_blooms(d: Path, size):
    i1, i2, i3, c, dd = (load_rgb(d / f"bloom_{n}.png") for n in ("i1", "i2", "i3", "c", "d"))
    packs = [
        np.dstack([i1[..., 0], i1[..., 1], i1[..., 2], i2[..., 0]]),
        np.dstack([i2[..., 1], i2[..., 2], i3[..., 0], i3[..., 1]]),
        np.dstack([c[..., 0], c[..., 1], dd[..., 0], dd[..., 1]]),
    ]
    return [box_resize(p, size[0], size[1], packed=True) if p.shape[1] != size[0] else p for p in packs]


def mip_chain(a: np.ndarray, packed: bool):
    chain = [a]
    while chain[-1].shape[0] > 1 or chain[-1].shape[1] > 1:
        h, w = chain[-1].shape[:2]
        chain.append(box_resize(chain[-1], max(1, w // 2), max(1, h // 2), packed))
    return chain


def astc_encode(a: np.ndarray, fmt: int, srgb: bool) -> bytes:
    bx = BLOCK[fmt]
    h, w = a.shape[:2]
    profile = A.ASTCProfile.LDR_SRGB if srgb else A.ASTCProfile.LDR
    ctx = A.ASTCContext(A.ASTCConfig(profile, bx, bx, 1, A.ASTCQualityPreset.THOROUGH))
    img = A.ASTCImage(A.ASTCType.U8, w, h, 1, np.ascontiguousarray(a).tobytes())
    return bytes(ctx.compress(img, A.ASTCSwizzle.from_str("RGBA")))


def write_ntex(path: Path, a: np.ndarray, fmt: int, srgb: bool, packed: bool):
    mips = [encode_level(level, fmt, srgb) for level in mip_chain(a, packed)]
    h, w = a.shape[:2]
    header = MAGIC + struct.pack("<HBBIII", VERSION, fmt, 0, w, h, len(mips))
    header += b"".join(struct.pack("<I", len(m)) for m in mips)
    path.write_bytes(header + b"".join(mips))


def encode_level(level: np.ndarray, fmt: int, srgb: bool) -> bytes:
    if fmt == FORMAT_RGBA8:
        return np.ascontiguousarray(level).tobytes()
    return astc_encode(level, fmt, srgb)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    (out / "png").mkdir(parents=True, exist_ok=True)
    (out / "ntex").mkdir(parents=True, exist_ok=True)

    chassis = load_rgba(src / "chassis.png")
    interior = load_rgba(src / "interior.png")
    glass_full = load_rgba(src / "glass.png")
    h, w = chassis.shape[:2]
    glass = box_resize(glass_full, w // 2, h // 2)
    bloom_size = (w // 8, h // 8)

    layers = {"chassis": (chassis, FORMAT_ASTC4, True), "interior": (interior, FORMAT_ASTC6, True), "glass": (glass, FORMAT_ASTC4, True)}
    for name, m in zip(MASKS, pack_masks(src)):
        layers[name] = (m, FORMAT_ASTC6, False)
    for name, b in zip(BLOOMS, pack_blooms(src, bloom_size)):
        layers[name] = (b, FORMAT_ASTC4, False)

    manifest = {"version": VERSION, "channels": ["think", "sense", "act", "shell", "delegate", "say", "link", "star", "seam", "eye", "rib", "ear"], "layers": {}}
    for name, (arr, fmt, srgb) in layers.items():
        png = out / "png" / f"{name}.png"
        Image.fromarray(arr, "RGBA").save(png, optimize=True)
        entry = {"width": arr.shape[1], "height": arr.shape[0], "srgb": srgb, "png": png.stat().st_size, "pngSha": digest(png)}
        if A is not None:
            ntex = out / "ntex" / f"{name}.ntex"
            write_ntex(ntex, arr, fmt, srgb, packed=name not in COLOUR)
            entry.update({"format": fmt, "ntex": ntex.stat().st_size, "ntexSha": digest(ntex)})
        manifest["layers"][name] = entry
        print(f"{name:9s} {arr.shape[1]}x{arr.shape[0]}  png {entry['png'] / 1024:7.0f} KB" + (f"  ntex {entry['ntex'] / 1024:7.0f} KB" if "ntex" in entry else ""))

    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    total_png = sum(e["png"] for e in manifest["layers"].values())
    total_ntex = sum(e.get("ntex", 0) for e in manifest["layers"].values())
    print(f"total png {total_png / 1048576:.1f} MB  ntex {total_ntex / 1048576:.1f} MB")


if __name__ == "__main__":
    main()
