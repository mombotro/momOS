# momOS Phase 1 fix + Phase 4 + Phase 4.5 Design

Date: 2026-04-18

---

## Scope

1. **Phase 1 fix** — IPC unit tests (`tools/test_ipc.c`)
2. **Phase 4** — block-diff saves; Presario 5000 + Acer hardware tests (no code)
3. **Phase 4.5** — installer app, GRUB blob embedding, floppy + CD build targets

`sys.export` / `sys.import` deferred — not needed for Presario milestone.

---

## 1. IPC Unit Tests

### Approach
Host binary (`tools/test_ipc.c`). Same pattern as `test_vfs.c`:
- Include `kernel/ipc/msgqueue.c` directly
- Stub `serial_puts` / `serial_putc` / `serial_hex` / `kmalloc` / `kfree`
- Link Lua 5.4 sources (already vendored in `lua/`) so `luaL_ref` / `lua_rawgeti` work

### Test cases
| # | What |
|---|------|
| 1 | `ipc_queue_open` registers queue, returns 0 |
| 2 | Duplicate `ipc_queue_open` returns 0 (idempotent) |
| 3 | `ipc_queue_close` removes queue |
| 4 | Send + recv round-trip: string value |
| 5 | Send + recv round-trip: number value |
| 6 | Send + recv round-trip: table value |
| 7 | `ipc_pending` returns correct count |
| 8 | Queue-full: 64th message accepted, 65th returns -1 |
| 9 | Send to nonexistent queue returns -1 |
| 10 | Recv from empty queue returns 0 / pushes nil |
| 11 | Close flushes queue (pending drops to 0) |

### Build integration
`make test` runs `test_vfs` then `test_ipc`. Both must exit 0.

---

## 2. Block-Diff Saves

### Problem
`sys.save()` writes entire VFS image every call — slow on large images, stresses old ATA hardware.

### Design
Replace bulk write in `l_sys_save` with per-sector comparison:

```
for each 512-byte sector i in [0, aligned/512):
    read sector i from disk → tmp_buf[512]
    if memcmp(base + i*512, tmp_buf, 512) != 0:
        ata_write sector i
flush cache (CMD_FLUSH)
```

- Temp buffer: 512 bytes on stack — no heap allocation
- First save (blank disk): reads all zeros, writes all sectors — same as before
- Subsequent saves: only changed sectors written
- Return value unchanged: `bool, errmsg`

### No VFS changes needed
`vfs_get_base()` + `vfs_get_size()` already exist.

---

## 3. Installer App

### Overview
`initrd/apps/installer.lua` — fullscreen Lua app on the live build. Draws directly to screen (no WM window). Launched from desktop or auto-launched in install boot mode.

### New C APIs (added to `klua.c` + `sys_lib`)

| API | Signature | Notes |
|-----|-----------|-------|
| `sys.disk_scan()` | `→ array of {index, size_mb, model}` | Wraps `ata_init` + IDENTIFY for drives 0–3 |
| `sys.disk_write_raw(drive, lba, data)` | `→ bool, errmsg` | Writes one sector (512 bytes) of raw `data` string via ATA PIO |
| `sys.disk_write_mbr(drive, lba_start, size_sectors)` | `→ bool, errmsg` | Writes MBR partition table: one LFS partition (type `0x4C`), bootable flag, MBR magic `0x55AA` |

### Installer flow

```
1. Welcome screen
   - Full-screen dark background, centered text
   - "momOS Installer — press Enter to begin"

2. Drive detection
   - sys.disk_scan() → list drives
   - If no drives found: error screen + reboot prompt

3. Drive select TUI
   - Arrow keys to highlight, Enter to select
   - Show: drive index, size (MB), model string
   - Confirmation prompt: "WARNING: all data on drive N will be erased. Y/N"

4. Partition
   - sys.disk_write_mbr(drive, lba_start=2048, size_sectors=partition_sectors)
   - lba_start=2048 leaves room for GRUB core.img at LBA 1–2047

5. GRUB install
   - Read /sys/boot/mbr.bin (446 bytes) → write to LBA 0 bytes 0–445
     (preserves partition table at bytes 446–511, written by step 4)
   - Read /sys/boot/core.img → write to LBA 1 onward via sys.disk_write_raw

6. Format + copy filesystem
   - sys.save() — snapshots in-memory VFS to HDD LFS partition
   - On error: show message, offer retry

7. Write grub.cfg
   - Write /sys/grub.cfg with:
     - gfxmode from `SCREEN_W` x `SCREEN_H` globals (actual running resolution)
     - kernel + initrd paths
     - timeout 3
   - sys.save() again to persist grub.cfg to disk

8. Done screen
   - "Installation complete. Remove install media and press Enter to reboot."
   - sys.reboot()
```

