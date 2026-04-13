#pragma once
#include <stdint.h>

void paging_init(uint32_t fb_addr, uint32_t fb_size_bytes);

/* Map a 4 MB region containing phys_addr as uncached MMIO.
   Call after paging_init() when a new device MMIO BAR is discovered. */
void paging_map_mmio(uint32_t phys_addr);
