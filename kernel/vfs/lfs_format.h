/* LFS — Luminos Filesystem on-disk layout
   Shared between kernel driver and host tools.

   Block size : 512 bytes
   Inode size : 128 bytes  (4 per block)
   Max name   : 71 chars
   Max file   : 8 direct blocks + 128 indirect = ~68 KB

   Image layout
   ────────────
   Block 0          : Superblock
   Blocks 1..N      : Inode table  (N = inode_table_blocks)
   Blocks N+1..end  : Data blocks
*/
#pragma once
#include <stdint.h>

#define LFS_MAGIC       "LFS!"
#define LFS_VERSION     1
#define LFS_BLOCK_SIZE  512
#define LFS_INODE_SIZE  128
#define LFS_INODES_PER_BLOCK  (LFS_BLOCK_SIZE / LFS_INODE_SIZE)  /* 4 */
#define LFS_NAME_MAX    71      /* max filename length (excl. null) */
#define LFS_DIRECT      8       /* direct block pointers per inode  */

/* Inode type field */
#define LFS_TYPE_FREE   0
#define LFS_TYPE_FILE   1
#define LFS_TYPE_DIR    2

/* ── Superblock ─────────────────────────────────────────────────────────────*/
typedef struct {
    uint8_t  magic[4];           /* "LFS!"                          */
    uint32_t version;            /* LFS_VERSION                     */
    uint32_t block_size;         /* always 512                      */
    uint32_t total_blocks;       /* total blocks in image           */
    uint32_t inode_table_start;  /* first block of inode table (=1) */
    uint32_t inode_table_blocks; /* blocks reserved for inodes      */
    uint32_t inode_count;        /* total inodes (= blocks * 4)     */
    uint32_t data_start;         /* first data block                */
    uint8_t  pad[512 - 32];      /* reserved, zeroed                */
} __attribute__((packed)) lfs_super_t;

/* ── Inode ──────────────────────────────────────────────────────────────────*/
typedef struct {
    uint32_t type;               /* LFS_TYPE_*                      */
    uint32_t parent;             /* parent inode index (root → 0)   */
    uint32_t size;               /* bytes (files); 0 (dirs)         */
    uint32_t direct[LFS_DIRECT]; /* direct data block indices       */
    uint32_t indirect;           /* single-indirect block index     */
    char     name[LFS_NAME_MAX + 1]; /* null-terminated filename    */
    uint32_t reserved[2];
} __attribute__((packed)) lfs_inode_t;

/* Compile-time size check — both must be exactly their declared sizes */
typedef char _lfs_super_size_check [(sizeof(lfs_super_t)  == 512) ? 1 : -1];
typedef char _lfs_inode_size_check [(sizeof(lfs_inode_t)  == 128) ? 1 : -1];
