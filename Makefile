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

CFLAGS  = -std=c11 -ffreestanding -O2 -Wall -Wextra \
          -fno-stack-protector -fno-builtin
LDFLAGS = -T linker.ld -nostdlib

OBJS = kernel/boot/entry.o \
       kernel/cpu/cpu.o \
       kernel/cpu/isr.o \
       kernel/cpu/serial.o \
       kernel/cpu/gdt.o \
       kernel/cpu/idt.o \
       kernel/cpu/pit.o \
       kernel/kernel.o

# ── Targets ──────────────────────────────────────────────────────────────────

all: kernel.bin

kernel/boot/entry.o: kernel/boot/entry.asm
	$(AS) -f elf32 $< -o $@

kernel/cpu/cpu.o: kernel/cpu/cpu.asm
	$(AS) -f elf32 $< -o $@

kernel/cpu/isr.o: kernel/cpu/isr.asm
	$(AS) -f elf32 $< -o $@

kernel/cpu/%.o: kernel/cpu/%.c
	$(CC) $(CFLAGS) -Ikernel -c $< -o $@

kernel/kernel.o: kernel/kernel.c
	$(CC) $(CFLAGS) -Ikernel -c $< -o $@

kernel.bin: $(OBJS)
	$(LD) $(LDFLAGS) $(OBJS) -o $@

# ── ISO build (run this from WSL2, not MSYS2) ─────────────────────────────────
# kernel.bin must already be built in MSYS2 first — this just packages it
iso:
	mkdir -p iso/boot/grub
	cp kernel.bin iso/boot/kernel.bin
	printf 'set timeout=0\nset default=0\n\nmenuentry "momOS" {\n\tmultiboot /boot/kernel.bin\n\tboot\n}\n' > iso/boot/grub/grub.cfg
	grub-mkrescue -o momos.iso iso
	rm -rf iso

# ── Run targets (run these from MSYS2) ────────────────────────────────────────

# Boot from ISO (GRUB handles VESA — use this instead of run)
run-iso: momos.iso
	$(QEMU) -M pc -cdrom momos.iso -m 64M -vga std -display sdl -boot d -serial stdio

# Legacy direct kernel boot (no framebuffer)
run: kernel.bin
	$(QEMU) -M pc -kernel kernel.bin -m 64M -vga std -display sdl

# Run without a window (serial only) — useful for headless debug
run-serial: kernel.bin
	$(QEMU) -kernel kernel.bin -m 64M -nographic \
	        -serial stdio

clean:
	rm -f kernel/boot/entry.o kernel/kernel.o \
	      kernel/cpu/cpu.o kernel/cpu/isr.o \
	      kernel/cpu/serial.o kernel/cpu/gdt.o kernel/cpu/idt.o kernel/cpu/pit.o \
	      kernel.bin momos.iso
	rm -rf iso

.PHONY: all run run-iso run-serial iso clean
