"""Independent, NumPy-only YIN pitch estimation.

The squared difference uses all overlapping samples at each lag. FFT correlation
is zero-padded and both lag-dependent energy sums are included; this is not the
incorrect ``2 * (energy - autocorrelation)`` shortcut. No exercise target enters
the detector or smoother. Quality is periodicity evidence, not accuracy.
"""

from collections import deque
from dataclasses import dataclass, replace
import math

import numpy as np


@dataclass(frozen=True)
class PitchEstimate:
    timestamp: float
    frequency: float | None
    quality: float
    rms: float
    voiced: bool

    def cents(self, sa_hz: float) -> float | None:
        if not math.isfinite(sa_hz) or sa_hz <= 0:
            raise ValueError("Sa must be a positive finite frequency")
        if not self.voiced or self.frequency is None or self.frequency <= 0:
            return None
        return 1200.0 * math.log2(self.frequency / sa_hz)


def _validated_samples(samples, max_lag):
    x = np.asarray(samples, dtype=np.float64)
    if x.ndim != 1 or len(x) < 2 or not np.all(np.isfinite(x)):
        raise ValueError("Expected a finite mono audio window")
    if not isinstance(max_lag, (int, np.integer)) or not 1 <= max_lag < len(x):
        raise ValueError("max_lag must be an integer between 1 and N-1")
    return x


def difference_reference(samples, max_lag: int) -> np.ndarray:
    """d[tau] = sum((x[j] - x[j+tau])**2), j in [0,N-tau)."""
    x = _validated_samples(samples, max_lag)
    return np.array([np.dot(x[: len(x) - lag] - x[lag:],
                            x[: len(x) - lag] - x[lag:])
                     for lag in range(max_lag + 1)])


def difference_fft(samples, max_lag: int) -> np.ndarray:
    """Exact overlapping-window difference, accelerated by linear correlation."""
    x = _validated_samples(samples, max_lag)
    n = len(x)
    fft_size = 1 << (2 * n - 1).bit_length()
    spectrum = np.fft.rfft(x, fft_size)
    correlation = np.fft.irfft(spectrum * spectrum.conjugate(), fft_size)[:max_lag + 1]
    energy = np.concatenate(([0.0], np.cumsum(x * x)))
    lags = np.arange(max_lag + 1)
    difference = energy[n - lags] + energy[n] - energy[lags] - 2 * correlation
    # Cancellation may create tiny negative values for a perfectly periodic tone.
    difference = np.maximum(difference, 0.0)
    difference[0] = 0.0
    return difference


def cumulative_mean_normalized_difference(difference) -> np.ndarray:
    d = np.asarray(difference, dtype=np.float64)
    cmndf = np.ones_like(d)
    cumulative = np.cumsum(d[1:])
    np.divide(d[1:] * np.arange(1, len(d)), cumulative,
              out=cmndf[1:], where=cumulative > np.finfo(float).tiny)
    return cmndf


