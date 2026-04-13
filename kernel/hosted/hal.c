/* hal.c — Hardware Abstraction Layer for momOS hosted (SDL2) mode.
 *
 * Replaces the following bare-metal modules:
 *   cpu/serial, cpu/gdt, cpu/idt, cpu/pit, cpu/keyboard, cpu/mouse, cpu/acpi
 *   mm/phys, mm/paging, mm/heap
 *   audio/ac97, audio/hda, audio/pcspeaker
 *   disk/ata_pio, disk/disk
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <SDL.h>

#include "../cpu/keyboard.h"
#include "../cpu/mouse.h"
#include "../audio/audio.h"
#include "../disk/disk.h"
#include "../disk/ata_pio.h"
#include "../mm/phys.h"

/* ── Serial → stdout ─────────────────────────────────────────────────────── */
void serial_init(void) {}
void serial_putc(char c)              { fputc(c, stderr); }
void serial_puts(const char *s)       { fputs(s, stderr); }
void serial_write(const char *s, unsigned int len) {
    fwrite(s, 1, len, stderr);
}
void serial_hex(uint32_t n) {
    char buf[9];
    for (int i = 7; i >= 0; i--) {
        int nibble = (n >> (i*4)) & 0xF;
        buf[7-i] = (char)(nibble < 10 ? '0'+nibble : 'a'+(nibble-10));
    }
    buf[8] = 0;
    fputs(buf, stderr);
}

/* ── GDT / IDT → no-op ───────────────────────────────────────────────────── */
void gdt_init(void) {}
void idt_init(void) {}

/* ── PIT → SDL ticks ─────────────────────────────────────────────────────── */
/* We define 60 ticks per second to match bare-metal (PIT ~60Hz) */
void     pit_init(void) {}
uint32_t pit_ticks(void) {
    return (uint32_t)(SDL_GetTicks64() * 60 / 1000);
}
void pit_sleep(uint32_t ticks) {
    if (ticks > 0)
        SDL_Delay((Uint32)(ticks * 1000 / 60));
}

/* ── Keyboard ─────────────────────────────────────────────────────────────── */
/* key_state[0..255]: 1 = held.  Index is the momOS PS/2 scancode. */
static uint8_t key_state[256];
/* char ring buffer for kbd_getchar */
#define KBD_BUF 64
static char kbd_buf[KBD_BUF];
static int  kbd_head = 0, kbd_tail = 0;

void kbd_init(void) { memset(key_state, 0, sizeof key_state); }

char kbd_getchar(void) {
    if (kbd_head == kbd_tail) return 0;
    char c = kbd_buf[kbd_head];
    kbd_head = (kbd_head + 1) % KBD_BUF;
    return c;
}
int kbd_key_down(int scancode) {
    if (scancode < 0 || scancode > 255) return 0;
    return key_state[scancode];
}

/* SDL scancode → momOS PS/2 Set-1 scancode.
   Extended keys (E0-prefix in real PS/2) use momOS's 128+ range. */
