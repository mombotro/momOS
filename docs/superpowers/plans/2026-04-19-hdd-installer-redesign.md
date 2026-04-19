# HDD Installer Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix HDD installation so momOS can be installed and booted from a real hard drive on Presario 5000 and Acer Aspire 1.

**Architecture:** Two problems solved together: (1) LFS single-indirect file size limit (68 KB) extended to ~8.5 MB via double-indirect using the existing `reserved[0]` inode field; (2) GRUB-can't-read-LFS fixed by writing a FAT12 boot partition that GRUB can read natively, containing `kernel.bin` and `initrd.lfs`. The installer creates a 2-partition HDD layout (FAT12 + LFS) and GRUB boots directly from the FAT12 partition via an embedded config (no grub.cfg needed on disk).

**Tech Stack:** C11 (freestanding i686), Lua 5.4, ATA PIO, FAT12, LFS, GRUB2 i386-pc, NASM

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `kernel/vfs/lfs_format.h` | Modify | Rename `reserved[0]` → `indirect2` |
| `tools/mklfs.c` | Modify | Add double-indirect write path |
| `kernel/vfs/vfs.c` | Modify | Add double-indirect read/write/free paths |
| `kernel/disk/fat12.h` | Create | FAT12 API declarations |
| `kernel/disk/fat12.c` | Create | FAT12 format + file write |
| `kernel/lua/klua.c` | Modify | Add `sys.fat_format`, `sys.fat_write`, `sys.fat_write_vfs`, `sys.disk_write_mbr2` |
| `Makefile` | Modify | Add `fat12.o` to OBJS; add `grub-blobs` embedded config; add `kernel.bin` copy step |
| `.gitignore` | Modify | Add `initrd/sys/boot/kernel.bin` |
| `initrd/apps/installer.lua` | Modify | Replace 4-step install with 7-step sequence |

---

## Task 1: LFS double-indirect — lfs_format.h + mklfs.c

**Files:**
- Modify: `kernel/vfs/lfs_format.h:44-57`
- Modify: `tools/mklfs.c:57-100`

The inode struct has `uint32_t reserved[2]` at bytes 120–127. We repurpose `reserved[0]` as `indirect2`. The struct stays 128 bytes — the compile-time size check at line 57 guards this.

- [ ] **Step 1: Update lfs_format.h**

Replace the inode struct's `reserved[2]` with `indirect2 + reserved` and update the header comment:

```c
/* LFS — Luminos Filesystem on-disk layout
   Shared between kernel driver and host tools.

   Block size : 512 bytes
   Inode size : 128 bytes  (4 per block)
   Max name   : 71 chars
   Max file   : 8 direct + 128 single-indirect + 16384 double-indirect = ~8.5 MB
   ...
*/
```

In the inode struct, change:
```c
    uint32_t reserved[2];
```
to:
```c
    uint32_t indirect2;           /* double-indirect block index (0 = unused) */
    uint32_t reserved;
```

- [ ] **Step 2: Update write_file_data in mklfs.c**

Replace the entire `write_file_data` function (lines 59–100) with this version that supports double-indirect. Note: mklfs has direct `image[blk]` array access so there is no need for buffers — writes go straight to the right block.

```c
static void write_file_data(lfs_inode_t *inode, const uint8_t *data, uint32_t len) {
    uint32_t written = 0;
    uint32_t blk_idx = 0;
    const uint32_t IND = LFS_BLOCK_SIZE / 4; /* 128 entries per indirect block */

    while (written < len) {
        uint32_t chunk = len - written;
        if (chunk > LFS_BLOCK_SIZE) chunk = LFS_BLOCK_SIZE;

        uint32_t abs_blk;

        if (blk_idx < LFS_DIRECT) {
            abs_blk = alloc_block();
            inode->direct[blk_idx] = abs_blk;

        } else if (blk_idx < LFS_DIRECT + IND) {
            uint32_t ind_idx = blk_idx - LFS_DIRECT;
            if (!inode->indirect) {
                inode->indirect = alloc_block();
                memset(image[inode->indirect], 0, LFS_BLOCK_SIZE);
            }
            abs_blk = alloc_block();
            ((uint32_t *)image[inode->indirect])[ind_idx] = abs_blk;

        } else {
            uint32_t d_idx = blk_idx - LFS_DIRECT - IND;
            uint32_t outer  = d_idx / IND;
            uint32_t inner  = d_idx % IND;
            if (outer >= IND) die("file too large for double indirect");

            if (!inode->indirect2) {
                inode->indirect2 = alloc_block();
                memset(image[inode->indirect2], 0, LFS_BLOCK_SIZE);
            }
            uint32_t *d2 = (uint32_t *)image[inode->indirect2];
            if (!d2[outer]) {
                d2[outer] = alloc_block();
                memset(image[d2[outer]], 0, LFS_BLOCK_SIZE);
            }
            abs_blk = alloc_block();
            ((uint32_t *)image[d2[outer]])[inner] = abs_blk;
        }

        memcpy(image[abs_blk], data + written, chunk);
        written += chunk;
        blk_idx++;
    }
    inode->size = len;
}
```

- [ ] **Step 3: Rebuild mklfs and test double-indirect**

Run in MSYS2:
```bash
make tools/mklfs
mkdir -p /tmp/testlfs
dd if=/dev/zero of=/tmp/testlfs/bigfile.bin bs=1024 count=100
./tools/mklfs /tmp/testlfs /tmp/test.lfs
```

