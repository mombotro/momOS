/* test_vfs — VFS / LFS unit tests
   Builds as a host binary. Links against mklfs logic to build an in-memory
   image, then mounts it using the kernel VFS code compiled for the host.

   Usage: make test
   Exit code 0 = all passed, non-zero = failures.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ── Minimal stubs so vfs.c and lfs code compile on the host ──────────────── */

/* serial stub */
void serial_puts(const char *s) { (void)s; }
void serial_putc(char c)        { (void)c; }
void serial_hex(uint32_t v)     { (void)v; }

/* heap stubs: just use malloc/free */
void *kmalloc(unsigned int sz)              { return malloc(sz); }
void  kfree(void *p)                        { free(p); }
void *krealloc(void *p, unsigned int sz)    { return realloc(p, sz); }

/* Include VFS source directly */
#include "../kernel/vfs/vfs.c"

/* Include mklfs helpers to build an in-memory image */
#include "../kernel/vfs/lfs_format.h"

/* ── Test framework ──────────────────────────────────────────────────────── */
static int tests_run    = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define CHECK(expr) do { \
    tests_run++; \
    if (expr) { \
        tests_passed++; \
    } else { \
        tests_failed++; \
        fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); \
    } \
} while(0)

#define SECTION(name) printf("\n[%s]\n", name)

/* ── Build a minimal in-memory LFS image ─────────────────────────────────── */
#define TEST_INODES      16
#define TEST_DATA_BLOCKS 64
#define TEST_INODE_BLOCKS (TEST_INODES / LFS_INODES_PER_BLOCK)  /* 4 */
#define TEST_DATA_START  (1 + TEST_INODE_BLOCKS)
#define TEST_TOTAL       (TEST_DATA_START + TEST_DATA_BLOCKS)
#define IMG_SZ           (TEST_TOTAL * LFS_BLOCK_SIZE)

static uint8_t img[IMG_SZ];
static uint32_t next_ino  = 0;
static uint32_t next_data = 0;

static lfs_super_t *tsb;
static lfs_inode_t *tino;

static uint32_t t_alloc_ino(void) { return next_ino++; }
static uint32_t t_alloc_data(void) {
    uint32_t blk = TEST_DATA_START + next_data++;
    return blk;
}

static void t_write_file(lfs_inode_t *in, const char *data) {
    uint32_t len = (uint32_t)strlen(data);
    uint32_t blk = t_alloc_data();
    in->direct[0] = blk;
    in->size = len;
    memcpy(img + blk * LFS_BLOCK_SIZE, data, len);
}

static void build_image(void) {
    memset(img, 0, IMG_SZ);

    tsb = (lfs_super_t *)img;
    memcpy(tsb->magic, LFS_MAGIC, 4);
    tsb->version            = LFS_VERSION;
    tsb->block_size         = LFS_BLOCK_SIZE;
    tsb->total_blocks       = TEST_TOTAL;
    tsb->inode_table_start  = 1;
    tsb->inode_table_blocks = TEST_INODE_BLOCKS;
    tsb->inode_count        = TEST_INODES;
    tsb->data_start         = TEST_DATA_START;

    /* inode table pointer */
    tino = (lfs_inode_t *)(img + LFS_BLOCK_SIZE);

    /* inode 0 = root dir */
    uint32_t root = t_alloc_ino();
    tino[root].type   = LFS_TYPE_DIR;
    tino[root].parent = 0;
    strncpy(tino[root].name, "/", LFS_NAME_MAX);

    /* inode 1 = /hello.txt */
    uint32_t f1 = t_alloc_ino();
    tino[f1].type   = LFS_TYPE_FILE;
    tino[f1].parent = root;
    strncpy(tino[f1].name, "hello.txt", LFS_NAME_MAX);
    t_write_file(&tino[f1], "Hello, LFS!");

    /* inode 2 = /subdir */
    uint32_t d1 = t_alloc_ino();
    tino[d1].type   = LFS_TYPE_DIR;
    tino[d1].parent = root;
    strncpy(tino[d1].name, "subdir", LFS_NAME_MAX);

    /* inode 3 = /subdir/nested.txt */
    uint32_t f2 = t_alloc_ino();
    tino[f2].type   = LFS_TYPE_FILE;
    tino[f2].parent = d1;
    strncpy(tino[f2].name, "nested.txt", LFS_NAME_MAX);
    t_write_file(&tino[f2], "Nested file content.");
}

/* ── Tests ───────────────────────────────────────────────────────────────── */

