#pragma once
#include <stdint.h>

#define VFS_MAX_PATH  256
#define VFS_MAX_NAME   72

/* Opaque file handle returned by vfs_open */
typedef struct vfs_file vfs_file_t;

/* Directory entry returned by vfs_list */
typedef struct {
    char     name[VFS_MAX_NAME];
    uint32_t size;   /* 0 for directories */
    int      is_dir;
} vfs_dirent_t;

/* Initialise VFS with an LFS image at the given physical address */
void vfs_init(uint32_t lfs_phys_addr, uint32_t lfs_size);

/* Open a file by absolute path (e.g. "/sys/config.txt").
   Returns NULL if not found. */
vfs_file_t *vfs_open(const char *path);

/* Read up to len bytes at offset into buf. Returns bytes read. */
uint32_t vfs_read(vfs_file_t *f, uint32_t offset, void *buf, uint32_t len);

/* Return file size in bytes */
uint32_t vfs_size(vfs_file_t *f);

/* Close a file handle */
void vfs_close(vfs_file_t *f);

/* List a directory. Calls cb(entry, userdata) for each child.
   Returns number of entries found, or -1 if path not a directory. */
int vfs_list(const char *path,
             void (*cb)(const vfs_dirent_t *e, void *ud),
             void *userdata);

/* Read entire file into a heap-allocated, NUL-terminated buffer.
   Caller must kfree() the result. Returns NULL on error. */
char *vfs_read_alloc(const char *path);