Expected output:
```
  + /tmp/testlfs/bigfile.bin (102400 bytes)
mklfs: wrote ... blocks (...) to /tmp/test.lfs
```
Must NOT print `mklfs: file too large for single indirect`.

- [ ] **Step 4: Commit**

```bash
git add kernel/vfs/lfs_format.h tools/mklfs.c
git commit -m "feat: LFS double-indirect — extends max file size to ~8.5 MB"
```

---

## Task 2: LFS double-indirect — kernel VFS reader/writer (vfs.c)

**Files:**
- Modify: `kernel/vfs/vfs.c:103-156` (block_in_use, free_inode_blocks)
- Modify: `kernel/vfs/vfs.c:189-222` (vfs_read)
- Modify: `kernel/vfs/vfs.c:305-366` (vfs_write)
- Modify: `kernel/vfs/vfs.c:283-303` (vfs_mkdir — zero indirect2)
- Modify: `kernel/vfs/vfs.c:305-366` (vfs_write — zero indirect2 for new inodes)

- [ ] **Step 1: Add `#define LFS_IND` constant at top of vfs.c**

After the includes (line 5), add:
```c
#define LFS_IND  (LFS_BLOCK_SIZE / 4)   /* 128 entries per indirect block */
```

- [ ] **Step 2: Update block_in_use to check indirect2**

In `block_in_use` (lines 106–122), after the existing single-indirect check block, add before the closing `}`:

```c
        /* Double-indirect */
        if (n->indirect2 == blk) return 1;
        if (n->indirect2) {
            uint32_t *d2 = (uint32_t *)block_ptr(n->indirect2);
            for (uint32_t j = 0; j < LFS_IND; j++) {
                if (d2[j] == blk) return 1;
                if (d2[j]) {
                    uint32_t *l2 = (uint32_t *)block_ptr(d2[j]);
                    for (uint32_t k = 0; k < LFS_IND; k++)
                        if (l2[k] == blk) return 1;
                }
            }
        }
```

- [ ] **Step 3: Update free_inode_blocks to free indirect2 blocks**

In `free_inode_blocks` (lines 136–156), after the `if (n->indirect)` block (before the closing `}`), add:

```c
    if (n->indirect2) {
        uint32_t *d2 = (uint32_t *)block_ptr(n->indirect2);
        for (uint32_t j = 0; j < LFS_IND; j++) {
            if (!d2[j]) continue;
            uint32_t *l2 = (uint32_t *)block_ptr(d2[j]);
            for (uint32_t k = 0; k < LFS_IND; k++) {
                if (!l2[k]) continue;
                uint8_t *b = (uint8_t *)block_ptr(l2[k]);
                for (int m = 0; m < LFS_BLOCK_SIZE; m++) b[m] = 0;
                l2[k] = 0;
            }
            uint8_t *l2b = (uint8_t *)block_ptr(d2[j]);
            for (int m = 0; m < LFS_BLOCK_SIZE; m++) l2b[m] = 0;
            d2[j] = 0;
        }
        uint8_t *d2b = (uint8_t *)block_ptr(n->indirect2);
        for (int m = 0; m < LFS_BLOCK_SIZE; m++) d2b[m] = 0;
        n->indirect2 = 0;
    }
```

- [ ] **Step 4: Update vfs_read to handle double-indirect**

Replace the `else` branch in `vfs_read` (the single-indirect block, starting at line ~209) with:

```c
        uint32_t abs_blk;
        if (blk_idx < LFS_DIRECT) {
            abs_blk = n->direct[blk_idx];
        } else if (blk_idx < LFS_DIRECT + LFS_IND) {
            uint32_t ind_idx = blk_idx - LFS_DIRECT;
            if (!n->indirect) break;
            uint32_t *ind_tbl = (uint32_t *)block_ptr(n->indirect);
            abs_blk = ind_tbl[ind_idx];
        } else {
            uint32_t d_idx = blk_idx - LFS_DIRECT - LFS_IND;
            uint32_t outer  = d_idx / LFS_IND;
            uint32_t inner  = d_idx % LFS_IND;
            if (!n->indirect2) break;
            uint32_t *d2 = (uint32_t *)block_ptr(n->indirect2);
            if (!d2[outer]) break;
            uint32_t *l2 = (uint32_t *)block_ptr(d2[outer]);
            abs_blk = l2[inner];
        }
```

- [ ] **Step 5: Update vfs_write to handle double-indirect**

Replace the block-writing loop in `vfs_write` (lines 333–364) with:

