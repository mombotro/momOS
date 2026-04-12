# LFS — Luminos Filesystem Format

Version 1. Block size: 512 bytes.

---

## Overview

LFS is a flat, append-friendly filesystem stored as a contiguous binary image.
It has three regions:

```
Block 0          : Superblock
Blocks 1..N      : Inode table   (N = inode_table_blocks)
Blocks N+1..end  : Data blocks
```

All multi-byte integers are little-endian.

---

## Superblock (Block 0, exactly 512 bytes)

| Offset | Size | Field                | Description                        |
|--------|------|----------------------|------------------------------------|
| 0      | 4    | magic                | `"LFS!"` (no null terminator)      |
| 4      | 4    | version              | Always `1`                         |
| 8      | 4    | block_size           | Always `512`                       |
| 12     | 4    | total_blocks         | Total blocks in the image          |
| 16     | 4    | inode_table_start    | First block of inode table (= `1`) |
| 20     | 4    | inode_table_blocks   | Number of blocks in inode table    |
| 24     | 4    | inode_count          | Total inodes (= `inode_table_blocks × 4`) |
| 28     | 4    | data_start           | First data block index             |
| 32     | 480  | pad                  | Reserved, must be zero             |

---

## Inode Table (Blocks 1..N)

Each inode is exactly 128 bytes. Four inodes fit per 512-byte block.
Inode 0 is always the root directory (`/`).

### Inode layout (128 bytes)

| Offset | Size | Field       | Description                                     |
|--------|------|-------------|-------------------------------------------------|
| 0      | 4    | type        | `0` = free, `1` = file, `2` = directory        |
| 4      | 4    | parent      | Parent inode index (root points to itself: `0`) |
| 8      | 4    | size        | File size in bytes (directories: always `0`)    |
| 12     | 32   | direct[8]   | Up to 8 direct data block indices              |
| 44     | 4    | indirect    | Single-indirect block index (`0` if unused)    |
| 48     | 72   | name        | Null-terminated filename (max 71 chars + `\0`) |
| 120    | 8    | reserved    | Zeroed                                          |

**Directory membership**: a file or directory belongs to a parent directory
if its `parent` field equals the parent's inode index. There is no explicit
directory entry list — the VFS driver scans all inodes to find children.

**Max file size**: 8 direct blocks + 128 indirect entries × 512 bytes = ~68 KB.

---

## Data Blocks (Blocks data_start..end)

Raw 512-byte blocks. File content is stored here. An indirect block holds
up to 128 uint32 block indices (512 / 4 = 128), pointing to additional data
blocks.

---

## Free Space

Unused data blocks (beyond the last written block, up to `total_blocks`) are
available for runtime writes via `fs.write()`. The kernel VFS tracks the next
free block at runtime using a simple linear scan from `data_start`.

---

## Host Tools

| Tool             | Purpose                                   |
|------------------|-------------------------------------------|
| `tools/mklfs`    | Pack a host directory into an LFS image   |
| `tools/lfs_inspect` | Dump the contents of an LFS image      |

Usage:
```
./tools/mklfs  <source-dir>  <output.lfs>  [inode-count]
./tools/lfs_inspect  <image.lfs>
```

---

## Limits

| Property         | Value          |
|------------------|----------------|
| Block size       | 512 bytes      |
| Max filename     | 71 characters  |
| Max file size    | ~68 KB         |
| Max inodes       | 256 (default: 64 in initrd) |
| Max image size   | ~2 MB (4096 data blocks)    |
