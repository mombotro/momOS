#pragma once
#include <stdint.h>

void     pit_init(void);
uint32_t pit_ticks(void);
void     pit_sleep(uint32_t ticks);
