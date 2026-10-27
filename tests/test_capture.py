"""Hardware-independent tests of the real capture boundary and reference synthesis."""
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from audio.capture import AudioCapture, AudioError, _Packet, list_input_devices
from audio.reference_audio import ReferencePlayer, synthesize_timeline, synthesize_tone
from tools.microphone import record_wav


class CaptureTests(unittest.TestCase):
    def test_callback_only_hands_off_copied_samples_and_counts_overflow(self):
        received = []
        capture = AudioCapture(on_frame=received.append, queue_blocks=1)
        block = np.ones((512, 1), dtype=np.float32)
        pa_time = SimpleNamespace(inputBufferAdcTime=9.0, currentTime=10.0)
        with patch('audio.capture.time.monotonic', return_value=100.0):
            capture._callback(block, 512, pa_time, SimpleNamespace(input_overflow=True))
            capture._callback(block, 512, pa_time, SimpleNamespace(input_overflow=False))
        block[:] = 0
        packet = capture._queue.get_nowait()
        self.assertEqual(packet.first_sample_time, 99.0)
        self.assertTrue(np.all(packet.samples == 1))
        self.assertEqual(received, [])
        self.assertEqual(capture.metrics['dropped_samples'], 512)
        self.assertEqual(capture.metrics['overruns'], 1)
        self.assertEqual(capture.metrics['captured_samples'], 1024)

    def test_worker_builds_sliding_window_with_center_timestamps(self):
        received = []
        capture = AudioCapture(sample_rate=8000, window_size=1024, block_size=512,
                               on_frame=received.append)
        for i in range(3):
            capture._queue.put_nowait(_Packet(1 + i * 512 / 8000,
                                              np.full(512, i, dtype=np.float32)))
        capture._stop.set()
        worker = threading.Thread(target=capture._run_worker)
        worker.start()
        worker.join(1)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(received), 2)
        self.assertAlmostEqual(received[0].timestamp, 1 + 1023 / 16000)
        self.assertAlmostEqual(received[1].timestamp - received[0].timestamp, 512 / 8000)
        np.testing.assert_array_equal(received[1].samples[:512], np.ones(512))
        np.testing.assert_array_equal(received[1].samples[512:], np.full(512, 2))
        self.assertAlmostEqual(received[0].rms, np.sqrt(0.5))

    def test_callback_scheduling_jitter_does_not_change_adc_sample_spacing(self):
        capture = AudioCapture(sample_rate=8000)
        status = SimpleNamespace(input_overflow=False)
        with patch('audio.capture.time.monotonic', side_effect=[100.0, 100.2]):
            capture._callback(np.zeros((512, 1)), 512,
                              SimpleNamespace(inputBufferAdcTime=9.0, currentTime=10.0), status)
            capture._callback(np.zeros((512, 1)), 512,
                              SimpleNamespace(inputBufferAdcTime=9.064, currentTime=10.064), status)
        first, second = capture._queue.get_nowait(), capture._queue.get_nowait()
        self.assertAlmostEqual(second.first_sample_time - first.first_sample_time, 512 / 8000)

    def test_missing_blocks_reset_window_instead_of_splicing(self):
        received = []
        capture = AudioCapture(sample_rate=8000, window_size=1024, block_size=512,
                               on_frame=received.append)
        capture._queue.put_nowait(_Packet(1, np.ones(512, dtype=np.float32)))
        capture._queue.put_nowait(_Packet(2, np.zeros(512, dtype=np.float32)))
        capture._queue.put_nowait(_Packet(2 + 512 / 8000, np.zeros(512, dtype=np.float32)))
        capture._stop.set()
        capture._run_worker()
        self.assertEqual(len(received), 1)
        self.assertTrue(np.all(received[0].samples == 0))
        self.assertEqual(capture.metrics['timestamp_discontinuities'], 1)

    def test_overflow_resets_window_even_when_adc_timestamps_appear_contiguous(self):
        received = []
        capture = AudioCapture(sample_rate=8000, window_size=1024, block_size=512,
                               on_frame=received.append)
        with patch('audio.capture.time.monotonic', return_value=100):
            for i in range(3):
                capture._callback(np.full((512, 1), 1 if i == 0 else 0, dtype=np.float32), 512,
                                  SimpleNamespace(inputBufferAdcTime=9 + i * .064,
                                                  currentTime=10 + i * .064),
                                  SimpleNamespace(input_overflow=i == 1))
        capture._stop.set()
        capture._run_worker()
        self.assertEqual(len(received), 1)
        self.assertTrue(np.all(received[0].samples == 0))
        self.assertEqual(capture.metrics['overruns'], 1)
        self.assertEqual(capture.metrics['timestamp_discontinuities'], 1)

    def test_queue_loss_marks_next_accepted_packet_even_without_timestamp_gap(self):
        capture = AudioCapture(queue_blocks=1)
        block = np.zeros((512, 1), dtype=np.float32)
        clock = SimpleNamespace(inputBufferAdcTime=9, currentTime=10)
        status = SimpleNamespace(input_overflow=False)
        capture._callback(block, 512, clock, status)
        capture._callback(block, 512, clock, status)  # bounded handoff full
        capture._queue.get_nowait()
        capture._callback(block, 512, clock, status)
        self.assertTrue(capture._queue.get_nowait().discontinuity)
        self.assertEqual(capture.metrics['dropped_samples'], 512)

    def test_worker_reports_measured_processing_and_center_to_delivery_age(self):
        capture = AudioCapture(sample_rate=8000, window_size=512, block_size=512)
        for i in range(3):
            capture._queue.put_nowait(_Packet(1 + i * .064, np.zeros(512, dtype=np.float32)))
        capture._stop.set()
        with patch('audio.capture.time.perf_counter', side_effect=[0, .001, .01, .013, .02, .029]), \
                patch('audio.capture.time.monotonic', return_value=2):
            capture._run_worker()
        metrics = capture.metrics
        self.assertEqual(metrics['timing_sample_count'], 3)
        self.assertAlmostEqual(metrics['processing_median_ms'], 3)
        self.assertAlmostEqual(metrics['processing_p95_ms'], 8.4)
        self.assertAlmostEqual(metrics['analysis_age_median_ms'], (2 - (1 + .064 + 511 / 16000)) * 1000)
        ages = [(2 - (1 + i * .064 + 511 / 16000)) * 1000 for i in range(3)]
        self.assertAlmostEqual(metrics['analysis_age_p95_ms'], np.percentile(ages, 95))
        self.assertEqual(capture._processing_times.maxlen, 4096)
        self.assertEqual(capture._analysis_ages.maxlen, 4096)

    def test_worker_failure_exposed(self):
        def broken(_):
            raise ValueError('DSP failure')
        capture = AudioCapture(window_size=512, on_frame=broken)
        capture._queue.put_nowait(_Packet(1, np.ones(512, dtype=np.float32)))
        capture._stop.set()
        with self.assertLogs('audio.capture', level='ERROR'):
            capture._run_worker()
        self.assertIn('DSP failure', capture.error)
        self.assertEqual(capture.metrics['worker_errors'], 1)

    def test_start_falls_back_to_supported_rate_and_closes_only_own_stream(self):
        class FakeStream:
            active = False
            closed = False
            def __init__(self, **kwargs):
                self.kwargs = kwargs
            def start(self):
                self.active = True
            def stop(self):
                self.active = False
            def close(self):
                self.closed = True

        def settings(**kwargs):
            if kwargs['samplerate'] != 48000:
                raise ValueError('unsupported rate')
        sd = SimpleNamespace(query_devices=lambda *args: {'default_samplerate': 48000},
                             check_input_settings=settings, InputStream=FakeStream)
        with patch('audio.capture._sounddevice', return_value=sd):
            capture = AudioCapture()
            capture.start()
            stream = capture._stream
            self.assertTrue(capture.running)
            self.assertEqual(capture.sample_rate, 48000)
            with self.assertRaises(AudioError):
                capture.start()
            capture.stop()
            self.assertFalse(capture.running)
            self.assertTrue(stream.closed)
            capture.stop()  # idempotent

    def test_no_microphone_fails_actionably_and_releases_resources(self):
        def no_device(*args):
            raise ValueError('No default input device')
        with patch('audio.capture._sounddevice', return_value=SimpleNamespace(query_devices=no_device)):
            capture = AudioCapture()
            with self.assertRaisesRegex(AudioError, 'Cannot start microphone'):
                capture.start()
            self.assertFalse(capture.running)
            self.assertIsNone(capture._stream)

    def test_disconnection_is_reported_without_status_exception(self):
        capture = AudioCapture()
        capture._stream = SimpleNamespace(active=False)
        self.assertFalse(capture.running)
        self.assertIn('disconnected', capture.error)

        class BrokenStatus:
            @property
            def active(self):
                raise RuntimeError('PortAudio device gone')
        capture.error = None
        capture._stream = BrokenStatus()
        self.assertFalse(capture.running)
        self.assertIn('device gone', capture.error)

    def test_enumeration_filters_output_only_devices(self):
        sd = SimpleNamespace(query_devices=lambda: [
            dict(name='Speakers', max_input_channels=0, default_samplerate=48000),
            dict(name='Mic', max_input_channels=1, default_samplerate=44100)])
        with patch('audio.capture._sounddevice', return_value=sd):
            devices = list_input_devices()
        self.assertEqual(len(devices), 1)
        self.assertEqual(devices[0]['index'], 1)
        self.assertEqual(devices[0]['name'], 'Mic')

    def test_recording_does_not_overwrite_existing_file(self):
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            record_wav(__file__)


