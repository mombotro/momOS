/* kernel/disk/fat12.c — minimal FAT12 writer, installer use only */
#include "fat12.h"
#include "ata_pio.h"
#include "../vfs/vfs.h"
#include "../mm/heap.h"
#include <stdint.h>

/* ── Helpers ─────────────────────────────────────────────────────────────── */

static void u16_le(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
}

static void u32_le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

/* Parse "kernel.bin" → name[8]="KERNEL  " ext[3]="BIN" (FAT 8.3, uppercase) */
static void parse_83(const char *fn, uint8_t *name, uint8_t *ext) {
    int i;
    for (i = 0; i < 8; i++) name[i] = ' ';
    for (i = 0; i < 3; i++) ext[i]  = ' ';

    int dot = -1;
    for (i = 0; fn[i]; i++) if (fn[i] == '.') { dot = i; break; }

    int ni = 0;
    for (i = 0; fn[i] && fn[i] != '.' && ni < 8; i++) {
        uint8_t c = (uint8_t)fn[i];
        if (c >= 'a' && c <= 'z') c = (uint8_t)(c - 32);
        name[ni++] = c;
    }
    if (dot >= 0) {
        int ei = 0;
        for (i = dot + 1; fn[i] && ei < 3; i++) {
            uint8_t c = (uint8_t)fn[i];
            if (c >= 'a' && c <= 'z') c = (uint8_t)(c - 32);
            ext[ei++] = c;
        }
    }
}

/* Read/write a FAT12 12-bit entry.
   fat: pointer to full FAT buffer (FAT12_FAT_SIZE * 512 bytes). */
static uint16_t fat12_get(const uint8_t *fat, uint32_t cluster) {
    uint32_t off = cluster + cluster / 2;
    uint16_t val = (uint16_t)fat[off] | ((uint16_t)fat[off + 1] << 8);
    return (cluster & 1u) ? (val >> 4) : (val & 0xFFFu);
}

static void fat12_set(uint8_t *fat, uint32_t cluster, uint16_t val) {
    uint32_t off = cluster + cluster / 2;
    if (cluster & 1u) {
        fat[off]     = (uint8_t)((fat[off] & 0x0Fu) | ((val & 0x0Fu) << 4));
        fat[off + 1] = (uint8_t)((val >> 4) & 0xFFu);
    } else {
        fat[off]     = (uint8_t)(val & 0xFFu);
        fat[off + 1] = (uint8_t)((fat[off + 1] & 0xF0u) | ((val >> 8) & 0x0Fu));
    }
}

/* ── fat12_format ────────────────────────────────────────────────────────── */

int fat12_format(int drive, uint32_t lba_start) {
    uint8_t sec[512];
    int i;
    for (i = 0; i < 512; i++) sec[i] = 0;

    /* Boot sector / BPB */
    sec[0] = 0xEB; sec[1] = 0x58; sec[2] = 0x90; /* JMP SHORT + NOP */
    const char *oem = "MSDOS5.0";
    for (i = 0; i < 8; i++) sec[3 + i] = (uint8_t)oem[i];
    u16_le(sec + 11, 512);                       /* bytes per sector */
    sec[13] = (uint8_t)FAT12_SEC_PER_CLU;
    u16_le(sec + 14, (uint16_t)FAT12_RESERVED);
    sec[16] = (uint8_t)FAT12_FAT_COUNT;
    u16_le(sec + 17, (uint16_t)FAT12_ROOT_ENTS);
    u16_le(sec + 19, (uint16_t)FAT12_SECTORS);   /* total sectors (16-bit) */
    sec[21] = 0xF8;                               /* media: fixed disk */
    u16_le(sec + 22, (uint16_t)FAT12_FAT_SIZE);
    u16_le(sec + 24, 63);                         /* sectors per track */
    u16_le(sec + 26, 255);                        /* number of heads */
    u32_le(sec + 28, lba_start);                  /* hidden sectors = LBA offset */
    u32_le(sec + 32, 0);                          /* total_sec32 = 0 (use 16-bit) */
    sec[36] = 0x80;                               /* drive number */
    sec[38] = 0x29;                               /* extended boot sig */
    u32_le(sec + 39, 0xDEADB00Fu);               /* volume ID */
    const char *label = "MOMOS      ";
    for (i = 0; i < 11; i++) sec[43 + i] = (uint8_t)label[i];
    const char *fstype = "FAT12   ";
    for (i = 0; i < 8; i++) sec[54 + i] = (uint8_t)fstype[i];
    sec[510] = 0x55; sec[511] = 0xAA;

    if (ata_write(drive, lba_start, 1, sec) != 0) return -1;

    /* Zero sector reused below */
    for (i = 0; i < 512; i++) sec[i] = 0;

    /* FAT tables: first 3 bytes = media descriptor + reserved cluster entries.
       Packed FAT12: cluster 0 = 0xFF8, cluster 1 = 0xFFF → bytes F8 FF FF */
    uint8_t fat_init[512];
    for (i = 0; i < 512; i++) fat_init[i] = 0;
    fat_init[0] = 0xF8; fat_init[1] = 0xFF; fat_init[2] = 0xFF;

    uint32_t copy;
    for (copy = 0; copy < FAT12_FAT_COUNT; copy++) {
        uint32_t fat_lba = lba_start + FAT12_RESERVED + copy * FAT12_FAT_SIZE;
        if (ata_write(drive, fat_lba, 1, fat_init) != 0) return -1;
        uint32_t s;
        for (s = 1; s < FAT12_FAT_SIZE; s++) {
            if (ata_write(drive, fat_lba + s, 1, sec) != 0) return -1;
        }
    }

    /* Root directory: all zeros */
    uint32_t root_lba = lba_start + FAT12_RESERVED + FAT12_FAT_COUNT * FAT12_FAT_SIZE;
    uint32_t s;
    for (s = 0; s < FAT12_ROOT_SECS; s++) {
        if (ata_write(drive, root_lba + s, 1, sec) != 0) return -1;
    }

    return 0;
}