static const uint16_t sdl_to_ps2[512] = {
    [4]  = 0x1E, /* A */  [5]  = 0x30, /* B */  [6]  = 0x2E, /* C */
    [7]  = 0x20, /* D */  [8]  = 0x12, /* E */  [9]  = 0x21, /* F */
    [10] = 0x22, /* G */  [11] = 0x23, /* H */  [12] = 0x17, /* I */
    [13] = 0x24, /* J */  [14] = 0x25, /* K */  [15] = 0x26, /* L */
    [16] = 0x32, /* M */  [17] = 0x31, /* N */  [18] = 0x18, /* O */
    [19] = 0x19, /* P */  [20] = 0x10, /* Q */  [21] = 0x13, /* R */
    [22] = 0x1F, /* S */  [23] = 0x14, /* T */  [24] = 0x16, /* U */
    [25] = 0x2F, /* V */  [26] = 0x11, /* W */  [27] = 0x2D, /* X */
    [28] = 0x15, /* Y */  [29] = 0x2C, /* Z */
    [30] = 0x02, /* 1 */  [31] = 0x03, /* 2 */  [32] = 0x04, /* 3 */
    [33] = 0x05, /* 4 */  [34] = 0x06, /* 5 */  [35] = 0x07, /* 6 */
    [36] = 0x08, /* 7 */  [37] = 0x09, /* 8 */  [38] = 0x0A, /* 9 */
    [39] = 0x0B, /* 0 */
    [40] = 0x1C, /* RETURN */   [41] = 0x01, /* ESCAPE */
    [42] = 0x0E, /* BACKSPACE */ [43] = 0x0F, /* TAB */
    [44] = 0x39, /* SPACE */    [45] = 0x0C, /* MINUS */
    [46] = 0x0D, /* EQUALS */
    [57] = 0x3A, /* CAPS */
    [58] = 0x3B, /* F1 */   [59] = 0x3C, /* F2 */  [60] = 0x3D, /* F3 */
    [61] = 0x3E, /* F4 */   [62] = 0x3F, /* F5 */  [63] = 0x40, /* F6 */
    [64] = 0x41, /* F7 */   [65] = 0x42, /* F8 */  [66] = 0x43, /* F9 */
    [67] = 0x44, /* F10 */
    /* Extended (128+) */
    [73] = 128 + 0x52, /* INSERT */  [74] = 128 + 0x47, /* HOME */
    [75] = 128 + 0x49, /* PGUP */    [76] = 128 + 0x53, /* DELETE */
    [77] = 128 + 0x4F, /* END */     [78] = 128 + 0x51, /* PGDN */
    [79] = 128 + 0x4D, /* RIGHT */   [80] = 128 + 0x4B, /* LEFT */
    [81] = 128 + 0x50, /* DOWN */    [82] = 128 + 0x48, /* UP */
    /* Modifiers */
    [224] = 0x1D, /* LCTRL */  [225] = 0x2A, /* LSHIFT */
    [226] = 0x38, /* LALT */   [228] = 0x1D, /* RCTRL  (same slot) */
    [229] = 0x36, /* RSHIFT */ [230] = 0x38, /* RALT   (same slot) */
};

/* Push one char into the keyboard ring buffer */
static void kbd_push(char c) {
    int next = (kbd_tail + 1) % KBD_BUF;
    if (next != kbd_head) {
        kbd_buf[kbd_tail] = c;
        kbd_tail = next;
    }
}

/* Called from hosted/main.c to feed SDL events into the HAL */
void hal_kbd_event(SDL_Keycode sym, SDL_Scancode scancode, int down) {
    /* Update key_state for input.key_down() polling */
    if (scancode < 512) {
        uint16_t ps2 = sdl_to_ps2[scancode];
        if (ps2 > 0 && ps2 < 256)
            key_state[ps2] = (uint8_t)down;
    }

    /* Inject character events for keys that SDL_TEXTINPUT never covers.
       This covers initial press AND auto-repeat (SDL sends KEYDOWN for both). */
    if (!down) return;
    switch (sym) {
    case SDLK_BACKSPACE: kbd_push('\b');   break;
    case SDLK_RETURN:
    case SDLK_KP_ENTER:  kbd_push('\n');   break;
    case SDLK_ESCAPE:    kbd_push('\x1b'); break;
    case SDLK_DELETE:    kbd_push('\x7f'); break;
    case SDLK_UP:        kbd_push('\x01'); break;
    case SDLK_DOWN:      kbd_push('\x02'); break;
    case SDLK_LEFT:      kbd_push('\x03'); break;
    case SDLK_RIGHT:     kbd_push('\x04'); break;
    case SDLK_TAB:
        /* Shift+Tab → \x19 (NAK, safe unused code)
           Plain Tab → \t   (filtered by hal_text_event anyway) */
        kbd_push(key_state[0x2A] || key_state[0x36] ? '\x19' : '\t');
        break;
    default: break;
    }
}

void hal_text_event(const char *text) {
    /* SDL_TEXTINPUT: filter out chars already injected by hal_kbd_event */
    for (; *text; text++) {
        unsigned char c = (unsigned char)*text;
        /* Skip control chars — they come from hal_kbd_event instead */
        if (c < 0x20 || c == 0x7F) continue;
        kbd_push((char)c);
    }
}

