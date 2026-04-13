/* acpi.c — minimal ACPI shutdown for momOS
 *
 * Procedure:
 *  1. Scan EBDA + BIOS ROM for RSDP ("RSD PTR ")
 *  2. Walk RSDT to find the FADT (signature "FACP")
 *  3. Read PM1a_CNT_BLK and optional PM1b_CNT_BLK from FADT
 *  4. Map and scan DSDT AML bytecode for the _S5_ package to get SLP_TYPa/b
 *  5. Write (SLP_TYPa << 10) | SLP_EN to PM1a_CNT_BLK to power off
 *
 * Reboot uses the 8042 keyboard controller reset line (always works).
 */

#include "acpi.h"
#include "io.h"
#include "serial.h"
#include "../mm/paging.h"
#include <stdint.h>

/* ── I/O helpers ─────────────────────────────────────────────────────────── */
static void     _outw (uint16_t p, uint16_t v) { __asm__ volatile("outw %0,%1"::"a"(v),"Nd"(p)); }
static void     _outb (uint16_t p, uint8_t  v) { __asm__ volatile("outb %0,%1"::"a"(v),"Nd"(p)); }
static uint16_t _inw  (uint16_t p) { uint16_t v; __asm__ volatile("inw %1,%0":"=a"(v):"Nd"(p)); return v; }

/* ── ACPI table structures ───────────────────────────────────────────────── */
typedef struct {
    char     sig[8];        /* "RSD PTR " */
    uint8_t  checksum;
    char     oem_id[6];
    uint8_t  revision;      /* 0 = ACPI 1.0, 2 = ACPI 2.0+ */
    uint32_t rsdt_addr;
    /* ACPI 2.0 extension (revision >= 2): */
    uint32_t length;
    uint64_t xsdt_addr;
    uint8_t  ext_checksum;
    uint8_t  reserved[3];
} __attribute__((packed)) rsdp_t;

/* Generic ACPI table header */
typedef struct {
    char     sig[4];
    uint32_t length;
    uint8_t  revision;
    uint8_t  checksum;
    char     oem_id[6];
    char     oem_table_id[8];
    uint32_t oem_revision;
    uint32_t creator_id;
    uint32_t creator_revision;
} __attribute__((packed)) acpi_hdr_t;   /* 36 bytes */

/* FADT-specific fields after the header (offsets relative to table start) */
#define FADT_OFF_SMI_CMD      48    /* uint32_t: SMI command port */
#define FADT_OFF_ACPI_ENABLE  52    /* uint8_t:  value to write to enable ACPI */
#define FADT_OFF_DSDT         40    /* uint32_t: DSDT physical address */
#define FADT_OFF_PM1A_CNT_BLK 64    /* uint32_t: PM1a control I/O port */
#define FADT_OFF_PM1B_CNT_BLK 68    /* uint32_t: PM1b control I/O port (0=absent) */
#define FADT_OFF_PM1_CNT_LEN  89    /* uint8_t:  PM1 control register width */

/* PM1 control register bits */
#define SLP_EN  (1u << 13)   /* sleep enable */
/* SLP_TYP occupies bits 12:10 */

/* ── State ───────────────────────────────────────────────────────────────── */
static int      acpi_ready    = 0;
static uint16_t pm1a_cnt      = 0;   /* I/O port */
static uint16_t pm1b_cnt      = 0;   /* I/O port, 0 = not present */
static uint16_t slp_typa      = 5;   /* default S5 value for most ICH */
static uint16_t slp_typb      = 5;

/* ── Memory-scan helpers ─────────────────────────────────────────────────── */
static int mem_sig8(const void *p, const char *sig) {
    const char *b = (const char *)p;
    for (int i = 0; i < 8; i++) if (b[i] != sig[i]) return 0;
    return 1;
}
static int mem_sig4(const void *p, const char *sig) {
    const char *b = (const char *)p;
    for (int i = 0; i < 4; i++) if (b[i] != sig[i]) return 0;
    return 1;
}

/* Map a physical region if it's outside the low-64MB identity map */
static void ensure_mapped(uint32_t addr) {
    if (addr >= 64u * 1024 * 1024)
        paging_map_mmio(addr);
}

