# momOS — Build Checklist

---

## Phase 0 — Toolchain & Boot

### Toolchain Setup
- [x] Install/build i686-elf-gcc cross-compiler (prebuilt)
- [x] Install NASM, GRUB2, xorriso, QEMU
- [x] Write bootstrap script (`setup.sh` + `tools/setup-wsl.sh`)
- [x] Write Makefile with `make run` target

### Boot (GRUB2 / Multiboot1)
- [x] Write GRUB2 config (single boot entry, gfxmode fallback list)
- [x] Hybrid ISO build via xorriso (`make iso`)
- [x] `make run` boots in QEMU

### Kernel Entry
- [x] Write `entry.asm` (Multiboot1 header, stack setup, jump to C)
- [x] Write `kernel/cpu/gdt.c` (GDT with code + data segments)
- [x] Write `kernel/cpu/idt.c` (IDT, ISR stubs for exceptions 0–31)
- [x] Serial debug output (COM1)
- [x] Multiboot1 info parsing (memory map, framebuffer, modules)

### Memory
- [x] Physical memory map from Multiboot1 mmap
- [x] Write `kernel/mm/phys.c` (bitmap allocator)
- [x] Write `kernel/mm/paging.c` (PSE 4 MB identity map 0–64 MB + framebuffer)
- [x] Write `kernel/mm/heap.c` (free-list heap backed by phys_alloc)

### Display
- [x] Accept VESA framebuffer pointer from GRUB
- [x] Write `kernel/gfx/framebuffer.c`
- [x] Confirm 640×480 and 1024×600 modes work

### Timer & RTC
- [x] Write `kernel/cpu/pit.c` (PIT at 60 Hz, IRQ0 handler)
- [x] `sys.time()` — reads CMOS RTC (year/month/day/hour/min/sec)

### ACPI
- [x] Write `kernel/cpu/acpi.c` — RSDP scan, RSDT walk, FADT parse, DSDT _S5_ scan
- [x] `acpi_shutdown()` — writes SLP_TYP+SLP_EN to PM1a_CNT (with ACPI OS handoff)
- [x] `acpi_reboot()` — 8042 reset line + triple fault fallback

**Phase 0 milestone: `make run` boots QEMU, shows desktop at 60 FPS.**

> **2026-04-07**: Kernel boots in QEMU via Multiboot1. VESA framebuffer confirmed.
> Toolchain: i686-elf-gcc (prebuilt) + NASM + MSYS2 make + QEMU on Windows.

---

## Phase 1 — OS Primitives

### LFS Filesystem
- [x] Write LFS format spec (`docs/lfs_format.md`)
- [x] Write `tools/mklfs.c` (host tool: directory → .lfs image)
- [x] Write `tools/lfs_inspect.c` (host tool: dump .lfs contents)
- [x] Write `kernel/vfs/lfs.c` (kernel-side LFS driver)
- [x] Write `kernel/vfs/vfs.c` (VFS layer over LFS)
- [x] Mount initrd LFS image at boot
- [x] VFS unit tests pass (`make test`) — `tools/test_vfs.c`, 13 tests

### Lua VM
- [x] Vendor Lua 5.4.7 source in `lua/`
- [x] Strip: remove `io`, `os`, `package`, `debug`, `require`
- [x] Compile Lua as static library into kernel
- [x] Lua allocator redirects to kernel heap
- [x] `gfx.pset`, `gfx.cls`, `gfx.rect`, `gfx.line`, `gfx.print`

### Lua API — Minimal Set
- [x] `gfx.pset`, `gfx.pget`, `gfx.cls`, `gfx.rect`, `gfx.line`, `gfx.print`
- [x] `fs.read`, `fs.write`, `fs.list`, `fs.mkdir`, `fs.delete`
- [x] `input.getchar()`, `input.key_down(key)`
- [x] `mouse.x()`, `mouse.y()`, `mouse.btn(n)`
- [x] `sys.ticks()`, `sys.mem()`, `sys.spawn()`, `sys.kill()`, `sys.ps()`
- [x] `sys.time()` — hardware RTC
- [x] `sys.audio_info()` — reports AC97 / HDA / PC speaker
- [x] `sys.shutdown()` / `sys.reboot()` — ACPI + fallbacks