/* ── Mouse ───────────────────────────────────────────────────────────────── */
static int  ms_x = 320, ms_y = 240;
static uint8_t ms_btn[3];

void mouse_init(void) {}
int  mouse_x(void)       { return ms_x; }
int  mouse_y(void)       { return ms_y; }
int  mouse_btn(int b)    { return (b >= 0 && b < 3) ? ms_btn[b] : 0; }

void hal_mouse_move(int x, int y) { ms_x = x; ms_y = y; }
void hal_mouse_btn(int b, int down) {
    if (b >= 0 && b < 3) ms_btn[b] = (uint8_t)down;
}

/* ── Paging → no-op ──────────────────────────────────────────────────────── */
void paging_init(uint32_t fb_addr, uint32_t fb_size_bytes) {
    (void)fb_addr; (void)fb_size_bytes;
}
void paging_map_mmio(uint32_t phys_addr) { (void)phys_addr; }

/* ── Physical allocator → malloc-backed ─────────────────────────────────── */
#define PHYS_FAKE_TOTAL  (64 * 1024)   /* fake 64k pages = 256 MB */
static uint32_t phys_used = 0;

void     phys_init(uint32_t mmap_addr, uint32_t mmap_len, uint32_t kernel_end) {
    (void)mmap_addr; (void)mmap_len; (void)kernel_end;
}
void     phys_reserve(uint32_t start, uint32_t end) { (void)start; (void)end; }
uint32_t phys_alloc(void) {
    void *p = malloc(PAGE_SIZE);
    if (p) { phys_used++; return (uint32_t)(uintptr_t)p; }
    return 0;
}
uint32_t phys_alloc_contig(uint32_t n) {
    void *p = malloc((size_t)n * PAGE_SIZE);
    if (p) { phys_used += n; return (uint32_t)(uintptr_t)p; }
    return 0;
}
void     phys_free(uint32_t addr) { free((void *)(uintptr_t)addr); if (phys_used) phys_used--; }
uint32_t phys_free_count(void)    { return PHYS_FAKE_TOTAL - phys_used; }
uint32_t phys_total_count(void)   { return PHYS_FAKE_TOTAL; }

/* ── Heap → malloc ───────────────────────────────────────────────────────── */
void  heap_init(void)                           {}
void *kmalloc(uint32_t size)                    { return malloc(size); }
void *krealloc(void *ptr, uint32_t size)        { return realloc(ptr, size); }
void  kfree(void *ptr)                          { free(ptr); }

/* ── ACPI → SDL_Quit / exit ──────────────────────────────────────────────── */
void acpi_init(void)     {}
void acpi_shutdown(void) { SDL_Quit(); exit(0); }
void acpi_reboot(void)   { SDL_Quit(); exit(0); }

/* ── PC speaker → no-op ─────────────────────────────────────────────────── */
void pcspeaker_tone(uint32_t freq) { (void)freq; }

/* ── Audio backend flags ─────────────────────────────────────────────────── */
int ac97_present = 0;
int hda_present  = 0;

/* SDL audio callback: called by SDL audio thread */
static void sdl_audio_cb(void *userdata, Uint8 *stream, int len) {
    (void)userdata;
    audio_mix(stream, len);
}

int audio_init(void) {
    SDL_AudioSpec want = {0}, have = {0};
    want.freq     = AUDIO_SAMPLE_RATE;
    want.format   = AUDIO_U8;
    want.channels = 1;
    want.samples  = AUDIO_BUF_SAMPLES;
    want.callback = sdl_audio_cb;
    want.userdata = NULL;
    SDL_AudioDeviceID dev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
    if (dev == 0) {
        fprintf(stderr, "[AUDIO] SDL_OpenAudioDevice failed: %s\n", SDL_GetError());
        return 0;
    }
    SDL_PauseAudioDevice(dev, 0);
    fprintf(stderr, "[AUDIO] SDL audio started (%d Hz U8 mono)\n", have.freq);
    return 1;
}
/* Stub — bare-metal refill is driven by IRQ; SDL uses callback instead */
void audio_refill(void) {}

