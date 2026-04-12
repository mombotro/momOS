#include "audio.h"
#include "../cpu/serial.h"
#include <stdint.h>

/* ── AC97 via Intel ICH PCI Audio Controller ────────────────────────────────
   Scans PCI bus for device class 0x04 (multimedia), subclass 0x01 (audio).
   Uses Bus Master DMA for PCM output.                                        */

/* ── PCI access (port I/O method) ──────────────────────────────────────────*/
static void outb(uint16_t p, uint8_t v)  { __asm__ volatile("outb %0,%1"::"a"(v),"Nd"(p)); }
static void outl(uint16_t p, uint32_t v) { __asm__ volatile("outl %0,%1"::"a"(v),"Nd"(p)); }
static uint8_t  inb(uint16_t p)  { uint8_t  v; __asm__ volatile("inb %1,%0":"=a"(v):"Nd"(p)); return v; }
static uint16_t inw(uint16_t p)  { uint16_t v; __asm__ volatile("inw %1,%0":"=a"(v):"Nd"(p)); return v; }
static uint32_t inl(uint16_t p)  { uint32_t v; __asm__ volatile("inl %1,%0":"=a"(v):"Nd"(p)); return v; }

#define PCI_ADDR  0xCF8
#define PCI_DATA  0xCFC

static uint32_t pci_read(uint8_t bus, uint8_t dev, uint8_t fn, uint8_t reg) {
    uint32_t addr = 0x80000000u
        | ((uint32_t)bus << 16) | ((uint32_t)dev << 11)
        | ((uint32_t)fn  <<  8) | (reg & 0xFC);
    outl(PCI_ADDR, addr);
    return inl(PCI_DATA);
}

/* ── AC97 state ─────────────────────────────────────────────────────────────*/
static int      ac97_present   = 0;
static uint32_t ac97_nam_base  = 0;   /* Native Audio Mixer base (I/O) */
static uint32_t ac97_nabm_base = 0;   /* Native Audio Bus Master base (I/O) */

/* DMA buffer: double-buffered, AUDIO_BUF_SAMPLES each */
#define BUFDESC_COUNT  2
static uint8_t  ac97_pcm_buf[BUFDESC_COUNT][AUDIO_BUF_SAMPLES] __attribute__((aligned(4)));

/* Buffer Descriptor List entry */
typedef struct {
    uint32_t addr;    /* physical address */
    uint16_t samples; /* number of samples in buffer */
    uint16_t ctrl;    /* control flags */
} __attribute__((packed)) bdl_entry_t;

#define BDL_IOC   (1 << 15)  /* interrupt on completion */
#define BDL_BUP   (1 << 14)  /* buffer underrun policy: continue */

static bdl_entry_t ac97_bdl[BUFDESC_COUNT] __attribute__((aligned(4)));

/* NABM PCM out registers */
#define NABM_PCMOUT_BDBAR   0x10   /* Buffer Descriptor List Base Address */
#define NABM_PCMOUT_CIV     0x14   /* Current Index Value */
#define NABM_PCMOUT_LVI     0x15   /* Last Valid Index */
#define NABM_PCMOUT_SR      0x16   /* Status Register */
#define NABM_PCMOUT_CR      0x1B   /* Control Register */

#define CR_RPBM  (1 << 0)  /* Run/Pause Bus Master */
#define CR_RR    (1 << 1)  /* Reset */
#define CR_LVBIE (1 << 2)  /* Last Valid Buffer Interrupt Enable */
#define CR_FEIE  (1 << 3)  /* FIFO Error Interrupt Enable */
#define CR_IOCE  (1 << 4)  /* Interrupt on Completion Enable */

static void nabm_outb(uint8_t reg, uint8_t val)  { outb((uint16_t)(ac97_nabm_base + reg), val); }
static void nabm_outl(uint8_t reg, uint32_t val) { outl((uint16_t)(ac97_nabm_base + reg), val); }
static uint8_t nabm_inb(uint8_t reg)  { return inb((uint16_t)(ac97_nabm_base + reg)); }

