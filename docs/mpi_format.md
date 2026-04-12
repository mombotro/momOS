# momOS Pixel Image (.mpi) Format

## Overview

`.mpi` is a compact binary sprite format supporting multiple frames and layers.
All integer fields are unsigned, big-endian byte order.

---

## File Layout

```
[Header — 16 bytes]
[Pixel Data — w × h × layers × frames bytes]
[Palette Block — optional, 96 bytes + 4-byte tag]
```

---

## Header (16 bytes)

| Offset | Size | Field      | Description                          |
|--------|------|------------|--------------------------------------|
| 0      | 4    | magic      | `"MPI1"` (ASCII, no null)            |
| 4      | 1    | width      | Canvas width in pixels (1–128)       |
| 5      | 1    | height     | Canvas height in pixels (1–128)      |
| 6      | 1    | layers     | Number of layers (1–4)               |
| 7      | 1    | frames     | Number of animation frames (1–16)    |
| 8      | 8    | reserved   | Zero-padded; ignored on read         |

---

## Pixel Data

Immediately follows the header. Organized as:

```
for f = 1 to frames:
  for l = 1 to layers:
    w × h bytes (row-major, top-left first)
```

Each byte is a palette index (0–31). Index **0** means transparent.

Total pixel data size: `width × height × layers × frames` bytes.

---

## Optional Palette Block

If the file contains more data after the pixel section, check for a palette block:

| Offset (from end of pixel data) | Size | Field   | Description          |
|---------------------------------|------|---------|----------------------|
| 0                               | 4    | tag     | `"PAL1"` (ASCII)     |
| 4                               | 96   | colors  | 32 × 3 bytes (R,G,B) |

If `"PAL1"` is present, the 32 RGB entries override the default system palette
for rendering this sprite. Each color is a 3-byte tuple: red, green, blue (0–255).

Palette data is ignored on files written by earlier tools that don't know about it.

---

## Limits

| Property       | Min | Max |
|----------------|-----|-----|
| Width          | 1   | 128 |
| Height         | 1   | 128 |
| Layers         | 1   | 4   |
| Frames         | 1   | 16  |
| Palette colors | 32  | 32  |

---

## Example: 16×16, 1 frame, 1 layer, no custom palette

```
Offset  Bytes   Meaning
------  ------  -------
0       MPI1    magic
4       0x10    width = 16
5       0x10    height = 16
6       0x01    layers = 1
7       0x01    frames = 1
8–15    0×8     reserved (zeroes)
16–271  256 bytes  pixel data (16×16)
```

Total file size: **272 bytes**.

---

## Reading Algorithm (pseudo-code)

```lua
assert(data:sub(1,4) == "MPI1")
w, h, nl, nf = bytes 5–8
pixels = {}
pos = 17
for f = 1..nf do
  pixels[f] = {}
  for l = 1..nl do
    pixels[f][l] = read w*h bytes starting at pos
    pos += w*h
  end
end
if data:sub(pos, pos+3) == "PAL1" then
  palette = read 96 bytes at pos+4
end
```
