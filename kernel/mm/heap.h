#pragma once
#include <stdint.h>

void  heap_init(void);
void *kmalloc(uint32_t size);
void  kfree(void *ptr);
