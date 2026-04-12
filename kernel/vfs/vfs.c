#include "vfs.h"
#include "lfs_format.h"
#include "../cpu/serial.h"
#include "../mm/heap.h"
#include <stdint.h>

/* ── Internal state ─────────────────────────────────────────────────────────*/
static uint8_t      *lfs_base   = 0;
static lfs_super_t  *sb         = 0;
static lfs_inode_t  *inode_tbl  = 0;  /* pointer into image */
static uint32_t      inode_cnt  = 0;
static uint32_t      lfs_cap_blocks = 0; /* actual blocks in our buffer */

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
    /* Use the physical address directly — initrd is already protected by
       phys_reserve so the heap allocator will never touch those frames. */
    if (lfs_size < LFS_BLOCK_SIZE) { serial_puts("[VFS] image too small\n"); return; }
    lfs_base       = (uint8_t *)lfs_phys_addr;
    lfs_cap_blocks = lfs_size / LFS_BLOCK_SIZE;
    sb             = (lfs_super_t *)lfs_base;

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

/* ── Image accessors ────────────────────────────────────────────────────────*/
void *vfs_get_base(void) { return lfs_base; }
uint32_t vfs_get_size(void) { return lfs_cap_blocks * LFS_BLOCK_SIZE; }

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

/* ── Write helpers ──────────────────────────────────────────────────────────*/

/* Returns 1 if block blk is referenced by any inode */
static int block_in_use(uint32_t blk) {
    if (blk < sb->data_start) return 1;
    for (uint32_t i = 0; i < inode_cnt; i++) {
        lfs_inode_t *n = &inode_tbl[i];
        if (n->type == LFS_TYPE_FREE) continue;
        for (int j = 0; j < LFS_DIRECT; j++)
            if (n->direct[j] == blk) return 1;
        if (n->indirect == blk) return 1;
        if (n->indirect) {
            uint32_t *ind = (uint32_t *)block_ptr(n->indirect);
            uint32_t entries = LFS_BLOCK_SIZE / sizeof(uint32_t);
            for (uint32_t k = 0; k < entries; k++)
                if (ind[k] == blk) return 1;
        }
    }
    return 0;
}

static uint32_t alloc_block(void) {
    for (uint32_t b = sb->data_start; b < lfs_cap_blocks; b++)
        if (!block_in_use(b)) return b;
    return 0;
}

static uint32_t alloc_inode(void) {
    for (uint32_t i = 1; i < inode_cnt; i++)
        if (inode_tbl[i].type == LFS_TYPE_FREE) return i;
    return (uint32_t)-1;
}

static void free_inode_blocks(lfs_inode_t *n) {
    for (int j = 0; j < LFS_DIRECT; j++) {
        if (!n->direct[j]) continue;
        uint8_t *b = (uint8_t *)block_ptr(n->direct[j]);
        for (int k = 0; k < LFS_BLOCK_SIZE; k++) b[k] = 0;
        n->direct[j] = 0;
    }
    if (n->indirect) {
        uint32_t *ind = (uint32_t *)block_ptr(n->indirect);
        uint32_t entries = LFS_BLOCK_SIZE / sizeof(uint32_t);
        for (uint32_t k = 0; k < entries; k++) {
            if (!ind[k]) continue;
            uint8_t *b = (uint8_t *)block_ptr(ind[k]);
            for (int m = 0; m < LFS_BLOCK_SIZE; m++) b[m] = 0;
            ind[k] = 0;
        }
        uint8_t *ib = (uint8_t *)block_ptr(n->indirect);
        for (int k = 0; k < LFS_BLOCK_SIZE; k++) ib[k] = 0;
        n->indirect = 0;
    }
}

