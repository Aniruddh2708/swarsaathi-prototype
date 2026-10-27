import math
import unittest

from practice.alankars import Alankar, Note, build_timeline, load_alankars
from practice.pitch_comparator import compare, nearest_swara, scoring_interval


class ComparatorTests(unittest.TestCase):
    def setUp(self):
        self.timeline = build_timeline(load_alankars()[0], 220, 60)

    def test_pitch_status_and_error(self):
        for cents, status in [(0, 'On Pitch'), (30, 'On Pitch'), (-30, 'On Pitch'),
                              (40, 'Slightly High'), (-40, 'Slightly Low'),
                              (200, 'Wrong Swara'), (1200, 'Wrong Swara')]:
            with self.subTest(cents=cents):
                result = compare(self.timeline, .5, 220 * 2 ** (cents / 1200))
                self.assertEqual(result.status, status)
                self.assertAlmostEqual(result.cents_error, cents, places=8)

    def test_reject_unreliable_observations(self):
        for frequency, quality, voiced in [(None, 1, True), (0, 1, True), (-220, 1, True),
                                         (math.nan, 1, True), (math.inf, 1, True),
                                         (220, .79, True), (220, math.nan, True),
                                         (220, 1.1, True), (220, 1, False)]:
            with self.subTest(frequency=frequency, quality=quality, voiced=voiced):
                result = compare(self.timeline, .5, frequency, quality, voiced)
                self.assertEqual(result.status, 'No Reliable Voice')
                self.assertIsNone(result.cents_error)

    def test_boundaries_and_timeline(self):
        for timestamp in [-1, 0, .099, .9, .999, 1, self.timeline.duration]:
            with self.subTest(timestamp=timestamp):
                self.assertEqual(compare(self.timeline, timestamp, 220).status,
                                 'Transition / Unscored Boundary')
        self.assertEqual(compare(self.timeline, .1, 220).status, 'On Pitch')
        self.assertEqual(compare(self.timeline, 1.5, 220).status, 'Wrong Swara')
        self.assertIn('timing', compare(self.timeline, 1.5, 220).timing_warning)

    def test_grace_is_absolutely_bounded(self):
        first = self.timeline.notes[0]
        self.assertEqual(scoring_interval(first, 100), (.1, .9))
        short = build_timeline(Alankar('x', 'Short', (Note('Sa', 0, beats=.1),)), 220, 60)
        self.assertAlmostEqual(scoring_interval(short.notes[0])[0], .02)
        self.assertAlmostEqual(scoring_interval(short.notes[0])[1], .08)

    def test_all_chromatic_notes_and_octaves(self):
        names = [nearest_swara(220 * 2 ** (n / 12), 220) for n in range(12)]
        self.assertEqual(len(set(names)), 12)
        self.assertIn('komal Re', names[1])
        self.assertIn('tivra Ma', names[6])
        self.assertIn('+1 octave', nearest_swara(440, 220))
        self.assertIn('-1 octave', nearest_swara(110, 220))

    def test_changed_sa_changes_targets_and_comparison(self):
        shifted = build_timeline(self.timeline.alankar, 261.625565, 60)
        self.assertEqual(compare(shifted, .5, shifted.sa_hz).status, 'On Pitch')
        self.assertEqual(compare(shifted, .5, 220).status, 'Wrong Swara')
        self.assertEqual(self.timeline.graph_points(), shifted.graph_points())
        for a, b in zip(self.timeline.notes, shifted.notes):
            self.assertAlmostEqual(b.frequency / a.frequency, shifted.sa_hz / 220)


if __name__ == '__main__':
    unittest.main()
