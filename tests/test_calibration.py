"""Synthetic measurement tests, not real-singer validation."""
from dataclasses import replace
import math
import unittest

import numpy as np

from audio.pitch_detector import PitchEstimate, YinDetector
from calibration.find_my_sa import (
    CalibrationError, SessionState, note_name, recommend_sa, summarize_sample,
)
from practice.alankars import load_alankars, build_timeline


def track(frequency=200, seconds=3, quality=.98, voiced=True):
    return [PitchEstimate(float(t), frequency if voiced else None, quality,
                          .1 if voiced else 0, voiced)
            for t in np.arange(0, seconds, .01)]


def summary(frequency):
    return summarize_sample(track(frequency))


def detector_summary(frequency):
    """Independent, explicitly synthetic waveform through the real detector."""
    sample_rate = 44100
    waveform = .25 * np.sin(2 * np.pi * frequency * np.arange(3 * sample_rate) / sample_rate)
    detector = YinDetector(sample_rate=sample_rate)
    observations = [
        detector.detect(waveform[start:start + 4096], (start + 2048) / sample_rate)
        for start in range(0, len(waveform) - 4096 + 1, 512)
    ]
    return summarize_sample(observations)


class SampleTests(unittest.TestCase):
    def test_stable_voice_robust_median_and_statistics(self):
        rng = np.random.default_rng(72)
        rows = [replace(r, frequency=r.frequency * 2 ** (rng.normal(0, 5) / 1200))
                for r in track(220)]
        result = summarize_sample(rows)
        self.assertLess(abs(1200 * math.log2(result.median_hz / 220)), 2)
        self.assertLess(result.stability_cents, 8)
        self.assertGreater(result.voiced_seconds, 2)
        self.assertGreater(result.voiced_fraction, .98)

    def test_trims_unstable_beginnings_and_endings(self):
        rows = [replace(r, frequency=440 if r.timestamp < .29 or r.timestamp > 2.7 else 220)
                for r in track(220)]
        self.assertAlmostEqual(summarize_sample(rows).median_hz, 220)

    def test_silence_rejected(self):
        with self.assertRaisesRegex(CalibrationError, 'Calibration inconclusive'):
            summarize_sample(track(voiced=False))

    def test_low_quality_rejected(self):
        with self.assertRaises(CalibrationError):
            summarize_sample(track(quality=.2))

    def test_unstable_and_octave_alternations_rejected(self):
        rows = [replace(r, frequency=200 * 2 ** ((150 if i % 2 else -150) / 1200))
                for i, r in enumerate(track())]
        with self.assertRaisesRegex(CalibrationError, 'unstable'):
            summarize_sample(rows)

    def test_slow_drift_rejected(self):
        rows = [replace(r, frequency=200 * 2 ** (r.timestamp * 100 / 1200)) for r in track()]
        with self.assertRaises(CalibrationError):
            summarize_sample(rows)

    def test_insufficient_data_rejected(self):
        for rows in ([], track(seconds=.8), track()[::40]):
            with self.subTest(count=len(rows)), self.assertRaises(CalibrationError):
                summarize_sample(rows)

    def test_silent_gaps_reduce_coverage(self):
        rows = [r if r.timestamp < .8 or r.timestamp > 2.3 else replace(r, voiced=False, frequency=None)
                for r in track()]
        with self.assertRaises(CalibrationError):
            summarize_sample(rows)

    def test_timestamp_holes_and_duplicates_cannot_inflate_voice(self):
        rows = track()[::10]
        with self.assertRaises(CalibrationError):
            summarize_sample(rows * 30)

    def test_nonfinite_frequency_does_not_count_as_voice(self):
        with self.assertRaises(CalibrationError):
            summarize_sample([replace(r, frequency=float('nan')) for r in track()])

    def test_invalid_thresholds_rejected(self):
        with self.assertRaises(ValueError):
            summarize_sample(track(), min_coverage=1.1)


