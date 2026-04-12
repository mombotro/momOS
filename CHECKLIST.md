# momOS — Build Checklist

---

## Phase 0 — Toolchain & Boot (Weeks 1–6)

### Toolchain Setup
- [x] Install/build i686-elf-gcc cross-compiler (via crosstool-NG or prebuilt)
- [ ] Install/build x86_64-elf-gcc cross-compiler
- [x] Install NASM, SYSLINUX, GRUB2, xorriso, QEMU
- [x] Write bootstrap script that sets up the entire toolchain from scratch (`setup.sh` + `tools/setup-wsl.sh`)
- [x] Write initial Makefile with `make run` target

### Floppy Boot Path (SYSLINUX)
- [ ] Write SYSLINUX config for 1.44 MB floppy image
- [ ] Write floppy image assembly script in Makefile
- [ ] Confirm `make run-floppy1` boots in QEMU

### CD Boot Path (GRUB2)
- [ ] Write GRUB2 config with i686 + x86_64 boot menu entries
- [ ] Hybrid ISO build (UEFI + legacy BIOS via xorriso)
- [ ] Confirm `make run` boots in QEMU

### Kernel Entry
- [x] Write `entry.asm` (Multiboot1 header, stack setup, jump to C)
- [ ] Write SYSLINUX entry glue (flat binary entry point)
- [x] Write `kernel/cpu/gdt.c` (GDT with code + data segments)
- [x] Write `kernel/cpu/idt.c` (IDT, ISR stubs for exceptions 0–31)
- [x] Serial debug output (COM1) for early logging
- [x] Multiboot1 info parsing (memory map, framebuffer, modules — `mb1_info_t` in kernel.c)

### Memory
- [x] Physical memory map from Multiboot1 mmap
- [x] Write `kernel/mm/phys.c` (bitmap allocator, `phys_alloc_contig`)
- [x] Write `kernel/mm/paging.c` (PSE 4 MB identity map 0–64 MB + framebuffer)
- [x] Write `kernel/mm/heap.c` (free-list heap backed by phys_alloc)

### Display
- [x] Accept VESA framebuffer pointer from GRUB/SYSLINUX
- [x] Write `kernel/gfx/framebuffer.c` (write pixels to linear framebuffer)
- [x] Draw a colored rectangle on screen
- [x] Confirm 640×480 mode works in QEMU

### Timer
- [x] Write `kernel/cpu/pit.c` (PIT at 60 Hz, IRQ0 handler)
- [x] Tick counter increments in interrupt handler (`pit_ticks()`)

**Phase 0 milestone: `make run` boots QEMU, shows a bouncing colored square at 60 FPS. Serial console shows memory map.**

> **2026-04-07**: Kernel boots in QEMU via Multiboot1. VGA text mode confirmed working.
> Toolchain: i686-elf-gcc (prebuilt) + NASM + MSYS2 make + QEMU on Windows.

---

## Phase 1 — OS Primitives (Weeks 7–14)

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
- [x] Spawn a single Lua state, run a hardcoded "hello world" script
- [x] `gfx.pset(x, y, color)` draws a pixel on screen
- [x] `gfx.cls(color)` clears screen

### Lua API — Minimal Set
- [x] `gfx.pset`, `gfx.pget`, `gfx.cls`, `gfx.rect`, `gfx.line`, `gfx.print`
- [x] `fs.read(path)`, `fs.write(path, data)`, `fs.list(path)`, `fs.mkdir`, `fs.delete`
- [x] `input.getchar()`, `input.key_down(key)` (keyboard)
- [x] `mouse.x()`, `mouse.y()`, `mouse.btn(n)` (mouse)
- [x] `sys.ticks()`, `sys.mem()`, `sys.spawn()`, `sys.kill()`, `sys.ps()` — proper sys table

### Process Model
- [x] Write `kernel/proc/process.c` (process struct, fixed-size table, `proc_alloc/free/get/find`)
- [x] Write `kernel/proc/scheduler.c` (Lua debug hook preemption, `SCHED_BUDGET_TICKS=2`)
- [x] `_update()` / `_draw()` callback convention
- [x] PIT preempt: Lua debug hook fires every 2000 instructions; `luaL_error` if over budget
- [x] Spawn process from a file path in VFS (`launch(path)`)
- [x] Run multiple Lua apps simultaneously (app_list + wm)

### IPC
- [x] Write `kernel/ipc/msgqueue.c` (per-process inbox, cap 64 messages, Lua registry refs)
- [x] No serialization needed — single Lua state; values stored via `luaL_ref`
- [x] `ipc.send(name, data)` and `_msg(from, data)` callback dispatched in main.lua
- [ ] IPC unit tests pass