/* ── RSDP search ─────────────────────────────────────────────────────────── */
static rsdp_t *find_rsdp(void) {
    /* 1. Check EBDA (segment stored at 0x40E, EBDA at segment<<4) */
    uint16_t ebda_seg = *(volatile uint16_t *)(uintptr_t)0x40E;
    uint32_t ebda_addr = (uint32_t)ebda_seg << 4;
    if (ebda_addr >= 0x80000 && ebda_addr < 0xA0000) {
        for (uint32_t a = ebda_addr; a < ebda_addr + 1024; a += 16) {
            if (mem_sig8((void *)(uintptr_t)a, "RSD PTR "))
                return (rsdp_t *)(uintptr_t)a;
        }
    }
    /* 2. Scan BIOS ROM area 0xE0000–0xFFFFF */
    for (uint32_t a = 0xE0000; a < 0x100000; a += 16) {
        if (mem_sig8((void *)(uintptr_t)a, "RSD PTR "))
            return (rsdp_t *)(uintptr_t)a;
    }
    return 0;
}

/* ── DSDT _S5_ scan ──────────────────────────────────────────────────────── */
/* AML byte codes we care about */
#define AML_BYTEPREFIX  0x0A
#define AML_WORDPREFIX  0x0B
#define AML_ZERO        0x00
#define AML_ONE         0x01

static uint8_t aml_int_byte(const uint8_t *p) {
    if (*p == AML_ZERO)        return 0;
    if (*p == AML_ONE)         return 1;
    if (*p == AML_BYTEPREFIX)  return *(p+1);
    if (*p == AML_WORDPREFIX)  return *(p+1);   /* low byte sufficient */
    return (uint8_t)*p;
}

/* Decode AML PkgLength (1–4 bytes).  Returns bytes consumed via *out_skip. */
static uint32_t aml_pkg_len(const uint8_t *p, int *out_skip) {
    uint8_t first = p[0];
    int extra = (first >> 6) & 0x3;
    *out_skip = extra + 1;
    if (extra == 0) return first & 0x3F;
    uint32_t v = first & 0x0F;
    for (int i = 0; i < extra; i++) v |= (uint32_t)p[1+i] << (8 + i*8 - 4);
    return v;
}

static void scan_s5(uint32_t dsdt_addr) {
    ensure_mapped(dsdt_addr);
    acpi_hdr_t *h = (acpi_hdr_t *)(uintptr_t)dsdt_addr;
    if (!mem_sig4(h->sig, "DSDT")) { serial_puts("[ACPI] DSDT bad sig\n"); return; }

    uint32_t dsdt_end = dsdt_addr + h->length;
    /* Map tail of DSDT if it spans multiple 4MB regions */
    ensure_mapped(dsdt_end);

    const uint8_t *aml = (const uint8_t *)(uintptr_t)(dsdt_addr + 36);
    const uint8_t *end = (const uint8_t *)(uintptr_t)(dsdt_end);

    while (aml < end - 8) {
        /* Look for _S5_ name: 0x5F 0x53 0x35 0x5F */
        if (aml[0]==0x5F && aml[1]==0x53 && aml[2]==0x35 && aml[3]==0x5F) {
            serial_puts("[ACPI] found _S5_\n");
            const uint8_t *p = aml + 4;

            /* Skip NameOp or ScopeOp wrappers if present */
            if (*p == 0x08) p++;        /* NameOp */
            if (*p == 0x12) p++;        /* PackageOp */

            /* Decode package length */
            int skip;
            aml_pkg_len(p, &skip);
            p += skip;

            /* Element count */
            p++;  /* skip NumElements byte */

            /* First element = SLP_TYPa for S5 */
            slp_typa = aml_int_byte(p);
            if (*p == AML_BYTEPREFIX || *p == AML_WORDPREFIX) p++;
            p++;

            /* Second element = SLP_TYPb */
            if (p < end) slp_typb = aml_int_byte(p);

            serial_puts("[ACPI] SLP_TYPa="); serial_hex(slp_typa);
            serial_puts(" SLP_TYPb="); serial_hex(slp_typb); serial_puts("\n");
            return;
        }
        aml++;
    }
    serial_puts("[ACPI] _S5_ not found — using default SLP_TYP=5\n");
}

