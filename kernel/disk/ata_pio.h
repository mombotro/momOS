#pragma once
#include <stdint.h>

#define ATA_SECTOR_SIZE  512

/* Probe and initialise ATA buses (primary 0x1F0, secondary 0x170).
   Returns number of drives found (0..4). */
int  ata_init(void);

/* Read 'count' sectors starting at LBA 'lba' into 'buf'.
   drv: 0=primary master, 1=primary slave, 2=secondary master, 3=secondary slave.
   Returns 0 on success, -1 on error or drive not present. */
int  ata_read (int drv, uint32_t lba, uint32_t count, void *buf);

/* Write 'count' sectors from 'buf' to disk, then flush cache.
   Returns 0 on success, -1 on error. */
int  ata_write(int drv, uint32_t lba, uint32_t count, const void *buf);

/* Total sector count for drive 'drv', or 0 if not present. */
uint32_t ata_sector_count(int drv);
