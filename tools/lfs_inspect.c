/* lfs_inspect — dump the contents of an LFS image
   Usage: lfs_inspect <image.lfs> [-v]
          -v  verbose: show inode table and data block map
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "../kernel/vfs/lfs_format.h"

static int verbose = 0;

static void die(const char *msg) { fprintf(stderr, "lfs_inspect: %s\n", msg); exit(1); }

/* ── Load image ─────────────────────────────────────────────────────────── */
static uint8_t *image  = NULL;
static size_t   img_sz = 0;

static void *block_ptr(uint32_t blk) {
    size_t off = (size_t)blk * LFS_BLOCK_SIZE;
    if (off + LFS_BLOCK_SIZE > img_sz) die("block index out of range");
    return image + off;
}

static lfs_inode_t *inode_ptr(uint32_t idx, const lfs_super_t *sb) {
    uint32_t blk = sb->inode_table_start + idx / LFS_INODES_PER_BLOCK;
    uint32_t off = (idx % LFS_INODES_PER_BLOCK) * LFS_INODE_SIZE;
    return (lfs_inode_t *)((uint8_t *)block_ptr(blk) + off);
}

/* ── Tree printer ───────────────────────────────────────────────────────── */
static void print_tree(uint32_t dir_ino, const lfs_super_t *sb, int depth) {
    for (uint32_t i = 0; i < sb->inode_count; i++) {
        lfs_inode_t *in = inode_ptr(i, sb);
        if (in->type == LFS_TYPE_FREE) continue;
        if (i == 0 && dir_ino == 0 && in->parent == 0) {
            /* root dir itself — skip, printed by caller */
            continue;
        }
        if (in->parent != dir_ino) continue;

        for (int d = 0; d < depth; d++) printf("  ");
        if (in->type == LFS_TYPE_DIR) {
            printf("[%3u] %s/\n", i, in->name);
            print_tree(i, sb, depth + 1);
        } else {
            printf("[%3u] %-32s %u bytes\n", i, in->name, in->size);
        }
    }
}

/* ── Verbose inode dump ──────────────────────────────────────────────────── */
static void dump_inodes(const lfs_super_t *sb) {
    printf("\n── Inode table (%u entries) ──────────────────────────\n",
           sb->inode_count);
    for (uint32_t i = 0; i < sb->inode_count; i++) {
        lfs_inode_t *in = inode_ptr(i, sb);
        if (in->type == LFS_TYPE_FREE) continue;
        const char *tname = (in->type == LFS_TYPE_DIR) ? "DIR " : "FILE";
        printf("  [%3u] %s  parent=%-3u  size=%-6u  name=%s\n",
               i, tname, in->parent, in->size, in->name);
        if (verbose >= 2 && in->type == LFS_TYPE_FILE) {
            printf("        direct: ");
            for (int d = 0; d < LFS_DIRECT; d++)
                if (in->direct[d]) printf("%u ", in->direct[d]);
            if (in->indirect) printf("indirect=%u", in->indirect);
            printf("\n");
        }
    }
}

/* ── Main ───────────────────────────────────────────────────────────────── */
int main(int argc, char **argv) {
    const char *path = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-v") == 0) verbose++;
        else if (strcmp(argv[i], "-vv") == 0) verbose = 2;
        else path = argv[i];
    }
    if (!path) {
        fprintf(stderr, "usage: lfs_inspect <image.lfs> [-v] [-vv]\n");
        return 1;
    }

    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }
    fseek(f, 0, SEEK_END);
    img_sz = (size_t)ftell(f);
    rewind(f);
    image = malloc(img_sz);
    if (!image) die("malloc");
    if (fread(image, 1, img_sz, f) != img_sz) die("fread");
    fclose(f);

    if (img_sz < LFS_BLOCK_SIZE) die("image too small");

    lfs_super_t *sb = (lfs_super_t *)image;

    /* Validate magic */
    if (memcmp(sb->magic, LFS_MAGIC, 4) != 0) {
        fprintf(stderr, "lfs_inspect: bad magic (not an LFS image)\n");
        free(image); return 1;
    }

    /* Summary */
    printf("LFS image: %s\n", path);
    printf("  version      : %u\n",  sb->version);
    printf("  block size   : %u B\n", sb->block_size);
    printf("  total blocks : %u  (%u KB)\n",
           sb->total_blocks, sb->total_blocks * LFS_BLOCK_SIZE / 1024);
    printf("  inode table  : blocks %u..%u  (%u inodes)\n",
           sb->inode_table_start,
           sb->inode_table_start + sb->inode_table_blocks - 1,
           sb->inode_count);
    printf("  data start   : block %u\n", sb->data_start);
    printf("  image size   : %zu KB\n", img_sz / 1024);

    /* Count used inodes and bytes */
    uint32_t used_inodes = 0, used_bytes = 0;
    for (uint32_t i = 0; i < sb->inode_count; i++) {
        lfs_inode_t *in = inode_ptr(i, sb);
        if (in->type != LFS_TYPE_FREE) {
            used_inodes++;
            used_bytes += in->size;
        }
    }
    printf("  used inodes  : %u / %u\n", used_inodes, sb->inode_count);
    printf("  file data    : %u bytes\n\n", used_bytes);

    /* File tree */
    printf("── File tree ─────────────────────────────────────────\n");
    printf("/\n");
    print_tree(0, sb, 1);

    if (verbose) dump_inodes(sb);

    free(image);
    return 0;
}
