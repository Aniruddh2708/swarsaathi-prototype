"""Deterministic synthetic PCM fixtures only; no pitch implementation or human labels."""
import math, random, struct, sys, wave
from pathlib import Path
root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
rate = 44100
rng = random.Random(3103)
# 0.75 s lead-in and tail; labels describe generated signal, not human singing.
for name, amp, noise, hum, playback in [
    ("silence",0,0,0,0), ("white-noise",0,0.009,0,0),
    ("hum50",0,0,0.008,0), ("hum60",0,0,0.008,0),
    ("quiet-harmonics",0.006,0,0,0), ("quiet-plus-noise",0.006,0.002,0,0),
    ("quiet-plus-hum",0.006,0,0.004,0), ("playback-only",0,0,0,0.08),
    ("quiet-playback-only",0,0,0,0.008),
]:
    duration = 3
    pcm = bytearray()
    for i in range(duration*rate):
        t = i/rate
        active = 0.75 <= t < 2.25
        x = noise*rng.uniform(-1,1)
        x += hum*math.sin(2*math.pi*(60 if name=="hum60" else 50)*t)
        if active:
            x += amp*(math.sin(2*math.pi*220*t)+0.35*math.sin(2*math.pi*440*t))
            x += playback*math.sin(2*math.pi*275*t)
        pcm.extend(struct.pack("<h",round(max(-1,min(32767/32768,x))*32768)))
    with wave.open(str(root/(name+".wav")),"wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(rate); f.writeframes(pcm)
    with (root/(name+".csv")).open("w") as f:
        for i in range(300):
            t = i/100
            hz = 220 if amp and 0.75 <= t < 2.25 else 0
            f.write(f"{t:.2f},{hz}\n")