/* Split "/a/b/c" → parent="/a/b", name="c". Returns 0 on success. */
static int split_path(const char *path,
                      char *parent_out, char *name_out) {
    uint32_t len = kstrlen(path);
    if (!len || path[0] != '/') return -1;
    int last = -1;
    for (uint32_t i = 0; i < len; i++)
        if (path[i] == '/') last = (int)i;
    if (last < 0) return -1;
    uint32_t nlen = len - (uint32_t)last - 1;
    if (nlen == 0 || nlen >= VFS_MAX_NAME) return -1;
    if (last == 0) { parent_out[0] = '/'; parent_out[1] = '\0'; }
    else { for (int i = 0; i < last; i++) parent_out[i] = path[i]; parent_out[last] = '\0'; }
    for (uint32_t i = 0; i < nlen; i++) name_out[i] = path[last + 1 + i];
    name_out[nlen] = '\0';
    return 0;
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

int vfs_exists(const char *path) {
    return resolve(path) != (uint32_t)-1;
}

int vfs_mkdir(const char *path) {
    if (!path || !sb) return -1;
    char parent[VFS_MAX_PATH], name[VFS_MAX_NAME];
    if (split_path(path, parent, name) < 0) return -1;

    uint32_t parent_idx = (parent[0]=='/' && parent[1]=='\0') ? 0 : resolve(parent);
    if (parent_idx == (uint32_t)-1) return -1;
    if (find_child(parent_idx, name) != (uint32_t)-1) return -1; /* already exists */

    uint32_t idx = alloc_inode();
    if (idx == (uint32_t)-1) return -1;
    lfs_inode_t *n = &inode_tbl[idx];
    n->type     = LFS_TYPE_DIR;
    n->parent   = parent_idx;
    n->size     = 0;
    n->indirect = 0;
    for (int j = 0; j < LFS_DIRECT; j++) n->direct[j] = 0;
    uint32_t nlen = kstrlen(name);
    for (uint32_t i = 0; i <= nlen; i++) n->name[i] = name[i];
    return 0;
}

int vfs_write(const char *path, const void *data, uint32_t len) {
    if (!path || !sb) return -1;
    char parent[VFS_MAX_PATH], name[VFS_MAX_NAME];
    if (split_path(path, parent, name) < 0) return -1;

    uint32_t parent_idx = (parent[0]=='/' && parent[1]=='\0') ? 0 : resolve(parent);
    if (parent_idx == (uint32_t)-1) return -1;

    /* Find or create inode */
    uint32_t existing = find_child(parent_idx, name);
    lfs_inode_t *n;
    if (existing != (uint32_t)-1) {
        n = get_inode(existing);
        if (!n || n->type != LFS_TYPE_FILE) return -1;
        free_inode_blocks(n);
    } else {
        uint32_t idx = alloc_inode();
        if (idx == (uint32_t)-1) return -1;
        n = &inode_tbl[idx];
        n->type     = LFS_TYPE_FILE;
        n->parent   = parent_idx;
        n->indirect = 0;
        for (int j = 0; j < LFS_DIRECT; j++) n->direct[j] = 0;
        uint32_t nlen = kstrlen(name);
        for (uint32_t i = 0; i <= nlen; i++) n->name[i] = name[i];
    }
    n->size = 0;

    /* Write blocks */
    uint32_t written = 0, blk_idx = 0;
    while (written < len) {
        uint32_t chunk = len - written;
        if (chunk > LFS_BLOCK_SIZE) chunk = LFS_BLOCK_SIZE;

        /* Allocate indirect block before data block so alloc sees it as used */
        if (blk_idx >= LFS_DIRECT && !n->indirect) {
            n->indirect = alloc_block();
            if (!n->indirect) return -1;
            uint8_t *ib = (uint8_t *)block_ptr(n->indirect);
            for (int k = 0; k < LFS_BLOCK_SIZE; k++) ib[k] = 0;
        }

        uint32_t blk = alloc_block();
        if (!blk) return -1;

        uint8_t *dst = (uint8_t *)block_ptr(blk);
        for (int k = 0; k < LFS_BLOCK_SIZE; k++) dst[k] = 0;
        const uint8_t *src = (const uint8_t *)data + written;
        for (uint32_t k = 0; k < chunk; k++) dst[k] = src[k];

        if (blk_idx < LFS_DIRECT) {
            n->direct[blk_idx] = blk;
        } else {
            uint32_t *ind = (uint32_t *)block_ptr(n->indirect);
            ind[blk_idx - LFS_DIRECT] = blk;
        }
        written += chunk;
        blk_idx++;
    }
    n->size = len;
    return 0;
}

int vfs_delete(const char *path) {
    if (!path || !sb) return -1;
    uint32_t idx = resolve(path);
    if (idx == (uint32_t)-1 || idx == 0) return -1; /* can't delete root */
    lfs_inode_t *n = get_inode(idx);
    if (!n) return -1;
    /* Refuse to delete non-empty directories */
    if (n->type == LFS_TYPE_DIR) {
        for (uint32_t i = 1; i < inode_cnt; i++) {
            if (i == idx) continue;
            lfs_inode_t *c = get_inode(i);
            if (c && c->type != LFS_TYPE_FREE && c->parent == idx) return -1;
        }
    } else {
        free_inode_blocks(n);
    }
    n->type = LFS_TYPE_FREE;
    return 0;
}