### Process Model
- [x] Write `kernel/proc/process.c`
- [x] Write `kernel/proc/scheduler.c` (Lua debug hook preemption)
- [x] `_update()` / `_draw()` callback convention
- [x] Spawn process from VFS path (`launch(path)`)
- [x] Run multiple Lua apps simultaneously

### IPC
- [x] Write `kernel/ipc/msgqueue.c` (per-process inbox, cap 64 messages)
- [x] `ipc.send(name, data)` and `_msg(from, data)` callback
- [ ] IPC unit tests

### Input
- [x] Write `kernel/cpu/keyboard.c` (PS/2 keyboard, scancode → keycode)
- [x] Write `kernel/cpu/mouse.c` (PS/2 mouse, delta x/y, buttons)
- [x] Global input event queue, routed to focused process

**Phase 1 milestone: Write a Lua file, put it in initrd, it runs as a process.**

---

## Phase 2 — Desktop

### Compositor
- [x] Write `kernel/wm/wm.c` (owns framebuffer, composites windows)
- [x] Per-window off-screen pixel buffers
- [x] Dirty-region tracking + blit to framebuffer
- [x] `wm.open(title, x, y, w, h)` from Lua
- [x] Drag, z-ordering, close button, minimize/maximize

### Shell / Desktop (Tier 1 app)
- [x] Shell is PID 1 (`sys/main.lua`)
- [x] Wallpaper (solid color, user-configurable via Settings)
- [x] Desktop icons from `/home/desktop/`
- [x] Double-click icon → spawn process
- [x] Right-click context menu (new folder, terminal, files, settings, restart, shut down)
- [x] Taskbar: RTC-backed clock (12h/24h), running app buttons, home button
- [x] Quake-style dropdown terminal
- [x] Error badge in taskbar

### Terminal (Tier 1 app)
- [x] Terminal window with scrollback buffer
- [x] Lua REPL (`=expr`)
- [x] Built-in commands: `ls`, `cat`, `cd`, `run`, `write`, `mkdir`, `rm`, `clear`, `ps`, `kill`, `help`
- [x] Command history (up/down arrow)

### File Manager (Tier 1 app)
- [x] VFS tree navigation, icon + list view
- [x] Copy, cut, paste, delete, rename
- [x] Open file by extension
- [x] Edit in Quill

### Settings (Tier 1 app)
- [x] Clock: 12h/24h format, UTC offset, manual date/time entry (for no-internet systems)
- [x] Display: wallpaper color picker
- [x] Theme: 5 presets (Dark Navy, Green Terminal, Amber Terminal, Light, Deep Purple)
- [x] Audio: backend info, test tone
- [x] System: memory, resolution, audio hw, disk, RTC date
- [x] Auto-saves to `/sys/settings.lua`, loads on boot

**Phase 2 milestone: Boot to desktop, open terminal, write and run a Lua script.**

---

## Phase 3 — Creative Tools

### Quill — Code Editor
- [x] Text buffer, Lua syntax highlighting, line numbers
- [x] Tab-complete for momOS API (~60 entries)
- [x] Run current file (`:r`), inline error display
- [x] File tabs (up to 8), save/save-as (`:w`)
- [x] Help file (`:help`)

### Pixel — Sprite Editor
- [x] Canvas sizes 8×8 to 128×128 (`:n WxH`)
- [x] Tools: pencil, eraser, fill, line, rect, circle, select/move, eyedropper
- [x] 4 layers, 16 animation frames, onion skinning
- [x] Palette editor (HSV sliders, right-click cell)
- [x] Save/load `.mpi`, help (`?`)
- [x] `tools/import_png.py` (PNG → .mpi, Floyd-Steinberg dithering)
- [x] Wider toolbar with labeled tool buttons, larger palette cells, grid background

### Chirp — Music Tracker
- [x] 4-channel software mixer (22050 Hz, 8-bit, `kernel/audio/mixer.c`)
- [x] AC97 driver (`kernel/audio/ac97.c`) — auto-detected via PCI
- [x] Intel HDA driver (`kernel/audio/hda.c`) — fallback after AC97
- [x] PC speaker fallback (`kernel/audio/pcspeaker.c`)
- [x] Tracker UI: pattern grid, 4 channels, note/inst/vol/fx columns
- [x] 64 patterns × 32 rows, 16 instrument presets, 8 effects
- [x] Real-time playback (space), playing row highlighted + auto-scroll
- [x] Note preview auto-stops (no stuck sound)
- [x] Save/load `.msm`

