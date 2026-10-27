"""Measured comfort-range heuristic; a singer has no uniquely discoverable Sa.

Three short recordings indicate a range, rather than an exhaustive assessment.
The defaults exclude 300 ms at each edge, require at least 1 s of reliable voice
and 70% coverage, and reject central 80% spreads wider than 80 cents. Candidates
use the A4=440 Hz semitone grid, with 50-cent safety margins *inside* the measured
low and high. The full exercise span must fit; its midpoint is ranked against the
measured middle pitch. Candidates within 5 cents of the best ranking cost are
treated as ambiguous; the lower safe candidate wins deterministically. These are
conservative prototype settings, not standards
for Hindustani pedagogy, and should be validated by a teacher and real singers.
"""
from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Iterable

import numpy as np

from audio.pitch_detector import PitchEstimate


class CalibrationError(ValueError):
    """The measurements do not support a safe, repeatable recommendation."""


def _inconclusive(reason: str) -> CalibrationError:
    return CalibrationError(f"Calibration inconclusive — please retry. {reason}")


@dataclass(frozen=True)
class SampleSummary:
    median_hz: float
    stability_cents: float
    voiced_seconds: float
    usable_seconds: float
    voiced_fraction: float
    accepted_frames: int
    spread_cents: float = 0.0


@dataclass(frozen=True)
class SaRecommendation:
    sa_hz: float
    note_name: str
    low_hz: float
    high_hz: float
    explanation: str
    measured_low_hz: float
    measured_middle_hz: float
    measured_high_hz: float
    min_semitones: float
    max_semitones: float
    margin_cents: float
    candidate_count: int


def _union_duration(intervals: list[tuple[float, float]]) -> float:
    duration = 0.0
    end = -math.inf
    for left, right in sorted(intervals):
        duration += max(0.0, right - max(left, end))
        end = max(end, right)
    return duration


def summarize_sample(
    observations: Iterable[PitchEstimate],
    trim_seconds: float = 0.3,
    min_quality: float = 0.8,
    min_voiced_seconds: float = 1.0,
    min_coverage: float = 0.7,
    min_frames: int = 20,
    max_spread_cents: float = 80.0,
    max_frame_support: float = 0.05,
) -> SampleSummary:
    """Summarize independent detector observations, including unvoiced frames.

    A timestamp supports at most 50 ms of voice, so dropped frames or long gaps
    cannot impersonate a sustained recording. Duplicated timestamps count once.
    The stability measure is 1.4826 times median absolute deviation in cents;
    the separate 90th–10th percentile span catches broad drift and bimodality.
    """
    parameters = (trim_seconds, min_quality, min_voiced_seconds, min_coverage,
                  max_spread_cents, max_frame_support)
    if (not all(math.isfinite(x) for x in parameters) or trim_seconds < 0
            or not 0 <= min_quality <= 1 or min_voiced_seconds <= 0
            or not 0 < min_coverage <= 1 or min_frames < 1
            or max_spread_cents <= 0 or max_frame_support <= 0):
        raise ValueError('Invalid calibration thresholds')

    # Do not preferentially select a higher quality duplicate. Last arrival wins.
    by_time = {}
    for observation in observations:
        if math.isfinite(observation.timestamp):
            by_time[float(observation.timestamp)] = observation
    rows = [by_time[t] for t in sorted(by_time)]
    if len(rows) < min_frames:
        raise _inconclusive('Too few timestamped analysis frames.')
    times = np.array([r.timestamp for r in rows])
    start, end = times[0] + trim_seconds, times[-1] - trim_seconds
    usable = float(end - start)
    if usable < min_voiced_seconds:
        raise _inconclusive('Recording too short after trimming the beginning and end.')

    hop = min(float(np.median(np.diff(times))), max_frame_support)
    accepted = []
    support = []
    for row in rows:
        if not start <= row.timestamp <= end:
            continue
        frequency = row.frequency
        if (row.voiced and frequency is not None and math.isfinite(frequency)
                and frequency > 0 and math.isfinite(row.quality)
                and min_quality <= row.quality <= 1):
            accepted.append(float(frequency))
            support.append((max(start, row.timestamp - hop / 2),
                            min(end, row.timestamp + hop / 2)))
    voiced = _union_duration(support)
    coverage = voiced / usable
    if (len(accepted) < min_frames or voiced + 1e-9 < min_voiced_seconds
            or coverage + 1e-9 < min_coverage):
        raise _inconclusive('Not enough reliable sustained voice; check input level and sing steadily.')

    frequencies = np.asarray(accepted)
    median_hz = float(np.median(frequencies))
    cents = 1200 * np.log2(frequencies / median_hz)
    stability = float(1.4826 * np.median(np.abs(cents - np.median(cents))))
    spread = float(np.percentile(cents, 90) - np.percentile(cents, 10))
    if spread > max_spread_cents:
        raise _inconclusive(f'Pitch is unstable (central spread {spread:.0f} cents; limit {max_spread_cents:.0f}).')
    return SampleSummary(median_hz, stability, voiced, usable, coverage,
                         len(accepted), spread)


def note_name(frequency: float) -> str:
    if not math.isfinite(frequency) or frequency <= 0:
        raise ValueError('Frequency must be positive and finite')
    midi = int(math.floor(69 + 12 * math.log2(frequency / 440) + 0.5))
    names = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B')
    return f'{names[midi % 12]}{midi // 12 - 1}'


