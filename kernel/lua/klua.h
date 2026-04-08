#pragma once
#include <stdint.h>

/* Initialise Lua subsystem.
   fb        : pointer to the 32-bit back buffer (640×480 uint32_t array)
   fb_w/fb_h : framebuffer dimensions
   pal       : 32-color palette array                                  */
void klua_init(uint32_t *fb, uint32_t fb_w, uint32_t fb_h,
               const uint32_t *pal);

/* Run a Lua script from a NUL-terminated string.
   Returns 0 on success, non-zero on error. */
int klua_run(const char *script);

/* Call the Lua global function `name` with no args/return values.
   Returns 0 on success. */
int klua_call(const char *name);