/* ── HDA stubs (called from audio_init fallback path) ───────────────────── */
int  hda_init(void)   { return 0; }
void hda_refill(void) {}

/* ── ATA stubs → disk.img file ───────────────────────────────────────────── */
static FILE    *disk_img   = NULL;
static uint32_t disk_sectors = 0;

int  ata_init(void) {
    disk_img = fopen("disk.img", "r+b");
    if (!disk_img) {
        fprintf(stderr, "[ATA] disk.img not found — disk disabled\n");
        return 0;
    }
    fseek(disk_img, 0, SEEK_END);
    long sz = ftell(disk_img);
    rewind(disk_img);
    disk_sectors = (uint32_t)(sz / 512);
    fprintf(stderr, "[ATA] disk.img: %u sectors\n", disk_sectors);
    return 1;
}
int  ata_read(int drv, uint32_t lba, uint32_t count, void *buf) {
    if (drv != 0 || !disk_img) return -1;
    if (fseek(disk_img, (long)(lba * 512), SEEK_SET) != 0) return -1;
    if (fread(buf, 512, count, disk_img) != count) return -1;
    return 0;
}
int  ata_write(int drv, uint32_t lba, uint32_t count, const void *buf) {
    if (drv != 0 || !disk_img) return -1;
    if (fseek(disk_img, (long)(lba * 512), SEEK_SET) != 0) return -1;
    if (fwrite(buf, 512, count, disk_img) != count) return -1;
    fflush(disk_img);
    return 0;
}
uint32_t ata_sector_count(int drv) {
    return (drv == 0) ? disk_sectors : 0;
}

/* ── disk.c logic duplicated here for hosted ─────────────────────────────── */
/* disk/disk.c uses ata_pio internally, so we just replicate the thin wrapper */
static int      disk_lfs_drive   = -1;
static uint32_t disk_lfs_lba     = 0;
static uint32_t disk_lfs_sectors = 0;

int disk_init(void) {
    if (!ata_init()) return 0;
    /* Read MBR */
    uint8_t mbr[512];
    if (ata_read(0, 0, 1, mbr) != 0) return 0;
    if (mbr[510] != 0x55 || mbr[511] != 0xAA) {
        fprintf(stderr, "[DISK] no valid MBR signature\n");
        return 0;
    }
    /* Scan 4 primary partitions */
    for (int i = 0; i < 4; i++) {
        uint8_t *entry = mbr + 446 + i * 16;
        uint8_t  type  = entry[4];
        if (type == DISK_PART_TYPE_LFS) {
            disk_lfs_lba     = *(uint32_t *)(entry + 8);
            disk_lfs_sectors = *(uint32_t *)(entry + 12);
            disk_lfs_drive   = 0;
            fprintf(stderr, "[DISK] LFS partition: LBA %u, %u sectors\n",
                    disk_lfs_lba, disk_lfs_sectors);
            return 1;
        }
    }
    fprintf(stderr, "[DISK] no LFS partition found\n");
    return 0;
}
int  disk_ready(void)  { return disk_lfs_drive >= 0; }
int  disk_drive(void)  { return disk_lfs_drive; }

int disk_lfs_read(void *buf, uint32_t byte_offset, uint32_t byte_count) {
    if (disk_lfs_drive < 0) return -1;
    uint32_t lba   = disk_lfs_lba + byte_offset / 512;
    uint32_t count = byte_count / 512;
    return ata_read(disk_lfs_drive, lba, count, buf);
}
int disk_lfs_write(const void *buf, uint32_t byte_offset, uint32_t byte_count) {
    if (disk_lfs_drive < 0) return -1;
    uint32_t lba   = disk_lfs_lba + byte_offset / 512;
    uint32_t count = byte_count / 512;
    return ata_write(disk_lfs_drive, lba, count, buf);
}
uint32_t disk_lfs_size(void) { return disk_lfs_sectors * 512; }
