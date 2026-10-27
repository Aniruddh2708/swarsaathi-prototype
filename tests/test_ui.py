"""Offscreen software integration checks; injected data are synthetic test fixtures."""
import csv
import json
import math
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

import numpy as np
from PyQt6.QtWidgets import QApplication

from audio.capture import AudioError, AudioFrame
from audio.pitch_detector import PitchEstimate
from calibration.find_my_sa import SampleSummary, recommend_sa
from ui.main_window import MainWindow


class Clock:
    def __init__(self):
        self.now = 100.

    def __call__(self):
        return self.now


class Capture:
    fail = False

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.running = False
        self.error = None
        self.sample_rate = 44100
        self.metrics = {'dropped_samples': 0, 'overruns': 0}

    def start(self):
        if self.fail:
            raise AudioError('No test hardware available')
        self.running = True
        return self

    def stop(self):
        self.running = False


class Player:
    def __init__(self):
        self.playing = False
        self.completed = False
        self.error = None
        self.last_samples = None

    def play(self, samples, sample_rate=44100):
        self.last_samples = samples
        self.playing = True
        self.completed = False

    def stop(self):
        self.playing = False
        self.completed = False

    def complete(self):
        self.playing = False
        self.completed = True


class DesktopTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.devices = patch('ui.main_window.list_input_devices', return_value=[
            {'index': 3, 'name': 'Injected test input', 'default_samplerate': 44100}])
        self.devices.start()
        Capture.fail = False
        self.window = MainWindow(clock=self.clock, capture_factory=Capture, player_factory=Player,
                                 artifacts_dir=self.temp.name)
        self.window.timer.stop()

    def tearDown(self):
        self.window.close()
        self.devices.stop()
        self.temp.cleanup()

    def confirm(self):
        def summary(hz):
            return SampleSummary(hz, 1., 2., 2., 1., 150, 3.)
        recommendation = recommend_sa(summary(130.), summary(195.), summary(310.))
        self.window.state.propose(recommendation)
        self.window.confirm_sa()
        return recommendation.sa_hz

    def prepare_practice(self):
        self.confirm()
        self.window.play_reference()
        self.window.player.complete()
        self.window._tick()
        self.window.start_practice()
        return self.window._session_start

    def test_starts_with_calibration_and_no_fabricated_pitch_or_sa(self):
        self.assertEqual(self.window.views.count(), 3)
        self.assertEqual(self.window.views.currentIndex(), 0)
        self.assertIsNone(self.window.state.confirmed_sa_hz)
        self.assertFalse(self.window.confirm_button.isEnabled())
        self.assertFalse(self.window.start_button.isEnabled())
        self.assertFalse(self.window.graph.times)
        self.assertEqual(self.window.window_size.currentData(), 2048)
        self.window.start_practice()
        self.assertIsNone(self.window.capture)

    def test_three_calibration_recordings_confirm_measured_tonic(self):
        for stage, hz in enumerate((130., 195., 310.)):
            self.window.record_calibration()
            start = self.window._recording_started
            for t in np.arange(.05, 3., .012):
                self.window._accept_estimate(PitchEstimate(start + t, hz, .99, .1, True))
            self.clock.now = start + 3.3
            self.window._tick()
            self.assertEqual(self.window._stage, stage + 1)
        self.assertIsNotNone(self.window.state.recommendation)
        self.assertIsNone(self.window.state.confirmed_sa_hz)
        self.assertTrue(self.window.confirm_button.isEnabled())
        self.window.confirm_sa()
        self.assertEqual(self.window.views.currentIndex(), 1)
        self.assertEqual(self.window._timeline.sa_hz, self.window.state.confirmed_sa_hz)
        calibration = next(Path(self.temp.name).glob('calibration_*/calibration.json'))
        saved = json.loads(calibration.read_text())
        self.assertFalse(saved['confirmed'])
        self.assertEqual(len(saved['observations']), 3)

    def test_silent_calibration_retries_current_step(self):
        self.window.record_calibration()
        start = self.window._recording_started
        for t in np.arange(.05, 3., .012):
            self.window._accept_estimate(PitchEstimate(start + t, None, 0., 0., False))
        self.clock.now = start + 3.3
        self.window._tick()
        self.assertEqual(self.window._stage, 0)
        self.assertFalse(self.window._calibration_summaries)
        self.assertTrue(self.window.record_button.isEnabled())
        self.assertIn('inconclusive', self.window.message_label.text())

    def test_reference_requires_actual_completion_and_selection_changes_invalidate(self):
        self.confirm()
        self.window.play_reference()
        self.assertFalse(self.window.start_button.isEnabled())
        self.window.player.stop()  # early output stop cannot validate a reference
        self.window._tick()
        self.assertFalse(self.window._reference_completed)
        self.window.play_reference()
        self.window.player.complete()
        self.window._tick()
        self.assertTrue(self.window.start_button.isEnabled())
        self.window.bpm.setValue(80)
        self.assertFalse(self.window.start_button.isEnabled())
        self.assertFalse(self.window._reference_completed)
        self.assertEqual(self.window._timeline.bpm, 80)

    def test_target_graph_and_reference_share_confirmed_sa_and_timeline(self):
        sa = self.confirm()
        self.window.play_reference()
        self.assertEqual(len(self.window.player.last_samples), round(self.window._timeline.duration * 44100))
        self.window.graph.set_timeline(self.window._timeline)
        x, y = self.window.graph.expected.getData()
        np.testing.assert_allclose(x, self.window._timeline.graph_points()[0])
        np.testing.assert_allclose(y, self.window._timeline.graph_points()[1])
        self.assertAlmostEqual(self.window._timeline.notes[1].frequency, sa * 2 ** (2/12))
        self.assertIsNone(self.window.capture)

    def test_raw_wrong_octave_never_snaps_to_target_or_smoothing(self):
        start = self.prepare_practice()
        sa = self.window.state.confirmed_sa_hz
        self.window._accept_estimate(PitchEstimate(start + .2, sa, .99, .1, True))
        self.window._accept_estimate(PitchEstimate(start + .212, sa * 2, .99, .1, True))
        self.assertEqual(self.window._observations[-1].frequency, sa * 2)
        self.assertIn('Wrong Swara', self.window.status_label.text())
        # The isolated octave jump is rejected in the graph, never corrected to the target.
        self.assertTrue(math.isnan(self.window.graph.cents[-1]))
        self.window._accept_estimate(PitchEstimate(start + .224, sa * 2, .99, .1, True))
        self.window.graph.refresh()
        self.assertAlmostEqual(self.window.graph.cents[-1], 1200, places=5)
        self.assertGreater(self.window.graph.viewRange()[1][1], 1200)

    def test_count_in_is_unscored_and_stalled_input_clears_status(self):
        start = self.prepare_practice()
        sa = self.window.state.confirmed_sa_hz
        self.window._accept_estimate(PitchEstimate(start - .1, sa, .99, .1, True))
        self.assertFalse(self.window._observations)
        self.window._accept_estimate(PitchEstimate(start + .2, sa, .99, .1, True))
        self.assertEqual(self.window.status_label.text(), 'On Pitch')
        self.clock.now = start + .51
        self.window._tick()
        self.assertEqual(self.window.status_label.text(), 'No Reliable Voice')
        self.assertIn('250 ms', self.window.actual_label.text())
        self.assertIn('current', self.window.results.item(0, 0).text())
        self.assertIn('pending', self.window.results.item(1, 0).text())
        self.assertEqual(self.window.results.item(1, 1).text(), '—')

    def test_graph_breaks_silence_and_dropped_observation_gaps(self):
        self.confirm()
        self.window.graph.set_timeline(self.window._timeline)
        self.window.graph.append_observation(.1, 0)
        self.window.graph.append_observation(.11, None)
        self.window.graph.append_observation(.3, 1200)
        self.assertTrue(math.isnan(self.window.graph.cents[1]))
        self.assertTrue(math.isnan(self.window.graph.cents[2]))
        self.assertEqual(self.window.graph.cents[-1], 1200)

    def test_independent_pitch_track_scores_exports_and_silence_remains_missing(self):
        start = self.prepare_practice()
        sa = self.window.state.confirmed_sa_hz
        offsets = [0, 2, 4, 2, 0]  # independently specified synthetic performance
        beat = 60 / self.window._timeline.bpm
        for t in np.arange(.005, self.window._timeline.duration, .01):
            index = min(len(offsets)-1, int(t / beat))
            hz = sa * 2 ** (offsets[index] / 12)
            self.window._accept_estimate(PitchEstimate(start + t, hz, .99, .1, True))
        self.clock.now = start + self.window._timeline.duration + .3
        self.window._tick()
        self.assertEqual(self.window.mode, 'results')
        self.assertGreater(self.window._report.overall_accuracy, 98)
        self.assertEqual(self.window.results.rowCount(), 5)
        report_file = next(Path(self.temp.name).glob('practice_*/report.json'))
        payload = json.loads(report_file.read_text())
        self.assertEqual(payload['confirmed_sa_hz'], sa)
        self.assertEqual(payload['capture_metrics']['dropped_samples'], 0)
        with (report_file.parent / 'observations.csv').open(newline='') as source:
            rows = list(csv.DictReader(source))
        self.assertEqual(len(rows), len(self.window._observations))
        self.assertAlmostEqual(float(rows[0]['raw_frequency_hz']), sa)
        self.window.practice_again()
        self.assertFalse(self.window.start_button.isEnabled())
        self.window.play_reference()
        self.window.player.complete()
        self.window._tick()
        self.window.start_practice()
        self.window.finish_practice(incomplete=True)
        self.assertEqual(self.window._report.overall_accuracy, 0)
        self.assertTrue(all(n.missing_duration == n.eligible_duration for n in self.window._report.notes))

    def test_capture_worker_handoff_is_bounded_and_runs_real_yin(self):
        self.window.toggle_monitor()
        capture = self.window.capture
        samples = (.15 * np.sin(2*np.pi*220*np.arange(2048)/44100)).astype(np.float32)
        frame = AudioFrame(self.clock(), samples, 44100, .1)
        callback = capture.kwargs['on_frame']
        for _ in range(260):
            callback(frame)
        self.assertEqual(self.window._estimates.qsize(), 256)
        self.assertEqual(self.window.ui_queue_drops, 4)
        self.window._drain_estimates()
        self.assertIn('220.', self.window.detected_label.text())
        self.assertFalse(self.window._observations)

    def test_no_hardware_error_and_disconnect_produce_no_fake_success(self):
        Capture.fail = True
        self.window.record_calibration()
        self.assertIsNone(self.window.capture)
        self.assertIsNone(self.window.state.confirmed_sa_hz)
        self.assertIn('No test hardware', self.window.message_label.text())
        Capture.fail = False
        self.prepare_practice()
        self.window.capture.error = 'Microphone disconnected'
        self.window._tick()
        self.assertEqual(self.window.mode, 'results')
        self.assertEqual(self.window._report.overall_accuracy, 0)
        self.assertIn('Microphone disconnected', self.window.limitations_label.text())

    def test_finish_releases_only_owned_capture_and_output(self):
        self.prepare_practice()
        capture = self.window.capture
        self.window.finish()
        self.assertFalse(capture.running)
        self.assertIsNone(self.window.capture)
        self.assertFalse(self.window.player.playing)
        self.assertEqual(self.window.mode, 'idle')

    def test_new_attempt_does_not_keep_previous_timing_warning(self):
        start = self.prepare_practice()
        self.window._accept_estimate(PitchEstimate(
            start + .2, self.window.state.confirmed_sa_hz * 2, .99, .1, True))
        self.assertIn('mismatch', self.window.timing_label.text())
        self.window.finish_practice(incomplete=True)
        self.window.practice_again()
        self.window.play_reference()
        self.window.player.complete()
        self.window._tick()
        self.window.start_practice()
        self.assertEqual(self.window.timing_label.text(),
                         'Fixed guided tempo; substantial drift reduces alignment confidence.')


if __name__ == '__main__':
    unittest.main()
