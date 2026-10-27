"""Explicit synthetic audio regression, separate from pending human acceptance."""
import unittest

import numpy as np

from calibration.find_my_sa import CalibrationError, summarize_sample
from practice.alankars import build_timeline, load_alankars
from practice.scoring import score_session
from tools.validate import analyze_samples, synthesize_fixture, synthetic_calibration


class SyntheticAudioPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.state, cls.summaries = synthetic_calibration()
        cls.exercise = next(a for a in load_alankars() if a.id == "alankar_1")
        cls.timeline = build_timeline(cls.exercise, cls.state.confirmed_sa_hz, 72)
        cls.reports = {}
        for variant in ("correct", "wrong", "missing", "sharp", "silent"):
            cls.reports[variant] = score_session(
                cls.timeline, analyze_samples(synthesize_fixture(cls.state.confirmed_sa_hz, variant=variant)))

    def test_audio_drives_calibration_and_confirmed_tonic(self):
        for summary, expected in zip(self.summaries, (130.81, 174.61, 261.63)):
            self.assertAlmostEqual(summary.median_hz, expected, delta=.1)
            self.assertGreater(summary.voiced_fraction,.95)
        self.assertIsNotNone(self.state.confirmed_sa_hz)
        self.assertEqual(self.timeline.sa_hz,self.state.confirmed_sa_hz)
        self.assertGreater(self.state.confirmed_sa_hz,self.summaries[0].median_hz)

    def test_correct_harmonic_audio_is_detected_and_scores_high(self):
        report = self.reports["correct"]
        self.assertGreater(report.overall_accuracy,95)
        self.assertEqual(len(report.notes),5)
        self.assertTrue(all(n.attempted for n in report.notes))
        self.assertTrue(all(n.median_abs_cents < 10 for n in report.notes))

    def test_wrong_notes_and_sharp_audio_reduce_real_observation_score(self):
        correct = self.reports["correct"].overall_accuracy
        self.assertLess(self.reports["wrong"].overall_accuracy,correct - 50)
        self.assertLess(self.reports["sharp"].overall_accuracy,correct - 50)
        self.assertTrue(all(n.valid_duration > .9*n.eligible_duration
                            for n in self.reports["wrong"].notes))

    def test_missing_note_and_silent_audio_remain_in_denominator(self):
        report = self.reports["missing"]
        self.assertAlmostEqual(report.notes[2].accuracy,0)
        self.assertGreater(report.notes[2].missing_duration,.5)
        self.assertAlmostEqual(report.overall_accuracy,80,delta=2)
        self.assertEqual(self.reports["silent"].overall_accuracy,0)
        self.assertTrue(all(not n.attempted for n in self.reports["silent"].notes))

    def test_shifted_singer_calibration_changes_targets_and_observed_pitch(self):
        shifted, _ = synthetic_calibration(octave_shift=1)
        self.assertAlmostEqual(shifted.confirmed_sa_hz/self.state.confirmed_sa_hz,2,delta=.001)
        timeline = build_timeline(self.exercise, shifted.confirmed_sa_hz, 72)
        for lower, higher in zip(self.timeline.notes,timeline.notes):
            self.assertAlmostEqual(higher.frequency/lower.frequency,2)
        observations = analyze_samples(synthesize_fixture(shifted.confirmed_sa_hz))
        self.assertGreater(score_session(timeline,observations).overall_accuracy,95)
        self.assertLess(score_session(self.timeline,observations).overall_accuracy,5)

    def test_silent_recording_cannot_calibrate(self):
        with self.assertRaises(CalibrationError):
            summarize_sample(analyze_samples(np.zeros(3*44100)))


if __name__ == "__main__":
    unittest.main()
