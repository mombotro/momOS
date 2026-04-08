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
       kernel/mm/phys.o \
       kernel/mm/paging.o \
       kernel/mm/heap.o \
       kernel/vfs/vfs.o \
       kernel/wm/wm.o \
       kernel/lua/linit_kernel.o \
       kernel/lua/klua.o \
       $(COMPAT_OBJS) \
       $(LUA_OBJS) \
       kernel/kernel.o

# ── Targets ──────────────────────────────────────────────────────────────────

all: kernel.bin tools/mklfs initrd.lfs

# ── Host tools ────────────────────────────────────────────────────────────────
tools/mklfs: tools/mklfs.c kernel/vfs/lfs_format.h
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
	printf 'set timeout=0\nset default=0\n\nmenuentry "momOS" {\n\tmultiboot /boot/kernel.bin\n\tmodule /boot/initrd.lfs\n\tboot\n}\n' > iso/boot/grub/grub.cfg
	grub-mkrescue -o momos.iso iso
	rm -rf iso

# ── Run targets (run these from MSYS2) ────────────────────────────────────────

run-iso: momos.iso
	$(QEMU) -M pc -cdrom momos.iso -m 64M -vga std -display sdl -boot d -serial stdio

run: kernel.bin
	$(QEMU) -M pc -kernel kernel.bin -m 64M -vga std -display sdl

run-serial: kernel.bin
	$(QEMU) -kernel kernel.bin -m 64M -nographic -serial stdio

clean:
	rm -f tools/mklfs tools/mklfs.exe initrd.lfs
	rm -f kernel/boot/entry.o kernel/kernel.o \
	      kernel/cpu/cpu.o kernel/cpu/isr.o kernel/cpu/setjmp.o \
	      kernel/cpu/serial.o kernel/cpu/gdt.o kernel/cpu/idt.o kernel/cpu/pit.o \
	      kernel/mm/phys.o kernel/mm/paging.o kernel/mm/heap.o \
	      kernel/vfs/vfs.o \
	      kernel/lua/klua.o kernel/lua/linit_kernel.o \
	      $(COMPAT_OBJS) $(LUA_OBJS) \
	      kernel.bin momos.iso
	rm -rf iso

.PHONY: all run run-iso run-serial iso clean
