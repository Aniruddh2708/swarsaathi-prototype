"""Reproducible, explicitly SYNTHETIC engineering validation; never live audio.

Run ``python -m tools.validate`` from the repository root. Generated audio is a
labelled test fixture, not a singer recording. Detector observations are obtained
by processing those samples; the target timeline never populates observations.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import time
import wave

import numpy as np

from audio.pitch_detector import YinDetector, difference_fft, difference_reference
from calibration.find_my_sa import SessionState, summarize_sample, recommend_sa
from practice.alankars import build_timeline, load_alankars
from practice.scoring import score_session


SAMPLE_RATE = 44100
WINDOW_SAMPLES = 4096
HOP_SAMPLES = 512
# Independent, documented Alankar 1 test fixture; deliberately separate from the
# application's loaded target definitions so changes/errors cannot self-validate.
FIXTURE_SEMITONES = (0, 2, 4, 2, 0)


def analyze_samples(samples, sample_rate=SAMPLE_RATE):
    """Use the production detector on explicit test waveform windows."""
    samples = np.asarray(samples, dtype=np.float64)
    detector = YinDetector(sample_rate=sample_rate)
    return [detector.detect(samples[start:start + WINDOW_SAMPLES],
                            (start + WINDOW_SAMPLES / 2) / sample_rate)
            for start in range(0, len(samples) - WINDOW_SAMPLES + 1, HOP_SAMPLES)]


def synthetic_tone(frequency, duration=3.0, sample_rate=SAMPLE_RATE):
    return 0.25 * np.sin(2 * np.pi * frequency * np.arange(round(duration * sample_rate)) / sample_rate)


def synthetic_calibration(octave_shift=0):
    """Three labelled sine-wave measurements; no claim of vocal validity."""
    frequencies = (130.81, 174.61, 261.63)
    summaries = [summarize_sample(analyze_samples(synthetic_tone(hz * 2 ** octave_shift)))
                 for hz in frequencies]
    recommendation = recommend_sa(*summaries, min_semitones=0, max_semitones=7)
    state = SessionState()
    state.propose(recommendation)
    state.confirm()
    return state, summaries


def synthesize_fixture(sa_hz, bpm=72, variant="correct", sample_rate=SAMPLE_RATE):
    """Independently synthesize a labelled Alankar 1 test performance.

    This does not use reference_audio or target note objects. ``wrong`` moves all
    observed notes two semitones, ``missing`` silences the third, ``sharp`` adds
    40 cents, and ``silent`` has no signal. These are offline test modes only.
    """
    if variant not in ("correct", "wrong", "missing", "sharp", "silent"):
        raise ValueError("Unknown explicitly synthetic fixture variant")
    beat_seconds = 60.0 / bpm
    samples = np.zeros(round(len(FIXTURE_SEMITONES) * beat_seconds * sample_rate), dtype=np.float64)
    for index, semitones in enumerate(FIXTURE_SEMITONES):
        if variant == "silent" or (variant == "missing" and index == 2):
            continue
        extra_cents = 200 if variant == "wrong" else 40 if variant == "sharp" else 0
        frequency = sa_hz * 2 ** ((100 * semitones + extra_cents) / 1200)
        first = round(index * beat_seconds * sample_rate)
        last = round((index + 1) * beat_seconds * sample_rate)
        phase = 2 * np.pi * frequency * np.arange(last - first) / sample_rate
        # Harmonics exercise F0 extraction rather than a direct frequency path.
        samples[first:last] = .22 * np.sin(phase) + .08 * np.sin(2 * phase) + .04 * np.sin(3 * phase)
    return samples


def pipeline_metrics(wav_output=None):
    state, summaries = synthetic_calibration()
    exercise = next(a for a in load_alankars() if a.id == "alankar_1")
    timeline = build_timeline(exercise, state.confirmed_sa_hz, 72)
    scores, voiced_counts = {}, {}
    for variant in ("correct", "wrong", "missing", "sharp", "silent"):
        samples = synthesize_fixture(state.confirmed_sa_hz, variant=variant)
        observations = analyze_samples(samples)
        report = score_session(timeline, observations)
        scores[variant] = report.overall_accuracy
        voiced_counts[variant] = sum(o.voiced for o in observations)
        if variant == "correct" and wav_output is not None:
            path = Path(wav_output)
            path.parent.mkdir(parents=True, exist_ok=True)
            with wave.open(str(path), "wb") as handle:
                handle.setnchannels(1)
                handle.setsampwidth(2)
                handle.setframerate(SAMPLE_RATE)
                handle.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
    return {
        "label": "SYNTHETIC audio -> YIN -> calibration -> confirmed Sa -> target comparison and score",
        "calibration_input_hz": [130.81, 174.61, 261.63],
        "calibration_measured_median_hz": [s.median_hz for s in summaries],
        "recommended_sa_hz": state.confirmed_sa_hz,
        "pitch_match_scores_percent": scores,
        "voiced_observations": voiced_counts,
        "synthetic_wav": str(wav_output) if wav_output is not None else None,
        "human_voice_validated": False,
    }


def detector_metrics(iterations=1000):
    if iterations < 1:
        raise ValueError("Benchmark iterations must be positive")
    errors = []
    for rate in (44100, 48000):
        for length in (2048, 4096):
            detector = YinDetector(sample_rate=rate)
            for hz in (70, 82.41, 110, 146.83, 196, 233.08, 329.63, 440, 659.25, 880, 1000):
                samples = .25 * np.sin(2 * np.pi * hz * np.arange(length) / rate)
                observed = detector.detect(samples)
                if not observed.voiced:
                    raise RuntimeError(f"Clean synthetic tone rejected: {hz} Hz, {rate} Hz rate, {length} samples")
                errors.append(abs(1200 * math.log2(observed.frequency / hz)))
    samples = .25 * np.sin(2 * np.pi * 220 * np.arange(WINDOW_SAMPLES) / SAMPLE_RATE)
    detector = YinDetector()
    for _ in range(20):
        detector.detect(samples)
    milliseconds = []
    for _ in range(iterations):
        before = time.perf_counter()
        detector.detect(samples)
        milliseconds.append((time.perf_counter() - before) * 1000)
    random_samples = np.random.default_rng(42).normal(0, .5, WINDOW_SAMPLES)
    error = float(np.max(np.abs(difference_reference(random_samples, 678)
                                - difference_fft(random_samples, 678))))
    return {
        "label": "Synthetic tones and warmed detector-only cloud CPU benchmark; NOT human vocal accuracy or GUI latency",
        "clean_tone_cases": len(errors),
        "clean_max_absolute_cents": max(errors),
        "clean_median_absolute_cents": float(np.median(errors)),
        "detector_calls": iterations,
        "window_samples": WINDOW_SAMPLES,
        "sample_rate": SAMPLE_RATE,
        "hop_samples": HOP_SAMPLES,
        "processing_median_ms": float(np.median(milliseconds)),
        "processing_p95_ms": float(np.percentile(milliseconds, 95)),
        "fft_reference_max_absolute_difference": error,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="artifacts/detector_metrics.json")
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--wav-output", default="artifacts/synthetic_practice.wav")
    parser.add_argument("--skip-pipeline", action="store_true", help="Only validate/benchmark the detector")
    args = parser.parse_args(argv)
    if args.iterations < 1:
        parser.error("--iterations must be positive")
    result = detector_metrics(args.iterations)
    if not args.skip_pipeline:
        result["pipeline"] = pipeline_metrics(args.wav_output)
    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    failed = result["clean_max_absolute_cents"] > 10 or result["fft_reference_max_absolute_difference"] > 1e-8
    if "pipeline" in result:
        scores = result["pipeline"]["pitch_match_scores_percent"]
        failed |= (scores["correct"] < 95 or scores["silent"] > 0 or scores["wrong"] >= scores["correct"]
                   or scores["missing"] >= scores["correct"] or scores["sharp"] >= scores["correct"])
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
