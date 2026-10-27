"""Bounded audio handoff. DSP, application callbacks and storage run off PortAudio."""
from __future__ import annotations

from dataclasses import dataclass
from collections import deque
import logging
import math
import queue
import threading
import time
from typing import Callable

import numpy as np

LOG = logging.getLogger(__name__)


class AudioError(RuntimeError):
    """An actionable audio-device failure."""


def _sounddevice():
    try:
        import sounddevice
        return sounddevice
    except (ImportError, OSError) as exc:
        raise AudioError(
            "Audio backend unavailable. Install requirements; on Linux install "
            "PortAudio (libportaudio2). On Windows use the official sounddevice wheel."
        ) from exc


def list_input_devices() -> list[dict]:
    """Enumerate actual inputs; an empty list never creates a simulated device."""
    try:
        return [dict(d, index=i) for i, d in enumerate(_sounddevice().query_devices())
                if d['max_input_channels'] > 0]
    except AudioError:
        raise
    except Exception as exc:
        raise AudioError(f"Cannot enumerate microphones: {exc}") from exc


@dataclass(frozen=True)
class AudioFrame:
    timestamp: float  # monotonic clock, center of the analysis window
    samples: np.ndarray
    sample_rate: int
    rms: float


@dataclass(frozen=True)
class _Packet:
    first_sample_time: float
    samples: np.ndarray
    discontinuity: bool = False


