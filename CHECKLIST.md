# momOS — Build Checklist

---

## Phase 0 — Toolchain & Boot (Weeks 1–6)

### Toolchain Setup
- [ ] Install/build i686-elf-gcc cross-compiler (via crosstool-NG or prebuilt)
- [ ] Install/build x86_64-elf-gcc cross-compiler
- [ ] Install NASM, SYSLINUX, GRUB2, xorriso, QEMU
- [ ] Write bootstrap script that sets up the entire toolchain from scratch
- [ ] Write initial Makefile with `make run` target

### Floppy Boot Path (SYSLINUX)
- [ ] Write SYSLINUX config for 1.44 MB floppy image
- [ ] Write floppy image assembly script in Makefile
- [ ] Confirm `make run-floppy1` boots in QEMU

### CD Boot Path (GRUB2)
- [ ] Write GRUB2 config with i686 + x86_64 boot menu entries
- [ ] Hybrid ISO build (UEFI + legacy BIOS via xorriso)
- [ ] Confirm `make run` boots in QEMU

### Kernel Entry
- [ ] Write `entry.asm` (Multiboot2 header, stack setup, jump to C)
- [ ] Write SYSLINUX entry glue (flat binary entry point)
- [ ] Write `kernel/cpu/gdt.c` (GDT with code + data segments)
- [ ] Write `kernel/cpu/idt.c` (IDT, ISR stubs for exceptions 0–31)
- [ ] Serial debug output (COM1) for early logging
- [ ] Multiboot2 info parsing (memory map, framebuffer pointer)

### Memory
- [ ] Physical memory map from Multiboot2
- [ ] Write `kernel/mm/phys.c` (buddy allocator for physical frames)
- [ ] Write `kernel/mm/paging.c` (32-bit page tables for i686)
- [ ] Write `kernel/mm/heap.c` (kernel slab + general heap)

### Display
- [ ] Accept VESA framebuffer pointer from GRUB/SYSLINUX
- [ ] Write `kernel/gfx/framebuffer.c` (write pixels to linear framebuffer)
- [ ] Draw a colored rectangle on screen
- [ ] Confirm 640×480 mode works in QEMU

### Timer
- [ ] Write `kernel/cpu/pit.c` (PIT at 60 Hz, IRQ0 handler)
- [ ] Tick counter increments in interrupt handler

**Phase 0 milestone: `make run` boots QEMU, shows a bouncing colored square at 60 FPS. Serial console shows memory map.**

> **2026-04-07**: Kernel boots in QEMU via Multiboot1. VGA text mode confirmed working.
> Toolchain: i686-elf-gcc (prebuilt) + NASM + MSYS2 make + QEMU on Windows.

---

## Phase 1 — OS Primitives (Weeks 7–14)

### LFS Filesystem
- [ ] Write LFS format spec (`docs/lfs_format.md`)
- [ ] Write `tools/mklfs.c` (host tool: directory → .lfs image)
- [ ] Write `tools/lfs_inspect.c` (host tool: dump .lfs contents)
- [ ] Write `kernel/vfs/lfs.c` (kernel-side LFS driver)
- [ ] Write `kernel/vfs/vfs.c` (VFS layer over LFS)
- [ ] Mount initrd LFS image at boot
- [ ] VFS unit tests pass (`make test`)

### Lua VM
- [ ] Vendor Lua 5.4 source in `lua/`
- [ ] Strip: remove `io`, `os`, `package`, `debug`, `require`
- [ ] Compile Lua as static library into kernel
- [ ] Lua allocator redirects to process memory arena
- [ ] Spawn a single Lua state, run a hardcoded "hello world" script
- [ ] `gfx.pset(x, y, color)` draws a pixel on screen
- [ ] `gfx.cls(color)` clears screen

### Lua API — Minimal Set
- [ ] `gfx.pset`, `gfx.pget`, `gfx.cls`, `gfx.rect`, `gfx.line`, `gfx.print`
- [ ] `fs.read(path)`, `fs.write(path, data)`, `fs.list(path)`, `fs.mkdir`, `fs.delete`
- [ ] `input.key_pressed(key)`, `input.key_down(key)`
- [ ] `sys.spawn(path)`, `sys.kill(pid)`, `sys.ticks()`

### Process Model
- [ ] Write `kernel/proc/process.c` (process struct, arena allocation)
- [ ] Write `kernel/proc/scheduler.c` (round-robin, 1 tick per process)
- [ ] `_init()` / `_update()` / `_draw()` callback convention
- [ ] PIT preempt: suspend process if it exceeds its tick
- [ ] Spawn process from a file path in VFS
- [ ] Run two Lua processes simultaneously

### IPC
- [ ] Write `kernel/ipc/msgqueue.c` (per-process inbox, cap 64 messages)
- [ ] MessagePack serializer for Lua values
- [ ] `ipc.send(pid, data)` and `_msg(from, data)` callback
- [ ] IPC unit tests pass

