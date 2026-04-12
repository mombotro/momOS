# momOS Sound Module (.msm) Format

## Overview

`.msm` is a binary music tracker format for the Chirp app.
Supports 4 channels, 64 patterns, 32 rows per pattern, 16 instrument presets.
All integers are little-endian unless noted.

---

## File Layout

```
[Header — 32 bytes]
[Instrument Table — 16 × 16 bytes = 256 bytes]
[Song Order Table — 64 bytes]
[Pattern Data — pattern_count × 32 × 4 channels × 4 bytes = variable]
```

---

## Header (32 bytes)

| Offset | Size | Field           | Description                              |
|--------|------|-----------------|------------------------------------------|
| 0      | 4    | magic           | `"MSM1"` (ASCII)                         |
| 4      | 1    | bpm             | Beats per minute (1–255, default 120)    |
| 5      | 1    | ticks_per_row   | Ticks per row (1–16, default 6)          |
| 6      | 1    | pattern_count   | Number of patterns used (1–64)           |
| 7      | 1    | song_length     | Number of entries in song order (1–64)   |
| 8      | 24   | reserved        | Zero-padded                              |

---

## Instrument Table (256 bytes)

16 instruments × 16 bytes each:

| Offset | Size | Field      | Description                                |
|--------|------|------------|--------------------------------------------|
| 0      | 1    | waveform   | 0=square 1=sawtooth 2=triangle 3=noise     |
| 1      | 1    | attack     | Attack time (0–255, in ticks)              |
| 2      | 1    | decay      | Decay time (0–255, in ticks)               |
| 3      | 1    | sustain    | Sustain level (0–255)                      |
| 4      | 1    | release    | Release time (0–255, in ticks)             |
| 5      | 1    | volume     | Base volume (0–255)                        |
| 6      | 1    | vibrato    | Vibrato depth (0=none)                     |
| 7      | 1    | vibspeed   | Vibrato speed (ticks per cycle)            |
| 8      | 8    | reserved   | Zero-padded                                |

---

## Song Order Table (64 bytes)

64 single-byte entries, each containing a pattern index (0–63).
Only the first `song_length` entries are used.
A value of `0xFF` marks the end of the song.

---

## Pattern Data

`pattern_count` patterns in order, each 32 rows × 4 channels:

### Row (4 bytes per channel)

| Offset | Size | Field       | Description                                        |
|--------|------|-------------|----------------------------------------------------|
| 0      | 1    | note        | Note value: 0=empty, 1–96=note (C-0 to B-7)       |
| 1      | 1    | instrument  | Instrument index (0–15; 0=use last)                |
| 2      | 1    | volume      | Volume override (0–255; 0=use instrument default)  |
| 3      | 1    | effect      | Effect byte (see Effects table)                    |

A row with note=0, instrument=0, volume=0, effect=0 is an empty row.

---

## Note Encoding

```
note = (octave * 12) + semitone + 1
semitone: C=0 C#=1 D=2 D#=3 E=4 F=5 F#=6 G=7 G#=8 A=9 A#=10 B=11
```

Examples: C-4 = (4*12)+0+1 = 49,  A-4 = (4*12)+9+1 = 58

---

## Effects Table

| Value | Effect           | Description                                 |
|-------|-----------------|---------------------------------------------|
| 0x00  | None            | No effect                                   |
| 0x01  | Arpeggio        | Alternates between three notes each tick    |
| 0x02  | Slide Up        | Pitch slides up by N semitones              |
| 0x03  | Slide Down      | Pitch slides down by N semitones            |
| 0x04  | Vibrato         | Pitch LFO (overrides instrument vibrato)    |
| 0x05  | Tremolo         | Volume LFO                                  |
| 0x06  | Delay           | Note delay by N ticks                       |
| 0x07  | Cut             | Note cut after N ticks                      |
| 0x08  | Reserved        | (future use)                                |

---

## Playback

**Tick rate**: `bpm × ticks_per_row / 60` ticks per second (at the mixer level).
**Row advance**: Every `ticks_per_row` ticks, advance to the next row.
**Pattern advance**: After row 31, follow the song order table.
**Loop**: When `song_length` entries are exhausted, loop to order entry 0.

---

## Limits

| Property        | Min | Max |
|-----------------|-----|-----|
| BPM             | 1   | 255 |
| Ticks per row   | 1   | 16  |
| Patterns        | 1   | 64  |
| Song length     | 1   | 64  |
| Rows per pattern| 32  | 32  |
| Channels        | 4   | 4   |
| Instruments     | 16  | 16  |
