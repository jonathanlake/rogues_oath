#!/usr/bin/env python3
"""Generate placeholder combat SFX for Rogue's Oath (v0.6.3).

DETERMINISTIC (fixed RNG seed) so re-running reproduces byte-identical wavs — the committed
placeholders and this script travel together, so the future real-SFX pass knows exactly what it
is replacing. Two 44.1 kHz / 16-bit / mono files land beside this script in assets/audio/:

  slash.wav  — ~80 ms noise burst through a DOWNWARD-swept one-pole low-pass. The SWEEP (cutoff
               falling ~8 kHz -> ~2 kHz over the burst), not the noise itself, is what reads
               "swish" instead of "tick". Instant attack, exponential decay. Drives the attack
               SWING (player pitch 1.0, monster 0.85).
  impact.wav — ~120 ms thud: a 110 Hz sine with a fast decay plus a 5 ms noise-click transient.
               The 110 Hz base keeps the death variant (DeathSfx pitch 0.8 ~= 88 Hz) above the
               small-speaker floor. Drives the HIT (player 1.0, monster 0.9) and DeathSfx (0.8;
               pitch_scale also lengthens the tail, so death reads graver than a hit for free).

Run:  python3 assets/audio/generate_placeholder_sfx.py
"""

import math
import os
import random
import struct
import wave

SAMPLE_RATE = 44100
SEED = 20630718  # fixed -> byte-identical output every run (the whole point of committing this)


def _write_wav(path, samples):
    """Write a mono 16-bit PCM wav from an iterable of floats in [-1, 1] (clamped)."""
    frames = bytearray()
    for s in samples:
        v = max(-1.0, min(1.0, s))
        frames += struct.pack("<h", int(v * 32767.0))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(bytes(frames))


def gen_slash(rng):
    """~80 ms white-noise burst through a one-pole low-pass whose coefficient `a` is swept
    high -> low across the buffer. y += a*(x - y); a high near the start (cutoff ~8 kHz) falls to
    a low near the end (cutoff ~2 kHz), so the timbre darkens over the burst — the swish."""
    dur = 0.080
    n = int(SAMPLE_RATE * dur)
    # a = 1 - exp(-2*pi*fc/fs): ~0.68 at 8 kHz, ~0.25 at 2 kHz (precision irrelevant — the sweep is).
    a_start = 0.68
    a_end = 0.25
    y = 0.0
    out = []
    for i in range(n):
        t = i / n
        x = rng.uniform(-1.0, 1.0)              # white-noise source
        a = a_start + (a_end - a_start) * t     # linear downward sweep of the coefficient
        y += a * (x - y)                        # one-pole low-pass
        env = math.exp(-6.0 * t)                # instant attack, exponential decay
        out.append(y * env * 0.9)
    return out


def gen_impact(rng):
    """~120 ms thud: a 110 Hz sine under a fast exponential decay, with a 5 ms noise-click
    transient at the head so the hit has a percussive edge before the body."""
    dur = 0.120
    n = int(SAMPLE_RATE * dur)
    click_n = int(SAMPLE_RATE * 0.005)  # 5 ms noise click
    out = []
    for i in range(n):
        t = i / n
        body = math.sin(2.0 * math.pi * 110.0 * (i / SAMPLE_RATE))
        env = math.exp(-22.0 * t)               # fast decay thud
        s = body * env
        if i < click_n:
            click_env = 1.0 - (i / click_n)     # linear fade over the 5 ms transient
            s += rng.uniform(-1.0, 1.0) * click_env * 0.6
        out.append(s * 0.9)
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rng = random.Random(SEED)
    _write_wav(os.path.join(here, "slash.wav"), gen_slash(rng))
    _write_wav(os.path.join(here, "impact.wav"), gen_impact(rng))
    print("wrote slash.wav and impact.wav to", here)


if __name__ == "__main__":
    main()
