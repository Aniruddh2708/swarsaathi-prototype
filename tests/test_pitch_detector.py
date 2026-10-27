import math
from pathlib import Path
import tempfile
import unittest
import wave

import numpy as np

from audio.pitch_detector import (
    PitchEstimate, PitchSmoother, YinDetector, difference_fft,
    difference_reference, cumulative_mean_normalized_difference,
)
from tools.analyze_wav import analyze, read_pcm_wav


def tone(frequency, sample_rate=44100, length=4096, amplitude=0.25):
    return amplitude * np.sin(2 * np.pi * frequency * np.arange(length) / sample_rate)


class DifferenceTests(unittest.TestCase):
    def test_fft_matches_reference_random_and_dc_offset(self):
        rng = np.random.default_rng(810)
        for length in (127, 2048, 4096):
            samples = rng.normal(0.2, 0.5, length)
            lag = min(750, length - 1)
            np.testing.assert_allclose(difference_fft(samples, lag),
                                       difference_reference(samples, lag), rtol=1e-11, atol=1e-10)

    def test_energy_terms_are_lag_dependent(self):
        # A strong amplitude envelope makes the common fixed-energy shortcut wrong.
        x = np.linspace(0, 10, 250) * np.sin(np.arange(250) * 0.12)
        np.testing.assert_allclose(difference_fft(x, 180), difference_reference(x, 180), atol=1e-9)

    def test_cmndf_definition(self):
        np.testing.assert_allclose(cumulative_mean_normalized_difference([0, 2, 4, 3]), [1, 1, 4/3, 1])


class DetectorTests(unittest.TestCase):
    def test_clean_sines_under_ten_cents_both_sample_rates(self):
        for rate in (44100, 48000):
            for length in (2048, 4096):
                detector = YinDetector(sample_rate=rate)
                for hz in (70, 82.41, 110, 146.83, 196, 233.08, 329.63, 440, 659.25, 880, 1000):
                    with self.subTest(rate=rate, length=length, hz=hz):
                        estimate = detector.detect(tone(hz, rate, length), 1.25)
                        self.assertTrue(estimate.voiced)
                        self.assertLess(abs(1200 * math.log2(estimate.frequency / hz)), 10)
                        self.assertEqual(estimate.timestamp, 1.25)
                        self.assertGreater(estimate.quality, 0.95)

    def test_harmonic_rich_tones(self):
        rate = 44100
        t = np.arange(4096) / rate
        detector = YinDetector()
        for hz in (82.41, 130.81, 233.08, 440):
            x = 0.18*np.sin(2*np.pi*hz*t) + 0.22*np.sin(4*np.pi*hz*t) + 0.1*np.sin(6*np.pi*hz*t)
            estimate = detector.detect(x)
            self.assertTrue(estimate.voiced)
            self.assertLess(abs(1200 * math.log2(estimate.frequency / hz)), 10)

    def test_moderate_noise(self):
        rng = np.random.default_rng(24)
        detector = YinDetector()
        for hz in (110, 220, 440):
            estimate = detector.detect(tone(hz) + rng.normal(0, 0.025, 4096))
            self.assertTrue(estimate.voiced)
            self.assertLess(abs(1200 * math.log2(estimate.frequency / hz)), 10)

    def test_silence_dc_noise_and_invalid_frames_rejected(self):
        detector = YinDetector()
        rng = np.random.default_rng(300)
        for samples in (np.zeros(4096), np.ones(4096)*.8, rng.normal(0,.1,4096),
                        np.full(4096, np.nan), np.ones(4), tone(220, amplitude=.001)):
            estimate = detector.detect(samples)
            self.assertFalse(estimate.voiced)
            self.assertIsNone(estimate.frequency)

    def test_dc_removal(self):
        estimate = YinDetector().detect(tone(196) + .4)
        self.assertTrue(estimate.voiced)
        self.assertLess(abs(1200 * math.log2(estimate.frequency / 196)), 10)

    def test_configurable_gate_range_and_insufficient_cycles(self):
        self.assertTrue(YinDetector(rms_threshold=.0001).detect(tone(220, amplitude=.001)).voiced)
        self.assertFalse(YinDetector(min_frequency=150).detect(tone(110)).voiced)
        self.assertFalse(YinDetector(min_frequency=40).detect(tone(45, length=1024)).voiced)
        self.assertTrue(YinDetector(min_frequency=40).detect(tone(45, length=4096)).voiced)

    def test_raw_octave_transition_not_target_snapped(self):
        detector = YinDetector()
        first = detector.detect(tone(220))
        second = detector.detect(tone(440))
        self.assertAlmostEqual(second.frequency / first.frequency, 2, delta=.002)
        self.assertAlmostEqual(first.cents(220), 0, delta=2)
        self.assertAlmostEqual(second.cents(220), 1200, delta=2)