### Terrain — Map Editor
- [x] Tile grid up to 256×256, 4 tile layers + 1 object layer
- [x] Import sprite sheet from `.mpi`
- [x] Object properties key-value pairs
- [x] Save/load `.mtm`

### Shelf — Asset Browser
- [x] Grid view, `.mpi` thumbnails, `.msm` play button
- [x] Double-click → open in associated editor
- [x] Directory navigation

**Phase 3 milestone: Make a complete tiny game using only momOS tools.**

---

## Phase 4 — Persistence & Hardware

### Disk Driver
- [x] Write `kernel/disk/ata_pio.c` (ATA PIO, LBA28)
- [x] Detect Luminos LFS partition (type 0x4C in MBR)
- [x] Mount HDD LFS partition at boot (overlay on initrd)

### Save / Load
- [x] `sys.save()` — snapshot RAM disk to HDD
- [x] `sys.load()` — reload from HDD
- [ ] Block-diff: only write changed LFS blocks
- [ ] `sys.export` / `sys.import` — host filesystem bridge (hosted mode)

### SDL2 Hosted Mode
- [ ] Write `kernel/hal/hosted/` SDL2 HAL (display, input, audio, disk)
- [ ] `make hosted` builds native binary
- [ ] Disk image: `~/.momos/disk.img`
- [ ] Test on Linux, macOS, Windows

### Real Hardware Testing
- [x] Boot USB on Acer Aspire 1 — VESA framebuffer, keyboard, mouse
- [x] VESA 1024×600×32 on Acer (GRUB gfxmode)
- [x] HDA audio works on Acer (Intel HDA driver)
- [ ] ACPI shutdown on Acer (OS handoff implemented, needs hardware test)
- [ ] Boot on Presario 5000 — AC97 audio + PATA disk
- [ ] Confirm AC97 audio (Presario)
- [ ] Confirm ATA PIO disk (Presario)

**Phase 4 milestone: Full system on Presario 5000. Save/load works. SDL2 hosted build works.**

---

## Phase 4.5 — Distribution

### Installer
- [ ] Write `installer/install.lua`:
  - [ ] Detect IDE drives (ATA PIO)
  - [ ] TUI: show drives, ask user to select
  - [ ] Write MBR + GRUB2 to HDD
  - [ ] Create LFS partition
  - [ ] Write base system to HDD
  - [ ] Write `grub.cfg` using preferred resolution from `/sys/settings.lua`
  - [ ] Confirm bootable
- [ ] Test install flow in QEMU end-to-end

### Floppy 1 — Install Disk
- [ ] Floppy 1 kernel build (i686, Tier 1 apps only)
- [ ] SYSLINUX config for 1.44 MB image
- [ ] `make floppy-install` produces image
- [ ] Test in QEMU

### Floppy 2 — App Disk
- [ ] Copy Tier 2 apps from floppy to HDD partition
- [ ] `make floppy-apps` produces image
- [ ] Test: install Floppy 1 → Floppy 2 → reboot to full system

### CD — Hybrid ISO
- [ ] GRUB2 boot menu (Live / Install / Memtest)
- [ ] CD-based installer (GUI version)
- [ ] `make cd` produces bootable hybrid ISO
- [ ] Test UEFI and legacy BIOS in QEMU, test on real hardware

**Phase 4.5 milestone: Clean install from floppy or CD onto real hardware.**

---

## Phase 5 — v0.1 Release

- [ ] Write `README.md`
- [ ] Write `docs/api_reference.md` (complete Lua API)
- [ ] Write `CONTRIBUTING.md`
- [ ] Record demo video
- [ ] Build release artifacts: `momos-install.img`, `momos-apps.img`, `momos.iso`
- [ ] Publish on GitHub, write launch post, tag v0.1

---

## Ongoing / Backlog
- [ ] Settings: resolution selector (saves to `/sys/settings.lua`; installer writes into `grub.cfg` — reboot required, HDD only)
- [ ] AHCI disk driver (faster than ATA PIO)
- [ ] Chirp: MIDI import, more effects
- [ ] Additional built-in wallpapers
- [ ] Accessibility: larger font option
- [ ] Web build (Emscripten → WASM)
- [ ] App sharing (bundle + share `.lfs` packages)