```c
    uint32_t written = 0, blk_idx = 0;
    while (written < len) {
        uint32_t chunk = len - written;
        if (chunk > LFS_BLOCK_SIZE) chunk = LFS_BLOCK_SIZE;

        /* Allocate metadata blocks before data so block_in_use() sees them */
        if (blk_idx >= LFS_DIRECT && blk_idx < LFS_DIRECT + LFS_IND) {
            if (!n->indirect) {
                n->indirect = alloc_block();
                if (!n->indirect) return -1;
                uint8_t *ib = (uint8_t *)block_ptr(n->indirect);
                for (int k = 0; k < LFS_BLOCK_SIZE; k++) ib[k] = 0;
            }
        } else if (blk_idx >= LFS_DIRECT + LFS_IND) {
            uint32_t d_idx = blk_idx - LFS_DIRECT - LFS_IND;
            uint32_t outer  = d_idx / LFS_IND;
            uint32_t inner  = d_idx % LFS_IND;
            (void)inner;
            if (!n->indirect2) {
                n->indirect2 = alloc_block();
                if (!n->indirect2) return -1;
                uint8_t *d2b = (uint8_t *)block_ptr(n->indirect2);
                for (int k = 0; k < LFS_BLOCK_SIZE; k++) d2b[k] = 0;
            }
            uint32_t *d2 = (uint32_t *)block_ptr(n->indirect2);
            if (!d2[outer]) {
                uint32_t l2 = alloc_block();
                if (!l2) return -1;
                d2[outer] = l2;
                uint8_t *l2b = (uint8_t *)block_ptr(l2);
                for (int k = 0; k < LFS_BLOCK_SIZE; k++) l2b[k] = 0;
            }
        }

        uint32_t blk = alloc_block();
        if (!blk) return -1;

        uint8_t *dst = (uint8_t *)block_ptr(blk);
        for (int k = 0; k < LFS_BLOCK_SIZE; k++) dst[k] = 0;
        const uint8_t *src = (const uint8_t *)data + written;
        for (uint32_t k = 0; k < chunk; k++) dst[k] = src[k];

        if (blk_idx < LFS_DIRECT) {
            n->direct[blk_idx] = blk;
        } else if (blk_idx < LFS_DIRECT + LFS_IND) {
            uint32_t *ind = (uint32_t *)block_ptr(n->indirect);
            ind[blk_idx - LFS_DIRECT] = blk;
        } else {
            uint32_t d_idx = blk_idx - LFS_DIRECT - LFS_IND;
            uint32_t outer  = d_idx / LFS_IND;
            uint32_t inner  = d_idx % LFS_IND;
            uint32_t *d2 = (uint32_t *)block_ptr(n->indirect2);
            uint32_t *l2 = (uint32_t *)block_ptr(d2[outer]);
            l2[inner] = blk;
        }

        written += chunk;
        blk_idx++;
    }
    n->size = len;
```

- [ ] **Step 6: Zero indirect2 when initialising new inodes**

In `vfs_mkdir` (around line 298), after `n->indirect = 0;` add:
```c
    n->indirect2 = 0;
```

In `vfs_write` (around line 327), in the `else` branch (new inode), after `n->indirect = 0;` add:
```c
        n->indirect2 = 0;
```

- [ ] **Step 7: Compile kernel.bin to verify**

Run in MSYS2:
```bash
make kernel.bin
```
Expected: compiles without errors. No runtime test possible at this stage.

- [ ] **Step 8: Commit**

```bash
git add kernel/vfs/vfs.c
git commit -m "feat: LFS double-indirect read/write in kernel VFS"
```

---

## Task 3: FAT12 boot partition writer

**Files:**
- Create: `kernel/disk/fat12.h`
- Create: `kernel/disk/fat12.c`

FAT12 volume parameters (hardcoded for 8 MB = 16384 sectors):
- 512 bytes/sector, 8 sectors/cluster (4 KB), 1 reserved sector
- 2 FAT copies × 6 sectors each = 12 FAT sectors
- 32 root directory entries = 2 root dir sectors
- Data starts at sector 15 (1 + 12 + 2)
- ~2046 clusters → well within FAT12 limit of 4084

- [ ] **Step 1: Create fat12.h**

```c
/* kernel/disk/fat12.h — minimal FAT12 writer for momOS installer */
#pragma once
#include <stdint.h>

/* Volume geometry (fixed 8 MB layout) */
#define FAT12_SECTORS      16384u  /* total sectors in volume */
#define FAT12_SEC_PER_CLU  8u      /* 4 KB clusters */
#define FAT12_RESERVED     1u
#define FAT12_FAT_COUNT    2u
#define FAT12_FAT_SIZE     6u      /* sectors per FAT */
#define FAT12_ROOT_ENTS    32u
#define FAT12_ROOT_SECS    2u      /* 32 entries × 32 bytes = 1024 = 2 sectors */
#define FAT12_DATA_START   (FAT12_RESERVED + FAT12_FAT_COUNT * FAT12_FAT_SIZE + FAT12_ROOT_SECS)
/* = 1 + 12 + 2 = 15 */

/*
 * Format a FAT12 volume at (drive, lba_start).
 * Writes boot sector, 2 FAT copies, and empty root directory.
 * Returns 0 on success, -1 on disk error.
 */
int fat12_format(int drive, uint32_t lba_start);

/*
 * Write a flat file to the root directory of a FAT12 volume.
 * filename: up to "8.3" format, e.g. "kernel.bin" or "initrd.lfs"
 * Returns 0 on success, -1 on error.
 */
int fat12_write_file(int drive, uint32_t lba_start,
                     const char *filename,
                     const uint8_t *data, uint32_t len);

/*
 * Same as fat12_write_file but reads from the in-memory VFS
 * (uses vfs_get_base() / vfs_get_size() — writes the live initrd image).
 */
int fat12_write_vfs(int drive, uint32_t lba_start, const char *filename);
```

- [ ] **Step 2: Create fat12.c — helpers + fat12_format**

