#include "audio.h"
#include "../cpu/serial.h"
#include <stdint.h>

static audio_chan_t chans[AUDIO_CHANNELS];

/* Phase step for a given frequency at 22050 Hz (fixed-point 16.16) */
static uint32_t phase_step(uint32_t freq) {
    /* step = freq * 65536 / sample_rate */
    return (uint32_t)(((uint64_t)freq << 16) / AUDIO_SAMPLE_RATE);
}

void audio_set_channel(int ch, uint8_t wave, uint32_t freq, uint8_t vol) {
    if (ch < 0 || ch >= AUDIO_CHANNELS) return;
    audio_chan_t *c = &chans[ch];
    c->wave   = wave;
    c->freq   = freq;
    c->volume = vol;
    c->active = (wave != WAVE_OFF && freq > 0 && vol > 0) ? 1 : 0;
    if (!c->active) c->phase = 0;
    if (c->lfsr == 0) c->lfsr = 0xACE1u;
}

void audio_stop_channel(int ch) {
    if (ch < 0 || ch >= AUDIO_CHANNELS) return;
    chans[ch].active = 0;
    chans[ch].phase  = 0;
}

void audio_stop_all(void) {
    for (int i = 0; i < AUDIO_CHANNELS; i++) audio_stop_channel(i);
}

/* Mix one sample from a single channel, advance phase. Returns -128..127. */
static int mix_chan(audio_chan_t *c) {
    if (!c->active) return 0;
    uint32_t step = phase_step(c->freq);
    int32_t  s    = 0;

    switch (c->wave) {
    case WAVE_SQUARE:
        s = (c->phase < 0x8000u) ? 127 : -128;
        break;
    case WAVE_SAWTOOTH:
        s = (int32_t)(c->phase >> 8) - 128;  /* 0..255 → -128..127 */
        break;
    case WAVE_TRIANGLE: {
        uint32_t p = c->phase;
        if (p < 0x8000u) s = (int32_t)((p >> 7) - 128);
        else              s = (int32_t)(128 - (int32_t)((p - 0x8000u) >> 7));
        break;
    }
    case WAVE_NOISE:
        c->lfsr = (c->lfsr >> 1) ^ ((c->lfsr & 1) ? 0xB400u : 0);
        s = ((int32_t)(c->lfsr & 0xFF)) - 128;
        break;
    default:
        break;
    }

    c->phase = (c->phase + step) & 0xFFFFu;
    return (s * (int32_t)c->volume) >> 8;
}

void audio_mix(uint8_t *dst, int samples) {
    for (int i = 0; i < samples; i++) {
        int32_t sum = 0;
        for (int ch = 0; ch < AUDIO_CHANNELS; ch++)
            sum += mix_chan(&chans[ch]);
        /* Clamp to 8-bit unsigned */
        sum = (sum >> 2) + 128;  /* divide by 4 channels, shift to 0–255 */
        if (sum < 0)   sum = 0;
        if (sum > 255) sum = 255;
        dst[i] = (uint8_t)sum;
    }
}
