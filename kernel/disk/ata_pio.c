#include "ata_pio.h"
#include "../cpu/serial.h"
#include <stdint.h>

/* ── Port I/O ────────────────────────────────────────────────────────────────*/
static inline void outb(uint16_t port, uint8_t v)  { __asm__ volatile ("outb %0,%1" :: "a"(v), "Nd"(port)); }
static inline void outw(uint16_t port, uint16_t v) { __asm__ volatile ("outw %0,%1" :: "a"(v), "Nd"(port)); }
static inline uint8_t  inb(uint16_t port)  { uint8_t  v; __asm__ volatile ("inb %1,%0" : "=a"(v) : "Nd"(port)); return v; }
static inline uint16_t inw(uint16_t port)  { uint16_t v; __asm__ volatile ("inw %1,%0" : "=a"(v) : "Nd"(port)); return v; }

/* ── ATA register offsets from channel base ──────────────────────────────────*/
#define REG_DATA       0   /* R/W 16-bit data window */
#define REG_ERR        1   /* R: error; W: features  */
#define REG_SECCOUNT   2
#define REG_LBA_LO     3
#define REG_LBA_MID    4
#define REG_LBA_HI     5
#define REG_DRVHEAD    6   /* drive/head / LBA[27:24] */
#define REG_STATUS     7   /* R: status; W: command  */
#define REG_CMD        7

#define REG_ALT_STATUS 0x206  /* alt-status / device control (base+0x206) */

/* Status bits */
#define STATUS_BSY   0x80
#define STATUS_RDY   0x40
#define STATUS_DRQ   0x08
#define STATUS_ERR   0x01

/* ATA commands */
#define CMD_READ     0x20
#define CMD_WRITE    0x30
#define CMD_FLUSH    0xE7
#define CMD_IDENTIFY 0xEC

/* ── Channel table ───────────────────────────────────────────────────────────*/
static const uint16_t chan_base[2] = { 0x1F0, 0x170 };  /* primary, secondary */
static const uint16_t chan_ctrl[2] = { 0x3F6, 0x376 };  /* alt-status / ctrl  */

/* Per-drive state: channel (0/1), which drive on channel (0/1), total sectors */
typedef struct {
    int      present;
    uint8_t  chan;    /* 0 = primary, 1 = secondary */
    uint8_t  slave;   /* 0 = master, 1 = slave */
    uint32_t sectors; /* LBA28 sector count from IDENTIFY */
} ata_drive_t;

static ata_drive_t drives[4];  /* 0=pm,1=ps,2=sm,3=ss */

/* ── Helpers ─────────────────────────────────────────────────────────────────*/
static uint16_t base(int drv)  { return chan_base[drives[drv].chan]; }

/* Poll until BSY clears; returns status byte.  Spins up to ~300 ms worth. */
static uint8_t ata_poll_bsy(uint16_t b) {
    for (int i = 0; i < 0x7FFFF; i++) {
        uint8_t s = inb(b + REG_STATUS);
        if (!(s & STATUS_BSY)) return s;
    }
    return 0xFF; /* timeout */
}

/* Poll until DRQ or ERR, with BSY first cleared */
static uint8_t ata_poll_drq(uint16_t b) {
    uint8_t s;
    for (int i = 0; i < 0x7FFFF; i++) {
        s = inb(b + REG_STATUS);
        if (s & STATUS_ERR) return s;
        if (!(s & STATUS_BSY) && (s & STATUS_DRQ)) return s;
    }
    return 0xFF;
}

/* Select drive and wait for it to be ready */
static int ata_select(int drv) {
    uint16_t b     = base(drv);
    uint8_t  slave = drives[drv].slave;
    /* 400ns delay via 4 alt-status reads */
    inb(chan_ctrl[drives[drv].chan]);
    inb(chan_ctrl[drives[drv].chan]);
    inb(chan_ctrl[drives[drv].chan]);
    inb(chan_ctrl[drives[drv].chan]);
    outb(b + REG_DRVHEAD, 0xA0 | (slave << 4));
    /* 400ns delay again */
    inb(chan_ctrl[drives[drv].chan]);
    inb(chan_ctrl[drives[drv].chan]);
    inb(chan_ctrl[drives[drv].chan]);
    inb(chan_ctrl[drives[drv].chan]);
    uint8_t s = ata_poll_bsy(b);
    if (s == 0xFF) return -1;
    return 0;
}

