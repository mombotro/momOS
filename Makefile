# momOS Makefile
# Requires: i686-elf-gcc, i686-elf-ld, nasm, qemu-system-i386
# Install via MSYS2 UCRT64:
#   pacman -S mingw-w64-ucrt-x86_64-i686-elf-gcc \
#             mingw-w64-ucrt-x86_64-i686-elf-binutils \
#             mingw-w64-ucrt-x86_64-nasm make
#
# ISO build requires WSL2 with: grub-pc-bin grub-common xorriso mtools
# Build ISO from WSL2: make iso
# Then run from MSYS2:  make run-iso

CC     = i686-elf-gcc
LD     = i686-elf-ld
AS     = nasm
QEMU   = qemu-system-i386
HOSTCC = gcc
LIBGCC = $(shell $(CC) -print-libgcc-file-name)

CFLAGS  = -std=c11 -ffreestanding -O2 -Wall -Wextra \
          -fno-stack-protector -fno-builtin
LDFLAGS = -T linker.ld -nostdlib

# Lua source files (exclude OS/IO libs and standalone binaries)
LUA_SRCS = \
    lua/lapi.c lua/lauxlib.c lua/lbaselib.c lua/lcode.c lua/lcorolib.c \
    lua/lctype.c lua/ldebug.c lua/ldo.c lua/ldump.c lua/lfunc.c lua/lgc.c \
    lua/llex.c lua/lmathlib.c lua/lmem.c lua/lobject.c lua/lopcodes.c \
    lua/lparser.c lua/lstate.c lua/lstring.c lua/lstrlib.c lua/ltable.c \
    lua/ltablib.c lua/ltm.c lua/lundump.c lua/lutf8lib.c lua/lvm.c lua/lzio.c

LUA_OBJS = $(LUA_SRCS:.c=.o)

# Flags for Lua: no -fno-builtin so GCC can use builtins for memcpy etc.
# -I kernel/lua/compat shadows system headers with our kernel stubs.
LUACFLAGS = -std=c99 -ffreestanding -O2 -fno-stack-protector \
            -w \
            -I kernel/lua/compat \
            -include kernel/lua/lua_kernel_config.h

# Compat library objects (our minimal libc for Lua)
COMPAT_OBJS = \
    kernel/lua/compat/string.o \
    kernel/lua/compat/stdlib.o \
    kernel/lua/compat/stdio.o \
    kernel/lua/compat/math.o

OBJS = kernel/boot/entry.o \
       kernel/cpu/cpu.o \
       kernel/cpu/isr.o \
       kernel/cpu/setjmp.o \
       kernel/cpu/serial.o \
       kernel/cpu/gdt.o \
       kernel/cpu/idt.o \
       kernel/cpu/pit.o \
       kernel/cpu/keyboard.o \
       kernel/cpu/mouse.o \
       kernel/cpu/acpi.o \
       kernel/mm/phys.o \
       kernel/mm/paging.o \
       kernel/mm/heap.o \
       kernel/vfs/vfs.o \
       kernel/wm/wm.o \
       kernel/ipc/msgqueue.o \
       kernel/proc/process.o \
       kernel/proc/scheduler.o \
       kernel/audio/mixer.o \
       kernel/audio/ac97.o \
       kernel/audio/hda.o \
       kernel/audio/pcspeaker.o \
       kernel/disk/ata_pio.o \
       kernel/disk/disk.o \
       kernel/lua/linit_kernel.o \
       kernel/lua/klua.o \
       $(COMPAT_OBJS) \
       $(LUA_OBJS) \
       kernel/kernel.o

# ── Targets ──────────────────────────────────────────────────────────────────

# ── Hosted (SDL2) mode ────────────────────────────────────────────────────────
# Builds a native binary using SDL2 instead of bare metal.
# Requires SDL2 dev headers; on MSYS2: pacman -S mingw-w64-ucrt-x86_64-SDL2
SDL2_CFLAGS := $(shell sdl2-config --cflags 2>/dev/null || echo "-I/usr/include/SDL2 -D_REENTRANT")
SDL2_LIBS   := $(shell sdl2-config --libs   2>/dev/null || echo "-lSDL2")

HOSTED_CFLAGS = -std=c11 -O2 -Wall -Wextra -DHOSTED -Ikernel $(SDL2_CFLAGS)
HOSTED_LUACFLAGS = -std=c99 -O2 -w -DHOSTED -Ikernel -I lua

# Hosted LUA objects (built with hosted flags, no compat layer)
HOSTED_LUA_OBJS = $(patsubst lua/%.c,hosted_obj/lua/%.o,$(LUA_SRCS))

# Hosted kernel objects
HOSTED_OBJS = \
    hosted_obj/hosted/hal.o \
    hosted_obj/hosted/main.o \
    hosted_obj/vfs/vfs.o \
    hosted_obj/wm/wm.o \
    hosted_obj/ipc/msgqueue.o \
    hosted_obj/proc/process.o \
    hosted_obj/proc/scheduler.o \
    hosted_obj/audio/mixer.o \
    hosted_obj/lua/klua.o \
    hosted_obj/lua/linit_kernel.o \
    $(HOSTED_LUA_OBJS)