### GRUB blob embedding

**Build step (`make grub-blobs`, runs in WSL2):**
```bash
# Extract 446-byte MBR boot sector from GRUB
dd if=/usr/lib/grub/i386-pc/boot.img of=initrd/sys/boot/mbr.bin bs=446 count=1

# Build core.img with LFS module + biosdisk
grub-mkimage -O i386-pc -o initrd/sys/boot/core.img \
    -p "(hd0,msdos1)/boot/grub" \
    biosdisk part_msdos fat ext2 normal echo ls cat
```

`initrd/sys/boot/` is packed into `initrd.lfs` at `make` time like any other initrd directory.

---

## 4. Floppy + CD Build Targets

### Floppy 1 — install disk (`make floppy-install` → `momos-install.img`)

- Compile flag `TIER1_ONLY=1`: exclude `apps/maze3d.lua`, `apps/asteroid.lua`, `apps/bouncer.lua`, `apps/snake.lua` from initrd to shrink image
- SYSLINUX (installed via `pacman -S syslinux` in MSYS2): writes bootloader to 1.44 MB floppy image
- Image layout: SYSLINUX MBR → kernel.bin → initrd.lfs
- Floppy boots → momOS desktop with installer on taskbar / desktop icon

### Floppy 2 — app disk (`make floppy-apps` → `momos-apps.img`)

- Bare LFS image (no kernel/bootloader)
- Contains: Tier 2 apps (`maze3d.lua`, `asteroid.lua`, etc.) + any large assets
- Installer on Floppy 1 detects floppy B, reads `.lfs` image, copies contents to HDD
- `make floppy-apps` builds via `tools/mklfs` with the Tier 2 app set

### CD — hybrid ISO (`make cd` → `momos.iso`)

Extends existing `make iso`. GRUB boot menu with 3 entries:

```
set timeout=5
set default=0

menuentry "momOS Live" {
    multiboot /boot/kernel.bin
    module /boot/initrd.lfs
    boot
}

menuentry "momOS Install" {
    set boot_mode=install
    multiboot /boot/kernel.bin boot_mode=install
    module /boot/initrd.lfs
    boot
}

menuentry "Memory Test (stub)" {
    echo "Memtest not included in this build."
    sleep 3
}
```

When `boot_mode=install` is passed via multiboot cmdline, `kernel.c` reads the cmdline and auto-spawns `installer.lua` instead of `main.lua`.

**`make cd` = `make` (MSYS2) + `make grub-blobs` + `make iso` (WSL2) with updated `grub.cfg`.**

---

## 5. Hardware Testing (no code)

| Test | Machine | What to verify |
|------|---------|----------------|
| Boot from USB | Presario 5000 | GRUB appears, momOS desktop loads |
| AC97 audio | Presario 5000 | Chirp plays sound, Settings shows "AC97" |
| ATA PIO disk | Presario 5000 | `sys.disk_ready()` true in terminal, `sys.save()` / `sys.load()` round-trip |
| ACPI shutdown | Acer Aspire 1 | Settings → Shutdown powers off (not just halts) |

---

## File changes summary

| File | Change |
|------|--------|
| `tools/test_ipc.c` | New — IPC unit test binary |
| `Makefile` | Add `test_ipc` to `make test`; add `grub-blobs`, `floppy-install`, `floppy-apps`, `cd` targets; add `TIER1_ONLY` flag |
| `kernel/lua/klua.c` | `l_sys_save` → block-diff; add `l_sys_disk_scan`, `l_sys_disk_write_raw`, `l_sys_disk_write_mbr` |
| `kernel/disk/ata_pio.c` | Expose IDENTIFY model string via `ata_model(drive, buf)` |
| `kernel/disk/ata_pio.h` | Declare `ata_model` |
| `initrd/apps/installer.lua` | New — fullscreen installer app |
| `initrd/sys/boot/` | New dir — `mbr.bin`, `core.img` (generated by `make grub-blobs`) |
| `boot/grub-live.cfg` | Updated GRUB config with 3-entry menu |
| `kernel/kernel.c` | Read multiboot cmdline for `boot_mode=install` |