### Input
- [ ] Write `kernel/input/keyboard.c` (PS/2 keyboard, scancode → keycode)
- [ ] Write `kernel/input/mouse.c` (PS/2 mouse, delta x/y, buttons)
- [ ] Global input event queue, routed to focused process

**Phase 1 milestone: Write a Lua file, put it in initrd, it runs as a process. Two demo processes exchange messages.**

---

## Phase 2 — Desktop (Weeks 15–22)

### Compositor
- [ ] Write `kernel/gfx/compositor.c` (privileged Lua process, owns framebuffer)
- [ ] Per-window off-screen pixel buffers
- [ ] Dirty-region tracking + blit to system framebuffer
- [ ] Window creation from Lua: `gfx.new_window({title, width, height})`
- [ ] Drag windows by title bar
- [ ] Z-ordering (click to bring to front)
- [ ] Close button

### Shell / Desktop (Tier 1 app)
- [ ] Shell is PID 1, first spawned process
- [ ] Render wallpaper (solid color or built-in pixel art)
- [ ] Desktop icons from `/home/desktop/`
- [ ] Double-click icon → spawn process
- [ ] Right-click context menu
- [ ] Taskbar: clock, running app icons, home button

### Terminal (Tier 1 app)
- [ ] Terminal window with scrollback buffer
- [ ] Lua REPL (evaluate expressions, print results)
- [ ] Built-in shell commands: `ls`, `cat`, `run`, `kill`, `ps`, `save`, `clear`
- [ ] Command history (up arrow)

### File Manager (Tier 1 app)
- [ ] VFS tree navigation
- [ ] Icon view + list view toggle
- [ ] Copy, move, delete, rename
- [ ] Open file with associated app (by extension)
- [ ] Placeholder icons for unknown file types

**Phase 2 milestone: Boot to desktop, open terminal, write a Lua script, save it, run it. Feels like an OS.**

---

## Phase 3 — Creative Tools (Weeks 23–34)

### Quill — Code Editor
- [ ] Text buffer with line/column tracking
- [ ] Lua syntax highlighting (keywords, strings, comments)
- [ ] Line numbers
- [ ] Tab-complete for momOS API functions (static list)
- [ ] Run button → spawns current file as new process
- [ ] Inline error display (Lua errors highlight offending line)
- [ ] File tabs (up to 8 open files)
- [ ] Save / Save As

### Pixel — Sprite Editor
- [ ] Write `.mpi` format spec (`docs/mpi_format.md`)
- [ ] Canvas sizes: 8×8 to 128×128
- [ ] Tools: pencil, fill, line, rect, circle, eyedropper, select/move
- [ ] 4 layers
- [ ] 16 animation frames + onion skinning
- [ ] Palette editor (edit the 32 colors, HSV picker)
- [ ] Save/load `.mpi`
- [ ] `tools/import_png.py` (PNG → .mpi)

### Chirp — Music Tracker
- [ ] Write `.msm` format spec (`docs/msm_format.md`)
- [ ] Write `kernel/audio/mixer.c` (4-channel software mixer, 22050 Hz, 8-bit)
- [ ] Write `kernel/audio/ac97.c` (AC97 via PCI)
- [ ] PC speaker fallback driver
- [ ] Tracker UI: pattern grid, channel rows, note/instrument/volume/effect columns
- [ ] 64 patterns × 32 rows
- [ ] 8 effects: vibrato, arpeggio, slide up/down, delay + 4 more
- [ ] 16 instrument presets (waveform-based)
- [ ] Real-time playback during editing
- [ ] Save/load `.msm`

### Terrain — Map Editor
- [ ] Write `.mtm` format spec (`docs/mtm_format.md`)
- [ ] Import sprite sheet from `.mpi` (8×8 or 16×16 tiles)
- [ ] Tile grid up to 256×256
- [ ] 4 tile layers + 1 object layer
- [ ] Object properties (key-value pairs)
- [ ] Save/load `.mtm`

### P8 — PICO-8 Player
- [ ] Parse `.p8` format (sections: `__lua__`, `__gfx__`, `__map__`, `__sfx__`, `__music__`)
- [ ] Load sprite sheet (128×128, 4bpp) + translate 16-color PICO-8 palette
- [ ] Load map (128×64)
- [ ] Load SFX + music patterns
- [ ] Implement PICO-8 API shim over momOS gfx/input/audio:
  - [ ] `pset`, `pget`, `cls`, `camera`, `color`
  - [ ] `spr`, `sspr`, `map`, `mget`, `mset`, `fget`, `fset`
  - [ ] `btn`, `btnp`
  - [ ] `sfx`, `music`
  - [ ] `rnd`, `flr`, `ceil`, `abs`, `max`, `min`, `mid`, `sqrt`, `cos`, `sin`, `atan2`
  - [ ] `peek`, `poke` (stub — return 0, warn)
  - [ ] `tostr`, `tonum`, `sub`, `print` (PICO-8 flavors)
