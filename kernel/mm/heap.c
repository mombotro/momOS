#include "heap.h"
#include "phys.h"
#include "../cpu/serial.h"
#include <stdint.h>

/* Simple free-list heap.
   The heap lives in the identity-mapped region (physical = virtual).
   It starts right after the kernel at HEAP_BASE and grows page by page
   as needed, up to HEAP_MAX. */

#define ALIGN8(n)  (((n) + 7u) & ~7u)

typedef struct block {
    uint32_t      size;   /* usable bytes after header */
    uint32_t      used;   /* 1 = allocated, 0 = free   */
    struct block *next;   /* next block in list         */
} block_t;

static block_t *heap_head = 0;

void heap_init(void) {
    uint32_t frame = phys_alloc();
    if (!frame) return;
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

    /* No suitable block — allocate contiguous pages anywhere in physical RAM */
    uint32_t need  = sizeof(block_t) + size;
    uint32_t pages = (need + PAGE_SIZE - 1) / PAGE_SIZE;
    uint32_t base  = phys_alloc_contig(pages);
    if (!base) return 0;

    block_t *nb = (block_t *)base;
    nb->size = pages * PAGE_SIZE - sizeof(block_t);
    nb->used = 0;
    nb->next = 0;

    /* Append to free list (merge with tail if physically adjacent) */
    block_t *tail = heap_head;
    while (tail->next) tail = tail->next;
    if (!tail->used &&
        (uint8_t *)tail + sizeof(block_t) + tail->size == (uint8_t *)nb) {
        tail->size += sizeof(block_t) + nb->size;
    } else {
        tail->next = nb;
    }
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
