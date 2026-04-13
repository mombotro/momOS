/* hda.c — Intel High Definition Audio (Azalia) driver
 *
 * Scans PCI for class 04 / subclass 03.
 * Uses CORB/RIRB for codec communication.
 * Walks the codec widget graph to find DAC(s) and output PINs.
 * Streams 22050 Hz 16-bit mono PCM from the software mixer.
 *
 * Audio output path: audio_mix() → 8-bit unsigned → convert → 16-bit signed
 * HDA stream format: 44.1kHz base / 2 = 22050 Hz, 16-bit, 1 channel
 */

#include "audio.h"
#include "../cpu/serial.h"
#include "../mm/paging.h"
#include <stdint.h>

/* ── PCI helpers ─────────────────────────────────────────────────────────── */
static void _outl(uint16_t p, uint32_t v) { __asm__ volatile("outl %0,%1"::"a"(v),"Nd"(p)); }
static uint32_t _inl(uint16_t p) { uint32_t v; __asm__ volatile("inl %1,%0":"=a"(v):"Nd"(p)); return v; }

#define PCI_ADDR 0xCF8
#define PCI_DATA 0xCFC

static uint32_t pci_read(uint8_t bus, uint8_t dev, uint8_t fn, uint8_t reg) {
    _outl(PCI_ADDR, 0x80000000u | ((uint32_t)bus<<16) | ((uint32_t)dev<<11)
                                | ((uint32_t)fn<<8) | (reg & 0xFC));
    return _inl(PCI_DATA);
}
static void pci_write(uint8_t bus, uint8_t dev, uint8_t fn, uint8_t reg, uint32_t v) {
    _outl(PCI_ADDR, 0x80000000u | ((uint32_t)bus<<16) | ((uint32_t)dev<<11)
                                | ((uint32_t)fn<<8) | (reg & 0xFC));
    _outl(PCI_DATA, v);
}

/* ── HDA MMIO register offsets ───────────────────────────────────────────── */
#define HDA_GCAP        0x00   /* Global Capabilities (16-bit) */
#define HDA_GCTL        0x08   /* Global Control (32-bit) */
#define HDA_WAKEEN      0x0C   /* Wake Enable (16-bit) */
#define HDA_STATESTS    0x0E   /* State Change Status (16-bit) */
#define HDA_INTCTL      0x20   /* Interrupt Control (32-bit) */
#define HDA_WALCLK      0x30   /* Wall Clock Counter (32-bit) */
#define HDA_SSYNC       0x38   /* Stream Synchronisation (32-bit) */
#define HDA_CORBLBASE   0x40   /* CORB Lower Base (32-bit) */
#define HDA_CORBUBASE   0x44   /* CORB Upper Base (32-bit) */
#define HDA_CORBWP      0x48   /* CORB Write Pointer (16-bit) */
#define HDA_CORBRP      0x4A   /* CORB Read Pointer (16-bit) */
#define HDA_CORBCTL     0x4C   /* CORB Control (8-bit) */
#define HDA_CORBSIZE    0x4E   /* CORB Size (8-bit) */
#define HDA_RIRBLBASE   0x50   /* RIRB Lower Base (32-bit) */
#define HDA_RIRBUBASE   0x54   /* RIRB Upper Base (32-bit) */
#define HDA_RIRBWP      0x58   /* RIRB Write Pointer (16-bit) */
#define HDA_RINTCNT     0x5A   /* Response Interrupt Count (16-bit) */
#define HDA_RIRBCTL     0x5C   /* RIRB Control (8-bit) */
#define HDA_RIRBSTS     0x5D   /* RIRB Status (8-bit) */
#define HDA_RIRBSIZE    0x5E   /* RIRB Size (8-bit) */
#define HDA_IC          0x60   /* Immediate Command (32-bit) */
#define HDA_IR          0x64   /* Immediate Response (32-bit) */
#define HDA_IRS         0x68   /* Immediate Response Status (16-bit) */
#define HDA_DPLBASE     0x70   /* DMA Position Lower Base (32-bit) */
#define HDA_DPUBASE     0x74   /* DMA Position Upper Base (32-bit) */

/* Stream descriptor base: ISS streams first, then OSS streams.
   SD_BASE(n) = 0x80 + n*0x20.  We figure out first OSS index from GCAP. */
