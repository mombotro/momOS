# momOS HDD Installation Guide

---

## Part 1 — End User: Installing momOS to a Hard Drive

### What you need

- A PC with an i686 (32-bit x86) or compatible CPU
- At least 512 MB RAM
- A hard drive with at least 256 MB free (the installer erases the whole disk)
- The `momos.iso` file burned to a CD-R, or written to a USB drive with a tool like Rufus
- A keyboard

### Disk layout after install

```
LBA 0          MBR boot code (GRUB first stage)
LBA 1–2047     GRUB core.img (boots directly into momOS, no menu)
LBA 2048       Partition 1 — FAT12, 8 MB
                 /kernel.bin   (momOS kernel)
                 /initrd.lfs   (momOS filesystem image)
LBA 18432      Partition 2 — LFS (momOS native filesystem)
                 (user data, settings — populated on first boot)
```

### Step-by-step install

1. **Boot from the install media.**  
   Insert the CD or USB, set your BIOS to boot from it, and power on.
   The GRUB menu appears with two options: "momOS Live" and "momOS Install".

2. **Select "momOS Install" and press Enter.**  
   The installer launches fullscreen. You will see a dark screen with a blue header bar reading "momOS Installer".

3. **Press Enter at the welcome screen.**  
   Text appears: "Welcome to momOS — Press ENTER to begin."

4. **Select your target hard drive.**  
   Use the UP/DOWN arrow keys to highlight the drive you want to install to.  
   The drive's size and model are shown. **All data on that drive will be erased.**

5. **Confirm with Y.**  
   A warning screen appears. Press **Y** to begin, or **N** to go back.

6. **Wait for installation to complete.**  
   The installer runs 6 steps automatically:
   - Partitioning the drive
   - Formatting the boot partition (FAT12)
   - Copying the kernel
   - Copying the filesystem image
   - Installing the bootloader (GRUB)
   - Writing the MBR boot code

7. **Reboot.**  
   When "Installation complete!" appears, remove the install media and press Enter.
   The system reboots directly into momOS from the hard drive — no menu, no delay.

### If something goes wrong

- **Installation failed: [message]** — Press **R** to retry the install from the beginning, or **Q** to reboot and try again.
- **No ATA drives detected** — The installer only works on real ATA/IDE hardware. SATA drives in AHCI mode are not supported; switch your BIOS to IDE/legacy mode.
- **After install: GRUB rescue prompt** — The bootloader didn't write correctly. Re-run the installer.
- **After install: black screen** — The kernel booted but can't find a video mode. Try a different monitor or cable.

---

## Part 2 — Developer: Building momOS and the Install Media

momOS uses two separate toolchain environments:

| Environment | What it does |
|-------------|-------------|
| **MSYS2 UCRT64** | Compiles kernel, tools, and packages the initrd (LFS image) |
| **WSL2 (Ubuntu)** | Builds the GRUB boot blobs and the ISO image |

### Prerequisites