class AudioCapture:
    """Mono capture with a bounded queue and sliding-window worker.

    Queue loss resets the analysis window: unrelated blocks are never spliced
    into an apparently continuous pitch observation. Input timestamps are mapped
    from PortAudio's ADC clock using a fixed time.monotonic() conversion.
    """

    def __init__(self, device=None, sample_rate=44100, window_size=4096,
                 block_size=512, on_frame: Callable[[AudioFrame], None] | None = None,
                 queue_blocks=24):
        if min(sample_rate, window_size, block_size, queue_blocks) <= 0:
            raise ValueError("Capture dimensions must be positive")
        if window_size < block_size:
            raise ValueError("Analysis window must be at least one callback block")
        self.device, self.sample_rate = device, int(sample_rate)
        self.window_size, self.block_size = int(window_size), int(block_size)
        self.on_frame = on_frame
        self._queue: queue.Queue[_Packet] = queue.Queue(maxsize=queue_blocks)
        self._stop = threading.Event()
        self._stream = None
        self._worker = None
        self._clock_offset = None
        self._pending_discontinuity = False
        self.error: str | None = None
        self._metrics = {}
        self._timing_lock = threading.Lock()
        self._processing_times = deque(maxlen=4096)
        self._analysis_ages = deque(maxlen=4096)
        self._reset_metrics()

    def _reset_metrics(self):
        self._metrics = dict(captured_samples=0, dropped_samples=0, overruns=0,
                             timestamp_discontinuities=0, analyzed_frames=0,
                             worker_errors=0, input_rms=0.0, max_queue_delay_ms=0.0,
                             last_processing_ms=0.0, max_processing_ms=0.0)
        with self._timing_lock:
            self._processing_times.clear()
            self._analysis_ages.clear()

    @property
    def metrics(self) -> dict:
        """Measured counters and rolling summaries over at most 4096 windows.

        Processing spans window extraction/RMS and on_frame execution. Analysis
        age is window-center to completion of that worker processing, including
        half-window acquisition and queueing. Neither measures GUI presentation
        latency or audio hardware output latency. Statistics run in the caller,
        never in the PortAudio callback.
        """
        result = dict(self._metrics)
        with self._timing_lock:
            durations = np.asarray(self._processing_times, dtype=float)
            ages = np.asarray(self._analysis_ages, dtype=float)
        result['timing_sample_count'] = len(durations)
        result['processing_median_ms'] = float(np.median(durations)) if len(durations) else 0.0
        result['processing_p95_ms'] = float(np.percentile(durations, 95)) if len(durations) else 0.0
        result['analysis_age_median_ms'] = float(np.median(ages)) if len(ages) else 0.0
        result['analysis_age_p95_ms'] = float(np.percentile(ages, 95)) if len(ages) else 0.0
        return result

    @property
    def running(self) -> bool:
        if self._stream is None or self._stop.is_set() or self.error is not None:
            return False
        try:
            active = bool(self._stream.active)
        except Exception as exc:
            self.error = f"Microphone status failed: {exc}"
            return False
        if not active:
            self.error = "Microphone stopped unexpectedly; check for a disconnected or busy device"
        return active

    def _callback(self, indata, frames, pa_time, status):
        # Keep this bounded: no DSP, RMS, UI, logging, filesystem or waits here.
        now = time.monotonic()
        if status and getattr(status, 'input_overflow', False):
            self._metrics['overruns'] += 1
            self._pending_discontinuity = True
        self._metrics['captured_samples'] += frames
        adc = getattr(pa_time, 'inputBufferAdcTime', 0.0)
        current = getattr(pa_time, 'currentTime', 0.0)
        if current > 0 and math.isfinite(adc) and math.isfinite(current):
            # Fix the clock conversion once; scheduling jitter must not turn
            # contiguous ADC samples into artificial timeline discontinuities.
            if self._clock_offset is None:
                self._clock_offset = now - current
            first_time = adc + self._clock_offset
        else:
            first_time = now - frames / self.sample_rate
        packet = _Packet(first_time, indata[:, 0].copy(), self._pending_discontinuity)
        try:
            self._queue.put_nowait(packet)
            self._pending_discontinuity = False
        except queue.Full:
            self._metrics['dropped_samples'] += frames
            self._pending_discontinuity = True

    def _run_worker(self):
        samples = np.empty(0, dtype=np.float32)
        start = previous_end = None
        try:
            while not self._stop.is_set() or not self._queue.empty():
                try:
                    packet = self._queue.get(timeout=0.05)
                except queue.Empty:
                    continue
                if packet.discontinuity or previous_end is None or abs(packet.first_sample_time - previous_end) > max(0.003, 2 / self.sample_rate):
                    if previous_end is not None or packet.discontinuity:
                        self._metrics['timestamp_discontinuities'] += 1
                    samples = np.empty(0, dtype=np.float32)
                    start = packet.first_sample_time
                previous_end = packet.first_sample_time + len(packet.samples) / self.sample_rate
                self._metrics['max_queue_delay_ms'] = max(
                    self._metrics['max_queue_delay_ms'],
                    max(0.0, time.monotonic() - previous_end) * 1000)
                self._metrics['input_rms'] = float(np.sqrt(np.mean(packet.samples.astype(np.float64) ** 2)))
                samples = np.concatenate((samples, packet.samples))
                while len(samples) >= self.window_size:
                    began = time.perf_counter()
                    window = samples[:self.window_size].copy()
                    frame = AudioFrame(start + (self.window_size - 1) / (2 * self.sample_rate),
                                       window, self.sample_rate,
                                       float(np.sqrt(np.mean(window.astype(np.float64) ** 2))))
                    if self.on_frame is not None:
                        self.on_frame(frame)
                    duration = (time.perf_counter() - began) * 1000
                    age = max(0.0, time.monotonic() - frame.timestamp) * 1000
                    with self._timing_lock:
                        self._processing_times.append(duration)
                        self._analysis_ages.append(age)
                    self._metrics['last_processing_ms'] = duration
                    self._metrics['max_processing_ms'] = max(self._metrics['max_processing_ms'], duration)
                    self._metrics['analyzed_frames'] += 1
                    samples = samples[self.block_size:]
                    start += self.block_size / self.sample_rate
        except Exception as exc:
            self.error = f"Audio analysis worker failed: {exc}"
            self._metrics['worker_errors'] += 1
            self._stop.set()
            LOG.exception("Audio worker failed")

    def start(self):
        if self._stream is not None:
            raise AudioError("Capture already started; stop it before starting again")
        sd = _sounddevice()
        self.error = None
        self._clock_offset = None
        self._pending_discontinuity = False
        self._reset_metrics()
        self._stop.clear()
        while not self._queue.empty():
            self._queue.get_nowait()
        try:
            info = sd.query_devices(self.device, 'input')
            preferred = [self.sample_rate, int(info['default_samplerate']), 48000, 44100]
            selected = None
            errors = []
            for rate in dict.fromkeys(preferred):
                try:
                    sd.check_input_settings(device=self.device, channels=1, dtype='float32', samplerate=rate)
                    selected = rate
                    break
                except Exception as exc:
                    errors.append(f"{rate} Hz: {exc}")
            if selected is None:
                raise AudioError("No supported mono input rate. " + '; '.join(errors))
            self.sample_rate = selected
            self._stream = sd.InputStream(device=self.device, samplerate=selected,
                                          channels=1, dtype='float32',
                                          blocksize=self.block_size, callback=self._callback)
            self._worker = threading.Thread(target=self._run_worker, name='pitch-audio-worker', daemon=True)
            self._worker.start()
            self._stream.start()
        except Exception as exc:
            self.stop()
            self.error = f"Cannot start microphone: {exc}"
            raise AudioError(self.error + ". Check device selection and Windows microphone permissions.") from exc
        return self

    def stop(self):
        stream, self._stream = self._stream, None
        if stream is not None:
            try:
                stream.stop()
            except Exception:
                LOG.warning("Audio stream stop failed", exc_info=True)
            finally:
                try:
                    stream.close()
                except Exception:
                    LOG.warning("Audio stream close failed", exc_info=True)
        self._stop.set()
        worker, self._worker = self._worker, None
        if worker is not None and worker is not threading.current_thread():
            worker.join(timeout=3)
            if worker.is_alive():
                self.error = "Audio worker did not stop within 3 seconds"
                LOG.error(self.error)

    def __enter__(self):
        return self.start()

    def __exit__(self, *_):
        self.stop()
