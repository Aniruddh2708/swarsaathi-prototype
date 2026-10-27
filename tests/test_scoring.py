from dataclasses import asdict
import json
import math
import unittest

from practice.alankars import Alankar, Note, build_timeline, load_alankars
from practice.scoring import Observation, score_session


def track(timeline, modifier=lambda note, t: note.frequency):
    """Independent simulated observations, explicitly not microphone evidence."""
    result = []
    for index in range(math.ceil(timeline.duration / .01)):
        timestamp = index * .01 + .005
        note = timeline.at(timestamp)
        if note is not None:
            frequency = modifier(note, timestamp)
            result.append(Observation(timestamp, frequency, voiced=frequency is not None))
    return result


class ScoringTests(unittest.TestCase):
    def setUp(self):
        self.timeline = build_timeline(load_alankars()[0], 220, 60)

    def test_perfect_matching_track(self):
        report = score_session(self.timeline, track(self.timeline))
        self.assertAlmostEqual(report.overall_accuracy, 100)
        self.assertTrue(all(n.attempted and n.accuracy == 100 for n in report.notes))
        self.assertEqual(report.notes[0].expected_intervals, 40)
        self.assertAlmostEqual(report.notes[0].eligible_duration, .8)
        json.dumps(asdict(report), allow_nan=False)

    def test_wrong_and_sharp_flat_scores_fall(self):
        for cents in [40, -40, 200, -200, 1200]:
            with self.subTest(cents=cents):
                report = score_session(self.timeline, track(self.timeline, lambda n, t: n.frequency * 2 ** (cents / 1200)))
                self.assertEqual(report.overall_accuracy, 0)
                self.assertAlmostEqual(report.notes[0].median_abs_cents, abs(cents))

    def test_missing_note_and_silence_penalized(self):
        report = score_session(self.timeline, track(self.timeline, lambda n, t: None if n.index == 2 else n.frequency))
        self.assertAlmostEqual(report.overall_accuracy, 80)
        self.assertEqual(report.notes[2].accuracy, 0)
        self.assertFalse(report.notes[2].attempted)
        self.assertAlmostEqual(report.notes[2].missing_duration, .8)
        self.assertEqual(score_session(self.timeline, []).overall_accuracy, 0)
        silent = track(self.timeline, lambda n, t: None)
        self.assertEqual(score_session(self.timeline, silent).overall_accuracy, 0)

    def test_partial_silence_keeps_full_denominator(self):
        observations = track(self.timeline, lambda n, t: n.frequency if (t - n.start) < .5 else None)
        report = score_session(self.timeline, observations)
        self.assertAlmostEqual(report.overall_accuracy, 50)
        self.assertTrue(all(n.valid_intervals == n.expected_intervals / 2 for n in report.notes))

    def test_unreliable_nan_frames_are_missing(self):
        for frequency, quality, voiced in [(220, .5, True), (math.nan, 1, True), (220, math.nan, True),
                                         (220, 1, False), (-1, 1, True)]:
            bad = [Observation(t * .01, frequency, quality, voiced) for t in range(500)]
            report = score_session(self.timeline, bad)
            self.assertEqual(report.overall_accuracy, 0)
            self.assertTrue(all(n.valid_duration == 0 for n in report.notes))

    def test_sparse_stale_duplicates_do_not_fill_silence(self):
        # One measurement has support in only one cell, even when duplicated.
        single = [Observation(.51, 220)]
        report = score_session(self.timeline, single * 1000)
        self.assertEqual(report.notes[0].correct_intervals, 1)
        self.assertAlmostEqual(report.notes[0].accuracy, 2.5)
        self.assertAlmostEqual(report.overall_accuracy, .5)
        self.assertEqual(score_session(self.timeline, [Observation(-1, 220)]).overall_accuracy, 0)

    def test_order_and_duplicate_invariance(self):
        observations = track(self.timeline)
        original = score_session(self.timeline, observations)
        duplicated = score_session(self.timeline, list(reversed(observations)) * 3)
        self.assertEqual(asdict(original), asdict(duplicated))

    def test_grace_handles_small_timing_shift_but_not_large_drift(self):
        def shifted(delay):
            result = []
            for index in range(500):
                timestamp = index * .01 + .005
                note = self.timeline.at(timestamp - delay)
                result.append(Observation(timestamp, note.frequency if note else None, voiced=note is not None))
            return result
        self.assertEqual(score_session(self.timeline, shifted(.08)).overall_accuracy, 100)
        self.assertEqual(score_session(self.timeline, shifted(-.08)).overall_accuracy, 100)
        late = score_session(self.timeline, shifted(.3))
        early = score_session(self.timeline, shifted(-.3))
        self.assertLess(late.overall_accuracy, 90)
        self.assertLess(early.overall_accuracy, 90)
        self.assertTrue(any('alignment confidence' in s for s in late.limitations))

    def test_equal_note_weights_for_different_durations(self):
        timeline = build_timeline(Alankar('x', 'Unequal', (Note('Sa', 0, beats=1), Note('Re', 2, beats=3))), 220, 60)
        result = score_session(timeline, track(timeline, lambda n, t: n.frequency if n.index == 0 else None))
        self.assertEqual(result.overall_accuracy, 50)

    def test_shifted_sa_and_octave_target(self):
        timeline = build_timeline(Alankar('x', 'Octave', (Note('Sa', 0, 1),)), 261.625565, 60)
        self.assertEqual(score_session(timeline, track(timeline)).overall_accuracy, 100)
        self.assertEqual(score_session(timeline, track(timeline, lambda n, t: n.frequency / 2)).overall_accuracy, 0)
        self.assertEqual(timeline.graph_points()[1], [1200, 1200])

    def test_grace_cannot_be_arbitrarily_inflated(self):
        baseline = score_session(self.timeline, [], grace_seconds=.1)
        exaggerated = score_session(self.timeline, [], grace_seconds=100)
        self.assertEqual(asdict(baseline), asdict(exaggerated))

    def test_invalid_parameters_rejected(self):
        for kwargs in [{'frame_seconds': 1}, {'frame_seconds': 0}, {'max_observation_age': 1},
                       {'grace_seconds': -1}, {'tolerance_cents': math.nan}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                score_session(self.timeline, [], **kwargs)


if __name__ == '__main__':
    unittest.main()