#define HDA_SD_BASE     0x80
#define HDA_SD_STRIDE   0x20

/* Stream descriptor register offsets */
#define SD_CTL   0x00   /* 24-bit */
#define SD_STS   0x03   /* 8-bit  (byte 3 of CTL word) */
#define SD_LPIB  0x04   /* 32-bit — Link Position in Buffer */
#define SD_CBL   0x08   /* 32-bit — Cyclic Buffer Length */
#define SD_LVI   0x0C   /* 16-bit — Last Valid Index */
#define SD_FIFOW 0x0E   /* 16-bit — FIFO Watermark */
#define SD_FMT   0x12   /* 16-bit — Stream Format */
#define SD_BDPL  0x18   /* 32-bit — BDL Lower Base */
#define SD_BDPU  0x1C   /* 32-bit — BDL Upper Base */

/* GCTL bits */
#define GCTL_CRST   (1u << 0)   /* Controller Reset (0=reset, 1=run) */
#define GCTL_FCNTRL (1u << 1)   /* Flush Control */

/* SD_CTL bits */
#define SDCTL_SRST  (1u << 0)   /* Stream Reset */
#define SDCTL_RUN   (1u << 1)   /* Stream Run */
#define SDCTL_IOCE  (1u << 2)   /* Interrupt on Completion Enable */
#define SDCTL_FEIE  (1u << 3)   /* FIFO Error Interrupt Enable */
#define SDCTL_DEIE  (1u << 4)   /* Descriptor Error Interrupt Enable */
/* bits 23-20: Stream Number (tag). bits 19-16: reserved. */

/* ── Buffer layout ────────────────────────────────────────────────────────── */
#define HDA_BDL_COUNT    4                             /* BDL entries           */
#define HDA_BUF_SAMPLES  AUDIO_BUF_SAMPLES             /* samples per buffer    */
#define HDA_BUF_BYTES    (HDA_BUF_SAMPLES * 2)         /* 16-bit → 2 bytes each */
#define HDA_CBL          (HDA_BDL_COUNT * HDA_BUF_BYTES) /* total cyclic length */

/* Buffer Descriptor List entry */
typedef struct {
    uint32_t addr_lo;
    uint32_t addr_hi;
    uint32_t length;
    uint32_t flags;     /* bit 0 = IOC */
} __attribute__((packed)) hda_bdle_t;

#define BDLE_IOC (1u << 0)

/* 8-bit unsigned mixer output → 16-bit signed per-buffer staging */
static uint8_t  _mix8[HDA_BDL_COUNT][HDA_BUF_SAMPLES] __attribute__((aligned(128)));
/* 16-bit signed HDA DMA buffers */
static int16_t  _pcm16[HDA_BDL_COUNT][HDA_BUF_SAMPLES] __attribute__((aligned(128)));
/* BDL */
static hda_bdle_t _bdl[HDA_BDL_COUNT]                  __attribute__((aligned(128)));
/* CORB: 256 entries × 4 bytes */
static uint32_t   _corb[256]                            __attribute__((aligned(128)));
/* RIRB: 256 entries × 8 bytes */
static uint64_t   _rirb[256]                            __attribute__((aligned(128)));

/* ── State ────────────────────────────────────────────────────────────────── */
int             hda_present = 0;
static volatile uint8_t *hda_base = 0;   /* MMIO base pointer */
static uint32_t hda_sd_off = 0;          /* stream descriptor MMIO offset */
static int      hda_corb_wp = 0;
static int      hda_rirb_rp = 0;
static int      hda_last_entry = 0;      /* last BDL entry we filled */

/* ── MMIO accessors ──────────────────────────────────────────────────────── */
static uint8_t  hda_r8 (uint32_t off) { return hda_base[off]; }
static uint16_t hda_r16(uint32_t off) { return *(volatile uint16_t*)(hda_base+off); }
static uint32_t hda_r32(uint32_t off) { return *(volatile uint32_t*)(hda_base+off); }
static void hda_w8 (uint32_t off, uint8_t  v) { hda_base[off] = v; }
static void hda_w16(uint32_t off, uint16_t v) { *(volatile uint16_t*)(hda_base+off) = v; }
static void hda_w32(uint32_t off, uint32_t v) { *(volatile uint32_t*)(hda_base+off) = v; }

