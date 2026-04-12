#include "disk.h"
#include "ata_pio.h"
#include "../vfs/lfs_format.h"
#include "../cpu/serial.h"
#include <stdint.h>

/* ── MBR partition entry ──────────────────────────────────────────────────────*/
typedef struct {
    uint8_t  status;          /* 0x80 = bootable */
    uint8_t  chs_first[3];
    uint8_t  type;            /* partition type */
    uint8_t  chs_last[3];
    uint32_t lba_start;       /* start sector (little endian) */
    uint32_t sector_count;    /* size in sectors */
} __attribute__((packed)) mbr_part_t;

/* ── Module state ─────────────────────────────────────────────────────────────*/
static int      lfs_drv        = -1;
static uint32_t lfs_lba_start  = 0;
static uint32_t lfs_sec_count  = 0;
static int      lfs_ready      = 0;

int  disk_ready(void)   { return lfs_ready; }
int  disk_drive(void)   { return lfs_drv;   }
uint32_t disk_lfs_size(void) { return lfs_sec_count * ATA_SECTOR_SIZE; }

/* ── Init ─────────────────────────────────────────────────────────────────────*/
int disk_init(void) {
    int drives = ata_init();
    if (!drives) {
        serial_puts("[DISK] no ATA drives\n");
        return 0;
    }

    /* MBR sector buffer */
    static uint8_t mbr[ATA_SECTOR_SIZE];

    /* Scan drives 0..3 for first LFS partition */
    for (int d = 0; d < 4; d++) {
        if (!ata_sector_count(d)) continue;

        if (ata_read(d, 0, 1, mbr) != 0) continue;

        /* Validate MBR magic */
        if (mbr[510] != 0x55 || mbr[511] != 0xAA) continue;

        /* Scan 4 partition entries at offset 0x1BE */
        mbr_part_t *parts = (mbr_part_t *)(mbr + 0x1BE);
        for (int p = 0; p < 4; p++) {
            if (parts[p].type == DISK_PART_TYPE_LFS &&
                parts[p].lba_start > 0 &&
                parts[p].sector_count > 0) {
                lfs_drv       = d;
                lfs_lba_start = parts[p].lba_start;
                lfs_sec_count = parts[p].sector_count;

                serial_puts("[DISK] LFS partition on drive ");
                serial_hex(d);
                serial_puts(" LBA=");
                serial_hex(lfs_lba_start);
                serial_puts(" sectors=");
                serial_hex(lfs_sec_count);
                serial_puts("\n");

                /* Peek at superblock to check for valid LFS magic */
                uint8_t sb[ATA_SECTOR_SIZE];
                if (ata_read(d, lfs_lba_start, 1, sb) == 0) {
                    if (sb[0]=='L' && sb[1]=='F' && sb[2]=='S' && sb[3]=='!') {
                        lfs_ready = 1;
                        serial_puts("[DISK] LFS superblock OK\n");
                    } else {
                        serial_puts("[DISK] partition found but no LFS magic (use sys.save() to init)\n");
                    }
                }
                return lfs_ready;
            }
        }
    }

    serial_puts("[DISK] no LFS partition found\n");
    return 0;
}

/* ── I/O ──────────────────────────────────────────────────────────────────────*/
int disk_lfs_read(void *buf, uint32_t byte_offset, uint32_t byte_count) {
    if (lfs_drv < 0) return -1;
    if (byte_offset % ATA_SECTOR_SIZE || byte_count % ATA_SECTOR_SIZE) return -1;
    uint32_t first = lfs_lba_start + byte_offset / ATA_SECTOR_SIZE;
    uint32_t cnt   = byte_count / ATA_SECTOR_SIZE;
    if (first + cnt > lfs_lba_start + lfs_sec_count) return -1;
    return ata_read(lfs_drv, first, cnt, buf);
}

int disk_lfs_write(const void *buf, uint32_t byte_offset, uint32_t byte_count) {
    if (lfs_drv < 0) return -1;
    if (byte_offset % ATA_SECTOR_SIZE || byte_count % ATA_SECTOR_SIZE) return -1;
    uint32_t first = lfs_lba_start + byte_offset / ATA_SECTOR_SIZE;
    uint32_t cnt   = byte_count / ATA_SECTOR_SIZE;
    if (first + cnt > lfs_lba_start + lfs_sec_count) return -1;
    return ata_write(lfs_drv, first, cnt, buf);
}
