"""Analyze genuine PCM WAV audio with the same independent YIN detector.

Run from repository root: python -m tools.analyze_wav recording.wav --output pitch.csv
No synthetic observations are inserted. --expected-hz is appropriate only for a
known, constant labelled test tone, not an unlabelled singer recording.
"""

import argparse
import csv
import json
import math
from pathlib import Path
import sys
import time
import wave

import numpy as np

from audio.pitch_detector import YinDetector


def read_pcm_wav(path):
    """Return mono float64 PCM plus sample rate; average stereo channels."""
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        if wav.getcomptype() != "NONE":
            raise ValueError("Only uncompressed PCM WAV is supported")
        raw = wav.readframes(wav.getnframes())
    if width == 1:
        samples = (np.frombuffer(raw, dtype=np.uint8).astype(np.float64) - 128) / 128
    elif width == 2:
        samples = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768
    elif width == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        values = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        values = (values ^ 0x800000) - 0x800000
        samples = values.astype(np.float64) / 8388608
    elif width == 4:
        samples = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648
    else:
        raise ValueError(f"Unsupported PCM sample width: {width}")
    return samples.reshape(-1, channels).mean(axis=1), sample_rate


def analyze(path, output, sa_hz=None, expected_hz=None, window=4096, hop=512):
    if window not in (2048, 4096) or hop <= 0:
        raise ValueError("Use a 2048/4096-sample window and positive hop")
    if sa_hz is not None and (not math.isfinite(sa_hz) or sa_hz <= 0):
        raise ValueError("Sa must be positive and finite")
    if expected_hz is not None and (not math.isfinite(expected_hz) or expected_hz <= 0):
        raise ValueError("Expected test-tone frequency must be positive and finite")
    samples, rate = read_pcm_wav(path)
    detector = YinDetector(sample_rate=rate)
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    estimates, timings, errors = [], [], []
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["timestamp_seconds", "frequency_hz", "cents_relative_to_sa", "quality", "rms", "voiced"])
        for start in range(0, len(samples) - window + 1, hop):
            before = time.perf_counter()
            estimate = detector.detect(samples[start:start + window], (start + window / 2) / rate)
            timings.append((time.perf_counter() - before) * 1000)
            estimates.append(estimate)
            cents = estimate.cents(sa_hz) if sa_hz is not None else None
            writer.writerow([estimate.timestamp, estimate.frequency, cents, estimate.quality,
                             estimate.rms, estimate.voiced])
            if expected_hz is not None and estimate.voiced:
                errors.append(abs(1200 * math.log2(estimate.frequency / expected_hz)))
    voiced_hz = [e.frequency for e in estimates if e.voiced]
    result = {
        "source": str(path), "sample_rate": rate, "duration_seconds": len(samples) / rate,
        "frames": len(estimates), "voiced_frames": sum(e.voiced for e in estimates),
        "median_voiced_frequency_hz": float(np.median(voiced_hz)) if voiced_hz else None,
        "window_samples": window, "hop_samples": hop,
        "processing_median_ms": float(np.median(timings)) if timings else None,
        "processing_p95_ms": float(np.percentile(timings, 95)) if timings else None,
        "note": "Observed pitches only. Human-vocal accuracy requires independently labelled real-voice data.",
    }
    if expected_hz is not None:
        result["supplied_constant_ground_truth_hz"] = expected_hz
        result["median_absolute_error_cents"] = float(np.median(errors)) if errors else None
        result["max_absolute_error_cents"] = float(max(errors)) if errors else None
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav")
    parser.add_argument("--output", default="artifacts/pitch.csv")
    parser.add_argument("--sa", type=float)
    parser.add_argument("--expected-hz", type=float, help="Known constant labelled test-tone frequency only")
    parser.add_argument("--window", type=int, choices=(2048, 4096), default=4096)
    args = parser.parse_args(argv)
    try:
        result = analyze(args.wav, args.output, args.sa, args.expected_hz, args.window)
    except (OSError, ValueError, wave.Error) as error:
        print(f"WAV analysis failed: {error}. Convert to uncompressed PCM WAV if needed.", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0 if result["frames"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
