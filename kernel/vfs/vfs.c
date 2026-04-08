#include "vfs.h"
#include "lfs_format.h"
#include "../cpu/serial.h"
#include "../mm/heap.h"
#include <stdint.h>

/* ── Internal state ─────────────────────────────────────────────────────────*/
static uint8_t      *lfs_base  = 0;
static lfs_super_t  *sb        = 0;
static lfs_inode_t  *inode_tbl = 0;  /* pointer into image */
static uint32_t      inode_cnt = 0;

struct vfs_file {
    lfs_inode_t *inode;
};

/* ── Low-level helpers ──────────────────────────────────────────────────────*/
static void *block_ptr(uint32_t blk) {
    return lfs_base + blk * LFS_BLOCK_SIZE;
}

static lfs_inode_t *get_inode(uint32_t idx) {
    if (idx >= inode_cnt) return 0;
    return &inode_tbl[idx];
}

/* Simple strcmp / strncmp for freestanding environment */
static int kstrcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

static uint32_t kstrlen(const char *s) {
    uint32_t n = 0; while (s[n]) n++; return n;
}

/* ── Init ───────────────────────────────────────────────────────────────────*/
void vfs_init(uint32_t lfs_phys_addr, uint32_t lfs_size) {
    /* Copy image into heap so future kmalloc can't overwrite the initrd */
    lfs_base = (uint8_t *)kmalloc(lfs_size);
    if (!lfs_base) { serial_puts("[VFS] out of memory\n"); return; }
    uint8_t *src = (uint8_t *)lfs_phys_addr;
    for (uint32_t i = 0; i < lfs_size; i++) lfs_base[i] = src[i];
    sb        = (lfs_super_t *)lfs_base;

    if (sb->magic[0] != 'L' || sb->magic[1] != 'F' ||
        sb->magic[2] != 'S' || sb->magic[3] != '!') {
        serial_puts("[VFS] bad LFS magic\n");
        return;
    }

    inode_tbl = (lfs_inode_t *)(lfs_base + sb->inode_table_start * LFS_BLOCK_SIZE);
    inode_cnt = sb->inode_count;

    serial_puts("[VFS] LFS mounted — ");
    serial_hex(inode_cnt);
    serial_puts(" inodes, data @ block ");
    serial_hex(sb->data_start);
    serial_puts("\n");
}

/* ── Path resolution ────────────────────────────────────────────────────────*/
/* Find the inode for a path component `name` whose parent is `parent_idx`.
   Returns inode index or (uint32_t)-1 if not found. */
static uint32_t find_child(uint32_t parent_idx, const char *name) {
    for (uint32_t i = 0; i < inode_cnt; i++) {
        lfs_inode_t *n = get_inode(i);
        if (!n || n->type == LFS_TYPE_FREE) continue;
        if (n->parent == parent_idx && kstrcmp(n->name, name) == 0)
            return i;
    }
    return (uint32_t)-1;
}

/* Walk an absolute path and return the inode index, or -1 */
static uint32_t resolve(const char *path) {
    if (!path || path[0] != '/') return (uint32_t)-1;

    uint32_t cur = 0; /* start at root inode (index 0) */
    path++;           /* skip leading '/' */

    while (*path) {
        /* Extract next component */
        char component[VFS_MAX_NAME];
        uint32_t i = 0;
        while (*path && *path != '/' && i < VFS_MAX_NAME - 1)
            component[i++] = *path++;
        component[i] = '\0';
        if (*path == '/') path++;
        if (i == 0) continue; /* skip double slashes */

        cur = find_child(cur, component);
        if (cur == (uint32_t)-1) return (uint32_t)-1;
    }
    return cur;
}

/* ── Public API ─────────────────────────────────────────────────────────────*/
vfs_file_t *vfs_open(const char *path) {
    uint32_t idx = resolve(path);
    if (idx == (uint32_t)-1) return 0;
    lfs_inode_t *n = get_inode(idx);
    if (!n || n->type != LFS_TYPE_FILE) return 0;

    vfs_file_t *f = (vfs_file_t *)kmalloc(sizeof(vfs_file_t));
    if (!f) return 0;
    f->inode = n;
    return f;
}

uint32_t vfs_read(vfs_file_t *f, uint32_t offset, void *buf, uint32_t len) {
    if (!f || !buf) return 0;
    lfs_inode_t *n = f->inode;
    if (offset >= n->size) return 0;
    if (offset + len > n->size) len = n->size - offset;

    uint8_t *dst = (uint8_t *)buf;
    uint32_t read = 0;

    while (read < len) {
        uint32_t file_off  = offset + read;
        uint32_t blk_idx   = file_off / LFS_BLOCK_SIZE;
        uint32_t blk_off   = file_off % LFS_BLOCK_SIZE;
        uint32_t chunk     = LFS_BLOCK_SIZE - blk_off;
        if (chunk > len - read) chunk = len - read;

        uint32_t abs_blk;
        if (blk_idx < LFS_DIRECT) {
            abs_blk = n->direct[blk_idx];
        } else {
            /* Single indirect */
            uint32_t ind_idx = blk_idx - LFS_DIRECT;
            if (!n->indirect) break;
            uint32_t *ind_tbl = (uint32_t *)block_ptr(n->indirect);
            abs_blk = ind_tbl[ind_idx];
        }

        if (!abs_blk) break;
        uint8_t *src = (uint8_t *)block_ptr(abs_blk) + blk_off;
        for (uint32_t i = 0; i < chunk; i++) dst[read + i] = src[i];
        read += chunk;
    }
    return read;
}

uint32_t vfs_size(vfs_file_t *f) {
    return f ? f->inode->size : 0;
}

void vfs_close(vfs_file_t *f) {
    kfree(f);
}

char *vfs_read_alloc(const char *path) {
    vfs_file_t *f = vfs_open(path);
    if (!f) return 0;
    uint32_t sz = vfs_size(f);
    char *buf = (char *)kmalloc(sz + 1);
    if (!buf) { vfs_close(f); return 0; }
    vfs_read(f, 0, buf, sz);
    buf[sz] = '\0';
    vfs_close(f);
    return buf;
}

int vfs_list(const char *path,
             void (*cb)(const vfs_dirent_t *e, void *ud),
             void *userdata) {
    uint32_t dir_idx;

    /* Root is a special case */
    if (kstrlen(path) == 1 && path[0] == '/') {
        dir_idx = 0;
    } else {
        dir_idx = resolve(path);
        if (dir_idx == (uint32_t)-1) return -1;
        lfs_inode_t *d = get_inode(dir_idx);
        if (!d || d->type != LFS_TYPE_DIR) return -1;
    }

    int count = 0;
    for (uint32_t i = 0; i < inode_cnt; i++) {
        lfs_inode_t *n = get_inode(i);
        if (!n || n->type == LFS_TYPE_FREE) continue;
        if (n->parent != dir_idx || i == dir_idx) continue; /* skip self */

        vfs_dirent_t e;
        for (uint32_t j = 0; j < VFS_MAX_NAME - 1; j++) {
            e.name[j] = n->name[j];
            if (!n->name[j]) break;
        }
        e.name[VFS_MAX_NAME - 1] = '\0';
        e.size   = n->size;
        e.is_dir = (n->type == LFS_TYPE_DIR);
        cb(&e, userdata);
        count++;
    }
    return count;
}