**MSYS2 UCRT64:**
```
pacman -S make mingw-w64-ucrt-x86_64-gcc
```
Also requires a pre-built i686-elf cross-compiler at `C:\i686-elf-tools\` (see README).

**WSL2:**
```
sudo apt install grub-pc-bin grub-common xorriso
```

---

### Full build sequence

#### 1. Build the kernel (MSYS2)

```bash
make kernel.bin
```

This compiles all C sources and links `kernel.bin` — the bare-metal i686 ELF kernel.

#### 2. Extract GRUB boot blobs (WSL2)

```bash
make grub-blobs
```

This runs in WSL2 because GRUB tools are Linux-only. It produces three files in `initrd/sys/boot/`:

| File | What it is |
|------|-----------|
| `mbr.bin` | 446 bytes of GRUB first-stage boot code (goes to LBA 0) |
| `core.img` | GRUB second stage with an embedded boot config (goes to LBA 1+) |

The embedded config in `core.img` is:
```
set timeout=0
insmod biosdisk
insmod part_msdos
insmod fat
set root=(hd0,msdos1)
multiboot /kernel.bin
module /initrd.lfs
boot
```

No `grub.cfg` file is needed on disk — everything is baked into `core.img`.

> **Note:** `core.img` is typically 100–150 KB. The LFS double-indirect support (added in this version) allows it to be stored in `initrd.lfs` even though it exceeds the old 68 KB single-indirect limit.

#### 3. Build the initrd (MSYS2)

```bash
make initrd.lfs
```

This copies `kernel.bin` into `initrd/sys/boot/kernel.bin` (for the installer to read at install time), then packs the entire `initrd/` directory into `initrd.lfs` using the custom LFS tool.

The initrd contains:
- All Lua apps (`initrd/apps/`)
- System scripts (`initrd/sys/`)
- GRUB blobs (`initrd/sys/boot/`)
- A copy of `kernel.bin` (`initrd/sys/boot/kernel.bin`) — used by the installer

> `initrd/sys/boot/kernel.bin` is gitignored (generated artifact).

#### 4. Build the ISO (WSL2)

```bash
make cd
```

This runs `grub-mkrescue` to produce `momos.iso` — a bootable hybrid ISO with a GRUB menu offering "momOS Live" and "momOS Install".

---

### Testing with QEMU

#### Install test

Create a blank disk image (do this once):
```bash
dd if=/dev/zero of=hdd_test.img bs=1M count=512
```

Boot from ISO, install to blank disk:
```bash
qemu-system-i386 -boot d -cdrom momos.iso -drive file=hdd_test.img,format=raw,if=ide -m 256 -display sdl
```

At the GRUB menu, select **momOS Install**. Follow the on-screen steps. When complete, press Enter to reboot.

#### HDD boot test

```bash
qemu-system-i386 -drive file=hdd_test.img,format=raw,if=ide -m 256 -display sdl
```

Expected: GRUB loads silently (timeout=0), momOS desktop appears within a few seconds.

> If you get "not bootable disk": the install didn't complete. Re-run the install test with a fresh `hdd_test.img`.

---

### What the installer does (technical detail)

The installer (`initrd/apps/installer.lua`) runs 6 steps:

| Step | Action | API |
|------|--------|-----|
| 1 | Write 2-partition MBR | `sys.disk_write_mbr2(drive, 2048, 16384, 18432, lfs_size)` |
| 2 | Format FAT12 partition at LBA 2048 | `sys.fat_format(drive, 2048)` |
| 3 | Write `kernel.bin` to FAT12 root | `sys.fat_write(drive, 2048, "kernel.bin", data)` |
| 4 | Write `initrd.lfs` to FAT12 root | `sys.fat_write_vfs(drive, 2048, "initrd.lfs")` |
| 5 | Write `core.img` to LBA 1–N | `sys.disk_write_raw` loop |
| 6 | Write `mbr.bin` to LBA 0 (read-modify-write, preserves partition table) | `sys.disk_write_raw(drive, 0, mbr_code)` |

Step 6 uses read-modify-write so the 446-byte boot code patches only bytes 0–445 of sector 0, leaving the partition table at bytes 446–509 and the 0x55AA signature at 510–511 intact.

The LFS partition (partition 2, type 0x4C) starts empty. On first boot from the HDD, `disk_init()` finds the partition, and `sys.save()` initialises it with the in-memory filesystem state.

---

### Commit checklist for a release build

```bash
# MSYS2
make kernel.bin

# WSL2
make grub-blobs

# MSYS2
make initrd.lfs

# WSL2
make cd

# Test
dd if=/dev/zero of=hdd_test.img bs=1M count=512
qemu-system-i386 -boot d -cdrom momos.iso -drive file=hdd_test.img,format=raw,if=ide -m 256 -display sdl
# ... complete install ...
qemu-system-i386 -drive file=hdd_test.img,format=raw,if=ide -m 256 -display sdl
# ... confirm desktop loads ...
```
