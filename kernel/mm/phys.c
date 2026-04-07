#include "phys.h"
#include <stdint.h>

/* Supports up to 256 MB of physical RAM.
   One bit per 4 KB frame → 8 KB bitmap.
   0 = free, 1 = used. */

#define MAX_FRAMES  (256 * 1024 * 1024 / PAGE_SIZE)   /* 65536 */

static uint8_t  bitmap[MAX_FRAMES / 8];               /* 8 KB in BSS */
static uint32_t total_frames = 0;
static uint32_t free_count   = 0;

/* Multiboot1 mmap entry layout */
typedef struct {
    uint32_t size;
    uint64_t addr;
    uint64_t len;
    uint32_t type;
} __attribute__((packed)) mmap_entry_t;

static void frame_set(uint32_t frame) {
    bitmap[frame / 8] |= (uint8_t)(1 << (frame % 8));
}

static void frame_clear(uint32_t frame) {
    bitmap[frame / 8] &= (uint8_t)~(1 << (frame % 8));
}

static int frame_used(uint32_t frame) {
    return (bitmap[frame / 8] >> (frame % 8)) & 1;
}

void phys_init(uint32_t mmap_addr, uint32_t mmap_len, uint32_t kernel_end) {
    /* Start with everything marked used */
    for (uint32_t i = 0; i < MAX_FRAMES / 8; i++) bitmap[i] = 0xFF;

    /* Walk the multiboot memory map and free usable regions */
    uint32_t off = 0;
    while (off < mmap_len) {
        mmap_entry_t *e = (mmap_entry_t *)(mmap_addr + off);

        if (e->type == 1) { /* available */
            /* Only handle the low 32-bit address space */
            if (e->addr < 0x100000000ULL) {
                uint32_t base = (uint32_t)e->addr;
                uint32_t len  = (e->addr + e->len > 0x100000000ULL)
                                ? (uint32_t)(0x100000000ULL - e->addr)
                                : (uint32_t)e->len;

                uint32_t first = (base + PAGE_SIZE - 1) / PAGE_SIZE;
                uint32_t last  = (base + len) / PAGE_SIZE;

                for (uint32_t f = first; f < last && f < MAX_FRAMES; f++) {
                    frame_clear(f);
                    free_count++;
                    if (f + 1 > total_frames) total_frames = f + 1;
                }
            }
        }

        off += e->size + 4;
    }

    /* Re-mark frame 0 (NULL page) as used */
    if (!frame_used(0)) { frame_set(0); free_count--; }

    /* Re-mark kernel frames as used (physical 0 → kernel_end) */
    uint32_t kframes = (kernel_end + PAGE_SIZE - 1) / PAGE_SIZE;
    for (uint32_t f = 0; f < kframes && f < MAX_FRAMES; f++) {
        if (!frame_used(f)) { frame_set(f); free_count--; }
    }
}

uint32_t phys_alloc(void) {
    for (uint32_t f = 1; f < total_frames; f++) {
        if (!frame_used(f)) {
            frame_set(f);
            free_count--;
            return f * PAGE_SIZE;
        }
    }
    return 0; /* out of memory */
}

void phys_reserve(uint32_t start, uint32_t end) {
    uint32_t first = start / PAGE_SIZE;
    uint32_t last  = (end + PAGE_SIZE - 1) / PAGE_SIZE;
    for (uint32_t f = first; f < last && f < MAX_FRAMES; f++) {
        if (!frame_used(f)) { frame_set(f); free_count--; }
    }
}

void phys_free(uint32_t addr) {
    uint32_t f = addr / PAGE_SIZE;
    if (f < MAX_FRAMES && frame_used(f)) {
        frame_clear(f);
        free_count++;
    }
}

uint32_t phys_free_count(void)  { return free_count;   }
uint32_t phys_total_count(void) { return total_frames;  }
