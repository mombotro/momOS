#include <stdint.h>
#include "cpu/serial.h"
#include "cpu/gdt.h"
#include "cpu/idt.h"
#include "cpu/pit.h"
#include "cpu/keyboard.h"
#include "cpu/mouse.h"
#include "mm/phys.h"
#include "mm/paging.h"
#include "mm/heap.h"
#include "vfs/vfs.h"
#include "lua/klua.h"

/* Exported by linker script */
extern uint32_t _kernel_end;

/* ── Multiboot1 info structure ───────────────────────────────────────────────*/
typedef struct {
    uint32_t flags;
    uint32_t mem_lower;
    uint32_t mem_upper;
    uint32_t boot_device;
    uint32_t cmdline;
    uint32_t mods_count;
    uint32_t mods_addr;
    uint8_t  syms[16];
    uint32_t mmap_length;
    uint32_t mmap_addr;
    uint32_t drives_length;
    uint32_t drives_addr;
    uint32_t config_table;
    uint32_t boot_loader_name;
    uint32_t apm_table;
    uint32_t vbe_control_info;
    uint32_t vbe_mode_info;
    uint16_t vbe_mode;
    uint16_t vbe_interface_seg;
    uint16_t vbe_interface_off;
    uint16_t vbe_interface_len;
    uint64_t fb_addr;
    uint32_t fb_pitch;
    uint32_t fb_width;
    uint32_t fb_height;
    uint8_t  fb_bpp;
    uint8_t  fb_type;
    uint8_t  color_info[6];
} __attribute__((packed)) mb1_info_t;

/* Multiboot1 mmap entry */
typedef struct {
    uint32_t size;
    uint64_t addr;
    uint64_t len;
    uint32_t type; /* 1 = available */
} __attribute__((packed)) mb1_mmap_t;

/* Multiboot1 module entry */
typedef struct {
    uint32_t mod_start;
    uint32_t mod_end;
    uint32_t cmdline;
    uint32_t reserved;
} __attribute__((packed)) mb1_mod_t;

#define MB1_FLAG_MODS (1 << 3)
#define MB1_FLAG_MMAP (1 << 6)
#define MB1_FLAG_FB   (1 << 12)

/* ── Framebuffer globals ─────────────────────────────────────────────────────*/
static uint8_t  *fb       = 0;
static uint32_t  fb_w     = 0;
static uint32_t  fb_h     = 0;
static uint32_t  fb_pitch = 0;

/* Back buffer — draw here, blit to fb once per frame to eliminate flicker */
static uint32_t backbuf[640 * 480];

/* ── momOS 32-color palette ──────────────────────────────────────────────────*/
static const uint32_t pal[32] = {
    0x1a1a2e, 0x16213e, 0x0f3460, 0x533483,
    0xe94560, 0xff6b9d, 0xffb3c6, 0xffffff,
    0xc0c0c0, 0x808080, 0x404040, 0x000000,
    0xff4444, 0xff8800, 0xffdd00, 0x88cc00,
    0x00cc44, 0x00ccaa, 0x00aaff, 0x0055ff,
    0x6600ff, 0xcc00ff, 0xff00aa, 0xff6666,
    0xffcc99, 0xffff99, 0x99ff99, 0x99ffff,
    0x99ccff, 0xcc99ff, 0x663300, 0x336600,
};

/* ── Drawing (into back buffer) ──────────────────────────────────────────────*/
static void pset(int x, int y, uint32_t color) {
    if ((uint32_t)x >= fb_w || (uint32_t)y >= fb_h) return;
    backbuf[y * fb_w + x] = color;
}

static void rect(int x, int y, int w, int h, uint32_t color) {
    for (int row = y; row < y + h; row++)
        for (int col = x; col < x + w; col++)
            pset(col, row, color);
}

static void cls(uint32_t color) {
    uint32_t total = fb_w * fb_h;
    for (uint32_t i = 0; i < total; i++) backbuf[i] = color;
}

/* Blit back buffer to real framebuffer in one shot */
static void present(void) {
    for (uint32_t y = 0; y < fb_h; y++) {
        uint32_t *dst = (uint32_t *)(fb + y * fb_pitch);
        uint32_t *src = backbuf + y * fb_w;
        for (uint32_t x = 0; x < fb_w; x++) dst[x] = src[x];
    }
}


/* ── VGA text fallback ───────────────────────────────────────────────────────*/
static void vga_print(const char *s) {
    volatile uint16_t *vga = (volatile uint16_t *)0xB8000;
    for (int i = 0; s[i]; i++)
        vga[i] = (uint16_t)(uint8_t)s[i] | 0x0F00;
}