### Input
- [x] Write `kernel/cpu/keyboard.c` (PS/2 keyboard, scancode → keycode)
- [x] Write `kernel/cpu/mouse.c` (PS/2 mouse, delta x/y, buttons)
- [x] Global input event queue, routed to focused process

**Phase 1 milestone: Write a Lua file, put it in initrd, it runs as a process. Two demo processes exchange messages.**

---

## Phase 2 — Desktop (Weeks 15–22)

### Compositor
- [x] Write `kernel/gfx/compositor.c` / `wm.c` (owns framebuffer, composites windows)
- [x] Per-window off-screen pixel buffers
- [x] Dirty-region tracking + blit to system framebuffer (per-window dirty flag, merged rect, row-range present)
- [x] Window creation from Lua: `wm.open(title, x, y, w, h)`
- [x] Drag windows by title bar
- [x] Z-ordering (click to bring to front)
- [x] Close button (F4 or title bar X)
- [x] Minimize / maximize buttons

### Shell / Desktop (Tier 1 app)
- [x] Shell is PID 1 / first spawned Lua process (`sys/main.lua`)
- [x] Render wallpaper (solid color)
- [x] Desktop icons from `/home/desktop/`
- [x] Double-click icon → spawn process
- [x] Right-click context menu (new folder, open terminal/files, restart, shut down)
- [x] Taskbar: clock, running app buttons, home button
- [x] Quake-style dropdown terminal (backtick to toggle, slides in/out, resizable)
- [x] Error badge in taskbar (flashing `!N` when unread errors exist)
- [x] `sys.shutdown()` / `sys.reboot()` — power off and warm restart

### Terminal (Tier 1 app)
- [x] Terminal window with scrollback buffer (spawned terminal app)
- [x] Lua REPL (evaluate expressions with `=expr` or raw Lua)
- [x] Built-in commands: `ls`, `cat`, `cd`, `run`, `write`, `mkdir`, `rm`, `clear`, `ps`, `kill`, `help`
- [x] Command history (up/down arrow)

### File Manager (Tier 1 app)
- [x] VFS tree navigation
- [x] Icon view + list view toggle (Tab)
- [x] Copy (`c`), cut (`x`), paste (`p`), delete (Del), rename (`r`)
- [x] Open file with associated app by extension (`.lua` → run, `.mpi` → pixel, other → quill)
- [x] Edit in quill (`e` key)
- [x] Colored type tags / placeholder icons by extension

**Phase 2 milestone: Boot to desktop, open terminal, write a Lua script, save it, run it. Feels like an OS.**

---

## Phase 3 — Creative Tools (Weeks 23–34)

### Quill — Code Editor
- [x] Text buffer with line/column tracking
- [x] Lua syntax highlighting (keywords, strings, comments, numbers)
- [x] Line numbers
- [x] Tab-complete for momOS API functions (static list ~60 entries)
- [x] Run current file (`:r`)
- [x] Inline error display (red background on error line)
- [x] File tabs (up to 8 open files)
- [x] Save / Save As (`:w`, `:w <path>`)
- [x] Help file accessible via `:help`

### Pixel — Sprite Editor
- [x] Write `.mpi` format spec (`docs/mpi_format.md`)
- [x] Canvas sizes: 8×8 to 128×128 (`:n WxH`)
- [x] Tools: pencil, eraser, fill, line, rect, eyedropper
- [x] Tools: circle (Bresenham), select/move (lasso-free rect select with floating buffer)
- [x] 4 layers
- [x] 16 animation frames + onion skinning
- [x] Palette editor (HSV sliders, `gfx.set_pal`/`gfx.get_pal` kernel API, right-click palette cell)
- [x] Save/load `.mpi`
- [x] Help file accessible via `?` or `:help`
- [x] `tools/import_png.py` (PNG → .mpi, Floyd-Steinberg dithering option)

### Chirp — Music Tracker
- [x] Write `.msm` format spec (`docs/msm_format.md`)
- [x] Write `kernel/audio/mixer.c` (4-channel software mixer, 22050 Hz, 8-bit)
- [x] Write `kernel/audio/ac97.c` (AC97 via PCI, auto-detected)
- [x] PC speaker fallback driver (`kernel/audio/pcspeaker.c`)
- [x] Tracker UI: pattern grid, 4 channels, note/instrument/volume/effect columns
- [x] 64 patterns × 32 rows
- [x] 8 effects defined in format spec (vibrato, arpeggio, slide, tremolo, delay, cut)
- [x] 16 instrument presets (waveform + ADSR + vibrato)
- [x] Real-time playback during editing (space to play/stop)
- [x] Save/load `.msm`