hosted: momos initrd.lfs

momos: $(HOSTED_OBJS)
	$(HOSTCC) -o $@ $^ $(SDL2_LIBS) -lm

# Rules for hosted objects
hosted_obj/hosted/%.o: kernel/hosted/%.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTED_CFLAGS) -c $< -o $@

hosted_obj/vfs/%.o: kernel/vfs/%.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTED_CFLAGS) -c $< -o $@

hosted_obj/wm/%.o: kernel/wm/%.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTED_CFLAGS) -c $< -o $@

hosted_obj/ipc/%.o: kernel/ipc/%.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTED_CFLAGS) -I lua -c $< -o $@

hosted_obj/proc/%.o: kernel/proc/%.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTED_CFLAGS) -I lua -c $< -o $@

hosted_obj/audio/%.o: kernel/audio/%.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTED_CFLAGS) -c $< -o $@

hosted_obj/lua/klua.o: kernel/lua/klua.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTED_LUACFLAGS) -Ikernel -I lua -c $< -o $@

hosted_obj/lua/linit_kernel.o: kernel/lua/linit_kernel.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTED_LUACFLAGS) -Ikernel -c $< -o $@

hosted_obj/lua/%.o: lua/%.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTED_LUACFLAGS) -c $< -o $@

all: kernel.bin tools/mklfs tools/lfs_inspect tools/mkdisk initrd.lfs

# ── Host tools ────────────────────────────────────────────────────────────────
tools/mklfs: tools/mklfs.c kernel/vfs/lfs_format.h
	$(HOSTCC) -std=c11 -O2 -Wall -o $@ $<

tools/lfs_inspect: tools/lfs_inspect.c kernel/vfs/lfs_format.h
	$(HOSTCC) -std=c11 -O2 -Wall -o $@ $<

tools/mkdisk: tools/mkdisk.c
	$(HOSTCC) -std=c11 -O2 -Wall -o $@ $<

# ── initrd image ──────────────────────────────────────────────────────────────
initrd.lfs: tools/mklfs $(shell find initrd -type f)
	./tools/mklfs initrd initrd.lfs

# ── ASM objects ──────────────────────────────────────────────────────────────
kernel/boot/entry.o: kernel/boot/entry.asm
	$(AS) -f elf32 $< -o $@

kernel/cpu/cpu.o: kernel/cpu/cpu.asm
	$(AS) -f elf32 $< -o $@

kernel/cpu/isr.o: kernel/cpu/isr.asm
	$(AS) -f elf32 $< -o $@

kernel/cpu/setjmp.o: kernel/cpu/setjmp.asm
	$(AS) -f elf32 $< -o $@

# ── Kernel C objects ──────────────────────────────────────────────────────────
kernel/cpu/%.o: kernel/cpu/%.c
	$(CC) $(CFLAGS) -Ikernel -c $< -o $@

kernel/mm/%.o: kernel/mm/%.c
	$(CC) $(CFLAGS) -Ikernel -c $< -o $@

kernel/vfs/%.o: kernel/vfs/%.c
	$(CC) $(CFLAGS) -Ikernel -c $< -o $@

kernel/wm/%.o: kernel/wm/%.c
	$(CC) $(CFLAGS) -Ikernel -c $< -o $@

kernel/ipc/%.o: kernel/ipc/%.c
	$(CC) $(LUACFLAGS) -Ikernel -I lua -c $< -o $@

kernel/proc/%.o: kernel/proc/%.c
	$(CC) $(LUACFLAGS) -Ikernel -I lua -c $< -o $@

kernel/audio/hda.o: kernel/audio/hda.c
	$(CC) $(CFLAGS) -Ikernel -c $< -o $@

kernel/audio/%.o: kernel/audio/%.c
	$(CC) $(CFLAGS) -Ikernel -c $< -o $@

kernel/disk/%.o: kernel/disk/%.c
	$(CC) $(CFLAGS) -Ikernel -c $< -o $@

kernel/lua/klua.o: kernel/lua/klua.c
	$(CC) $(LUACFLAGS) -Ikernel -I lua -c $< -o $@

kernel/lua/linit_kernel.o: kernel/lua/linit_kernel.c
	$(CC) $(LUACFLAGS) -Ikernel -c $< -o $@

kernel/kernel.o: kernel/kernel.c
	$(CC) $(CFLAGS) -Ikernel -I kernel/lua/compat -c $< -o $@

# ── Compat library (minimal libc for Lua) ────────────────────────────────────
kernel/lua/compat/%.o: kernel/lua/compat/%.c
	$(CC) $(LUACFLAGS) -c $< -o $@

# ── Lua VM objects ────────────────────────────────────────────────────────────
lua/%.o: lua/%.c
	$(CC) $(LUACFLAGS) -c $< -o $@