static uint32_t sd_r32(uint32_t off) { return hda_r32(hda_sd_off + off); }
static void     sd_w32(uint32_t off, uint32_t v) { hda_w32(hda_sd_off + off, v); }
static void     sd_w16(uint32_t off, uint16_t v) { hda_w16(hda_sd_off + off, v); }

/* ── Simple busy-wait delay ───────────────────────────────────────────────── */
static void hda_delay(int n) {
    for (volatile int i = 0; i < n * 1000; i++) {}
}

/* ── CORB/RIRB codec communication ──────────────────────────────────────── */
/* Send one verb and return the response, or 0xFFFFFFFF on timeout. */
static uint32_t codec_verb(uint8_t cad, uint8_t nid, uint32_t verb_payload) {
    uint32_t verb = ((uint32_t)cad << 28) | ((uint32_t)nid << 20) | (verb_payload & 0xFFFFF);

    /* Write verb into CORB at next write pointer */
    int wp = (hda_corb_wp + 1) & 0xFF;
    _corb[wp] = verb;
    hda_corb_wp = wp;
    hda_w16(HDA_CORBWP, (uint16_t)wp);

    /* Wait for RIRB to receive the response */
    for (int timeout = 10000; timeout > 0; timeout--) {
        uint16_t rirbwp = hda_r16(HDA_RIRBWP) & 0xFF;
        if ((int)rirbwp != hda_rirb_rp) {
            hda_rirb_rp = (hda_rirb_rp + 1) & 0xFF;
            /* Clear RIRB status */
            hda_w8(HDA_RIRBSTS, hda_r8(HDA_RIRBSTS) | 0x05);
            return (uint32_t)(_rirb[hda_rirb_rp] & 0xFFFFFFFFull);
        }
    }
    return 0xFFFFFFFF;
}

/* Convenience: GET_PARAMETER verb */
#define GET_PARAM(cad, nid, param) \
    codec_verb((cad), (nid), 0xF0000 | (param))

/* ── Codec widget configuration ──────────────────────────────────────────── */

/* HDA stream format word: 44.1 kHz / 2 = 22050 Hz, 16-bit, 1 channel
 * Bit 14:    BASE=1  (44.1 kHz)
 * Bits 13-11: MULT=000 (×1)
 * Bits 10-8:  DIV=001 (/2)   → 22050 Hz
 * Bits 6-4:   BITS=001 (16-bit)
 * Bits 3-0:   CHAN=0   (mono)
 */
#define HDA_FMT_22050_16_MONO  0x4110u

/* SET_STREAM_FORMAT  (verb 0x2 top nibble) */
#define VERB_SET_FMT(fmt)       (0x20000u | (fmt))
/* SET_STREAM_CHANNEL  (verb 0x706) — stream tag in bits 7-4, channel in 3-0 */
#define VERB_SET_STREAM(tag,ch) (0x70600u | (((tag)&0xF)<<4) | ((ch)&0xF))
/* SET_POWER_STATE D0  (verb 0x705) */
#define VERB_SET_POWER_D0       0x70500u
/* SET_AMP_GAIN_MUTE — output, left+right, unmute, gain=0x7F */
#define VERB_AMP_OUT_UNMUTE     0x3B07Fu   /* 0x3 = output, both sides, unmute */
/* SET_PIN_WIDGET_CTRL — output enable + HP enable (0x40|0x80) */
#define VERB_PIN_OUT_HP         0x70700u | 0xC0u
#define VERB_PIN_OUT_ONLY       0x70700u | 0x40u
/* EAPD enable */
#define VERB_SET_EAPD(v)        (0x70C00u | (v))

/* Widget capability bits */
#define WCAP_TYPE(cap)  (((cap) >> 20) & 0xF)
#define WTYPE_DAC       0x0
#define WTYPE_ADC       0x1
#define WTYPE_MIXER     0x2
#define WTYPE_SELECTOR  0x3
#define WTYPE_PIN       0x4

/* Pin capability: bit 4 = output capable */
#define PINCAP_OUT  (1u << 4)

