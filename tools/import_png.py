#!/usr/bin/env python3
"""
import_png.py — Convert a PNG image to momOS .mpi format

Usage:
  python import_png.py <input.png> [output.mpi] [options]

Options:
  --width W      Resize canvas to W pixels wide
  --height H     Resize canvas to H pixels tall
  --dither       Use Floyd-Steinberg dithering when quantizing

Requires: Pillow  (pip install Pillow)

The momOS 32-color palette is fixed at indices 0–31.
Color 0 is treated as transparent (black in the PNG is mapped to index 1).
Pixels whose alpha < 128 are mapped to index 0 (transparent).
"""

import sys
import struct
import math
import argparse
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Error: Pillow is required. Install with: pip install Pillow")

# ── momOS default 32-color palette (RGBA tuples) ─────────────────────────────
# Matches the palette defined in kernel/kernel.c
MOMOS_PALETTE = [
    (0,   0,   0),    # 0  black (transparent)
    (29,  43,  83),   # 1  dark navy
    (126, 37,  83),   # 2  dark purple
    (0,   135, 81),   # 3  dark green
    (171, 82,  54),   # 4  brown
    (95,  87,  79),   # 5  dark gray
    (194, 195, 199),  # 6  light gray
    (255, 241, 232),  # 7  white
    (255, 0,   77),   # 8  red
    (255, 163, 0),    # 9  orange
    (255, 236, 39),   # 10 yellow
    (0,   228, 54),   # 11 green
    (41,  173, 255),  # 12 blue
    (131, 118, 156),  # 13 lavender
    (255, 119, 168),  # 14 pink
    (255, 204, 170),  # 15 peach
    (41,  24,  20),   # 16 dark brown
    (17,  29,  53),   # 17 darker navy
    (66,  33,  54),   # 18 dark maroon
    (18,  83,  89),   # 19 dark teal
    (116, 47,  41),   # 20 rust
    (73,  51,  59),   # 21 mauve
    (162, 136, 121),  # 22 tan
    (243, 239, 125),  # 23 light yellow
    (190, 18,  80),   # 24 crimson
    (255, 108, 36),   # 25 deep orange
    (168, 234, 32),   # 26 lime
    (0,   181, 67),   # 27 bright green
    (6,   90,  181),  # 28 dark blue
    (117, 70,  101),  # 29 plum
    (255, 110, 89),   # 30 salmon
    (255, 157, 129),  # 31 light salmon
]


def color_distance(c1, c2):
    """Squared Euclidean distance in RGB space."""
    return (c1[0]-c2[0])**2 + (c1[1]-c2[1])**2 + (c1[2]-c2[2])**2


def nearest_color(r, g, b, alpha, skip_zero=True):
    """Find the nearest palette index for an RGB pixel.
    If alpha < 128, return 0 (transparent).
    If skip_zero, don't map opaque pixels to index 0."""
    if alpha < 128:
        return 0
    best_idx = 1 if skip_zero else 0
    best_dist = float('inf')
    start = 1 if skip_zero else 0
    for i in range(start, 32):
        d = color_distance((r, g, b), MOMOS_PALETTE[i])
        if d < best_dist:
            best_dist = d
            best_idx = i
    return best_idx


def quantize_image(img, dither=False):
    """Convert an RGBA PIL image to a list of palette indices."""
    w, h = img.size
    pixels = list(img.getdata())
    result = [0] * (w * h)

    if dither:
        # Floyd-Steinberg dithering
        # Work on a float error buffer
        err = [[list(pixels[y*w+x][:3]) for x in range(w)] for y in range(h)]
        for y in range(h):
            for x in range(w):
                alpha = pixels[y*w+x][3] if len(pixels[y*w+x]) == 4 else 255
                if alpha < 128:
                    result[y*w+x] = 0
                    continue
                r, g, b = err[y][x]
                r = max(0, min(255, int(r)))
                g = max(0, min(255, int(g)))
                b = max(0, min(255, int(b)))
                idx = nearest_color(r, g, b, 255)
                result[y*w+x] = idx
                pr, pg, pb = MOMOS_PALETTE[idx]
                er, eg, eb = r - pr, g - pg, b - pb
                # Distribute error
                if x + 1 < w:
                    err[y][x+1][0] += er * 7/16
                    err[y][x+1][1] += eg * 7/16
                    err[y][x+1][2] += eb * 7/16
                if y + 1 < h:
                    if x > 0:
                        err[y+1][x-1][0] += er * 3/16
                        err[y+1][x-1][1] += eg * 3/16
                        err[y+1][x-1][2] += eb * 3/16
                    err[y+1][x][0] += er * 5/16
                    err[y+1][x][1] += eg * 5/16
                    err[y+1][x][2] += eb * 5/16
                    if x + 1 < w:
                        err[y+1][x+1][0] += er * 1/16
                        err[y+1][x+1][1] += eg * 1/16
                        err[y+1][x+1][2] += eb * 1/16
    else:
        for i, px in enumerate(pixels):
            r, g, b = px[0], px[1], px[2]
            alpha = px[3] if len(px) == 4 else 255
            result[i] = nearest_color(r, g, b, alpha)

    return result, w, h


def write_mpi(pixel_data, w, h, output_path):
    """Write a single-frame, single-layer .mpi file."""
    if w > 128 or h > 128:
        sys.exit(f"Error: image {w}×{h} exceeds max .mpi size of 128×128")
    if w < 1 or h < 1:
        sys.exit("Error: image dimensions must be at least 1×1")

    header = b"MPI1"
    header += struct.pack("BBBBBBBBBBBB",
        w, h,
        1,   # layers
        1,   # frames
        0, 0, 0, 0, 0, 0, 0, 0)  # 8 reserved bytes

    pixel_bytes = bytes(pixel_data)
    data = header + pixel_bytes

    with open(output_path, 'wb') as f:
        f.write(data)

    nonzero = sum(1 for p in pixel_data if p != 0)
    print(f"Written: {output_path}")
    print(f"  Size: {w}×{h}, {len(data)} bytes")
    print(f"  Non-transparent pixels: {nonzero}/{w*h}")


def main():
    parser = argparse.ArgumentParser(description="Convert PNG to momOS .mpi")
    parser.add_argument("input",  help="Input PNG file")
    parser.add_argument("output", nargs="?", help="Output .mpi file (default: same name)")
    parser.add_argument("--width",  type=int, help="Resize to this width")
    parser.add_argument("--height", type=int, help="Resize to this height")
    parser.add_argument("--dither", action="store_true", help="Floyd-Steinberg dithering")
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        sys.exit(f"Error: input file not found: {args.input}")

    output_path = Path(args.output) if args.output else input_path.with_suffix(".mpi")

    img = Image.open(input_path).convert("RGBA")
    orig_w, orig_h = img.size
    print(f"Input: {input_path} ({orig_w}×{orig_h})")

    # Resize if requested or if too large
    target_w = args.width or min(orig_w, 128)
    target_h = args.height or min(orig_h, 128)
    if (target_w, target_h) != (orig_w, orig_h):
        img = img.resize((target_w, target_h), Image.NEAREST)
        print(f"Resized to: {target_w}×{target_h}")

    pixel_data, w, h = quantize_image(img, dither=args.dither)
    write_mpi(pixel_data, w, h, output_path)


if __name__ == "__main__":
    main()
