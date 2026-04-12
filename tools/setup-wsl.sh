#!/usr/bin/env bash
# momOS ISO build dependencies for WSL2
# Run this from inside WSL2 (Ubuntu/Debian). Required for 'make iso'.

set -e

echo "=== momOS WSL2 ISO-build setup ==="

echo "[1/2] Installing GRUB2 + ISO tools..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    grub-pc-bin grub-common xorriso mtools

echo "[2/2] Verifying tools..."
MISSING=0
for tool in grub-mkrescue xorriso mtools; do
    if command -v "$tool" &>/dev/null || dpkg -l "$tool" &>/dev/null 2>&1; then
        echo "  OK  $tool"
    else
        echo "  MISSING  $tool"
        MISSING=1
    fi
done

if [ $MISSING -eq 0 ]; then
    echo ""
    echo "WSL2 ISO tools ready."
    echo "From WSL2, cd to the momOS directory and run: make iso"
    echo "Then from MSYS2: make run-iso"
else
    echo "Some packages failed to install."
    exit 1
fi