/* ── acpi_init ───────────────────────────────────────────────────────────── */
void acpi_init(void) {
    rsdp_t *rsdp = find_rsdp();
    if (!rsdp) { serial_puts("[ACPI] RSDP not found\n"); return; }
    serial_puts("[ACPI] RSDP at "); serial_hex((uint32_t)(uintptr_t)rsdp);
    serial_puts(" rev="); serial_hex(rsdp->revision); serial_puts("\n");

    uint32_t rsdt_addr = rsdp->rsdt_addr;
    ensure_mapped(rsdt_addr);

    acpi_hdr_t *rsdt = (acpi_hdr_t *)(uintptr_t)rsdt_addr;
    if (!mem_sig4(rsdt->sig, "RSDT")) { serial_puts("[ACPI] bad RSDT\n"); return; }

    /* RSDT entry array immediately follows the 36-byte header */
    uint32_t n_entries = (rsdt->length - 36) / 4;
    uint32_t *entries  = (uint32_t *)((uint8_t *)rsdt + 36);

    acpi_hdr_t *fadt = 0;
    for (uint32_t i = 0; i < n_entries; i++) {
        uint32_t taddr = entries[i];
        ensure_mapped(taddr);
        acpi_hdr_t *t = (acpi_hdr_t *)(uintptr_t)taddr;
        if (mem_sig4(t->sig, "FACP")) { fadt = t; break; }
    }

    if (!fadt) { serial_puts("[ACPI] FADT not found\n"); return; }
    serial_puts("[ACPI] FADT at "); serial_hex((uint32_t)(uintptr_t)fadt); serial_puts("\n");

    /* Read PM1 control port(s) from FADT */
    uint8_t *fb = (uint8_t *)fadt;
    pm1a_cnt = (uint16_t)(*(uint32_t *)(fb + FADT_OFF_PM1A_CNT_BLK));
    pm1b_cnt = (uint16_t)(*(uint32_t *)(fb + FADT_OFF_PM1B_CNT_BLK));
    serial_puts("[ACPI] PM1a_CNT="); serial_hex(pm1a_cnt);
    serial_puts(" PM1b_CNT="); serial_hex(pm1b_cnt); serial_puts("\n");

    /* Enable ACPI mode if SCI_EN (bit 0 of PM1a_CNT) is not set.
     * Without this, writes to PM1a_CNT go to the SMI handler, not ACPI. */
    if (pm1a_cnt && !((_inw(pm1a_cnt)) & 0x0001)) {
        uint32_t smi_cmd    = *(uint32_t *)(fb + FADT_OFF_SMI_CMD);
        uint8_t  acpi_en    = fb[FADT_OFF_ACPI_ENABLE];
        serial_puts("[ACPI] enabling ACPI mode via SMI_CMD=");
        serial_hex(smi_cmd); serial_puts(" val="); serial_hex(acpi_en); serial_puts("\n");
        if (smi_cmd && acpi_en) {
            _outb((uint16_t)smi_cmd, acpi_en);
            /* Wait up to ~10ms for SCI_EN */
            for (int i = 0; i < 300000; i++) {
                if (_inw(pm1a_cnt) & 0x0001) break;
            }
            serial_puts("[ACPI] SCI_EN=");
            serial_hex(_inw(pm1a_cnt) & 1); serial_puts("\n");
        }
    } else {
        serial_puts("[ACPI] ACPI already enabled\n");
    }

    /* Read and scan DSDT for _S5_ */
    uint32_t dsdt_addr = *(uint32_t *)(fb + FADT_OFF_DSDT);
    serial_puts("[ACPI] DSDT at "); serial_hex(dsdt_addr); serial_puts("\n");
    scan_s5(dsdt_addr);

    acpi_ready = 1;
    serial_puts("[ACPI] init OK\n");
}

/* ── acpi_shutdown ───────────────────────────────────────────────────────── */
void acpi_shutdown(void) {
    if (acpi_ready && pm1a_cnt) {
        uint16_t val_a = (uint16_t)((slp_typa << 10) | SLP_EN);
        uint16_t val_b = (uint16_t)((slp_typb << 10) | SLP_EN);
        serial_puts("[ACPI] shutdown PM1a="); serial_hex(pm1a_cnt);
        serial_puts(" val="); serial_hex(val_a); serial_puts("\n");
        _outw(pm1a_cnt, val_a);
        if (pm1b_cnt) _outw(pm1b_cnt, val_b);
    } else {
        /* QEMU/Bochs fallback */
        serial_puts("[ACPI] fallback QEMU shutdown\n");
        _outw(0x604, 0x2000);
        _outw(0xB004, 0x2000);  /* older Bochs port */
    }
    /* If still running, halt */
    for (;;) { __asm__ volatile("cli; hlt"); }
}

/* ── acpi_reboot ─────────────────────────────────────────────────────────── */
void acpi_reboot(void) {
    /* Pulse the 8042 keyboard controller reset line */
    /* Drain the 8042 input buffer first */
    for (int i = 0; i < 10000; i++) {
        if (!(inb(0x64) & 0x02)) break;
    }
    outb(0x64, 0xFE);
    /* Short busy-wait for reset to take */
    for (volatile int i = 0; i < 100000; i++) {}
    /* Triple fault fallback */
    __asm__ volatile(
        "cli\n"
        "lidt (0)\n"   /* load null IDT — next interrupt triple-faults */
        "int $3\n"
    );
    for (;;) { __asm__ volatile("hlt"); }
}
