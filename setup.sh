#!/usr/bin/env bash
# momOS toolchain bootstrap
# Run this from an MSYS2 UCRT64 shell to install all build dependencies.
# For ISO building, also run tools/setup-wsl.sh from inside WSL2.

set -e

echo "=== momOS toolchain setup ==="

# ── MSYS2 packages ────────────────────────────────────────────────────────────
PACKAGES=(
    mingw-w64-ucrt-x86_64-i686-elf-gcc
    mingw-w64-ucrt-x86_64-i686-elf-binutils
    mingw-w64-ucrt-x86_64-nasm
    make
)

echo "[1/3] Updating package database..."
pacman -Sy --noconfirm

echo "[2/3] Installing cross-compiler and build tools..."
pacman -S --noconfirm --needed "${PACKAGES[@]}"

echo "[3/3] Verifying tools..."
MISSING=0
for tool in i686-elf-gcc i686-elf-ld nasm make; do
    if command -v "$tool" &>/dev/null; then
        echo "  OK  $tool ($(command -v $tool))"
    else
        echo "  MISSING  $tool"
        MISSING=1
    fi
done

if [ $MISSING -eq 0 ]; then
    echo ""
    echo "All tools installed. Run 'make run' to build and launch momOS in QEMU."
    echo "For ISO builds, run tools/setup-wsl.sh from inside WSL2."
else
    echo ""
    echo "Some tools are missing. Check that MSYS2 UCRT64 shell is being used."
    exit 1
fi
