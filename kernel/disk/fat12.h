/* kernel/disk/fat12.h — minimal FAT12 writer for momOS installer */
#pragma once
#include <stdint.h>

/* Volume geometry (fixed 8 MB layout) */
#define FAT12_SECTORS      16384u  /* total sectors in volume */
#define FAT12_SEC_PER_CLU  8u      /* 4 KB clusters */
#define FAT12_RESERVED     1u
#define FAT12_FAT_COUNT    2u
#define FAT12_FAT_SIZE     6u      /* sectors per FAT */
#define FAT12_ROOT_ENTS    32u
#define FAT12_ROOT_SECS    2u      /* 32 entries × 32 bytes = 1024 = 2 sectors */
#define FAT12_DATA_START   (FAT12_RESERVED + FAT12_FAT_COUNT * FAT12_FAT_SIZE + FAT12_ROOT_SECS)
/* = 1 + 12 + 2 = 15 */

/*
 * Format a FAT12 volume at (drive, lba_start).
 * Writes boot sector, 2 FAT copies, and empty root directory.
 * Returns 0 on success, -1 on disk error.
 */
int fat12_format(int drive, uint32_t lba_start);

/*
 * Write a flat file to the root directory of a FAT12 volume.
 * filename: up to "8.3" format, e.g. "kernel.bin" or "initrd.lfs"
 * Returns 0 on success, -1 on error.
 */
int fat12_write_file(int drive, uint32_t lba_start,
                     const char *filename,
                     const uint8_t *data, uint32_t len);

/*
 * Same as fat12_write_file but reads from the in-memory VFS
 * (uses vfs_get_base() / vfs_get_size() — writes the live initrd image).
 */
int fat12_write_vfs(int drive, uint32_t lba_start, const char *filename);
