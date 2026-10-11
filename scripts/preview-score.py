#!/usr/bin/env python3
"""The App Store preview's soundtrack, written rather than licensed.

An app preview must carry an audio track, and a track somebody owns is a question about who may
use it. This writes thirty seconds of music from numpy: a four-chord loop in A minor at 100 bpm
that arrives in layers — a slow pad, then a plucked arpeggio and a sub bass, then a soft kick, a
shaker and a clap — so the picture's beats (the board, the send, the answer, the approval, the
quotas) have something to land on, and a riser into a last hit at 28.8 s. It is deterministic: the
same run writes the same file.

  scripts/preview-score.py <out.wav> [seconds]
"""
import sys
import wave

import numpy as np

SR = 44100
BPM = 100
BEAT = 60 / BPM
BAR = BEAT * 4

# Each bar: bass note, pad notes, pluck notes (MIDI).
BARS = [
    (45, [57, 60, 64, 67, 71], [57, 60, 64, 67, 71, 67, 64, 60]),
    (41, [53, 57, 60, 64, 67], [53, 57, 60, 64, 67, 64, 60, 57]),
    (48, [52, 55, 59, 60, 62], [48, 55, 60, 62, 64, 62, 60, 55]),
    (43, [50, 55, 59, 64, 67], [50, 55, 59, 62, 67, 62, 59, 55]),
]


def hz(note):
    return 440.0 * 2 ** ((note - 69) / 12)


def tone(freq, seconds, harmonics=((1, 1.0),), detune=0.0):
    t = np.arange(int(seconds * SR)) / SR
    out = np.zeros_like(t)
    for n, amp in harmonics:
        out += amp * np.sin(2 * np.pi * freq * n * (1 + detune) * t)
    return out


def adsr(length, attack, release):
    env = np.ones(length)
    a = int(attack * SR)
    r = int(release * SR)
    if a:
        env[:a] = np.linspace(0, 1, a) ** 1.5
    if r:
        env[-r:] *= np.linspace(1, 0, r) ** 1.5
    return env


def place(mix, clip, start, pan=0.0, gain=1.0):
    """Adds a mono clip to a stereo mix at `start` seconds, panned from -1 to 1."""
    i = int(start * SR)
    if i >= mix.shape[0]:
        return
    n = min(len(clip), mix.shape[0] - i)
    left = gain * np.cos((pan + 1) * np.pi / 4)
    right = gain * np.sin((pan + 1) * np.pi / 4)
    mix[i:i + n, 0] += clip[:n] * left
    mix[i:i + n, 1] += clip[:n] * right


def pad_note(freq, seconds):
    clip = tone(freq, seconds, ((1, 1.0), (2, 0.35), (3, 0.12)), 0.0)
    clip += tone(freq, seconds, ((1, 0.8), (2, 0.25)), 0.004)
    clip += tone(freq, seconds, ((1, 0.8), (2, 0.25)), -0.004)
    return clip * adsr(len(clip), 0.7, 0.9)


def pluck(freq, seconds=1.1):
    t = np.arange(int(seconds * SR)) / SR
    clip = (np.sin(2 * np.pi * freq * t) + 0.5 * np.sin(2 * np.pi * freq * 2 * t) * np.exp(-t * 12)
            + 0.25 * np.sin(2 * np.pi * freq * 3 * t) * np.exp(-t * 18))
    return clip * np.exp(-t * 6.5) * adsr(len(t), 0.003, 0.05)


def kick():
    t = np.arange(int(0.32 * SR)) / SR
    freq = 42 + 90 * np.exp(-t * 38)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    return np.sin(phase) * np.exp(-t * 11) * 1.0


def noise_hit(seconds, decay, rng, bright=True):
    n = rng.standard_normal(int(seconds * SR))
    if bright:
        n = np.concatenate(([0], np.diff(n)))
    t = np.arange(len(n)) / SR
    return n * np.exp(-t * decay)


def clap(rng):
    body = noise_hit(0.18, 22, rng, True) * 0.7
    t = np.arange(len(body)) / SR
    return body + 0.25 * np.sin(2 * np.pi * 190 * t) * np.exp(-t * 30)


