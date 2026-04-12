#pragma once
#include <stdint.h>

/* MBR partition type used for the Luminos LFS partition */
#define DISK_PART_TYPE_LFS  0x4C   /* 'L' */

/* Probe ATA and scan MBR for an LFS partition.
   Returns 1 if found and ready, 0 otherwise.
   Call after ata_init() and vfs_init(). */
int  disk_init(void);

/* 1 if an LFS partition was found and confirmed valid, 0 otherwise */
int  disk_ready(void);

/* Drive number that holds the LFS partition (-1 if none) */
int  disk_drive(void);

/* Read/write raw bytes within the LFS partition.
   byte_offset and byte_count must both be multiples of 512.
   Returns 0 on success, -1 on error. */
int  disk_lfs_read (void *buf, uint32_t byte_offset, uint32_t byte_count);
int  disk_lfs_write(const void *buf, uint32_t byte_offset, uint32_t byte_count);

/* Total byte size of the LFS partition */
uint32_t disk_lfs_size(void);