```c
/* kernel/disk/fat12.c — minimal FAT12 writer, installer use only */
#include "fat12.h"
#include "ata_pio.h"
#include "../vfs/vfs.h"
#include "../mm/heap.h"
#include <stdint.h>

/* ── Helpers ─────────────────────────────────────────────────────────────── */

static void u16_le(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
}

static void u32_le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

/* Parse "kernel.bin" → name[8]="KERNEL  " ext[3]="BIN" (FAT 8.3, uppercase) */
static void parse_83(const char *fn, uint8_t *name, uint8_t *ext) {
    int i;
    for (i = 0; i < 8; i++) name[i] = ' ';
    for (i = 0; i < 3; i++) ext[i]  = ' ';

    int dot = -1;
    for (i = 0; fn[i]; i++) if (fn[i] == '.') { dot = i; break; }

    int ni = 0;
    for (i = 0; fn[i] && fn[i] != '.' && ni < 8; i++) {
        uint8_t c = (uint8_t)fn[i];
        if (c >= 'a' && c <= 'z') c = (uint8_t)(c - 32);
        name[ni++] = c;
    }
    if (dot >= 0) {
        int ei = 0;
        for (i = dot + 1; fn[i] && ei < 3; i++) {
            uint8_t c = (uint8_t)fn[i];
            if (c >= 'a' && c <= 'z') c = (uint8_t)(c - 32);
            ext[ei++] = c;
        }
    }
}

/* Read/write a FAT12 12-bit entry.
   fat: pointer to full FAT buffer (FAT12_FAT_SIZE * 512 bytes). */
static uint16_t fat12_get(const uint8_t *fat, uint32_t cluster) {
    uint32_t off = cluster + cluster / 2;
    uint16_t val = (uint16_t)fat[off] | ((uint16_t)fat[off + 1] << 8);
    return (cluster & 1u) ? (val >> 4) : (val & 0xFFFu);
}

static void fat12_set(uint8_t *fat, uint32_t cluster, uint16_t val) {
    uint32_t off = cluster + cluster / 2;
    if (cluster & 1u) {
        fat[off]     = (uint8_t)((fat[off] & 0x0Fu) | ((val & 0x0Fu) << 4));
        fat[off + 1] = (uint8_t)((val >> 4) & 0xFFu);
    } else {
        fat[off]     = (uint8_t)(val & 0xFFu);
        fat[off + 1] = (uint8_t)((fat[off + 1] & 0xF0u) | ((val >> 8) & 0x0Fu));
    }
}

/* ── fat12_format ────────────────────────────────────────────────────────── */

int fat12_format(int drive, uint32_t lba_start) {
    uint8_t sec[512];
    int i;
    for (i = 0; i < 512; i++) sec[i] = 0;

    /* Boot sector / BPB */
    sec[0] = 0xEB; sec[1] = 0x58; sec[2] = 0x90; /* JMP SHORT + NOP */
    const char *oem = "MSDOS5.0";
    for (i = 0; i < 8; i++) sec[3 + i] = (uint8_t)oem[i];
    u16_le(sec + 11, 512);                       /* bytes per sector */
    sec[13] = (uint8_t)FAT12_SEC_PER_CLU;
    u16_le(sec + 14, (uint16_t)FAT12_RESERVED);
    sec[16] = (uint8_t)FAT12_FAT_COUNT;
    u16_le(sec + 17, (uint16_t)FAT12_ROOT_ENTS);
    u16_le(sec + 19, (uint16_t)FAT12_SECTORS);   /* total sectors (16-bit) */
    sec[21] = 0xF8;                               /* media: fixed disk */
    u16_le(sec + 22, (uint16_t)FAT12_FAT_SIZE);
    u16_le(sec + 24, 63);                         /* sectors per track */
    u16_le(sec + 26, 255);                        /* number of heads */
    u32_le(sec + 28, lba_start);                  /* hidden sectors = LBA offset */
    u32_le(sec + 32, 0);                          /* total_sec32 = 0 (use 16-bit) */
    sec[36] = 0x80;                               /* drive number */
    sec[38] = 0x29;                               /* extended boot sig */
    u32_le(sec + 39, 0xDEADB00Fu);               /* volume ID */
    const char *label = "MOMOS      ";
    for (i = 0; i < 11; i++) sec[43 + i] = (uint8_t)label[i];
    const char *fstype = "FAT12   ";
    for (i = 0; i < 8; i++) sec[54 + i] = (uint8_t)fstype[i];
    sec[510] = 0x55; sec[511] = 0xAA;

    if (ata_write(drive, lba_start, 1, sec) != 0) return -1;

    /* Zero sector reused below */
    for (i = 0; i < 512; i++) sec[i] = 0;

    /* FAT tables: first 3 bytes = media descriptor + reserved cluster entries.
       Packed FAT12: cluster 0 = 0xFF8, cluster 1 = 0xFFF → bytes F8 FF FF */
    uint8_t fat_init[512];
    for (i = 0; i < 512; i++) fat_init[i] = 0;
    fat_init[0] = 0xF8; fat_init[1] = 0xFF; fat_init[2] = 0xFF;

    uint32_t copy;
    for (copy = 0; copy < FAT12_FAT_COUNT; copy++) {
        uint32_t fat_lba = lba_start + FAT12_RESERVED + copy * FAT12_FAT_SIZE;
        if (ata_write(drive, fat_lba, 1, fat_init) != 0) return -1;
        uint32_t s;
        for (s = 1; s < FAT12_FAT_SIZE; s++) {
            if (ata_write(drive, fat_lba + s, 1, sec) != 0) return -1;
        }
    }

    /* Root directory: all zeros */
    uint32_t root_lba = lba_start + FAT12_RESERVED + FAT12_FAT_COUNT * FAT12_FAT_SIZE;
    uint32_t s;
    for (s = 0; s < FAT12_ROOT_SECS; s++) {
        if (ata_write(drive, root_lba + s, 1, sec) != 0) return -1;
    }

    return 0;
}

/* ── fat12_write_file ────────────────────────────────────────────────────── */

int fat12_write_file(int drive, uint32_t lba_start,
                     const char *filename,
                     const uint8_t *data, uint32_t len) {
    const uint32_t bytes_per_clus = FAT12_SEC_PER_CLU * 512u;
    uint32_t num_clus = (len + bytes_per_clus - 1) / bytes_per_clus;
    if (num_clus == 0) num_clus = 1;

    /* Read both FAT copies into one buffer (use FAT1 as authoritative) */
    uint8_t *fat = (uint8_t *)kmalloc(FAT12_FAT_SIZE * 512);
    if (!fat) return -1;

    uint32_t fat1_lba = lba_start + FAT12_RESERVED;
    uint32_t s;
    for (s = 0; s < FAT12_FAT_SIZE; s++) {
        if (ata_read(drive, fat1_lba + s, 1, fat + s * 512) != 0) {
            kfree(fat); return -1;
        }
    }

    /* Cluster list: allocate contiguous free clusters starting at 2 */
    uint16_t *clus_list = (uint16_t *)kmalloc(num_clus * sizeof(uint16_t));
    if (!clus_list) { kfree(fat); return -1; }

    uint32_t found = 0;
    uint32_t c;
    for (c = 2; c < 4084u && found < num_clus; c++) {
        if (fat12_get(fat, c) == 0) clus_list[found++] = (uint16_t)c;
    }
    if (found < num_clus) { kfree(clus_list); kfree(fat); return -1; }

    /* Build FAT chain */
    uint32_t ci;
    for (ci = 0; ci < num_clus - 1; ci++)
        fat12_set(fat, clus_list[ci], clus_list[ci + 1]);
    fat12_set(fat, clus_list[num_clus - 1], 0xFFFu); /* EOF */

    /* Write file data cluster by cluster */
    uint8_t sec[512];
    uint32_t written = 0;
    for (ci = 0; ci < num_clus; ci++) {
        uint32_t clus_lba = lba_start + FAT12_DATA_START +
                            ((uint32_t)clus_list[ci] - 2u) * FAT12_SEC_PER_CLU;
        uint32_t si;
        for (si = 0; si < FAT12_SEC_PER_CLU; si++) {
            int k;
            for (k = 0; k < 512; k++) sec[k] = 0;
            uint32_t avail = (written < len) ? (len - written) : 0u;
            uint32_t chunk = (avail > 512u) ? 512u : avail;
            for (k = 0; k < (int)chunk; k++)
                sec[k] = data[written + (uint32_t)k];
            if (ata_write(drive, clus_lba + si, 1, sec) != 0) {
                kfree(clus_list); kfree(fat); return -1;
            }
            written += chunk;
        }
    }

    /* Write both FAT copies */
    uint32_t copy;
    for (copy = 0; copy < FAT12_FAT_COUNT; copy++) {
        uint32_t fat_lba = lba_start + FAT12_RESERVED + copy * FAT12_FAT_SIZE;
        for (s = 0; s < FAT12_FAT_SIZE; s++) {
            if (ata_write(drive, fat_lba + s, 1, fat + s * 512) != 0) {
                kfree(clus_list); kfree(fat); return -1;
            }
        }
    }

    /* Read root directory, find free slot, write directory entry */
    uint32_t root_lba = lba_start + FAT12_RESERVED +
                        FAT12_FAT_COUNT * FAT12_FAT_SIZE;
    uint8_t root[FAT12_ROOT_SECS * 512];
    for (s = 0; s < FAT12_ROOT_SECS; s++)
        ata_read(drive, root_lba + s, 1, root + s * 512);

    int slot = -1;
    uint32_t i;
    for (i = 0; i < FAT12_ROOT_ENTS; i++) {
        if (root[i * 32] == 0x00u || root[i * 32] == 0xE5u) {
            slot = (int)i; break;
        }
    }
    if (slot < 0) { kfree(clus_list); kfree(fat); return -1; }

    uint8_t name8[8], ext3[3];
    parse_83(filename, name8, ext3);

    uint8_t *e = root + slot * 32;
    for (i = 0; i < 32u; i++) e[i] = 0;
    for (i = 0; i < 8u; i++)  e[i]     = name8[i];
    for (i = 0; i < 3u; i++)  e[8 + i] = ext3[i];
    e[11] = 0x20u;                          /* archive attribute */
    e[26] = (uint8_t)(clus_list[0]);
    e[27] = (uint8_t)(clus_list[0] >> 8);
    u32_le(e + 28, len);

    for (s = 0; s < FAT12_ROOT_SECS; s++)
        ata_write(drive, root_lba + s, 1, root + s * 512);

    kfree(clus_list);
    kfree(fat);
    return 0;
}

/* ── fat12_write_vfs ─────────────────────────────────────────────────────── */

int fat12_write_vfs(int drive, uint32_t lba_start, const char *filename) {
    const uint8_t *base = (const uint8_t *)vfs_get_base();
    uint32_t size       = vfs_get_size();
    return fat12_write_file(drive, lba_start, filename, base, size);
}
```