/* ── fat12_write_file ────────────────────────────────────────────────────── */

int fat12_write_file(int drive, uint32_t lba_start,
                     const char *filename,
                     const uint8_t *data, uint32_t len) {
    const uint32_t bytes_per_clus = FAT12_SEC_PER_CLU * 512u;
    uint32_t num_clus = (len + bytes_per_clus - 1) / bytes_per_clus;
    if (num_clus == 0) num_clus = 1;

    /* Read FAT1 into buffer */
    uint8_t *fat = (uint8_t *)kmalloc(FAT12_FAT_SIZE * 512);
    if (!fat) return -1;

    uint32_t fat1_lba = lba_start + FAT12_RESERVED;
    uint32_t s;
    for (s = 0; s < FAT12_FAT_SIZE; s++) {
        if (ata_read(drive, fat1_lba + s, 1, fat + s * 512) != 0) {
            kfree(fat); return -1;
        }
    }

    /* Allocate contiguous free clusters starting at 2 */
    uint16_t *clus_list = (uint16_t *)kmalloc(num_clus * sizeof(uint16_t));
    if (!clus_list) { kfree(fat); return -1; }

    uint32_t found = 0;
    uint32_t c;
    for (c = 2; c < 4084u && found < num_clus; c++) {
        if (fat12_get(fat, c) == 0) clus_list[found++] = (uint16_t)c;
    }
    if (found < num_clus) { kfree(clus_list); kfree(fat); return -1; }

    /* Build FAT chain */
    uint32_t ci;
    for (ci = 0; ci < num_clus - 1; ci++)
        fat12_set(fat, clus_list[ci], clus_list[ci + 1]);
    fat12_set(fat, clus_list[num_clus - 1], 0xFFFu); /* EOF */

    /* Write file data cluster by cluster */
    uint8_t sec[512];
    uint32_t written = 0;
    for (ci = 0; ci < num_clus; ci++) {
        uint32_t clus_lba = lba_start + FAT12_DATA_START +
                            ((uint32_t)clus_list[ci] - 2u) * FAT12_SEC_PER_CLU;
        uint32_t si;
        for (si = 0; si < FAT12_SEC_PER_CLU; si++) {
            int k;
            for (k = 0; k < 512; k++) sec[k] = 0;
            uint32_t avail = (written < len) ? (len - written) : 0u;
            uint32_t chunk = (avail > 512u) ? 512u : avail;
            for (k = 0; k < (int)chunk; k++)
                sec[k] = data[written + (uint32_t)k];
            if (ata_write(drive, clus_lba + si, 1, sec) != 0) {
                kfree(clus_list); kfree(fat); return -1;
            }
            written += chunk;
        }
    }

    /* Write both FAT copies */
    uint32_t copy;
    for (copy = 0; copy < FAT12_FAT_COUNT; copy++) {
        uint32_t fat_lba = lba_start + FAT12_RESERVED + copy * FAT12_FAT_SIZE;
        for (s = 0; s < FAT12_FAT_SIZE; s++) {
            if (ata_write(drive, fat_lba + s, 1, fat + s * 512) != 0) {
                kfree(clus_list); kfree(fat); return -1;
            }
        }
    }

    /* Find free root dir slot and write entry */
    uint32_t root_lba = lba_start + FAT12_RESERVED +
                        FAT12_FAT_COUNT * FAT12_FAT_SIZE;
    uint8_t root[FAT12_ROOT_SECS * 512];
    for (s = 0; s < FAT12_ROOT_SECS; s++)
        ata_read(drive, root_lba + s, 1, root + s * 512);

    int slot = -1;
    uint32_t i;
    for (i = 0; i < FAT12_ROOT_ENTS; i++) {
        if (root[i * 32] == 0x00u || root[i * 32] == 0xE5u) {
            slot = (int)i; break;
        }
    }
    if (slot < 0) { kfree(clus_list); kfree(fat); return -1; }

    uint8_t name8[8], ext3[3];
    parse_83(filename, name8, ext3);

    uint8_t *e = root + slot * 32;
    for (i = 0; i < 32u; i++) e[i] = 0;
    for (i = 0; i < 8u; i++)  e[i]     = name8[i];
    for (i = 0; i < 3u; i++)  e[8 + i] = ext3[i];
    e[11] = 0x20u;                          /* archive attribute */
    e[26] = (uint8_t)(clus_list[0]);
    e[27] = (uint8_t)(clus_list[0] >> 8);
    u32_le(e + 28, len);

    for (s = 0; s < FAT12_ROOT_SECS; s++)
        ata_write(drive, root_lba + s, 1, root + s * 512);

    kfree(clus_list);
    kfree(fat);
    return 0;
}

/* ── fat12_write_vfs ─────────────────────────────────────────────────────── */

int fat12_write_vfs(int drive, uint32_t lba_start, const char *filename) {
    const uint8_t *base = (const uint8_t *)vfs_get_base();
    uint32_t size       = vfs_get_size();
    return fat12_write_file(drive, lba_start, filename, base, size);
}