static int list_count;
static char list_names[32][LFS_NAME_MAX + 1];
static void list_cb(const vfs_dirent_t *e, void *ud) {
    (void)ud;
    if (list_count < 32) {
        strncpy(list_names[list_count], e->name, LFS_NAME_MAX);
        list_count++;
    }
}

static int name_in_list(const char *name) {
    for (int i = 0; i < list_count; i++)
        if (strcmp(list_names[i], name) == 0) return 1;
    return 0;
}

static void test_mount(void) {
    SECTION("mount");
    vfs_init((uint32_t)(uintptr_t)img, IMG_SZ);
    /* If we got here without crashing, mount succeeded */
    CHECK(1);
}

static void test_list_root(void) {
    SECTION("fs.list /");
    list_count = 0;
    int r = vfs_list("/", list_cb, NULL);
    CHECK(r == 0);
    CHECK(list_count == 2);
    CHECK(name_in_list("hello.txt"));
    CHECK(name_in_list("subdir"));
}

static void test_list_subdir(void) {
    SECTION("fs.list /subdir");
    list_count = 0;
    int r = vfs_list("/subdir", list_cb, NULL);
    CHECK(r == 0);
    CHECK(list_count == 1);
    CHECK(name_in_list("nested.txt"));
}

static void test_list_missing(void) {
    SECTION("fs.list missing dir");
    list_count = 0;
    int r = vfs_list("/doesnotexist", list_cb, NULL);
    CHECK(r < 0);
    CHECK(list_count == 0);
}

static void test_read_file(void) {
    SECTION("fs.read");
    char *data = vfs_read_alloc("/hello.txt");
    CHECK(data != NULL);
    if (data) {
        CHECK(strcmp(data, "Hello, LFS!") == 0);
        kfree(data);
    }
}

static void test_read_nested(void) {
    SECTION("fs.read nested");
    char *data = vfs_read_alloc("/subdir/nested.txt");
    CHECK(data != NULL);
    if (data) {
        CHECK(strcmp(data, "Nested file content.") == 0);
        kfree(data);
    }
}

static void test_read_missing(void) {
    SECTION("fs.read missing");
    char *data = vfs_read_alloc("/no_such_file.txt");
    CHECK(data == NULL);
}

static void test_exists(void) {
    SECTION("fs.exists");
    CHECK(vfs_exists("/hello.txt"));
    CHECK(vfs_exists("/subdir"));
    CHECK(!vfs_exists("/ghost.txt"));
}

static void test_write_new(void) {
    SECTION("fs.write new file");
    const char *content = "New file data.";
    int r = vfs_write("/newfile.txt", content, (uint32_t)strlen(content));
    CHECK(r == 0);
    CHECK(vfs_exists("/newfile.txt"));
    char *back = vfs_read_alloc("/newfile.txt");
    CHECK(back != NULL);
    if (back) { CHECK(strcmp(back, content) == 0); kfree(back); }
}

static void test_write_overwrite(void) {
    SECTION("fs.write overwrite");
    vfs_write("/hello.txt", "Updated!", 8);
    char *data = vfs_read_alloc("/hello.txt");
    CHECK(data != NULL);
    if (data) { CHECK(strcmp(data, "Updated!") == 0); kfree(data); }
}

static void test_mkdir(void) {
    SECTION("fs.mkdir");
    int r = vfs_mkdir("/newdir");
    CHECK(r == 0);
    CHECK(vfs_exists("/newdir"));
    list_count = 0;
    vfs_list("/newdir", list_cb, NULL);
    CHECK(list_count == 0);
}

static void test_delete_file(void) {
    SECTION("fs.delete file");
    vfs_write("/todel.txt", "bye", 3);
    CHECK(vfs_exists("/todel.txt"));
    int r = vfs_delete("/todel.txt");
    CHECK(r == 0);
    CHECK(!vfs_exists("/todel.txt"));
}

static void test_delete_missing(void) {
    SECTION("fs.delete missing");
    int r = vfs_delete("/no_such_file.txt");
    CHECK(r < 0);
}

/* ── Entry ───────────────────────────────────────────────────────────────── */
int main(void) {
    printf("=== momOS VFS unit tests ===\n");

    build_image();

    test_mount();
    test_list_root();
    test_list_subdir();
    test_list_missing();
    test_read_file();
    test_read_nested();
    test_read_missing();
    test_exists();
    test_write_new();
    test_write_overwrite();
    test_mkdir();
    test_delete_file();
    test_delete_missing();

    printf("\n─────────────────────────────\n");
    printf("  %d / %d tests passed", tests_passed, tests_run);
    if (tests_failed) printf("  (%d FAILED)", tests_failed);
    printf("\n");

    return tests_failed ? 1 : 0;
}