- [ ] **Step 3: Verify vfs.h exports vfs_get_base and vfs_get_size**

Run in MSYS2:
```bash
grep "vfs_get_base\|vfs_get_size" kernel/vfs/vfs.h
```
Expected: both declarations present. If not, add them to vfs.h:
```c
void    *vfs_get_base(void);
uint32_t vfs_get_size(void);
```

- [ ] **Step 4: Add fat12.o to OBJS in Makefile**

In `Makefile`, in the `OBJS` list (around line 70), after `kernel/disk/ata_pio.o` and `kernel/disk/disk.o`, add:
```makefile
       kernel/disk/fat12.o \
```

- [ ] **Step 5: Compile check**

Run in MSYS2:
```bash
make kernel.bin
```
Expected: no errors. fat12.c should compile as part of `kernel/disk/%.o` rule.

- [ ] **Step 6: Commit**

```bash
git add kernel/disk/fat12.h kernel/disk/fat12.c Makefile
git commit -m "feat: FAT12 boot partition writer for HDD installer"
```

---

## Task 4: Lua bindings — sys.fat_format, sys.fat_write, sys.fat_write_vfs, sys.disk_write_mbr2

**Files:**
- Modify: `kernel/lua/klua.c` (add four new functions + register in sys_lib[])

- [ ] **Step 1: Add #include for fat12.h in klua.c**

