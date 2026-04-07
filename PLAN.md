# momOS — Implementation Plan

A lightweight fantasy desktop OS inspired by Picotron and KolibriOS.
Runs entirely from RAM. Saves to HDD. Fits on a floppy.
Targets the Compaq Presario 5000 (i686, 64–256 MB RAM) and modern x86_64 machines.

---

## Identity & Constraints

| Parameter         | Value                                      |
|-------------------|--------------------------------------------|
| CPU target        | i686 (floppy/HDD) + x86_64 (CD/modern)    |
| Resolution        | 640×480, 32-color indexed palette          |
| Audio             | 4 channels (2 pulse, 1 triangle, 1 noise)  |
| RAM disk          | 8 MB (floppy), 16 MB (HDD), 32 MB (CD)    |
| Max processes     | 8 (≤128 MB RAM), 16 (>128 MB RAM)          |
| Scripting         | Lua 5.4 (stripped)                         |
| Multitasking      | Cooperative (safety preempt via PIT @60Hz) |
| Networking        | None                                       |

---

## Distribution Media

### Floppy 1 — Install Disk (1.44 MB)
- SYSLINUX bootloader
- Compressed i686 kernel (base only — no creative tools)
- Installer app (TUI: partition HDD, write base system)
- Installs: kernel, shell, terminal, file manager, empty `/home` `/apps` `/sys`

### Floppy 2 — App Disk (1.44 MB)
- Same minimal kernel as Floppy 1
- App installer payload
- Installs to existing momOS HDD partition:
  `/apps/quill`, `/apps/pixel`, `/apps/chirp`, `/apps/terrain`, `/apps/p8`, `/apps/shelf`

### CD / Modern Full Version
- Hybrid ISO: GRUB2 (UEFI + legacy BIOS)
- x86_64 kernel + i686 kernel (boot menu selects)
- All apps pre-installed
- Boot menu: Live / Install / Legacy 32-bit / Memtest

---

## Architecture

### Kernel (C11, i686-elf-gcc / x86_64-elf-gcc)
- Multiboot2 entry (GRUB) + SYSLINUX entry (floppy)
- GDT, IDT, PIT (60 Hz scheduler tick)
- Physical memory allocator (buddy allocator)
- Paging (32-bit for i686, 64-bit for x86_64)
- Kernel heap (slab + general)
- VESA VBE 2.0 framebuffer (via GRUB/SYSLINUX — no kernel-side VESA code)
- PS/2 keyboard + mouse drivers
- ATA PIO disk driver (IDE)
- AC97 audio driver (via PCI enumeration)
- PCI bus enumeration

### VFS — LFS (Luminos Filesystem)
- 512-byte blocks, flat inode table
- Single-user, no permissions, no journaling
- Kernel API: `fs_read`, `fs_write`, `fs_list`, `fs_mkdir`, `fs_delete`
- Lua API: `fs.read(path)`, `fs.write(path, data)`, `fs.list(path)`, etc.
- RAM disk = primary storage (always present)
- HDD = snapshot (`sys.save()` / `sys.load()`)

### Process Model
- Each process = Lua 5.4 VM state + 2 MB memory arena
- Callbacks: `_init()`, `_update()`, `_draw()`, `_msg(from, data)`, `_quit()`
- Round-robin scheduler, 1 tick (16 ms) per process
- PIT preempts if process exceeds tick (safety net)
- IPC: message queues, MessagePack serialization, inbox cap 64 messages

### Display
- System framebuffer owned by compositor (privileged Lua process)
- Per-window off-screen pixel buffers, blitted by compositor
- 640×480, 32-color indexed palette (editable per project)
- All rendering software (no GPU acceleration)

### Audio
- 22050 Hz, 8-bit unsigned, 4 channels
- Software mixing in kernel, output via AC97 or PC speaker fallback
- Submitted in 512-sample chunks via timer interrupt

---

## App Tiers

### Tier 1 — Compiled into kernel binary (always available)
| App          | Description                        |
|--------------|------------------------------------|
| Shell        | Desktop, PID 1, wallpaper, icons   |
| Terminal     | Lua REPL + shell built-ins         |
| File Manager | VFS tree, copy/move/delete/rename  |

### Tier 2 — Lua files in `/apps/` (installed from Floppy 2 or CD)
| App     | Description                                   |
|---------|-----------------------------------------------|
| Quill   | Lua code editor, syntax highlight, run button |
| Pixel   | Sprite/image editor, `.mpi` format            |
| Chirp   | 4-channel music tracker, `.msm` format        |
| Terrain | Tile map editor, `.mtm` format                |
| P8      | PICO-8 `.p8` cartridge player (~70% compat)   |
| Shelf   | Asset browser with thumbnails                 |