def recommend_sa(
    low: SampleSummary,
    middle: SampleSummary,
    high: SampleSummary,
    min_semitones: float = 0,
    max_semitones: float = 7,
    margin_cents: float = 50,
    min_stage_separation_cents: float = 100,
    ranking_tolerance_cents: float = 5,
) -> SaRecommendation:
    """Fit every demo note inside conservative measured boundaries.

    Candidate Sa need not equal the measured middle: the *exercise midpoint*
    should sit near that pitch. A lack of safe grid candidates is inconclusive,
    rather than permission to lower safety margins or silently change exercises.
    Candidate costs within ``ranking_tolerance_cents`` of the minimum are a
    near-tie. Select the lower safe candidate and disclose this ambiguity instead
    of letting sub-cent detector interpolation differences flip the tonic.
    """
    settings = (min_semitones, max_semitones, margin_cents,
                min_stage_separation_cents, ranking_tolerance_cents)
    if (not all(math.isfinite(x) for x in settings)
            or min_semitones > max_semitones or margin_cents < 0
            or min_stage_separation_cents <= 0 or ranking_tolerance_cents < 0):
        raise ValueError('Invalid exercise span or safety thresholds')
    values = [s.median_hz for s in (low, middle, high)]
    if any(not math.isfinite(v) or v <= 0 for v in values):
        raise _inconclusive('Measured frequencies are invalid.')
    # Summary objects may have been loaded or constructed by callers. Reject
    # evidence that could not have passed the documented default quality rules.
    for sample in (low, middle, high):
        stats = (sample.stability_cents, sample.voiced_seconds,
                 sample.usable_seconds, sample.voiced_fraction, sample.spread_cents)
        if (not all(math.isfinite(x) for x in stats)
                or sample.voiced_seconds < 1 - 1e-9 or sample.usable_seconds <= 0
                or not .7 - 1e-9 <= sample.voiced_fraction <= 1 + 1e-9
                or sample.accepted_frames < 20 or sample.stability_cents < 0
                or not 0 <= sample.spread_cents <= 80):
            raise _inconclusive('One or more recordings have insufficient or unstable evidence.')
    low_hz, middle_hz, high_hz = values
    if (middle_hz <= low_hz or high_hz <= middle_hz
            or 1200 * math.log2(middle_hz / low_hz) < min_stage_separation_cents
            or 1200 * math.log2(high_hz / middle_hz) < min_stage_separation_cents):
        raise _inconclusive('Low, middle and high samples must be distinctly ordered comfortable pitches.')

    safe_low = low_hz * 2 ** (margin_cents / 1200)
    safe_high = high_hz * 2 ** (-margin_cents / 1200)
    minimum_sa = safe_low / 2 ** (min_semitones / 12)
    maximum_sa = safe_high / 2 ** (max_semitones / 12)
    if minimum_sa > maximum_sa:
        raise _inconclusive('Measured comfortable range is too narrow for the full demonstration exercise span.')
    first_midi = math.ceil(69 + 12 * math.log2(minimum_sa / 440) - 1e-10)
    last_midi = math.floor(69 + 12 * math.log2(maximum_sa / 440) + 1e-10)
    candidates = [440 * 2 ** ((midi - 69) / 12)
                  for midi in range(first_midi, last_midi + 1)]
    if not candidates:
        raise _inconclusive('No standard semitone-grid tonic fits the safe measured range.')
    midpoint = (min_semitones + max_semitones) / 2
    costs = {f: abs(1200 * math.log2(f * 2 ** (midpoint / 12) / middle_hz))
             for f in candidates}
    best_cost = min(costs.values())
    near_tied = [f for f in candidates
                 if costs[f] <= best_cost + ranking_tolerance_cents + 1e-9]
    sa = min(near_tied)
    if len(near_tied) > 1:
        ranking_explanation = (
            f'Ranking is ambiguous: {len(near_tied)} safe candidates are within '
            f'{ranking_tolerance_cents:g} cents of the best midpoint-error cost. '
            f'The lower candidate, {note_name(sa)}, is chosen deterministically; '
            'small measurement differences do not establish a unique best Sa. '
        )
    else:
        ranking_explanation = (
            f'{note_name(sa)} has the best exercise-midpoint fit to the measured '
            f'middle (ranking tolerance {ranking_tolerance_cents:g} cents). '
        )
    explanation = (
        f'Measured low/middle/high: {low_hz:.2f}/{middle_hz:.2f}/{high_hz:.2f} Hz. '
        f'Inset {margin_cents:g}-cent margins give an approximate safe range '
        f'{safe_low:.2f}–{safe_high:.2f} Hz. All exercise intervals '
        f'({min_semitones:g} to {max_semitones:g} semitones) fit. '
        f'Evaluated {len(candidates)} grid candidates. '
        f'{ranking_explanation}'
        'This is a comfortable '
        'tonic recommendation from three short samples, not a fixed personal Sa '
        'or an exhaustive vocal-range assessment.'
    )
    return SaRecommendation(sa, note_name(sa), safe_low, safe_high, explanation,
                            low_hz, middle_hz, high_hz, min_semitones,
                            max_semitones, margin_cents, len(candidates))


@dataclass
class SessionState:
    """In-memory session only; new proposals never overwrite confirmed Sa."""
    confirmed_sa_hz: float | None = None
    recommendation: SaRecommendation | None = None

    def propose(self, recommendation: SaRecommendation) -> None:
        self.recommendation = recommendation

    def confirm(self, recommendation: SaRecommendation | None = None) -> float:
        selected = recommendation if recommendation is not None else self.recommendation
        if selected is None or not math.isfinite(selected.sa_hz) or selected.sa_hz <= 0:
            raise _inconclusive('No valid Sa recommendation to confirm.')
        self.recommendation = selected
        self.confirmed_sa_hz = selected.sa_hz
        return self.confirmed_sa_hz

    def reset(self, clear_confirmed: bool = False) -> None:
        """Retry clears the proposal; a confirmed tonic survives unless explicit."""
        self.recommendation = None
        if clear_confirmed:
            self.confirmed_sa_hz = None