- [ ] 128×128 viewport scaled/letterboxed on 640×480
- [ ] Run cartridge, handle errors gracefully

### Shelf — Asset Browser
- [ ] Grid view of all files in current directory
- [ ] Thumbnail preview: `.mpi` → scaled sprite, `.msm` → waveform icon, `.lua` → code icon
- [ ] Play button on `.msm` files
- [ ] Double-click → open in associated editor
- [ ] Navigate directories

**Phase 3 milestone: Make a complete tiny game using only momOS tools (code + sprites + music + map). Export and share.**

---

## Phase 4 — Persistence & Hardware (Weeks 35–40)

### Disk Driver
- [ ] Write `kernel/disk/ata_pio.c` (ATA PIO read/write, IRQ14/15)
- [ ] PCI enumeration to find disk controller
- [ ] Detect Luminos LFS partition (custom partition type)
- [ ] Mount HDD LFS partition at boot (overlay on top of initrd)

### Save / Load
- [ ] `sys.save()` — snapshot RAM disk to HDD partition
- [ ] `sys.load()` — reload from HDD (called at boot if partition found)
- [ ] Block-diff: only write changed LFS blocks
- [ ] `sys.export(path)` / `sys.import(path)` — host filesystem bridge (hosted mode)

### SDL2 Hosted Mode
- [ ] Write `kernel/hal/hosted/` SDL2 HAL (display, input, audio, disk)
- [ ] `make hosted` builds native binary
- [ ] Disk image: `~/.momos/disk.img` (LFS image file)
- [ ] Test on Linux, macOS, Windows

### Real Hardware Testing
- [ ] Boot Floppy 1 on Presario 5000
- [ ] Boot CD on Presario 5000
- [ ] Confirm VESA 640×480 framebuffer works
- [ ] Confirm PS/2 keyboard + mouse work
- [ ] Confirm AC97 audio works
- [ ] Confirm ATA PIO disk access works
- [ ] Fix any hardware-specific bugs

**Phase 4 milestone: Full system running on Presario 5000. Save and load works. SDL2 hosted build works on Windows.**

---

## Phase 4.5 — Distribution (Weeks 41–44)

### Floppy 1 — Install Disk
- [ ] Floppy 1 kernel build (i686, Tier 1 apps only, compressed with gzip)
- [ ] SYSLINUX config for floppy 1
- [ ] Write `installer/install.lua`:
  - [ ] Detect IDE drives (via ATA PIO)
  - [ ] TUI: show drives, ask user to select
  - [ ] Write MBR + GRUB2 stage2 to HDD
  - [ ] Create LFS partition
  - [ ] Write base system (kernel, shell, terminal, file manager, initrd)
  - [ ] Confirm bootable
- [ ] `make floppy-install` produces 1.44 MB image
- [ ] Test install flow in QEMU end-to-end

### Floppy 2 — App Disk
- [ ] Floppy 2 kernel build (same as Floppy 1 kernel)
- [ ] Write `installer/appinstall.lua`:
  - [ ] Detect existing momOS HDD partition
  - [ ] Mount it
  - [ ] Copy Tier 2 apps from floppy initrd to `/apps/` on HDD
  - [ ] Report success/failure per app
- [ ] `make floppy-apps` produces 1.44 MB image
- [ ] Test on QEMU: install Floppy 1, then Floppy 2, reboot to full system

### CD — Hybrid ISO
- [ ] GRUB2 boot menu (Live / Install / Legacy 32-bit / Memtest)
- [ ] Bundle both i686 and x86_64 kernels on disc
- [ ] CD-based installer app (same logic as Floppy 1 installer, GUI version)
- [ ] `make cd` produces bootable hybrid ISO
- [ ] Test on QEMU (UEFI and legacy BIOS modes)
- [ ] Test on real hardware

**Phase 4.5 milestone: Clean install from Floppy 1 + Floppy 2 on Presario. Clean install from CD on modern machine.**

---

## Phase 5 — v0.1 Release

- [ ] Write `README.md` (what it is, how to build, how to run, screenshots)
- [ ] Write `docs/api_reference.md` (complete Lua API)
- [ ] Write all format specs (lfs, mpi, msm, mtm)
- [ ] Write `CONTRIBUTING.md` (code style, PR process, good-first-issues)
- [ ] Record demo video
- [ ] Build release artifacts: `momos-install.img`, `momos-apps.img`, `momos.iso`
- [ ] Publish on GitHub
- [ ] Write launch post
- [ ] Tag v0.1

---

## Ongoing / Backlog
- [ ] Pixel editor: animation timeline UI polish
- [ ] Chirp: MIDI import
- [ ] AHCI disk driver (faster than ATA PIO)
- [ ] Web build (Emscripten → WASM)
- [ ] App sharing (bundle + share `.lfs` app packages)
- [ ] Pixel editor: more tools (curve, text tool)
- [ ] Chirp: more effects
- [ ] Additional built-in wallpapers
- [ ] Accessibility: larger font option
