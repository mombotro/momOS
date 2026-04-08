#include "heap.h"
#include "phys.h"
#include "../cpu/serial.h"
#include <stdint.h>

/* Simple free-list heap.
   The heap lives in the identity-mapped region (physical = virtual).
   It starts right after the kernel at HEAP_BASE and grows page by page
   as needed, up to HEAP_MAX. */

#define HEAP_BASE  0x00800000u   /* 8 MB physical — well above any kernel BSS  */
#define HEAP_MAX   0x04000000u   /* 64 MB ceiling (stays in our identity map)  */
#define ALIGN8(n)  (((n) + 7u) & ~7u)

typedef struct block {
    uint32_t      size;   /* usable bytes after header */
    uint32_t      used;   /* 1 = allocated, 0 = free   */
    struct block *next;   /* next block in list         */
} block_t;

static block_t *heap_head = 0;
static uint32_t heap_top  = HEAP_BASE;  /* next uncommitted address */

/* Expand the heap by at least `need` bytes, returns 1 on success */
static int heap_expand(uint32_t need) {
    uint32_t pages = (need + PAGE_SIZE - 1) / PAGE_SIZE;
    for (uint32_t i = 0; i < pages; i++) {
        if (heap_top + PAGE_SIZE > HEAP_MAX) return 0;
        uint32_t frame = phys_alloc();
        if (!frame) return 0;
        /* Since we identity-map, physical == virtual here.
           The frame address must match heap_top — enforce this by only
           expanding into frames at the expected address. */
        if (frame != heap_top) {
            /* Frame address mismatch: this shouldn't happen in the identity-
               mapped region if phys_alloc scans upward, but handle gracefully */
            phys_free(frame);
            return 0;
        }
        heap_top += PAGE_SIZE;
    }
    return 1;
}

void heap_init(void) {
    /* Pre-commit one page so there is always at least one block */
    uint32_t frame = phys_alloc();
    if (!frame) return; /* out of memory at boot — fatal */

    heap_top = frame + PAGE_SIZE;
    heap_head = (block_t *)frame;
    heap_head->size = PAGE_SIZE - sizeof(block_t);
    heap_head->used = 0;
    heap_head->next = 0;

    serial_puts("[HEAP] init @ ");
    serial_hex(frame);
    serial_puts("\n");
}

void *kmalloc(uint32_t size) {
    if (!size) return 0;
    size = ALIGN8(size);

    /* First-fit search */
    block_t *b = heap_head;
    while (b) {
        if (!b->used && b->size >= size) {
            /* Split if there is room for another header + at least 8 bytes */
            if (b->size >= size + sizeof(block_t) + 8) {
                block_t *split = (block_t *)((uint8_t *)b + sizeof(block_t) + size);
                split->size = b->size - size - sizeof(block_t);
                split->used = 0;
                split->next = b->next;
                b->next = split;
                b->size = size;
            }
            b->used = 1;
            return (void *)((uint8_t *)b + sizeof(block_t));
        }
        b = b->next;
    }

    /* No suitable block — expand the heap */
    uint32_t need = sizeof(block_t) + size;
    if (!heap_expand(need)) return 0;

    block_t *nb = (block_t *)(heap_top - PAGE_SIZE * ((need + PAGE_SIZE - 1) / PAGE_SIZE));
    /* Walk to end of list and append */
    block_t *tail = heap_head;
    while (tail->next) tail = tail->next;

    if (!tail->used && (uint8_t *)tail + sizeof(block_t) + tail->size == (uint8_t *)nb) {
        /* Merge with tail */
        tail->size += sizeof(block_t) + nb->size;
        return kmalloc(size); /* retry — tail now has space */
    }

    nb->size = (PAGE_SIZE * ((need + PAGE_SIZE - 1) / PAGE_SIZE)) - sizeof(block_t);
    nb->used = 0;
    nb->next = 0;
    tail->next = nb;
    return kmalloc(size);
}

void *krealloc(void *ptr, uint32_t size) {
    if (!ptr) return kmalloc(size);
    if (!size) { kfree(ptr); return 0; }
    block_t *b = (block_t *)((uint8_t *)ptr - sizeof(block_t));
    if (b->size >= size) return ptr; /* already big enough */
    void *newp = kmalloc(size);
    if (!newp) return 0;
    uint32_t copy = b->size < size ? b->size : size;
    for (uint32_t i = 0; i < copy; i++)
        ((uint8_t *)newp)[i] = ((uint8_t *)ptr)[i];
    kfree(ptr);
    return newp;
}

void kfree(void *ptr) {
    if (!ptr) return;
    block_t *b = (block_t *)((uint8_t *)ptr - sizeof(block_t));
    b->used = 0;

    /* Coalesce with next block if it is also free */
    while (b->next && !b->next->used) {
        b->size += sizeof(block_t) + b->next->size;
        b->next  = b->next->next;
    }
}
