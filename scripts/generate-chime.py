#!/usr/bin/env python3
"""Original DevFlow soft two-note bell, synthesized without sampled audio."""
import math
import pathlib
import struct
import wave

RATE = 48000
DURATION = 0.72
samples = []
for i in range(round(RATE * DURATION)):
    t = i / RATE
    value = 0.0
    for start, frequency, gain in [(0.0, 1046.5, 0.26), (0.105, 1568.0, 0.17)]:
        u = t - start
        if u < 0:
            continue
        envelope = (1 - math.exp(-u / 0.006)) * math.exp(-u / 0.115)
        fundamental = math.sin(2 * math.pi * frequency * u)
        overtone = 0.12 * math.sin(2 * math.pi * frequency * 2.003 * u) * math.exp(-u / 0.05)
        value += gain * envelope * (fundamental + overtone)
    value *= min(1.0, max(0.0, (DURATION - t) / 0.03))
    samples.append(round(value * 32767))
path = pathlib.Path(__file__).resolve().parents[1] / 'DevFlow/Resources/DevFlowChime.wav'
with wave.open(str(path), 'wb') as out:
    out.setparams((1, 2, RATE, len(samples), 'NONE', 'not compressed'))
    out.writeframes(struct.pack('<' + 'h' * len(samples), *samples))
print(f'{path.name}: {DURATION:.2f}s, peak {max(abs(x) for x in samples)/32767:.3f}, original synthesis')