static void configure_codec(uint8_t cad) {
    /* Get root node count */
    uint32_t nc = GET_PARAM(cad, 0, 0x04);  /* NODE_COUNT */
    if (nc == 0xFFFFFFFF) return;
    uint8_t fg_start = (nc >> 16) & 0xFF;
    uint8_t fg_count = nc & 0xFF;
    serial_puts("[HDA] codec "); serial_hex(cad);
    serial_puts(" fg_start="); serial_hex(fg_start);
    serial_puts(" count="); serial_hex(fg_count); serial_puts("\n");

    /* Find Audio Function Group (type 0x01) */
    int afg = -1;
    for (uint8_t i = fg_start; i < fg_start + fg_count; i++) {
        uint32_t fgt = GET_PARAM(cad, i, 0x05);  /* FUNC_GROUP_TYPE */
        if ((fgt & 0xFF) == 0x01) { afg = i; break; }
    }
    if (afg < 0) { serial_puts("[HDA] no AFG found\n"); return; }
    serial_puts("[HDA] AFG at node "); serial_hex((uint32_t)afg); serial_puts("\n");

    /* Power up AFG */
    codec_verb(cad, (uint8_t)afg, VERB_SET_POWER_D0);
    hda_delay(5);

    /* Get widget list in AFG */
    uint32_t wnc = GET_PARAM(cad, (uint8_t)afg, 0x04);
    uint8_t w_start = (wnc >> 16) & 0xFF;
    uint8_t w_count = wnc & 0xFF;

    /* First pass: find first DAC widget */
    int dac_nid = -1;
    for (uint8_t n = w_start; n < w_start + w_count; n++) {
        uint32_t wcap = GET_PARAM(cad, n, 0x09);  /* AUDIO_WIDGET_CAP */
        if (WCAP_TYPE(wcap) == WTYPE_DAC) {
            dac_nid = n;
            serial_puts("[HDA] DAC at node "); serial_hex(n); serial_puts("\n");
            break;
        }
    }
    if (dac_nid < 0) { serial_puts("[HDA] no DAC found\n"); return; }

    /* Configure DAC: power up, set stream format, assign stream tag 1 ch 0 */
    codec_verb(cad, (uint8_t)dac_nid, VERB_SET_POWER_D0);
    codec_verb(cad, (uint8_t)dac_nid, VERB_SET_FMT(HDA_FMT_22050_16_MONO));
    codec_verb(cad, (uint8_t)dac_nid, VERB_SET_STREAM(1, 0));
    codec_verb(cad, (uint8_t)dac_nid, VERB_AMP_OUT_UNMUTE);

    /* Second pass: find all output-capable PIN widgets and enable them */
    int pins_enabled = 0;
    for (uint8_t n = w_start; n < w_start + w_count; n++) {
        uint32_t wcap = GET_PARAM(cad, n, 0x09);
        if (WCAP_TYPE(wcap) != WTYPE_PIN) continue;
        uint32_t pcap = GET_PARAM(cad, n, 0x0C);  /* PIN_CAP */
        if (!(pcap & PINCAP_OUT)) continue;

        codec_verb(cad, n, VERB_SET_POWER_D0);
        /* Unmute output amp if widget has one */
        uint32_t amp_cap = GET_PARAM(cad, n, 0x12); /* OUTPUT_AMP_CAP */
        if (amp_cap & 0x80000000u)  /* OUTAMP_CAP present */
            codec_verb(cad, n, VERB_AMP_OUT_UNMUTE);
        /* Enable EAPD if supported */
        uint32_t ecap = GET_PARAM(cad, n, 0x0F);   /* check power state caps */
        (void)ecap;
        codec_verb(cad, n, VERB_SET_EAPD(0x02));   /* EAPD bit 1 = enable */
        /* Enable pin output (HP + OUT) */
        codec_verb(cad, n, VERB_PIN_OUT_HP);
        serial_puts("[HDA] PIN "); serial_hex(n); serial_puts(" enabled\n");
        pins_enabled++;
    }

    if (!pins_enabled)
        serial_puts("[HDA] warning: no output PINs found\n");
}

/* ── Fill one BDL entry with fresh mixer output ──────────────────────────── */
static void hda_fill(int entry) {
    audio_mix(_mix8[entry], HDA_BUF_SAMPLES);
    for (int i = 0; i < HDA_BUF_SAMPLES; i++) {
        /* 8-bit unsigned → 16-bit signed: (x - 128) * 256 */
        _pcm16[entry][i] = (int16_t)(((int)_mix8[entry][i] - 128) << 8);
    }
}

