# momOS Tile Map (.mtm) Format

## Overview

`.mtm` is a binary map format for the Terrain editor app.
Supports up to 256×256 tiles, 4 tile layers, 1 object layer, and key-value object properties.
All integers are little-endian.

---

## File Layout

```
[Header — 32 bytes]
[Tileset Reference — 64 bytes]
[Tile Layer Data — 4 × map_w × map_h bytes]
[Object Table — object_count × Object entries (variable)]
```

---

## Header (32 bytes)

| Offset | Size | Field          | Description                             |
|--------|------|----------------|-----------------------------------------|
| 0      | 4    | magic          | `"MTM1"` (ASCII)                        |
| 4      | 2    | map_w          | Map width in tiles (1–256)              |
| 6      | 2    | map_h          | Map height in tiles (1–256)             |
| 8      | 1    | tile_w         | Tile width in pixels (8 or 16)          |
| 9      | 1    | tile_h         | Tile height in pixels (8 or 16)         |
| 10     | 1    | layer_count    | Active tile layers (1–4)                |
| 11     | 2    | object_count   | Number of objects in the object layer   |
| 13     | 19   | reserved       | Zero-padded                             |

---

## Tileset Reference (64 bytes)

Null-terminated path to the `.mpi` tileset file used by this map.
Paths are absolute within the VFS (e.g., `/home/tileset.mpi`).
If the first byte is `0x00`, no tileset is associated.

---

## Tile Layer Data

`layer_count` layers stored sequentially.
Each layer is `map_w × map_h` bytes, row-major (top-left first).
Each byte is a tile index (0–255). Index **0** means empty / transparent.

Layers are composited bottom-to-top: layer 1 is the ground, layer 4 is on top.

Total size: `layer_count × map_w × map_h` bytes.

---

## Object Table

`object_count` object entries stored sequentially.

### Object Entry (variable length)

| Offset | Size | Field         | Description                              |
|--------|------|---------------|------------------------------------------|
| 0      | 2    | x             | X position in tile coordinates           |
| 2      | 2    | y             | Y position in tile coordinates           |
| 4      | 1    | type          | Object type (0=generic, 1=spawn, 2=exit) |
| 5      | 1    | prop_count    | Number of key-value properties (0–15)    |
| 6      | …    | properties    | `prop_count` Property entries            |

### Property Entry (variable length)

| Offset | Size | Field       | Description                              |
|--------|------|-------------|------------------------------------------|
| 0      | 1    | key_len     | Length of key string (1–31)              |
| 1      | key_len | key      | Key string (not null-terminated)         |
| 1+key_len | 1 | val_len   | Length of value string (0–63)            |
| 2+key_len | val_len | val  | Value string (not null-terminated)       |

---

## Tileset Layout (in the .mpi file)

Tiles are read from the tileset `.mpi` sequentially, row by row:

```
tile_index = row * tiles_per_row + col
tiles_per_row = mpi_width / tile_w
```

For a 128×128 `.mpi` with 8×8 tiles: 256 tiles (16 per row × 16 rows).
For a 128×128 `.mpi` with 16×16 tiles: 64 tiles (8 per row × 8 rows).

---

## Limits

| Property          | Min | Max  |
|-------------------|-----|------|
| Map width         | 1   | 256  |
| Map height        | 1   | 256  |
| Tile width        | 8   | 16   |
| Tile height       | 8   | 16   |
| Tile layers       | 1   | 4    |
| Objects           | 0   | 1023 |
| Properties/object | 0   | 15   |
| Key length        | 1   | 31   |
| Value length      | 0   | 63   |

---

## Example: 20×15 map, 8×8 tiles, 2 layers, no objects

```
Offset  Bytes   Meaning
------  ------  -------
0       MTM1    magic
4–5     0x14    map_w = 20
6–7     0x0F    map_h = 15
8       0x08    tile_w = 8
9       0x08    tile_h = 8
10      0x02    layer_count = 2
11–12   0x00    object_count = 0
13–31   zeroes  reserved
32–95   path    tileset path (up to 64 bytes, null-terminated)
96–395  300 bytes  layer 1 (20×15)
396–695 300 bytes  layer 2 (20×15)
```

Total file size: **696 bytes**.