/* ── Memory map dump ─────────────────────────────────────────────────────────*/
static void print_mmap(mb1_info_t *mb) {
    if (!(mb->flags & MB1_FLAG_MMAP)) {
        serial_puts("  (no mmap provided)\n");
        return;
    }
    uint32_t off = 0;
    while (off < mb->mmap_length) {
        mb1_mmap_t *e = (mb1_mmap_t *)(mb->mmap_addr + off);
        serial_puts("  base=");
        serial_hex((uint32_t)(e->addr >> 32)); serial_puts("_");
        serial_hex((uint32_t)e->addr);
        serial_puts(" len=");
        serial_hex((uint32_t)(e->len >> 32)); serial_puts("_");
        serial_hex((uint32_t)e->len);
        serial_puts(e->type == 1 ? "  [free]\n" : "  [reserved]\n");
        off += e->size + 4;
    }
}

static void vfs_print_entry(const vfs_dirent_t *e, void *ud) {
    (void)ud;
    serial_puts(e->is_dir ? "  DIR  " : "  FILE ");
    serial_puts(e->name);
    serial_puts("\n");
}

/* ── Kernel entry ────────────────────────────────────────────────────────────*/
void kernel_main(uint32_t magic, mb1_info_t *mb) {
    serial_init();
    serial_puts("\n=== momOS booting ===\n");

    if (magic != 0x2BADB002) {
        serial_puts("BAD MULTIBOOT MAGIC\n");
        vga_print("BAD MAGIC");
        return;
    }

    gdt_init();
    serial_puts("[GDT] loaded\n");

    idt_init();
    serial_puts("[IDT] loaded\n");

    __asm__ volatile ("sti");
    serial_puts("[CPU] interrupts enabled\n");

    pit_init();
    kbd_init();
    serial_puts("[KBD] ready\n");
    mouse_init();
    serial_puts("[MOUSE] ready\n");

    serial_puts("[MMAP]\n");
    print_mmap(mb);

    /* Physical memory allocator */
    if (mb->flags & MB1_FLAG_MMAP) {
        phys_init(mb->mmap_addr, mb->mmap_length, (uint32_t)&_kernel_end);

        /* Reserve multiboot modules so heap_alloc can't clobber them */
        if ((mb->flags & MB1_FLAG_MODS) && mb->mods_count > 0) {
            mb1_mod_t *mods = (mb1_mod_t *)mb->mods_addr;
            for (uint32_t i = 0; i < mb->mods_count; i++)
                phys_reserve(mods[i].mod_start, mods[i].mod_end);
        }

        serial_puts("[PHYS] ");
        serial_hex(phys_free_count() * PAGE_SIZE / 1024 / 1024);
        serial_puts(" MB free / ");
        serial_hex(phys_total_count() * PAGE_SIZE / 1024 / 1024);
        serial_puts(" MB total\n");
    }

    if (!mb || !(mb->flags & MB1_FLAG_FB) || mb->fb_type != 1) {
        serial_puts("[FB] not provided by bootloader\n");
        vga_print("NO FRAMEBUFFER");
        return;
    }

    fb       = (uint8_t *)(uintptr_t)mb->fb_addr;
    fb_w     = mb->fb_width;
    fb_h     = mb->fb_height;
    fb_pitch = mb->fb_pitch;

    /* Paging (identity map 0–64 MB + framebuffer) */
    paging_init((uint32_t)mb->fb_addr, fb_w * fb_h * (mb->fb_bpp / 8));

    /* Kernel heap */
    heap_init();

    /* Mount initrd (first multiboot module) */
    if ((mb->flags & MB1_FLAG_MODS) && mb->mods_count > 0) {
        mb1_mod_t *mod = (mb1_mod_t *)mb->mods_addr;
        uint32_t size = mod->mod_end - mod->mod_start;
        vfs_init(mod->mod_start, size);
    } else {
        serial_puts("[VFS] no initrd module\n");
    }

    serial_puts("[FB] ");
    serial_hex(fb_w); serial_puts("x");
    serial_hex(fb_h); serial_puts(" @ ");
    serial_hex((uint32_t)mb->fb_addr);
    serial_puts("\n");

    /* Quick VFS smoke test — list root */
    serial_puts("[VFS] root:\n");
    vfs_list("/", vfs_print_entry, 0);

    /* Lua VM */
    klua_init(backbuf, fb_w, fb_h, pal);

    /* Load and run main script from initrd */
    char *script = vfs_read_alloc("/sys/main.lua");
    if (script) {
        serial_puts("[LUA] running /sys/main.lua\n");
        klua_run(script);
        kfree(script);
    } else {
        serial_puts("[LUA] /sys/main.lua not found\n");
    }

    serial_puts("=== boot OK ===\n");

    while (1) {
        klua_call("_update");
        klua_call("_draw");
        present();
        pit_sleep(1);
    }
}