/* Set NAM volume register (master / PCM out) */
static void nam_outw(uint8_t reg, uint16_t val) { /* write to NAM base */
    __asm__ volatile("outw %0,%1"::"a"(val),"Nd"((uint16_t)(ac97_nam_base + reg)));
}

int audio_init(void) {
    /* Scan PCI bus for AC97 audio controller (class 04, subclass 01) */
    for (int bus = 0; bus < 8; bus++) {
        for (int dev = 0; dev < 32; dev++) {
            uint32_t id = pci_read((uint8_t)bus, (uint8_t)dev, 0, 0);
            if (id == 0xFFFFFFFF) continue;
            uint32_t cls = pci_read((uint8_t)bus, (uint8_t)dev, 0, 8);
            uint8_t  base_class = (cls >> 24) & 0xFF;
            uint8_t  sub_class  = (cls >> 16) & 0xFF;
            if (base_class == 0x04 && sub_class == 0x01) {
                /* Found AC97 — read BAR0 (NAM) and BAR1 (NABM) */
                uint32_t bar0 = pci_read((uint8_t)bus, (uint8_t)dev, 0, 0x10);
                uint32_t bar1 = pci_read((uint8_t)bus, (uint8_t)dev, 0, 0x14);
                ac97_nam_base  = bar0 & ~3u;
                ac97_nabm_base = bar1 & ~3u;
                ac97_present = 1;
                serial_puts("[AC97] found at ");
                serial_hex(id); serial_puts("\n");
                break;
            }
        }
        if (ac97_present) break;
    }

    if (!ac97_present) {
        serial_puts("[AC97] not found — PC speaker only\n");
        return 0;
    }

    /* Reset NABM PCM out channel */
    nabm_outb(NABM_PCMOUT_CR, CR_RR);
    /* Wait for reset to clear */
    for (int i = 0; i < 1000; i++) {
        if (!(nabm_inb(NABM_PCMOUT_CR) & CR_RR)) break;
    }

    /* Set master volume and PCM out volume to 0 dB (no attenuation) */
    nam_outw(0x02, 0x0000);  /* Master volume */
    nam_outw(0x18, 0x0000);  /* PCM out volume */

    /* Set sample rate to 22050 Hz */
    __asm__ volatile("outw %0,%1"::"a"((uint16_t)22050),
                     "Nd"((uint16_t)(ac97_nam_base + 0x2C)));

    /* Set up BDL with two ping-pong buffers */
    for (int i = 0; i < BUFDESC_COUNT; i++) {
        audio_mix(ac97_pcm_buf[i], AUDIO_BUF_SAMPLES);
        ac97_bdl[i].addr    = (uint32_t)(uintptr_t)ac97_pcm_buf[i];
        ac97_bdl[i].samples = AUDIO_BUF_SAMPLES;
        ac97_bdl[i].ctrl    = BDL_IOC;
    }

    /* Program BDL base and last valid index */
    nabm_outl(NABM_PCMOUT_BDBAR, (uint32_t)(uintptr_t)ac97_bdl);
    nabm_outb(NABM_PCMOUT_LVI, BUFDESC_COUNT - 1);

    /* Start the bus master */
    nabm_outb(NABM_PCMOUT_CR, CR_RPBM | CR_IOCE);

    serial_puts("[AC97] PCM out started (22050 Hz 8-bit mono)\n");
    return 1;
}

/* Called periodically (from PIT IRQ or explicit poll) to refill completed buffers */
void audio_refill(void) {
    if (!ac97_present) return;
    uint8_t civ = nabm_inb(NABM_PCMOUT_CIV);
    uint8_t lvi = nabm_inb(NABM_PCMOUT_LVI);
    /* Refill the buffer that was just consumed */
    uint8_t next = (lvi + 1) % BUFDESC_COUNT;
    if (next != civ) {
        audio_mix(ac97_pcm_buf[next], AUDIO_BUF_SAMPLES);
        nabm_outb(NABM_PCMOUT_LVI, next);
    }
}
