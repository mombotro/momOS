#pragma once
#include <stdint.h>

#define PAGE_SIZE 4096

void     phys_init(uint32_t mmap_addr, uint32_t mmap_len, uint32_t kernel_end);
void     phys_reserve(uint32_t start, uint32_t end); /* mark range as used */
uint32_t phys_alloc(void);          /* one free frame → physical address, or 0 */
void     phys_free(uint32_t addr);
uint32_t phys_free_count(void);
uint32_t phys_total_count(void);