class YinDetector:
    def __init__(self, sample_rate=44100, min_frequency=65.0,
                 max_frequency=1100.0, rms_threshold=0.008,
                 threshold=0.15, min_quality=0.8):
        if (not math.isfinite(sample_rate) or sample_rate <= 0
                or not 0 < min_frequency < max_frequency < sample_rate / 2
                or not 0 < threshold < 1 or not 0 <= min_quality <= 1
                or not math.isfinite(rms_threshold) or rms_threshold < 0):
            raise ValueError("Invalid detector frequency, level or quality settings")
        self.sample_rate = int(sample_rate)
        self.min_frequency = float(min_frequency)
        self.max_frequency = float(max_frequency)
        self.rms_threshold = float(rms_threshold)
        self.threshold = float(threshold)
        self.min_quality = float(min_quality)

    def detect(self, samples, timestamp=0.0) -> PitchEstimate:
        x = np.asarray(samples, dtype=np.float64)
        if x.ndim != 1:
            raise ValueError("YIN requires a mono analysis window")
        timestamp = float(timestamp)
        if not math.isfinite(timestamp):
            raise ValueError("Timestamp must be finite")
        empty = PitchEstimate(timestamp, None, 0.0, 0.0, False)
        if len(x) < 8 or not np.all(np.isfinite(x)):
            return empty
        x = x - np.mean(x)
        rms = float(np.sqrt(np.mean(x * x)))
        empty = replace(empty, rms=rms)
        if rms < self.rms_threshold or rms <= np.finfo(float).tiny:
            return empty
        min_lag = max(2, int(math.floor(self.sample_rate / self.max_frequency)))
        # At least 2.5 periods in a window; low voices should use 4096 samples.
        max_lag = min(int(math.ceil(self.sample_rate / self.min_frequency)),
                      int(len(x) / 2.5) - 1)
        if max_lag <= min_lag + 1:
            return empty
        cmndf = cumulative_mean_normalized_difference(difference_fft(x, max_lag + 1))
        selected = None
        lag = min_lag
        while lag <= max_lag:
            if cmndf[lag] < self.threshold:
                while lag < max_lag and cmndf[lag + 1] < cmndf[lag]:
                    lag += 1
                selected = lag
                break
            lag += 1
        if selected is None:
            # Do not report an arbitrary global minimum in noise as a voice.
            return replace(empty, quality=float(np.clip(1 - np.min(cmndf[min_lag:max_lag + 1]), 0, 1)))
        quality = float(np.clip(1.0 - cmndf[selected], 0.0, 1.0))
        denominator = cmndf[selected - 1] - 2 * cmndf[selected] + cmndf[selected + 1]
        shift = 0.0 if abs(denominator) < 1e-15 else float(
            np.clip(0.5 * (cmndf[selected - 1] - cmndf[selected + 1]) / denominator, -1, 1))
        period = selected + shift
        frequency = self.sample_rate / period if period > 0 else float("nan")
        if (quality < self.min_quality or not math.isfinite(frequency)
                or not self.min_frequency <= frequency <= self.max_frequency
                or len(x) / period < 2.5):
            return replace(empty, quality=quality)
        return PitchEstimate(timestamp, float(frequency), quality, rms, True)


class PitchSmoother:
    """Median in unwrapped relative cents; no pitch-grid/target snapping.

    Normal note changes (>80 cents) reset the median immediately. A jump over
    700 cents requires two consecutive agreeing frames to reject isolated octave
    glitches; this adds one analysis hop to a genuine octave transition. Silence
    always returns an unvoiced result, with state cleared after 250 ms.
    """
    def __init__(self, median_frames=3, min_quality=0.8, silence_timeout=0.25,
                 reset_change_cents=80.0, max_jump_cents=700.0):
        if median_frames < 1 or silence_timeout < 0:
            raise ValueError("Invalid smoother window/timeout")
        self.values = deque(maxlen=median_frames)
        self.min_quality = min_quality
        self.silence_timeout = silence_timeout
        self.reset_change_cents = reset_change_cents
        self.max_jump_cents = max_jump_cents
        self.last_timestamp = None
        self.last_voiced_timestamp = None
        self.sa_hz = None
        self.pending_jump = None

    def reset(self):
        self.values.clear()
        self.last_timestamp = self.last_voiced_timestamp = None
        self.pending_jump = None
        self.sa_hz = None

    def process(self, estimate: PitchEstimate, sa_hz: float) -> PitchEstimate:
        cents = estimate.cents(sa_hz)
        if self.sa_hz != sa_hz or (self.last_timestamp is not None
                                   and estimate.timestamp < self.last_timestamp):
            self.reset()
        self.sa_hz = sa_hz
        self.last_timestamp = estimate.timestamp
        if (self.last_voiced_timestamp is not None
                and estimate.timestamp - self.last_voiced_timestamp > self.silence_timeout):
            self.values.clear()
            self.pending_jump = None
        if cents is None or estimate.quality < self.min_quality:
            self.pending_jump = None
            return replace(estimate, frequency=None, voiced=False)
        if self.values:
            delta = cents - float(np.median(self.values))
            if abs(delta) > self.max_jump_cents:
                if self.pending_jump is None or abs(cents - self.pending_jump) > 80:
                    self.pending_jump = cents
                    return replace(estimate, frequency=None, voiced=False)
            if abs(delta) > self.reset_change_cents:
                self.values.clear()
        self.pending_jump = None
        self.last_voiced_timestamp = estimate.timestamp
        self.values.append(cents)
        median = float(np.median(self.values))
        return replace(estimate, frequency=sa_hz * 2.0 ** (median / 1200.0))