# ── Link ─────────────────────────────────────────────────────────────────────
kernel.bin: $(OBJS)
	$(LD) $(LDFLAGS) $(OBJS) $(LIBGCC) -o $@

# ── ISO build (run this from WSL2, not MSYS2) ─────────────────────────────────
iso:
	mkdir -p iso/boot/grub
	cp kernel.bin iso/boot/kernel.bin
	cp initrd.lfs iso/boot/initrd.lfs
	printf 'set timeout=0\nset default=0\nset gfxmode=1024x600x32,1024x600x24,800x600x32,800x600x24,640x480x32,640x480\nset gfxpayload=keep\n\nmenuentry "momOS" {\n\tmultiboot /boot/kernel.bin\n\tmodule /boot/initrd.lfs\n\tboot\n}\n' > iso/boot/grub/grub.cfg
	grub-mkrescue -o momos.iso iso
	rm -rf iso

# ── Run targets (run these from MSYS2) ────────────────────────────────────────

run-iso: momos.iso disk.img
	$(QEMU) -M pc -cdrom momos.iso -m 64M -vga std -display sdl -boot d -serial stdio \
	        -drive format=raw,file=disk.img \
	        -device AC97,audiodev=snd0 -audiodev sdl,id=snd0

# disk.img persists between runs so saves survive reboots.
# Delete it manually to reset to a clean disk.
disk.img: tools/mkdisk
	./tools/mkdisk disk.img 20

run: kernel.bin initrd.lfs disk.img
	$(QEMU) -M pc -kernel kernel.bin -initrd initrd.lfs -m 64M -vga std -display sdl \
	        -drive format=raw,file=disk.img -serial stdio \
	        -device AC97,audiodev=snd0 -audiodev sdl,id=snd0

run-hosted: momos initrd.lfs disk.img
	./momos

# ── Distributable Windows build ───────────────────────────────────────────────
# Produces dist/ with momos.exe + SDL2.dll + initrd.lfs + a fresh disk.img.
# Zip it up and run on any Windows machine (no MSYS2 needed).
SDL2_DLL ?= /ucrt64/bin/SDL2.dll

dist: momos initrd.lfs disk.img
	mkdir -p dist
	cp momos.exe dist/momos.exe 2>/dev/null || cp momos dist/momos.exe
	cp $(SDL2_DLL) dist/SDL2.dll
	cp initrd.lfs  dist/initrd.lfs
	cp disk.img    dist/disk.img
	@echo "dist/ ready — copy the folder and run momos.exe"

run-serial: kernel.bin
	$(QEMU) -kernel kernel.bin -m 64M -nographic -serial stdio

test: tools/test_vfs tools/test_ipc
	./tools/test_vfs
	./tools/test_ipc

tools/test_vfs: tools/test_vfs.c kernel/vfs/lfs_format.h kernel/vfs/vfs.h kernel/vfs/vfs.c
	$(HOSTCC) -std=c11 -O2 -Wall -Wno-unused-function \
	          -I. -o $@ tools/test_vfs.c

tools/test_ipc: tools/test_ipc.c kernel/ipc/msgqueue.c kernel/ipc/msgqueue.h $(LUA_SRCS)
	$(HOSTCC) -std=c11 -O2 -Wall -Wno-unused-function \
	          -I. -Ikernel -Ilua \
	          tools/test_ipc.c $(LUA_SRCS) -lm -o $@

clean:
	rm -f tools/mklfs tools/mklfs.exe tools/lfs_inspect tools/lfs_inspect.exe \
	      tools/mkdisk tools/mkdisk.exe tools/test_vfs tools/test_vfs.exe \
	      tools/test_ipc tools/test_ipc.exe initrd.lfs
	rm -f kernel/boot/entry.o kernel/kernel.o \
	      kernel/cpu/cpu.o kernel/cpu/isr.o kernel/cpu/setjmp.o \
	      kernel/cpu/serial.o kernel/cpu/gdt.o kernel/cpu/idt.o kernel/cpu/pit.o kernel/cpu/acpi.o \
	      kernel/mm/phys.o kernel/mm/paging.o kernel/mm/heap.o \
	      kernel/vfs/vfs.o \
	      kernel/ipc/msgqueue.o \
	      kernel/proc/process.o kernel/proc/scheduler.o \
	      kernel/audio/mixer.o kernel/audio/ac97.o kernel/audio/hda.o kernel/audio/pcspeaker.o \
	      kernel/disk/ata_pio.o kernel/disk/disk.o \
	      kernel/lua/klua.o kernel/lua/linit_kernel.o \
	      $(COMPAT_OBJS) $(LUA_OBJS) \
	      kernel.bin momos.iso momos momos.exe
	rm -rf iso hosted_obj dist

# Remove the disk image (loses all saved state)
clean-disk:
	rm -f disk.img

.PHONY: all hosted dist run run-hosted run-iso run-serial iso test clean clean-disk
