#include "paging.h"
#include "phys.h"
#include "../cpu/serial.h"
#include <stdint.h>

/* Page directory lives in BSS — must be 4 KB aligned */
static uint32_t page_dir[1024] __attribute__((aligned(4096)));

/* Flags for 4 MB PSE pages */
#define PDE_PRESENT  (1 << 0)
#define PDE_WRITABLE (1 << 1)
#define PDE_4MB      (1 << 7)

/* Identity-map a 4 MB region starting at phys_base using a single PDE */
static void map_4mb(uint32_t phys_base, uint32_t flags) {
    uint32_t pde_idx = phys_base >> 22;
    page_dir[pde_idx] = phys_base | flags | PDE_4MB | PDE_PRESENT;
}

void paging_init(uint32_t fb_addr, uint32_t fb_size_bytes) {
    /* Clear page directory */
    for (int i = 0; i < 1024; i++) page_dir[i] = 0;

    /* Enable PSE (4 MB pages) in CR4 */
    __asm__ volatile (
        "mov %%cr4, %%eax\n"
        "or  $0x10,  %%eax\n"
        "mov %%eax, %%cr4\n"
        : : : "eax"
    );

    /* Identity-map from 0 to 64 MB (kernel + heap + buffers) */
    for (uint32_t addr = 0; addr < 64 * 1024 * 1024; addr += 4 * 1024 * 1024)
        map_4mb(addr, PDE_WRITABLE);

    /* Map framebuffer region (round down to 4 MB boundary) */
    if (fb_addr) {
        uint32_t fb_start = fb_addr & ~((4 * 1024 * 1024) - 1);
        uint32_t fb_end   = fb_addr + fb_size_bytes;
        for (uint32_t a = fb_start; a < fb_end; a += 4 * 1024 * 1024)
            map_4mb(a, PDE_WRITABLE);
    }

    /* Load CR3 and enable paging in CR0 */
    __asm__ volatile (
        "mov %0,    %%cr3\n"
        "mov %%cr0, %%eax\n"
        "or  $0x80000000, %%eax\n"
        "mov %%eax, %%cr0\n"
        : : "r"((uint32_t)page_dir) : "eax"
    );

    serial_puts("[PAGING] enabled (identity 0-64MB");
    if (fb_addr) serial_puts(" + FB");
    serial_puts(")\n");
}