class ReferenceTests(unittest.TestCase):
    @staticmethod
    def _fake_output():
        class CallbackStop(Exception):
            pass

        class FakeStream:
            active = False
            def __init__(self, **kwargs):
                self.kwargs = kwargs
            def start(self):
                self.active = True
            def stop(self):
                self.active = False
            def close(self):
                pass

        return SimpleNamespace(OutputStream=FakeStream, CallbackStop=CallbackStop)

    def test_tone_length_fade_amplitude_and_frequency(self):
        tone = synthesize_tone(220, 1, 8000)
        self.assertEqual(len(tone), 8000)
        self.assertEqual(tone.dtype, np.float32)
        self.assertEqual(tone[0], 0)
        self.assertEqual(tone[-1], 0)
        self.assertLessEqual(np.max(np.abs(tone)), 0.20001)
        spectrum = np.abs(np.fft.rfft(tone))
        self.assertEqual(np.argmax(spectrum), 220)

    def test_timeline_is_single_source_for_audio_frequencies_and_durations(self):
        timeline = SimpleNamespace(notes=[SimpleNamespace(start=0, end=1, frequency=220),
                                          SimpleNamespace(start=1, end=1.5, frequency=440)])
        signal = synthesize_timeline(timeline, 8000)
        self.assertEqual(len(signal), 12000)
        self.assertEqual(np.argmax(np.abs(np.fft.rfft(signal[:8000]))), 220)
        self.assertEqual(np.argmax(np.abs(np.fft.rfft(signal[8000:]))), 220)  # bin spacing 2 Hz

    def test_invalid_tone_parameters(self):
        for frequency in (0, -10, float('nan'), 5000):
            with self.subTest(frequency=frequency), self.assertRaises(ValueError):
                synthesize_tone(frequency, sample_rate=8000)

    def test_player_owns_output_and_stops_cleanly(self):
        streams = []
        class FakeStream:
            active = False
            def __init__(self, **kwargs):
                self.kwargs = kwargs
                self.closed = False
                streams.append(self)
            def start(self):
                self.active = True
            def stop(self):
                self.active = False
            def close(self):
                self.closed = True
        with patch('audio.reference_audio._sounddevice', return_value=SimpleNamespace(OutputStream=FakeStream)):
            player = ReferencePlayer()
            player.play(np.zeros(100, dtype=np.float32), 8000)
            self.assertTrue(player.playing)
            player.stop()
            self.assertFalse(player.playing)
            self.assertTrue(streams[0].closed)

    def test_completion_requires_all_samples_and_hardware_finished_callback(self):
        sd = self._fake_output()
        with patch('audio.reference_audio._sounddevice', return_value=sd):
            player = ReferencePlayer()
            player.play(np.zeros(8, dtype=np.float32), 8000)
            stream = player._stream
            callback = stream.kwargs['callback']
            callback(np.empty((4, 1)), 4, None, None)
            self.assertFalse(player.completed)
            with self.assertRaises(sd.CallbackStop):
                callback(np.empty((4, 1)), 4, None, None)
            self.assertFalse(player.completed)  # hardware has not drained output yet
            stream.kwargs['finished_callback']()
            self.assertTrue(player.completed)
            self.assertFalse(player.playing)
            player.stop()
            self.assertFalse(player.completed)

    def test_interrupted_or_underflow_reference_never_completes_successfully(self):
        sd = self._fake_output()
        with patch('audio.reference_audio._sounddevice', return_value=sd):
            player = ReferencePlayer()
            player.play(np.zeros(8, dtype=np.float32), 8000)
            player.stop()
            self.assertFalse(player.completed)

            player.play(np.zeros(8, dtype=np.float32), 8000)
            stream = player._stream
            with self.assertRaises(sd.CallbackStop):
                stream.kwargs['callback'](np.empty((8, 1)), 8, None,
                                          SimpleNamespace(output_underflow=True))
            stream.kwargs['finished_callback']()
            self.assertFalse(player.completed)
            self.assertIn('underflow', player.error)
            player.stop()

            player.play(np.zeros(8, dtype=np.float32), 8000)
            player._stream.active = False
            self.assertFalse(player.playing)
            self.assertIn('stopped unexpectedly', player.error)
            self.assertFalse(player.completed)
            player.stop()

    def test_output_device_status_exception_is_actionable_and_not_completion(self):
        class DisconnectedStream:
            @property
            def active(self):
                raise RuntimeError('Output device unplugged')

        player = ReferencePlayer()
        player._stream = DisconnectedStream()
        player._samples = np.zeros(8, dtype=np.float32)
        player._finished = False
        self.assertFalse(player.playing)
        self.assertIn('Output device unplugged', player.error)
        self.assertFalse(player.completed)


if __name__ == '__main__':
    unittest.main()