def reverb(bus):
    """A few feedback combs and a pair of all-passes: a room, not a hall."""
    out = np.zeros_like(bus)
    for delay, feedback in ((0.0297, 0.62), (0.0371, 0.58), (0.0411, 0.55), (0.0437, 0.5)):
        d = int(delay * SR)
        comb = bus.copy()
        for i in range(d, len(comb)):
            comb[i] += feedback * comb[i - d]
        out += comb
    return out / 4


def echo(bus, delay=BEAT * 0.75, feedback=0.38, taps=4):
    out = bus.copy()
    d = int(delay * SR)
    for k in range(1, taps + 1):
        shifted = np.zeros_like(bus)
        shifted[d * k:] = bus[:len(bus) - d * k] * (feedback ** k)
        shifted = shifted[:, ::-1]
        out += shifted
    return out


def write(path, mix):
    peak = np.max(np.abs(mix))
    mix = np.tanh(mix / max(peak, 1e-9) * 1.35) / np.tanh(1.35) * 0.72
    pcm = (mix * 32767).astype("<i2")
    with wave.open(path, "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm.tobytes())


def main():
    out = sys.argv[1]
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
    rng = np.random.default_rng(1741)
    length = int(seconds * SR)
    pad_bus = np.zeros((length, 2))
    pluck_bus = np.zeros((length, 2))
    drums = np.zeros((length, 2))
    bass_bus = np.zeros((length, 2))
    bars = int(seconds / BAR) + 1
    for b in range(bars):
        bass, padnotes, pluckers = BARS[b % len(BARS)]
        start = b * BAR
        for k, note in enumerate(padnotes):
            place(pad_bus, pad_note(hz(note), BAR + 1.1), start, pan=(-0.5 + k * 0.25), gain=0.11)
        if start >= 4.8:
            for step, note in enumerate(pluckers):
                when = start + step * BEAT / 2
                if when < seconds - 1.3:
                    place(pluck_bus, pluck(hz(note)), when, pan=-0.45 if step % 2 else 0.45, gain=0.16)
        if start >= 7.2:
            for when, length_beats in ((0, 1.4), (BEAT * 2.5, 0.9)):
                clip = tone(hz(bass), length_beats * BEAT * 1.4, ((1, 1.0), (2, 0.2)))
                clip = np.tanh(clip * 1.6) * adsr(len(clip), 0.01, 0.2)
                place(bass_bus, clip, start + when, 0, 0.3)
        if start >= 9.6:
            for beat in range(4):
                place(drums, kick(), start + beat * BEAT, 0, 0.55)
        if start >= 14.4:
            for beat in range(8):
                place(drums, noise_hit(0.07, 70, rng), start + beat * BEAT / 2 + BEAT / 4,
                      0.3 if beat % 2 else -0.3, 0.05)
        if start >= 19.2:
            for beat in (1, 3):
                place(drums, clap(rng), start + beat * BEAT, 0, 0.16)
    riser_start, hit = 26.4, 28.8
    if seconds > hit:
        n = int((hit - riser_start) * SR)
        t = np.arange(n) / SR
        sweep = np.sin(2 * np.pi * np.cumsum(200 * 2 ** (t * 1.3)) / SR) * (t / t[-1]) ** 2
        swell = np.concatenate(([0], np.diff(rng.standard_normal(n)))) * (t / t[-1]) ** 3
        place(drums, sweep * 0.25 + swell * 0.07, riser_start, 0, 1.0)
        place(drums, kick() * 1.4, hit, 0, 0.8)
        place(pad_bus, pad_note(hz(45), 1.8) + pad_note(hz(57), 1.8) + pad_note(hz(64), 1.8), hit, 0, 0.18)
    wet = reverb(pad_bus[:, 0] + pad_bus[:, 1])
    wet_pluck = echo(pluck_bus)
    mix = pad_bus + wet_pluck + drums + bass_bus
    mix[:, 0] += wet * 0.22
    mix[:, 1] += wet[::-1] * 0.22
    fade = int(1.2 * SR)
    mix[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 1.5
    start_fade = int(0.35 * SR)
    mix[:start_fade] *= np.linspace(0, 1, start_fade)[:, None]
    write(out, mix)
    print(f"{out}: {seconds:.1f} s, peak {np.max(np.abs(mix)):.2f}")


if __name__ == "__main__":
    main()
