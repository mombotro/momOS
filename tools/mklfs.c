/* mklfs — pack a directory into an LFS image
   Usage: mklfs <source-dir> <output.lfs> [inode-count]
   Default inode count: 64 (enough for a basic initrd)
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <errno.h>

/* Pull in the shared format header.
   The host compiler sees __attribute__((packed)) fine. */
#include "../kernel/vfs/lfs_format.h"

/* ── Tunables ───────────────────────────────────────────────────────────────*/
#define DEFAULT_INODES   64
#define MAX_INODES      256
#define MAX_DATA_BLOCKS 4096   /* 4096 × 512 = 2 MB */

/* ── In-memory image ────────────────────────────────────────────────────────*/
static uint8_t image[1 + (MAX_INODES / LFS_INODES_PER_BLOCK) + MAX_DATA_BLOCKS]
                     [LFS_BLOCK_SIZE];

static lfs_super_t *super;
static lfs_inode_t  inodes[MAX_INODES];

static uint32_t inode_count    = DEFAULT_INODES;
static uint32_t next_inode     = 0;   /* next free inode index */
static uint32_t next_data      = 0;   /* next free data block  (relative to data_start) */
static uint32_t total_blocks   = 0;

/* ── Helpers ────────────────────────────────────────────────────────────────*/
static void die(const char *msg) {
    fprintf(stderr, "mklfs: %s\n", msg);
    exit(1);
}

/* Allocate a new inode; returns its index */
static uint32_t alloc_inode(void) {
    if (next_inode >= inode_count) die("out of inodes");
    return next_inode++;
}

/* Allocate a data block; returns absolute block index */
static uint32_t alloc_block(void) {
    if (next_data >= MAX_DATA_BLOCKS) die("out of data blocks");
    uint32_t blk = super->data_start + next_data;
    next_data++;
    return blk;
}

/* Write bytes into data blocks starting at the given inode's direct/indirect
   pointers. Splits across 512-byte blocks as needed. */
static void write_file_data(lfs_inode_t *inode, const uint8_t *data, uint32_t len) {
    uint32_t written = 0;
    uint32_t blk_idx = 0;  /* which block pointer we are filling */

    /* Indirect block contents (block indices), lazily allocated */
    uint32_t indirect_buf[LFS_BLOCK_SIZE / 4];
    memset(indirect_buf, 0, sizeof(indirect_buf));
    int indirect_dirty = 0;
    uint32_t indirect_blk = 0;

    while (written < len) {
        uint32_t chunk = len - written;
        if (chunk > LFS_BLOCK_SIZE) chunk = LFS_BLOCK_SIZE;

        uint32_t abs_blk;
        if (blk_idx < LFS_DIRECT) {
            abs_blk = alloc_block();
            inode->direct[blk_idx] = abs_blk;
        } else {
            /* Use indirect block */
            uint32_t ind_idx = blk_idx - LFS_DIRECT;
            if (ind_idx >= LFS_BLOCK_SIZE / 4)
                die("file too large for single indirect");
            if (!inode->indirect) {
                indirect_blk = alloc_block();
                inode->indirect = indirect_blk;
            }
            abs_blk = alloc_block();
            indirect_buf[ind_idx] = abs_blk;
            indirect_dirty = 1;
        }

        memcpy(image[abs_blk], data + written, chunk);
        written += chunk;
        blk_idx++;
    }

    if (indirect_dirty)
        memcpy(image[indirect_blk], indirect_buf, LFS_BLOCK_SIZE);

    inode->size = len;
}

/* Recursively add a directory to the image.
   path = host filesystem path, parent_ino = parent inode index */