/* ── audio_init — try HDA if AC97 not present ────────────────────────────── */
int hda_init(void) {
    /* Scan PCI for HDA controller: class 04, subclass 03 */
    uint32_t hda_pci_id = 0, hda_bar0 = 0;
    uint8_t hda_bus = 0, hda_dev = 0;
    for (int bus = 0; bus < 16 && !hda_present; bus++) {
        for (int dev = 0; dev < 32 && !hda_present; dev++) {
            uint32_t id  = pci_read((uint8_t)bus, (uint8_t)dev, 0, 0x00);
            if (id == 0xFFFFFFFF) continue;
            uint32_t cls = pci_read((uint8_t)bus, (uint8_t)dev, 0, 0x08);
            if (((cls>>24)&0xFF) == 0x04 && ((cls>>16)&0xFF) == 0x03) {
                hda_pci_id = id;
                hda_bar0   = pci_read((uint8_t)bus, (uint8_t)dev, 0, 0x10) & ~0xFu;
                hda_bus    = (uint8_t)bus;
                hda_dev    = (uint8_t)dev;
                hda_present = 1;
            }
        }
    }

    if (!hda_present) {
        serial_puts("[HDA] not found\n");
        return 0;
    }

    serial_puts("[HDA] found id="); serial_hex(hda_pci_id);
    serial_puts(" BAR0="); serial_hex(hda_bar0); serial_puts("\n");

    /* Enable PCI bus-master + memory space */
    uint32_t cmd = pci_read(hda_bus, hda_dev, 0, 0x04);
    pci_write(hda_bus, hda_dev, 0, 0x04, cmd | 0x06);

    /* Map MMIO and set base pointer */
    paging_map_mmio(hda_bar0);
    hda_base = (volatile uint8_t *)(uintptr_t)hda_bar0;

    /* ── Controller reset ─────────────────────────────────────────────────── */
    /* Assert reset (clear CRST) */
    hda_w32(HDA_GCTL, hda_r32(HDA_GCTL) & ~GCTL_CRST);
    hda_delay(2);
    /* De-assert reset */
    hda_w32(HDA_GCTL, hda_r32(HDA_GCTL) | GCTL_CRST);
    /* Wait until controller ready (CRST reads back 1) */
    for (int t = 0; t < 5000; t++) {
        if (hda_r32(HDA_GCTL) & GCTL_CRST) break;
    }
    hda_delay(10);  /* Codec enumeration delay ≥ 521 μs per spec */

    /* ── Read capabilities ────────────────────────────────────────────────── */
    uint16_t gcap   = hda_r16(HDA_GCAP);
    uint8_t  iss    = (gcap >> 8) & 0xF;   /* input stream count  */
    uint8_t  oss    = (gcap >> 12) & 0xF;  /* output stream count */
    serial_puts("[HDA] ISS="); serial_hex(iss);
    serial_puts(" OSS="); serial_hex(oss); serial_puts("\n");
    if (!oss) { serial_puts("[HDA] no output streams\n"); hda_present = 0; return 0; }

    /* First output stream descriptor offset */
    hda_sd_off = HDA_SD_BASE + (uint32_t)iss * HDA_SD_STRIDE;

    /* ── CORB setup ───────────────────────────────────────────────────────── */
    /* Reset CORB read pointer */
    hda_w16(HDA_CORBRP, hda_r16(HDA_CORBRP) | 0x8000);
    for (int t = 0; t < 1000; t++) {
        if (hda_r16(HDA_CORBRP) & 0x8000) break;
    }
    hda_w16(HDA_CORBRP, hda_r16(HDA_CORBRP) & ~0x8000u);

    hda_w32(HDA_CORBLBASE, (uint32_t)(uintptr_t)_corb);
    hda_w32(HDA_CORBUBASE, 0);
    hda_w8 (HDA_CORBSIZE, 0x02);   /* 256 entries */
    hda_w16(HDA_CORBWP, 0);
    hda_w8 (HDA_CORBCTL, 0x02);    /* CORBRUN */
    hda_corb_wp = 0;

    /* ── RIRB setup ───────────────────────────────────────────────────────── */
    /* Reset RIRB write pointer */
    hda_w16(HDA_RIRBWP, 0x8000);
    hda_w32(HDA_RIRBLBASE, (uint32_t)(uintptr_t)_rirb);
    hda_w32(HDA_RIRBUBASE, 0);
    hda_w8 (HDA_RIRBSIZE, 0x02);   /* 256 entries */
    hda_w16(HDA_RINTCNT, 0x00FF);  /* interrupt every 255 responses (not used) */
    hda_w8 (HDA_RIRBCTL, 0x02);    /* RIRBRUN */
    hda_rirb_rp = 0;

    /* ── Find and configure codecs ───────────────────────────────────────── */
    /* Enable wake on all codec slots */
    hda_w16(HDA_WAKEEN, 0x7FFF);
    hda_delay(5);
    uint16_t statests = hda_r16(HDA_STATESTS);
    serial_puts("[HDA] STATESTS="); serial_hex(statests); serial_puts("\n");

    int codec_found = 0;
    for (int cad = 0; cad < 15; cad++) {
        if (statests & (1u << cad)) {
            configure_codec((uint8_t)cad);
            codec_found = 1;
            break;   /* configure first responding codec */
        }
    }
    if (!codec_found) {
        serial_puts("[HDA] no codecs responded\n");
        hda_present = 0;
        return 0;
    }

    /* ── BDL setup ───────────────────────────────────────────────────────── */
    for (int i = 0; i < HDA_BDL_COUNT; i++) {
        hda_fill(i);
        _bdl[i].addr_lo = (uint32_t)(uintptr_t)_pcm16[i];
        _bdl[i].addr_hi = 0;
        _bdl[i].length  = HDA_BUF_BYTES;
        _bdl[i].flags   = BDLE_IOC;
    }
    hda_last_entry = HDA_BDL_COUNT - 1;

    /* ── Stream descriptor setup ──────────────────────────────────────────── */
    /* Reset stream */
    sd_w32(SD_CTL, sd_r32(SD_CTL) | SDCTL_SRST);
    for (int t = 0; t < 1000; t++) {
        if (sd_r32(SD_CTL) & SDCTL_SRST) break;
    }
    sd_w32(SD_CTL, sd_r32(SD_CTL) & ~SDCTL_SRST);
    for (int t = 0; t < 1000; t++) {
        if (!(sd_r32(SD_CTL) & SDCTL_SRST)) break;
    }

    /* Set stream tag=1 in CTL bits 23-20 */
    uint32_t ctl = sd_r32(SD_CTL);
    ctl &= ~(0xFu << 20);
    ctl |=  (0x1u << 20);   /* stream tag 1 */
    sd_w32(SD_CTL, ctl);

    /* Cyclic buffer length */
    sd_w32(SD_CBL, (uint32_t)HDA_CBL);

    /* Last valid index */
    sd_w16(SD_LVI, (uint16_t)(HDA_BDL_COUNT - 1));

    /* Stream format */
    sd_w16(SD_FMT, HDA_FMT_22050_16_MONO);

    /* BDL base address */
    sd_w32(SD_BDPL, (uint32_t)(uintptr_t)_bdl);
    sd_w32(SD_BDPU, 0);

    /* Unsync stream (clear SSYNC bit for stream) */
    hda_w32(HDA_SSYNC, hda_r32(HDA_SSYNC) & ~(1u << (uint32_t)iss));

    /* Start stream */
    sd_w32(SD_CTL, sd_r32(SD_CTL) | SDCTL_RUN);

    serial_puts("[HDA] stream started (22050 Hz 16-bit mono)\n");
    return 1;
}

/* ── audio_refill for HDA ─────────────────────────────────────────────────── */
void hda_refill(void) {
    if (!hda_present) return;

    /* Current byte position in the cyclic buffer */
    uint32_t lpib    = sd_r32(SD_LPIB);
    int cur_entry    = (int)(lpib / HDA_BUF_BYTES) % HDA_BDL_COUNT;

    /* Refill entries between last_entry+1 and cur_entry-1 */
    int next = (hda_last_entry + 1) % HDA_BDL_COUNT;
    while (next != cur_entry) {
        hda_fill(next);
        hda_last_entry = next;
        next = (next + 1) % HDA_BDL_COUNT;
    }
}