class RecommendationTests(unittest.TestCase):
    def test_candidate_is_on_grid_and_all_exercises_fit(self):
        rec = recommend_sa(summary(145), summary(210), summary(350))
        midi = 69 + 12 * math.log2(rec.sa_hz / 440)
        self.assertAlmostEqual(midi, round(midi))
        for exercise in load_alankars():
            for note in build_timeline(exercise, rec.sa_hz).notes:
                self.assertGreaterEqual(note.frequency + 1e-8, rec.low_hz)
                self.assertLessEqual(note.frequency, rec.high_hz + 1e-8)
        self.assertGreater(rec.low_hz, 145)
        self.assertLess(rec.high_hz, 350)
        self.assertIn('not a fixed personal Sa', rec.explanation)

    def test_different_singer_ranges_change_the_recommendation(self):
        lower = recommend_sa(summary(100), summary(150), summary(240))
        upper = recommend_sa(summary(200), summary(300), summary(480))
        self.assertAlmostEqual(upper.sa_hz / lower.sa_hz, 2)

    def test_tonic_is_not_average_of_measurements(self):
        rec = recommend_sa(summary(145), summary(210), summary(350))
        self.assertNotAlmostEqual(rec.sa_hz, (145 + 210 + 350) / 3)

    def test_repeatable_measurement_recommendation(self):
        self.assertEqual(recommend_sa(summary(145), summary(210), summary(350)),
                         recommend_sa(summary(145), summary(210), summary(350)))

    def test_near_tie_uses_lower_safe_candidate_and_discloses_ambiguity(self):
        # F3 puts C#3 and D3 exactly +/-50 cents from the exercise midpoint.
        boundary_middle = 440 * 2 ** ((53 - 69) / 12)
        expected_lower_sa = 440 * 2 ** ((49 - 69) / 12)
        for perturbation_cents in (-1, 0, 1):
            rec = recommend_sa(summary(130.81),
                               summary(boundary_middle * 2 ** (perturbation_cents / 1200)),
                               summary(261.63))
            self.assertAlmostEqual(rec.sa_hz, expected_lower_sa)
            self.assertIn('Ranking is ambiguous', rec.explanation)
            self.assertIn('within 5 cents', rec.explanation)

    def test_candidate_outside_near_tie_band_does_not_override_best_fit(self):
        boundary_middle = 440 * 2 ** ((53 - 69) / 12)
        rec = recommend_sa(summary(130.81), summary(boundary_middle * 2 ** (3 / 1200)),
                           summary(261.63))
        expected_upper_sa = 440 * 2 ** ((50 - 69) / 12)
        self.assertAlmostEqual(rec.sa_hz, expected_upper_sa)
        self.assertNotIn('Ranking is ambiguous', rec.explanation)

    def test_ranking_tolerance_is_configurable_and_validated(self):
        middle_hz = 440 * 2 ** ((53 - 69) / 12) * 2 ** (1 / 1200)
        rec = recommend_sa(summary(130.81), summary(middle_hz), summary(261.63),
                           ranking_tolerance_cents=0)
        self.assertAlmostEqual(rec.sa_hz, 440 * 2 ** ((50 - 69) / 12))
        with self.assertRaises(ValueError):
            recommend_sa(summary(130.81), summary(middle_hz), summary(261.63),
                         ranking_tolerance_cents=-1)

    def test_detector_derived_boundary_recommendation_is_octave_repeatable(self):
        # Regression: sub-cent YIN interpolation formerly flipped C#3 to D4
        # when the same synthetic singer range was shifted exactly one octave.
        recommendations = [recommend_sa(*(detector_summary(hz * 2 ** shift)
                                          for hz in (130.81, 174.61, 261.63)))
                           for shift in (0, 1)]
        self.assertEqual(recommendations[0].note_name, 'C#3')
        self.assertEqual(recommendations[1].note_name, 'C#4')
        self.assertAlmostEqual(recommendations[1].sa_hz / recommendations[0].sa_hz, 2)
        self.assertTrue(all('Ranking is ambiguous' in r.explanation for r in recommendations))

    def test_narrow_range_rejected(self):
        with self.assertRaisesRegex(CalibrationError, 'narrow'):
            recommend_sa(summary(200), summary(225), summary(260))

    def test_bad_stage_order_or_no_separation_rejected(self):
        for measurements in ((220, 200, 350), (200, 201, 350), (200, 250, 250)):
            with self.subTest(measurements=measurements), self.assertRaises(CalibrationError):
                recommend_sa(*(summary(v) for v in measurements))

    def test_no_grid_candidate_rejected_without_reducing_margins(self):
        # Safe tonic interval lies strictly between two adjacent semitone pitches.
        low = 270 * 2 ** (-50 / 1200)
        high = 272 * 2 ** ((700 + 50) / 1200)
        with self.assertRaisesRegex(CalibrationError, 'No standard'):
            recommend_sa(summary(low), summary(330), summary(high))

    def test_custom_negative_octave_exercise_span(self):
        rec = recommend_sa(summary(120), summary(220), summary(430), -12, 7)
        self.assertGreaterEqual(rec.sa_hz / 2 + 1e-8, rec.low_hz)
        self.assertLessEqual(rec.sa_hz * 2 ** (7 / 12), rec.high_hz + 1e-8)

    def test_malformed_summary_rejected(self):
        good = summary(145)
        for bad in (replace(good, accepted_frames=1), replace(good, voiced_fraction=.1),
                    replace(good, median_hz=float('inf')), replace(good, spread_cents=120)):
            with self.subTest(bad=bad), self.assertRaises(CalibrationError):
                recommend_sa(bad, summary(210), summary(350))

    def test_confirmed_sa_survives_new_proposal_and_retry(self):
        first = recommend_sa(summary(145), summary(210), summary(350))
        second = recommend_sa(summary(100), summary(150), summary(240))
        state = SessionState()
        with self.assertRaises(CalibrationError):
            state.confirm()
        state.propose(first)
        self.assertIsNone(state.confirmed_sa_hz)
        self.assertEqual(state.confirm(), first.sa_hz)
        state.propose(second)
        self.assertEqual(state.confirmed_sa_hz, first.sa_hz)
        state.reset()
        self.assertEqual(state.confirmed_sa_hz, first.sa_hz)
        self.assertIsNone(state.recommendation)
        state.confirm(second)
        self.assertEqual(state.confirmed_sa_hz, second.sa_hz)
        state.reset(clear_confirmed=True)
        self.assertIsNone(state.confirmed_sa_hz)

    def test_note_names_and_invalid_inputs(self):
        self.assertEqual(note_name(440), 'A4')
        self.assertEqual(note_name(261.6255653), 'C4')
        with self.assertRaises(ValueError):
            note_name(0)


if __name__ == '__main__':
    unittest.main()
