/* mkdisk.c — create a blank momOS disk image with an LFS partition.
   Usage: mkdisk <output.img> [size_mb]
   Default size: 20 MB.  LFS partition starts at sector 2048 (1 MB offset).
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define SECTOR      512
#define PART_START  2048         /* sectors — 1 MB alignment */

/* MBR partition entry */
typedef struct {
    uint8_t  status;
    uint8_t  chs_first[3];
    uint8_t  type;
    uint8_t  chs_last[3];
    uint32_t lba_start;
    uint32_t sector_count;
} __attribute__((packed)) mbr_part_t;

/* Write a placeholder CHS value (used only by legacy BIOSes, ignored for LBA) */
static void fill_chs(uint8_t *chs, uint32_t lba) {
    /* Clamp to max CHS 1023/254/63 */
    uint32_t cyl  = lba / (255 * 63); if (cyl  > 1023) cyl  = 1023;
    uint32_t head = (lba / 63) % 255;
    uint32_t sec  = (lba % 63) + 1;
    chs[0] = (uint8_t)head;
    chs[1] = (uint8_t)((sec & 0x3F) | ((cyl >> 2) & 0xC0));
    chs[2] = (uint8_t)(cyl & 0xFF);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: mkdisk <output.img> [size_mb]\n");
        return 1;
    }
    const char *out_path = argv[1];
    uint32_t    size_mb  = (argc >= 3) ? (uint32_t)atoi(argv[2]) : 20;
    if (size_mb < 4) size_mb = 4;

    uint32_t total_sectors  = size_mb * 1024 * 1024 / SECTOR;
    uint32_t part_sectors   = total_sectors - PART_START;

    printf("mkdisk: %s  %u MB  (%u sectors)\n", out_path, size_mb, total_sectors);
    printf("mkdisk: LFS partition  LBA %u  size %u sectors (%u MB)\n",
           PART_START, part_sectors, part_sectors / 2048);

    FILE *f = fopen(out_path, "wb");
    if (!f) { perror("fopen"); return 1; }

    /* Allocate and zero the whole image (may be slow for 20 MB but only done once) */
    uint8_t *img = calloc(total_sectors, SECTOR);
    if (!img) { fprintf(stderr, "out of memory\n"); fclose(f); return 1; }

    /* ── Build MBR ──────────────────────────────────────────────────────────── */
    /* Bootstrap code: just a "int $0x18" (boot failure) stub */
    img[0] = 0xEB; img[1] = 0xFE;   /* jmp $ */

    mbr_part_t *parts = (mbr_part_t *)(img + 0x1BE);

    /* Partition 0: LFS type 0x4C */
    parts[0].status       = 0x00;        /* not bootable */
    parts[0].type         = 0x4C;        /* Luminos LFS */
    parts[0].lba_start    = PART_START;
    parts[0].sector_count = part_sectors;
    fill_chs(parts[0].chs_first, PART_START);
    fill_chs(parts[0].chs_last,  PART_START + part_sectors - 1);

    /* MBR signature */
    img[510] = 0x55;
    img[511] = 0xAA;

    /* The LFS partition is left blank (all zeros).  No LFS magic means
       disk_init() will report "partition found but no LFS magic".
       After the first sys.save() from within momOS, the magic is written
       and subsequent boots will load from disk automatically. */

    if (fwrite(img, SECTOR, total_sectors, f) != total_sectors) {
        perror("fwrite"); free(img); fclose(f); return 1;
    }
    free(img);
    fclose(f);
    printf("mkdisk: done.\n");
    return 0;
}