Near the top of `klua.c`, after the existing `#include "../disk/ata_pio.h"` line, add:
```c
#include "../disk/fat12.h"
```

- [ ] **Step 2: Add l_sys_fat_format, l_sys_fat_write, l_sys_fat_write_vfs before sys_lib[]**

Insert these four functions immediately before the `static const luaL_Reg sys_lib[]` line:

```c
/* sys.fat_format(drive, lba_start) → bool, errmsg
   Formats a FAT12 volume (8 MB) at lba_start on drive. */
static int l_sys_fat_format(lua_State *ls) {
    int      drv = (int)luaL_checkinteger(ls, 1);
    uint32_t lba = (uint32_t)luaL_checkinteger(ls, 2);
    if (fat12_format(drv, lba) != 0) {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "fat12_format failed");
        return 2;
    }
    lua_pushboolean(ls, 1); lua_pushnil(ls); return 2;
}

/* sys.fat_write(drive, lba_start, name, data) → bool, errmsg
   Writes data string as a flat file in the FAT12 root directory. */
static int l_sys_fat_write(lua_State *ls) {
    int         drv  = (int)luaL_checkinteger(ls, 1);
    uint32_t    lba  = (uint32_t)luaL_checkinteger(ls, 2);
    const char *name = luaL_checkstring(ls, 3);
    size_t      dlen;
    const char *data = luaL_checklstring(ls, 4, &dlen);
    if (fat12_write_file(drv, lba, name, (const uint8_t *)data, (uint32_t)dlen) != 0) {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "fat12_write failed");
        return 2;
    }
    lua_pushboolean(ls, 1); lua_pushnil(ls); return 2;
}

/* sys.fat_write_vfs(drive, lba_start, name) → bool, errmsg
   Writes the live in-memory initrd as a file in the FAT12 root directory. */
static int l_sys_fat_write_vfs(lua_State *ls) {
    int         drv  = (int)luaL_checkinteger(ls, 1);
    uint32_t    lba  = (uint32_t)luaL_checkinteger(ls, 2);
    const char *name = luaL_checkstring(ls, 3);
    if (fat12_write_vfs(drv, lba, name) != 0) {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "fat12_write_vfs failed");
        return 2;
    }
    lua_pushboolean(ls, 1); lua_pushnil(ls); return 2;
}

/* sys.disk_write_mbr2(drive, fat_start, fat_size, lfs_start, lfs_size) → bool, errmsg
   Writes a 2-partition MBR:
     Partition 1 (bootable): FAT12 at fat_start, size fat_size sectors
     Partition 2:            LFS  at lfs_start, size lfs_size sectors */
static int l_sys_disk_write_mbr2(lua_State *ls) {
    int      drv       = (int)luaL_checkinteger(ls, 1);
    uint32_t fat_start = (uint32_t)luaL_checkinteger(ls, 2);
    uint32_t fat_size  = (uint32_t)luaL_checkinteger(ls, 3);
    uint32_t lfs_start = (uint32_t)luaL_checkinteger(ls, 4);
    uint32_t lfs_size  = (uint32_t)luaL_checkinteger(ls, 5);

    uint8_t mbr[512];
    if (ata_read(drv, 0, 1, mbr) != 0)
        for (int i = 0; i < 446; i++) mbr[i] = 0;

    for (int i = 446; i < 510; i++) mbr[i] = 0;

    /* Partition 1: FAT12, bootable */
    uint8_t *p1 = mbr + 446;
    p1[0] = 0x80;
    p1[1] = 0xFE; p1[2] = 0xFF; p1[3] = 0xFF;
    p1[4] = 0x01; /* FAT12 */
    p1[5] = 0xFE; p1[6] = 0xFF; p1[7] = 0xFF;
    p1[8]  = (uint8_t)(fat_start);       p1[9]  = (uint8_t)(fat_start >> 8);
    p1[10] = (uint8_t)(fat_start >> 16); p1[11] = (uint8_t)(fat_start >> 24);
    p1[12] = (uint8_t)(fat_size);        p1[13] = (uint8_t)(fat_size >> 8);
    p1[14] = (uint8_t)(fat_size >> 16);  p1[15] = (uint8_t)(fat_size >> 24);

    /* Partition 2: LFS */
    uint8_t *p2 = mbr + 462;
    p2[0] = 0x00;
    p2[1] = 0xFE; p2[2] = 0xFF; p2[3] = 0xFF;
    p2[4] = 0x4C; /* momOS LFS */
    p2[5] = 0xFE; p2[6] = 0xFF; p2[7] = 0xFF;
    p2[8]  = (uint8_t)(lfs_start);       p2[9]  = (uint8_t)(lfs_start >> 8);
    p2[10] = (uint8_t)(lfs_start >> 16); p2[11] = (uint8_t)(lfs_start >> 24);
    p2[12] = (uint8_t)(lfs_size);        p2[13] = (uint8_t)(lfs_size >> 8);
    p2[14] = (uint8_t)(lfs_size >> 16);  p2[15] = (uint8_t)(lfs_size >> 24);

    mbr[510] = 0x55; mbr[511] = 0xAA;

    if (ata_write(drv, 0, 1, mbr) != 0) {
        lua_pushboolean(ls, 0); lua_pushstring(ls, "write error"); return 2;
    }
    lua_pushboolean(ls, 1); lua_pushnil(ls); return 2;
}
```

