"""Reference synthesis from the same timeline used by the graph and scorer."""
from __future__ import annotations

import logging

import numpy as np

from audio.capture import AudioError, _sounddevice

LOG = logging.getLogger(__name__)


def synthesize_tone(frequency: float, duration=2.0, sample_rate=44100, amplitude=0.2) -> np.ndarray:
    if not np.isfinite(frequency) or frequency <= 0 or duration <= 0 or sample_rate <= 0:
        raise ValueError("Positive finite frequency, duration and sample rate required")
    if not 0 <= amplitude <= 1 or frequency >= sample_rate / 2:
        raise ValueError("Invalid amplitude or frequency above Nyquist")
    count = round(duration * sample_rate)
    signal = amplitude * np.sin(2 * np.pi * frequency * np.arange(count) / sample_rate)
    fade = min(round(0.01 * sample_rate), count // 2)
    if fade:
        ramp = np.linspace(0, 1, fade)
        signal[:fade] *= ramp
        signal[-fade:] *= ramp[::-1]
    return signal.astype(np.float32)


def synthesize_timeline(timeline, sample_rate=44100) -> np.ndarray:
    notes = timeline.notes
    if not notes:
        return np.empty(0, dtype=np.float32)
    output = np.zeros(round(max(n.end for n in notes) * sample_rate), dtype=np.float32)
    for note in notes:
        first, last = round(note.start * sample_rate), round(note.end * sample_rate)
        tone = synthesize_tone(note.frequency, (last - first) / sample_rate, sample_rate)
        output[first:last] = tone[:last - first]
    return output


class ReferencePlayer:
    """Owns its output stream; stop never stops an unrelated input stream."""

    def __init__(self):
        self._stream = None
        self._samples = np.empty(0, dtype=np.float32)
        self._position = 0
        self._finished = True
        self.error: str | None = None

    @property
    def playing(self):
        if self._stream is None or self._finished:
            return False
        try:
            active = bool(self._stream.active)
        except Exception as exc:
            self.error = f"Reference output status failed: {exc}"
            self._finished = True
            return False
        if not active:
            self.error = "Reference output stopped unexpectedly; check your output device"
            self._finished = True
        return active

    @property
    def completed(self):
        """True only after all output was delivered and the stream finished.

        Explicit stop, startup/device failure or reported underflow never counts
        as successfully listening to the reference.
        """
        return bool(self._stream is not None and self._finished and self.error is None
                    and len(self._samples) > 0 and self._position >= len(self._samples))

    def play(self, samples, sample_rate=44100):
        self.stop()
        self.error = None
        samples = np.asarray(samples, dtype=np.float32)
        if samples.ndim != 1 or not len(samples) or not np.all(np.isfinite(samples)):
            raise ValueError("Playback requires a finite nonempty mono signal")
        self._samples = samples
        self._position = 0
        self._finished = False

        def callback(outdata, frames, _time, _status):
            if _status and getattr(_status, 'output_underflow', False):
                self.error = "Reference output underflow; replay the complete reference before practice"
            remaining = min(frames, len(self._samples) - self._position)
            outdata.fill(0)
            outdata[:remaining, 0] = self._samples[self._position:self._position + remaining]
            self._position += remaining
            if self._position >= len(self._samples):
                raise sd.CallbackStop

        def finished():
            self._finished = True

        try:
            sd = _sounddevice()
            self._stream = sd.OutputStream(samplerate=sample_rate, channels=1, dtype='float32',
                                           callback=callback, finished_callback=finished)
            self._stream.start()
        except Exception as exc:
            self.stop()
            self.error = f"Reference playback failed: {exc}. Check your speakers/output device."
            raise AudioError(self.error) from exc

    def stop(self):
        stream, self._stream = self._stream, None
        self._finished = True
        if stream is not None:
            try:
                stream.stop()
            except Exception as exc:
                self.error = f"Reference stop failed: {exc}"
                LOG.warning(self.error, exc_info=True)
            finally:
                try:
                    stream.close()
                except Exception as exc:
                    self.error = f"Reference close failed: {exc}"
                    LOG.warning(self.error, exc_info=True)