---

## File Formats

| Format | Full Name             | Description                              |
|--------|-----------------------|------------------------------------------|
| `.mpi` | momOS Pixel Image     | Header + 32-color palette + indexed data |
| `.msm` | momOS Sound Module    | 4-channel tracker data + patterns        |
| `.mtm` | momOS Tile Map        | Tile layers + object layer + properties  |
| `.lfs` | momOS FS Image        | Raw LFS disk image (for save/backup)     |

---

## Repo Structure

```
momOS/
├── Makefile                    # All build targets (floppy1, floppy2, cd, run-*)
├── README.md
├── PLAN.md                     # This file
├── CHECKLIST.md                # Phase-by-phase task checklist
├── kernel/
│   ├── boot/                   # entry.asm, multiboot2, syslinux glue
│   ├── cpu/                    # GDT, IDT, ISR stubs
│   ├── mm/                     # Physical allocator, paging, heap
│   ├── vfs/                    # LFS implementation
│   ├── proc/                   # Scheduler, process table, context switch
│   ├── ipc/                    # Message queues, MessagePack
│   ├── gfx/                    # Compositor, framebuffer, software renderer
│   ├── input/                  # Keyboard, mouse, event queue
│   ├── audio/                  # Mixer, AC97, PC speaker fallback
│   ├── disk/                   # ATA PIO, PCI enumeration
│   ├── hal/                    # HAL interface (bare metal + SDL2 hosted)
│   └── kernel.c                # main(), init sequence
├── lua/                        # Lua 5.4 vendored + stripped
├── apps/                       # Tier 1 built-in apps (compiled into kernel)
│   ├── shell/
│   ├── terminal/
│   └── files/
├── userspace/                  # Tier 2 apps (Lua, copied to /apps/ on install)
│   ├── quill/
│   ├── pixel/
│   ├── chirp/
│   ├── terrain/
│   ├── p8/
│   └── shelf/
├── installer/                  # Floppy installer + app installer Lua apps
│   ├── install.lua             # Floppy 1 installer (partitions HDD, writes base)
│   └── appinstall.lua          # Floppy 2 installer (copies /apps/ to HDD)
├── initrd/                     # Default RAM disk contents
│   ├── sys/                    # Default config
│   └── home/desktop/           # Default desktop shortcuts
├── assets/                     # Kernel-side assets (font, palette, wallpapers)
├── tools/                      # Host-side tools
│   ├── mklfs.c                 # Build .lfs image from directory
│   ├── lfs_inspect.c           # Dump/inspect .lfs image
│   └── import_png.py           # Convert PNG to .mpi
├── docs/
│   ├── api_reference.md
│   ├── lfs_format.md
│   ├── mpi_format.md
│   ├── msm_format.md
│   └── mtm_format.md
└── tests/
    ├── test_mm.c
    ├── test_vfs.c
    └── test_ipc.c
```

---

## Build Targets

```makefile
make floppy-install    # Floppy 1: OS installer image
make floppy-apps       # Floppy 2: app installer image
make cd                # Hybrid ISO (x86_64 + i686, UEFI + BIOS)
make hdd-image         # Pre-built VM disk image
make hosted            # Native binary via SDL2 (Linux/macOS/Windows)
make run               # Boot CD in QEMU
make run-floppy1       # Test Floppy 1 in QEMU
make run-floppy2       # Test Floppy 2 in QEMU (needs hdd-image)
make run-hosted        # Run SDL2 hosted build
make test              # Run kernel unit tests on host
```

---

## Phased Roadmap

### Phase 0 — Toolchain & Boot (Weeks 1–6)
Get something on screen in QEMU.

### Phase 1 — OS Primitives (Weeks 7–14)
LFS VFS + embedded Lua VM + first Lua process.

### Phase 2 — Desktop (Weeks 15–22)
Compositor, windows, shell, terminal, file manager.

### Phase 3 — Creative Tools (Weeks 23–34)
Quill, Pixel, Chirp, Terrain, P8 Player, Shelf.

### Phase 4 — Persistence & Hardware (Weeks 35–40)
ATA disk saves, SDL2 hosted mode, real hardware testing on Presario.

### Phase 4.5 — Distribution (Weeks 41–44)
Floppy installer, app installer, hybrid ISO, full install flow tested end-to-end.

### Phase 5 — v0.1 Release
Tag, publish ISO + floppy images, write launch post.
