#pragma once
#include <stdint.h>

void mouse_init(void);

/* Current mouse state — call after each IRQ cycle */
int  mouse_x(void);
int  mouse_y(void);
int  mouse_btn(int b);   /* b=0 left, b=1 right, b=2 middle */