- [ ] **Step 3: Register the four functions in sys_lib[]**

In `sys_lib[]`, after the `{"disk_write_mbr", l_sys_disk_write_mbr},` entry, add:

```c
    {"disk_write_mbr2",  l_sys_disk_write_mbr2},
    {"fat_format",       l_sys_fat_format},
    {"fat_write",        l_sys_fat_write},
    {"fat_write_vfs",    l_sys_fat_write_vfs},
```

- [ ] **Step 4: Compile check**

Run in MSYS2:
```bash
make kernel.bin
```
Expected: compiles without errors.

- [ ] **Step 5: Commit**

```bash
git add kernel/lua/klua.c
git commit -m "feat: add sys.fat_format, sys.fat_write, sys.fat_write_vfs, sys.disk_write_mbr2"
```

---

## Task 5: Makefile — embedded grub-blobs + kernel.bin in initrd

**Files:**
- Modify: `Makefile` (grub-blobs target, initrd.lfs rule)
- Modify: `.gitignore`

- [ ] **Step 1: Update grub-blobs target in Makefile**

Find the `grub-blobs:` target (around line 246) and replace its body with:

```makefile
grub-blobs:
	mkdir -p initrd/sys/boot
	dd if=/usr/lib/grub/i386-pc/boot.img of=initrd/sys/boot/mbr.bin bs=446 count=1
	printf 'set timeout=0\ninsmod biosdisk\ninsmod part_msdos\ninsmod fat\nset root=(hd0,msdos1)\nmultiboot /kernel.bin\nmodule /initrd.lfs\nboot\n' \
	    > /tmp/grub-embedded.cfg
	grub-mkimage -O i386-pc \
	    --config=/tmp/grub-embedded.cfg \
	    -o initrd/sys/boot/core.img \
	    biosdisk part_msdos fat multiboot
	@echo "GRUB blobs written to initrd/sys/boot/ (embedded config, no menu)"
```

- [ ] **Step 2: Add kernel.bin copy rule and update initrd.lfs dependency**

Find the `initrd.lfs:` rule (around line 161):
```makefile
initrd.lfs: tools/mklfs $(shell find initrd -type f)
	./tools/mklfs initrd initrd.lfs
```

Replace with:
```makefile
initrd/sys/boot/kernel.bin: kernel.bin
	@mkdir -p initrd/sys/boot
	cp kernel.bin initrd/sys/boot/kernel.bin

initrd.lfs: tools/mklfs initrd/sys/boot/kernel.bin $(shell find initrd -type f)
	./tools/mklfs initrd initrd.lfs
```

- [ ] **Step 3: Add initrd/sys/boot/kernel.bin to .gitignore**

Open `.gitignore` and add alongside the other `initrd/sys/boot/` entries:
```
initrd/sys/boot/kernel.bin
```

- [ ] **Step 4: Run make grub-blobs in WSL2 and verify smaller core.img**

Run in WSL2:
```bash
cd /mnt/c/Users/mom/Documents/tools/momOS
make grub-blobs
ls -la initrd/sys/boot/core.img
```
Expected: `core.img` exists and is **smaller than the previous 105981 bytes** (target: under 70 KB). If it's still > 68 KB that's fine — double-indirect now handles it.

- [ ] **Step 5: Build initrd.lfs in MSYS2 and verify kernel.bin is included**

Run in MSYS2:
```bash
make kernel.bin
make initrd.lfs
```
Expected:
```
  + initrd/sys/boot/core.img (...bytes)
  + initrd/sys/boot/kernel.bin (...bytes)
  + initrd/sys/boot/mbr.bin (446 bytes)
...
mklfs: wrote ... blocks (...) to initrd.lfs
```
No "file too large" error.

- [ ] **Step 6: Commit**

```bash
git add Makefile .gitignore
git commit -m "feat: grub-blobs embedded config; kernel.bin copied into initrd for installer"
```

---

## Task 6: installer.lua — 7-step install sequence + QEMU end-to-end test

**Files:**
- Modify: `initrd/apps/installer.lua`

Replace the `do_install` function and update `install_step` counting from 4 steps to 7.

- [ ] **Step 1: Replace do_install() in installer.lua**

Replace the entire `do_install` function (lines 54–148) with:

```lua
local function do_install()
    local d = install_drive

    -- Step 0: announce and move to step 1
    if install_step == 0 then
        progress = "Partitioning drive " .. d.index .. "..."
        install_step = 1
        return
    end

    -- Step 1: write 2-partition MBR (FAT12 + LFS)
    if install_step == 1 then
        local disk_secs = d.size_mb * 2048
        local lfs_start = 18432
        local lfs_size  = disk_secs - lfs_start
        local ok, err = sys.disk_write_mbr2(d.index, 2048, 16384, lfs_start, lfs_size)
        if not ok then
            state = "error"; errmsg = "Partition failed: " .. (err or "?"); return
        end
        progress = "Formatting boot partition..."
        install_step = 2
        return
    end

    -- Step 2: format FAT12 at LBA 2048
    if install_step == 2 then
        local ok, err = sys.fat_format(d.index, 2048)
        if not ok then
            state = "error"; errmsg = "FAT format failed: " .. (err or "?"); return
        end
        progress = "Copying kernel..."
        install_step = 3
        return
    end

    -- Step 3: write kernel.bin to FAT partition
    if install_step == 3 then
        local kdata = fs.read("/sys/boot/kernel.bin")
        if not kdata then
            state = "error"; errmsg = "Missing /sys/boot/kernel.bin"; return
        end
        local ok, err = sys.fat_write(d.index, 2048, "kernel.bin", kdata)
        if not ok then
            state = "error"; errmsg = "kernel.bin write failed: " .. (err or "?"); return
        end
        progress = "Copying initrd..."
        install_step = 4
        return
    end

    -- Step 4: write live initrd.lfs to FAT partition
    if install_step == 4 then
        local ok, err = sys.fat_write_vfs(d.index, 2048, "initrd.lfs")
        if not ok then
            state = "error"; errmsg = "initrd.lfs write failed: " .. (err or "?"); return
        end
        progress = "Installing bootloader..."
        install_step = 5
        return
    end

    -- Step 5: write core.img to LBA 1–N
    if install_step == 5 then
        local core = fs.read("/sys/boot/core.img")
        if not core then
            state = "error"; errmsg = "Missing /sys/boot/core.img — run make grub-blobs"; return
        end
        local lba = 1
        for off = 1, #core, 512 do
            local chunk = core:sub(off, off + 511)
            local ok2, err2 = sys.disk_write_raw(d.index, lba, chunk)
            if not ok2 then
                state = "error"
                errmsg = "core.img write failed at LBA " .. lba .. ": " .. (err2 or "?")
                return
            end
            lba = lba + 1
        end
        progress = "Writing MBR boot code..."
        install_step = 6
        return
    end

    -- Step 6: write mbr.bin boot code to LBA 0 (bytes 0–445, preserves partition table)
    if install_step == 6 then
        local mbr_code = fs.read("/sys/boot/mbr.bin")
        if not mbr_code then
            state = "error"; errmsg = "Missing /sys/boot/mbr.bin — run make grub-blobs"; return
        end
        local ok, err = sys.disk_write_raw(d.index, 0, mbr_code)
        if not ok then
            state = "error"; errmsg = "MBR write failed: " .. (err or "?"); return
        end
        progress = "Saving user data to disk..."
        install_step = 7
        return
    end

    -- Step 7: persist user data to LFS partition 2
    if install_step == 7 then
        local ok, err = sys.save()
        if not ok then
            state = "error"; errmsg = "Save failed: " .. (err or "?"); return
        end
        progress = nil
        state    = "done"
        return
    end
end
```

- [ ] **Step 2: Compile and build ISO for testing**

Run in MSYS2:
```bash
make kernel.bin && make initrd.lfs
```
Run in WSL2:
```bash
make cd
```
Expected: `momos.iso` builds without errors.

- [ ] **Step 3: Create a blank disk image for QEMU install target**

Run in MSYS2 or WSL2:
```bash
dd if=/dev/zero of=hdd_test.img bs=1M count=512
```
This creates a 512 MB blank disk image.

- [ ] **Step 4: Run QEMU with both ISO and blank disk, select Install**

Run in MSYS2:
```bash
qemu-system-i386 \
    -cdrom momos.iso \
    -drive file=hdd_test.img,format=raw,if=ide,index=1 \
    -m 256 -display sdl
```

At the GRUB menu, select **"momOS Install"**. The installer launches fullscreen. Complete the install:
- Press Enter at welcome screen
- Verify it detects `hdd_test.img` as drive 1 (size ~512 MB)
- Select it and press Y to confirm
- Watch install progress through 7 steps
- Wait for "Installation complete!" screen and press Enter to reboot

- [ ] **Step 5: Boot QEMU from HDD only (no ISO)**

```bash
qemu-system-i386 \
    -drive file=hdd_test.img,format=raw,if=ide \
    -m 256 -display sdl
```

Expected: GRUB loads (no menu, `timeout=0`), momOS desktop appears within ~3 seconds.
If GRUB rescue appears: check that `core.img` was written to LBA 1+ and `mbr.bin` to LBA 0.

- [ ] **Step 6: Commit**

```bash
git add initrd/apps/installer.lua
git commit -m "feat: installer 7-step sequence — FAT12 boot partition + 2-partition layout"
```

---

## Self-Review

**Spec coverage:**
- ✅ LFS double-indirect — Tasks 1 + 2
- ✅ FAT12 format + write — Task 3
- ✅ sys.fat_format / sys.fat_write / sys.fat_write_vfs / sys.disk_write_mbr2 — Task 4
- ✅ grub-blobs embedded config, kernel.bin in initrd — Task 5
- ✅ 7-step installer sequence — Task 6
- ✅ QEMU end-to-end test — Task 6 Steps 3–5

**Type consistency:**
- `fat12_format(int drive, uint32_t lba_start)` — consistent across fat12.h, fat12.c, klua.c
- `fat12_write_file(drive, lba_start, filename, data, len)` — consistent
- `fat12_write_vfs(drive, lba_start, filename)` — consistent
- `sys.disk_write_mbr2(drive, fat_start, fat_size, lfs_start, lfs_size)` — 5 args, Lua and C match
- Disk layout: FAT at LBA 2048, size 16384 → LFS at LBA 18432. Used consistently in Task 4 (C) and Task 6 (Lua).

**No placeholders found.**