class SmoothingTests(unittest.TestCase):
    def estimate(self, hz, timestamp):
        return PitchEstimate(timestamp, hz, .99, .1, hz is not None)

    def test_short_median_and_unwrapped_octave_transition(self):
        smoother = PitchSmoother()
        for timestamp, hz in enumerate((220, 221, 219)):
            smoothed = smoother.process(self.estimate(hz, timestamp*.01), 220)
        self.assertAlmostEqual(smoothed.frequency, 220)
        self.assertFalse(smoother.process(self.estimate(440,.03),220).voiced)
        switched = smoother.process(self.estimate(440,.04),220)
        self.assertTrue(switched.voiced)
        self.assertAlmostEqual(switched.cents(220),1200)

    def test_note_change_immediate_and_silence_breaks_trace(self):
        smoother = PitchSmoother()
        smoother.process(self.estimate(220,0),220)
        self.assertAlmostEqual(smoother.process(self.estimate(246.94,.01),220).frequency,246.94)
        self.assertFalse(smoother.process(self.estimate(None,.02),220).voiced)
        self.assertAlmostEqual(smoother.process(self.estimate(110,.4),220).frequency,110)

    def test_new_sa_and_low_confidence(self):
        smoother = PitchSmoother()
        smoother.process(self.estimate(220,0),220)
        changed = smoother.process(self.estimate(330,.01),330)
        self.assertAlmostEqual(changed.cents(330),0)
        low = PitchEstimate(.02,330,.1,.1,True)
        self.assertFalse(smoother.process(low,330).voiced)

    def test_octave_confirmation_requires_consecutive_voiced_frames(self):
        smoother = PitchSmoother()
        smoother.process(self.estimate(220,0),220)
        self.assertFalse(smoother.process(self.estimate(440,.01),220).voiced)
        self.assertFalse(smoother.process(self.estimate(None,.02),220).voiced)
        self.assertFalse(smoother.process(self.estimate(440,.03),220).voiced)
        self.assertTrue(smoother.process(self.estimate(440,.04),220).voiced)


class WavTests(unittest.TestCase):
    def test_pcm_24_and_32_signed_decoding(self):
        with tempfile.TemporaryDirectory() as folder:
            for width in (3,4):
                path = Path(folder)/f"pcm{width}.wav"
                integer = np.array([0,1,-1,2**(8*width-1)-1,-2**(8*width-1)], dtype=np.int64)
                raw = b"".join(int(x).to_bytes(width,"little",signed=True) for x in integer)
                with wave.open(str(path),"wb") as wav:
                    wav.setnchannels(1)
                    wav.setsampwidth(width)
                    wav.setframerate(44100)
                    wav.writeframes(raw)
                decoded, rate = read_pcm_wav(path)
                np.testing.assert_allclose(decoded, integer / 2**(8*width-1),atol=1e-12)
                self.assertEqual(rate,44100)

    def test_pcm_stereo_roundtrip_and_csv_metrics(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"tone.wav"
            samples = tone(220, length=44100)
            stereo = np.column_stack((samples,samples))
            with wave.open(str(path),"wb") as wav:
                wav.setnchannels(2)
                wav.setsampwidth(2)
                wav.setframerate(44100)
                wav.writeframes((stereo*32767).astype("<i2").tobytes())
            read, rate = read_pcm_wav(path)
            self.assertEqual(rate,44100)
            np.testing.assert_allclose(read,samples,atol=4e-5)
            result = analyze(path,Path(folder)/"pitch.csv",220,220)
            self.assertGreater(result["frames"],70)
            self.assertEqual(result["voiced_frames"],result["frames"])
            self.assertLess(result["max_absolute_error_cents"],10)


if __name__ == "__main__":
    unittest.main()