### Terrain — Map Editor
- [x] Write `.mtm` format spec (`docs/mtm_format.md`)
- [x] Import sprite sheet from `.mpi` (8×8 or 16×16 tiles, `:ts <path>`)
- [x] Tile grid up to 256×256
- [x] 4 tile layers + 1 object layer (obj tool)
- [x] Object properties key-value pairs (in format, basic in UI)
- [x] Save/load `.mtm`

### P8 — PICO-8 Player
- [x] Parse `.p8` format (sections: `__lua__`, `__gfx__`, `__map__`)
- [x] Load sprite sheet (128×128, 4bpp) + translate 16-color PICO-8 palette
- [x] Load map (128×64)
- [ ] Load SFX + music patterns (stub — no audio routing yet)
- [x] Implement PICO-8 API shim over momOS gfx/input/audio:
  - [x] `pset`, `pget`, `cls`, `camera`, `color`, `line`, `rect`, `rectfill`, `circ`
  - [x] `spr`, `map`, `mget`, `mset`, `pal`
  - [x] `btn`, `btnp`
  - [x] `sfx`, `music` (stubs)
  - [x] `rnd`, `flr`, `ceil`, `abs`, `max`, `min`, `mid`, `sqrt`, `cos`, `sin`, `atan2`
  - [x] `peek`, `poke` (stubs — return 0)
  - [x] `tostr`, `tonum`, `sub`, `print` (PICO-8 flavors)
  - [ ] `sspr`, `fget`, `fset` (not yet — P8 player de-prioritised in favour of native Lua games)
- [x] 128×128 viewport scaled/letterboxed in window
- [x] Run cartridge, handle errors gracefully

### Shelf — Asset Browser
- [x] Grid view of all files in current directory
- [x] Thumbnail preview: `.mpi` → scaled sprite, other types → icon badge
- [x] Play button on `.msm` files (▶ badge on thumbnail → opens in Chirp)
- [x] Double-click → open in associated editor
- [x] Navigate directories

**Phase 3 milestone: Make a complete tiny game using only momOS tools (code + sprites + music + map). Export and share.**

---

## Phase 4 — Persistence & Hardware (Weeks 35–40)

### Disk Driver
- [x] Write `kernel/disk/ata_pio.c` (ATA PIO read/write, poll-based LBA28)
- [x] ATA bus scan sufficient for QEMU and PATA hardware (no PCI enumeration needed)
- [x] Detect Luminos LFS partition (type 0x4C in MBR)
- [x] Mount HDD LFS partition at boot (overlay on top of initrd)

### Save / Load
- [x] `sys.save()` — snapshot RAM disk to HDD partition
- [x] `sys.load()` — reload from HDD
- [ ] Block-diff: only write changed LFS blocks
- [ ] `sys.export(path)` / `sys.import(path)` — host filesystem bridge (hosted mode)

### SDL2 Hosted Mode
- [ ] Write `kernel/hal/hosted/` SDL2 HAL (display, input, audio, disk)
- [ ] `make hosted` builds native binary
- [ ] Disk image: `~/.momos/disk.img` (LFS image file)
- [ ] Test on Linux, macOS, Windows

### Real Hardware Testing
- [ ] Boot CD on Acer Aspire 1 (2009) — Intel Atom, HDA audio, SATA (initrd only)
- [ ] Boot CD on Presario 5000 — PATA disk + AC97 audio expected to work
- [ ] Confirm VESA 640×480×32 framebuffer works (GRUB config sets gfxmode + gfxpayload=keep)
- [ ] Confirm PS/2 keyboard + mouse work
- [ ] Confirm AC97 audio works (Presario)
- [ ] Confirm ATA PIO disk access works (Presario PATA drive)
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
- [ ] Pixel editor: circle tool
- [ ] Pixel editor: select/move tool
- [ ] Pixel editor: palette editor (HSV color picker)
- [ ] Pixel editor: animation timeline UI polish
- [ ] Chirp: MIDI import
- [ ] AHCI disk driver (faster than ATA PIO)
- [ ] Web build (Emscripten → WASM)
- [ ] App sharing (bundle + share `.lfs` app packages)
- [ ] Chirp: more effects
- [ ] Additional built-in wallpapers
- [ ] Accessibility: larger font option
