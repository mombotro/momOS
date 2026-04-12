#pragma once
#include <stdint.h>

/* ── momOS Audio Subsystem ───────────────────────────────────────────────────
   4 software channels mixed to a single output stream.
   PCM output: 22050 Hz, 8-bit unsigned, mono.
   Backend: AC97 via PCI (with PC speaker fallback for simple tones).        */

#define AUDIO_SAMPLE_RATE   22050
#define AUDIO_CHANNELS      4
#define AUDIO_BUF_SAMPLES   2048   /* DMA buffer size in samples */

/* Waveform types */
#define WAVE_SQUARE    0
#define WAVE_SAWTOOTH  1
#define WAVE_TRIANGLE  2
#define WAVE_NOISE     3
#define WAVE_OFF       4   /* channel silent */

typedef struct {
    uint8_t  wave;       /* WAVE_* */
    uint32_t freq;       /* frequency in Hz (0 = silence) */
    uint8_t  volume;     /* 0–255 */
    uint8_t  active;     /* 1 = playing */
    uint32_t phase;      /* current phase accumulator (fixed-point 16.16) */
    uint32_t lfsr;       /* noise LFSR state */
} audio_chan_t;

/* ── Public API ─────────────────────────────────────────────────────────────*/

/* Initialize audio subsystem. Returns 1 if AC97 found, 0 if PC speaker only. */
int  audio_init(void);

/* Set channel parameters (ch 0–3). */
void audio_set_channel(int ch, uint8_t wave, uint32_t freq, uint8_t vol);

/* Stop a channel. */
void audio_stop_channel(int ch);

/* Stop all channels. */
void audio_stop_all(void);

/* Mix AUDIO_BUF_SAMPLES into dst (called by AC97 IRQ or periodic timer). */
void audio_mix(uint8_t *dst, int samples);

/* PC speaker: play a tone at freq Hz (0 = off). Single-channel only. */
void pcspeaker_tone(uint32_t freq);