static void add_dir(const char *path, uint32_t parent_ino, const char *name) {
    uint32_t my_ino = alloc_inode();
    lfs_inode_t *inode = &inodes[my_ino];
    memset(inode, 0, sizeof(*inode));
    inode->type   = LFS_TYPE_DIR;
    inode->parent = parent_ino;
    strncpy(inode->name, name, LFS_NAME_MAX);

    DIR *d = opendir(path);
    if (!d) {
        fprintf(stderr, "mklfs: cannot open dir %s: %s\n", path, strerror(errno));
        return;
    }

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (!strcmp(ent->d_name, ".") || !strcmp(ent->d_name, "..")) continue;

        char child_path[4096];
        snprintf(child_path, sizeof(child_path), "%s/%s", path, ent->d_name);

        struct stat st;
        if (stat(child_path, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            add_dir(child_path, my_ino, ent->d_name);
        } else if (S_ISREG(st.st_mode)) {
            uint32_t file_ino = alloc_inode();
            lfs_inode_t *fi = &inodes[file_ino];
            memset(fi, 0, sizeof(*fi));
            fi->type   = LFS_TYPE_FILE;
            fi->parent = my_ino;
            strncpy(fi->name, ent->d_name, LFS_NAME_MAX);

            FILE *f = fopen(child_path, "rb");
            if (!f) {
                fprintf(stderr, "mklfs: cannot open %s\n", child_path);
                continue;
            }
            fseek(f, 0, SEEK_END);
            long fsz = ftell(f);
            rewind(f);
            if (fsz > 0) {
                uint8_t *buf = malloc((size_t)fsz);
                if (!buf) die("malloc failed");
                if ((long)fread(buf, 1, (size_t)fsz, f) != fsz)
                    die("fread failed");
                write_file_data(fi, buf, (uint32_t)fsz);
                free(buf);
            }
            fclose(f);
            printf("  + %s/%s (%u bytes)\n", path, ent->d_name, fi->size);
        }
    }
    closedir(d);
}

/* ── Main ───────────────────────────────────────────────────────────────────*/
int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: mklfs <source-dir> <output.lfs> [inode-count]\n");
        return 1;
    }
    const char *src  = argv[1];
    const char *out  = argv[2];
    if (argc >= 4) {
        inode_count = (uint32_t)atoi(argv[3]);
        if (inode_count < 4 || inode_count > MAX_INODES)
            die("inode-count must be 4..256");
    }

    /* Round inode_count up to multiple of LFS_INODES_PER_BLOCK */
    inode_count = ((inode_count + LFS_INODES_PER_BLOCK - 1)
                   / LFS_INODES_PER_BLOCK) * LFS_INODES_PER_BLOCK;

    uint32_t inode_blocks = inode_count / LFS_INODES_PER_BLOCK;
    uint32_t data_start   = 1 + inode_blocks;

    total_blocks = data_start + MAX_DATA_BLOCKS;

    /* Zero the image */
    memset(image, 0, sizeof(image));

    /* Set up superblock pointer into block 0 */
    super = (lfs_super_t *)image[0];
    memcpy(super->magic, LFS_MAGIC, 4);
    super->version            = LFS_VERSION;
    super->block_size         = LFS_BLOCK_SIZE;
    super->total_blocks       = total_blocks;
    super->inode_table_start  = 1;
    super->inode_table_blocks = inode_blocks;
    super->inode_count        = inode_count;
    super->data_start         = data_start;

    /* Inode 0 = root directory */
    memset(inodes, 0, sizeof(inodes));
    add_dir(src, 0, "/");

    /* Write inode table into image blocks */
    for (uint32_t i = 0; i < inode_count; i++) {
        uint32_t blk = 1 + i / LFS_INODES_PER_BLOCK;
        uint32_t off = (i % LFS_INODES_PER_BLOCK) * LFS_INODE_SIZE;
        memcpy(image[blk] + off, &inodes[i], LFS_INODE_SIZE);
    }

    /* Calculate real image size (no trailing empty data blocks) */
    uint32_t used_blocks = data_start + next_data;

    FILE *f = fopen(out, "wb");
    if (!f) { perror("fopen"); return 1; }
    fwrite(image, LFS_BLOCK_SIZE, used_blocks, f);
    fclose(f);

    printf("mklfs: wrote %u blocks (%u KB) to %s\n"
           "       inodes used: %u / %u\n"
           "       data blocks: %u\n",
           used_blocks, used_blocks * LFS_BLOCK_SIZE / 1024, out,
           next_inode, inode_count, next_data);
    return 0;
}