/* ── IDENTIFY ────────────────────────────────────────────────────────────────*/
static int ata_identify(uint8_t chan, uint8_t slave, uint32_t *sectors_out) {
    uint16_t b = chan_base[chan];
    /* Select drive */
    outb(b + REG_DRVHEAD, 0xA0 | (slave << 4));
    inb(chan_ctrl[chan]); inb(chan_ctrl[chan]);
    inb(chan_ctrl[chan]); inb(chan_ctrl[chan]);
    /* Check if anything is present (floating bus = 0xFF) */
    uint8_t s = inb(b + REG_STATUS);
    if (s == 0xFF) return 0;  /* nothing on this bus */

    /* Zero LBA/count regs, then send IDENTIFY */
    outb(b + REG_SECCOUNT, 0);
    outb(b + REG_LBA_LO, 0);
    outb(b + REG_LBA_MID, 0);
    outb(b + REG_LBA_HI, 0);
    outb(b + REG_CMD, CMD_IDENTIFY);

    s = inb(b + REG_STATUS);
    if (s == 0) return 0;  /* no drive */

    /* Wait for BSY to clear */
    s = ata_poll_bsy(b);

    /* If LBA_MID or LBA_HI are non-zero, it's ATAPI — skip */
    if (inb(b + REG_LBA_MID) || inb(b + REG_LBA_HI)) return 0;

    /* Wait for DRQ */
    s = ata_poll_drq(b);
    if (s & STATUS_ERR) return 0;

    /* Read 256 words of IDENTIFY data */
    uint16_t id[256];
    for (int i = 0; i < 256; i++) id[i] = inw(b + REG_DATA);

    /* Words 60-61 = LBA28 total sectors */
    *sectors_out = ((uint32_t)id[61] << 16) | id[60];
    return 1;
}

/* ── Init ────────────────────────────────────────────────────────────────────*/
int ata_init(void) {
    int found = 0;
    for (uint8_t c = 0; c < 2; c++) {
        for (uint8_t sl = 0; sl < 2; sl++) {
            int drv = c * 2 + sl;
            uint32_t secs = 0;
            if (ata_identify(c, sl, &secs)) {
                drives[drv].present = 1;
                drives[drv].chan    = c;
                drives[drv].slave  = sl;
                drives[drv].sectors = secs;
                found++;
                serial_puts("[ATA] drive ");
                serial_hex(drv);
                serial_puts(": ");
                serial_hex(secs);
                serial_puts(" sectors\n");
            }
        }
    }
    return found;
}

uint32_t ata_sector_count(int drv) {
    if (drv < 0 || drv > 3 || !drives[drv].present) return 0;
    return drives[drv].sectors;
}

/* ── Read ────────────────────────────────────────────────────────────────────*/
int ata_read(int drv, uint32_t lba, uint32_t count, void *buf) {
    if (drv < 0 || drv > 3 || !drives[drv].present) return -1;
    if (!count) return 0;

    uint16_t b     = base(drv);
    uint8_t  slave = drives[drv].slave;
    uint16_t *p    = (uint16_t *)buf;

    while (count) {
        /* Max 255 sectors per command (0 means 256 in ATA) */
        uint8_t n = (count >= 255) ? 255 : (uint8_t)count;

        if (ata_select(drv) < 0) return -1;

        outb(b + REG_SECCOUNT, n);
        outb(b + REG_LBA_LO,  (uint8_t)(lba));
        outb(b + REG_LBA_MID, (uint8_t)(lba >> 8));
        outb(b + REG_LBA_HI,  (uint8_t)(lba >> 16));
        outb(b + REG_DRVHEAD, 0xE0 | (slave << 4) | ((lba >> 24) & 0x0F));
        outb(b + REG_CMD, CMD_READ);

        for (int s = 0; s < n; s++) {
            uint8_t st = ata_poll_drq(b);
            if (st & STATUS_ERR) {
                serial_puts("[ATA] read error\n");
                return -1;
            }
            for (int w = 0; w < 256; w++) *p++ = inw(b + REG_DATA);
            /* 400ns delay */
            inb(chan_ctrl[drives[drv].chan]);
            inb(chan_ctrl[drives[drv].chan]);
            inb(chan_ctrl[drives[drv].chan]);
            inb(chan_ctrl[drives[drv].chan]);
        }

        lba   += n;
        count -= n;
    }
    return 0;
}

/* ── Write ───────────────────────────────────────────────────────────────────*/
int ata_write(int drv, uint32_t lba, uint32_t count, const void *buf) {
    if (drv < 0 || drv > 3 || !drives[drv].present) return -1;
    if (!count) return 0;

    uint16_t b     = base(drv);
    uint8_t  slave = drives[drv].slave;
    const uint16_t *p = (const uint16_t *)buf;

    while (count) {
        uint8_t n = (count >= 255) ? 255 : (uint8_t)count;

        if (ata_select(drv) < 0) return -1;

        outb(b + REG_SECCOUNT, n);
        outb(b + REG_LBA_LO,  (uint8_t)(lba));
        outb(b + REG_LBA_MID, (uint8_t)(lba >> 8));
        outb(b + REG_LBA_HI,  (uint8_t)(lba >> 16));
        outb(b + REG_DRVHEAD, 0xE0 | (slave << 4) | ((lba >> 24) & 0x0F));
        outb(b + REG_CMD, CMD_WRITE);

        for (int s = 0; s < n; s++) {
            uint8_t st = ata_poll_drq(b);
            if (st & STATUS_ERR) {
                serial_puts("[ATA] write error\n");
                return -1;
            }
            for (int w = 0; w < 256; w++) outw(b + REG_DATA, *p++);
            /* Flush after each sector */
            ata_poll_bsy(b);
        }

        lba   += n;
        count -= n;
    }

    /* Cache flush */
    if (ata_select(drv) == 0) {
        outb(b + REG_CMD, CMD_FLUSH);
        ata_poll_bsy(b);
    }
    return 0;
}
