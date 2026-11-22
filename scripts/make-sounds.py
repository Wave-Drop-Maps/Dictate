#!/usr/bin/env python3
"""Generates Dictate's interface sounds (soft, low 'pops') into ../sounds/. Original audio, no samples used."""
import math, os, struct, wave

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sounds")


def pop(f0, f1, dur, glide, decay, gain, second=0.18, body=0.12):
    """Fast attack, pitch glides from f0 down to f1, smooth exponential decay."""
    n = int(SR * dur)
    phase, s = 0.0, []
    for i in range(n):
        t = i / SR
        f = f1 + (f0 - f1) * math.exp(-t / glide)
        phase += 2 * math.pi * f / SR
        env = min(1, t / 0.004) * math.exp(-t / decay)
        s.append(env * (math.sin(phase) + second * math.sin(2 * phase) + body * math.sin(0.5 * phase)))
    peak = max(abs(v) for v in s)
    fade = int(SR * 0.01)
    for i in range(fade):
        s[-1 - i] *= i / fade
    return [v / peak * gain for v in s]


def write(name, sig):
    with wave.open(os.path.join(OUT, f"{name}.wav"), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in sig))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    g = 10 ** (-17 / 20)
    gap = [0.0] * int(SR * 0.055)
    write("start", pop(520, 360, 0.17, 0.035, 0.045, g))
    write("stop", pop(440, 290, 0.21, 0.045, 0.060, g))
    write("handsfree", pop(470, 340, 0.11, 0.03, 0.035, g * 0.85) + gap + pop(560, 400, 0.13, 0.03, 0.04, g * 0.85))
    write("cancel", pop(330, 220, 0.16, 0.04, 0.045, g * 0.85))
    write("notice", pop(420, 300, 0.11, 0.03, 0.035, g * 0.8) + gap + pop(330, 230, 0.15, 0.04, 0.05, g * 0.8))
