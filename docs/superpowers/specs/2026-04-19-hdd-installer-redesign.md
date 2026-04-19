# momOS HDD Installer Redesign

Date: 2026-04-19

---

## Problem

Two bugs block HDD installation:

1. **LFS file size limit** — `core.img` (106 KB) exceeds the 68 KB single-indirect ceiling (8 direct + 128 indirect blocks × 512 bytes). `make initrd.lfs` fails.
2. **GRUB cannot read LFS** — after install, GRUB looks for `grub.cfg` on the LFS partition but has no LFS filesystem driver. System enters rescue mode and cannot boot.

---

## Design

### 1. LFS Double-Indirect (fixes file size limit)

The inode struct has `reserved[2]` (8 bytes) at the end. Repurpose `reserved[0]` as `indirect2` — no inode size change (still 128 bytes), no format break for existing images (zeroed = unused).

New max file size: (8 direct + 128 single-indirect + 128×128 double-indirect) × 512 = 16,520 blocks = **~8.5 MB**.

**Files:**
- `kernel/vfs/lfs_format.h` — rename `reserved[0]` → `indirect2`, update header comment
- `tools/mklfs.c` — add double-indirect write path (triggered when file exceeds single-indirect limit)
- `kernel/vfs/vfs.c` — add double-indirect read path in `vfs_read_alloc` / file read loop

---

### 2. FAT12 Boot Partition Writer

New C module `kernel/disk/fat12.c` — minimal FAT12 writer used only by the installer. Three functions:

**`fat12_format(drive, lba_start, size_sectors)`**
Writes boot sector (BPB), two FAT table copies, and an empty root directory.
Volume parameters: 4 sectors/cluster (2 KB), 16 root directory entries, FAT12 chain.

**`fat12_write(drive, lba_start, filename, data, len)`**
Writes a flat file to the root directory. Allocates contiguous clusters from the first free one. No subdirectory support needed — GRUB reads `kernel.bin` and `initrd.lfs` from root.

**`fat12_write_vfs(drive, lba_start, filename)`**
Same as `fat12_write` but sources bytes directly from the live in-memory VFS via `vfs_get_base()` / `vfs_get_size()`. Avoids loading the full initrd into Lua memory as a string.

Lua-facing APIs registered in `sys_lib[]`:
- `sys.fat_format(drive, lba_start, size_sectors) → bool, errmsg`
- `sys.fat_write(drive, lba_start, name, data) → bool, errmsg`
- `sys.fat_write_vfs(drive, lba_start, name) → bool, errmsg`

---

### 3. GRUB Core.img — Embedded Config, No Menu

`make grub-blobs` (WSL2) embeds the boot config directly in `core.img` using `grub-mkimage --config`. No `normal` module — GRUB never reads `grub.cfg` from disk. Drops `echo`, `ls`, `cat`, `configfile` modules.

```bash
printf 'set timeout=0\ninsmod biosdisk\ninsmod part_msdos\ninsmod fat\nset root=(hd0,msdos1)\nmultiboot /kernel.bin\nmodule /initrd.lfs\nboot\n' \
    > /tmp/grub-embedded.cfg

grub-mkimage -O i386-pc \
    --config=/tmp/grub-embedded.cfg \
    -o initrd/sys/boot/core.img \
    biosdisk part_msdos fat multiboot
```

Estimated core.img size without `normal`: 55–65 KB. Fits within the new 8.5 MB LFS limit.

`kernel.bin` is copied into the initrd at `initrd/sys/boot/kernel.bin` at build time so the installer can read it via `fs.read`. This file is gitignored (generated artifact).

---

### 4. Disk Layout After Install

```
LBA 0          MBR boot code (boot.img, 446 bytes) + 2-partition table
LBA 1–2047     GRUB core.img (embedded config, boots directly into momOS)
LBA 2048       Partition 1: FAT12, 8 MB (16,384 sectors)
                 /kernel.bin
                 /initrd.lfs
LBA 18432      Partition 2: LFS, remainder of disk
                 (sys.save / sys.load user data)
```

New C API `sys.disk_write_mbr2(drive, fat_start, fat_size, lfs_start, lfs_size)` writes the 2-partition MBR. Old `sys.disk_write_mbr` kept for compatibility.

---

### 5. Installer Flow (installer.lua — 7 steps)

```
Step 0  Partition disk
        -- disk_size_sectors from sys.disk_scan() size_mb field: size_mb * 2048
        local disk_secs = drive_entry.size_mb * 2048
        sys.disk_write_mbr2(drive, 2048, 16384, 18432, disk_secs - 18432)

Step 1  Format FAT12 partition
        sys.fat_format(drive, 2048, 16384)

Step 2  Write kernel.bin to FAT
        sys.fat_write(drive, 2048, "kernel.bin", fs.read("/sys/boot/kernel.bin"))

Step 3  Write initrd.lfs to FAT
        sys.fat_write_vfs(drive, 2048, "initrd.lfs")

Step 4  Write GRUB core.img to LBA 1–N
        chunk-by-chunk via sys.disk_write_raw (existing logic)

Step 5  Write MBR boot code to LBA 0 bytes 0–445
        sys.disk_write_raw(drive, 0, fs.read("/sys/boot/mbr.bin"))

Step 6  Persist user data to LFS partition 2
        sys.save()
```

Error handling: each step checks return value, transitions to error state on failure. Error state offers retry (R) or reboot (Q), same as current installer.

Done screen: "Installation complete. Remove install media and press Enter to reboot." → `sys.reboot()`.

---

## File Changes

| File | Change |
|------|--------|
| `kernel/vfs/lfs_format.h` | `reserved[0]` → `indirect2`, update max-file comment |
| `tools/mklfs.c` | Double-indirect write path |
| `kernel/vfs/vfs.c` | Double-indirect read path |
| `kernel/disk/fat12.c` | New — FAT12 format + write |
| `kernel/disk/fat12.h` | New — declarations |
| `kernel/lua/klua.c` | Add `sys.fat_format`, `sys.fat_write`, `sys.fat_write_vfs`, `sys.disk_write_mbr2` |
| `Makefile` | Update `grub-blobs` target; copy `kernel.bin` → `initrd/sys/boot/kernel.bin` before `initrd.lfs` build |
| `initrd/apps/installer.lua` | Replace install steps with 7-step sequence above |
| `.gitignore` | Add `initrd/sys/boot/kernel.bin` |

---

## Testing Plan

1. `make grub-blobs` (WSL2) — confirm new core.img builds and is < 8.5 MB
2. `make initrd.lfs` (MSYS2) — confirm build succeeds with core.img and kernel.bin inside
3. QEMU end-to-end install test:
   - `make run` with blank `disk.img` → installer launches
   - Complete install flow, reboot
   - QEMU boots from `disk.img` directly (remove initrd from QEMU args) → momOS desktop loads
4. Hardware: Acer Aspire 1, then Presario 5000
