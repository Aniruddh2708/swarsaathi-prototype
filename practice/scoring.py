"""Auditable equal-note-weighted pitch-match scoring, including missing voice.

Each eligible note interval is partitioned into cells no longer than 20 ms by
default. Every cell contributes its duration to the denominator. An observation
can occupy only the cell containing its timestamp, never neighboring cells.
Where multiple observations occupy a cell, the closest to its midpoint is used;
exact timestamp duplicates are ignored. This conservative sampling rule keeps
sparse or stalled acquisition from filling silent gaps. Scores use raw detected
pitch, independently of graph smoothing and expected-pitch generation.
"""
from __future__ import annotations

from bisect import bisect_right
from dataclasses import dataclass, field
import math
from statistics import median
from typing import Iterable

from practice.alankars import Timeline
from practice.pitch_comparator import reliable, relative_cents, scoring_interval


@dataclass(frozen=True)
class Observation:
    timestamp: float
    frequency: float | None
    quality: float = 1
    voiced: bool = True


@dataclass(frozen=True)
class NoteResult:
    index: int
    swara: str
    eligible_duration: float
    valid_duration: float
    correct_duration: float
    missing_duration: float
    median_abs_cents: float | None
    attempted: bool
    accuracy: float
    expected_intervals: int
    valid_intervals: int
    correct_intervals: int


@dataclass(frozen=True)
class SessionReport:
    overall_accuracy: float
    notes: list[NoteResult]
    limitations: list[str] = field(default_factory=list)
    improvement_notes: list[str] = field(default_factory=list)
    tolerance_cents: float = 30
    grace_seconds: float = .1
    frame_seconds: float = .02


def score_session(timeline: Timeline, observations: Iterable[Observation],
                  tolerance_cents: float = 30, grace_seconds: float = .1,
                  frame_seconds: float = .02, max_observation_age: float = .04) -> SessionReport:
    if not math.isfinite(tolerance_cents) or not 0 < tolerance_cents < 50:
        raise ValueError('Pitch tolerance must be greater than 0 and below 50 cents')
    if not math.isfinite(frame_seconds) or not 0 < frame_seconds <= .04:
        raise ValueError('Scoring cells must be greater than 0 and no longer than 40 ms')
    if not math.isfinite(max_observation_age) or not 0 < max_observation_age <= .04:
        raise ValueError('Maximum observation age must be greater than 0 and at most 40 ms')
    # Validate grace even if a future caller supplies an empty timeline.
    if not math.isfinite(grace_seconds) or grace_seconds < 0:
        raise ValueError('Grace must be finite and nonnegative')
    unique = {}
    for observation in observations:
        if math.isfinite(observation.timestamp):
            unique.setdefault(observation.timestamp, observation)
    ordered = sorted(unique.values(), key=lambda item: item.timestamp)
    times = [item.timestamp for item in ordered]
    results = []
    substantial_mismatch = False
    for note in timeline.notes:
        start, end = scoring_interval(note, grace_seconds)
        duration = end - start
        count = max(1, math.ceil(duration / frame_seconds - 1e-10))
        # Equal-size cells prevent a tiny final cell from distorting sampling.
        width = duration / count
        cell_starts = [start + i * width for i in range(count)]
        selected = {}
        left = bisect_right(times, start - 1e-12)
        right = bisect_right(times, end - 1e-12)
        for item in ordered[left:right]:
            if not start <= item.timestamp < end:
                continue
            cell = min(count - 1, bisect_right(cell_starts, item.timestamp) - 1)
            midpoint = start + (cell + .5) * width
            distance = abs(item.timestamp - midpoint)
            if distance > max_observation_age:
                continue
            previous = selected.get(cell)
            if previous is None or distance < abs(previous.timestamp - midpoint):
                selected[cell] = item
        valid_count = correct_count = large_error_count = 0
        errors = []
        for item in selected.values():
            if reliable(item.frequency, item.quality, item.voiced):
                valid_count += 1
                error = abs(relative_cents(item.frequency, note.frequency))
                errors.append(error)
                if error > 50:
                    large_error_count += 1
                if error <= tolerance_cents + 1e-9:
                    correct_count += 1
        if valid_count and large_error_count / valid_count >= .1:
            substantial_mismatch = True
        valid_duration = valid_count * width
        correct_duration = correct_count * width
        results.append(NoteResult(
            index=note.index, swara=note.swara, eligible_duration=duration,
            valid_duration=valid_duration, correct_duration=correct_duration,
            missing_duration=max(0., duration - valid_duration),
            median_abs_cents=median(errors) if errors else None,
            # An attempted note needs at least half its eligible interval voiced.
            attempted=valid_duration >= .5 * duration,
            accuracy=100. * correct_count / count, expected_intervals=count,
            valid_intervals=valid_count, correct_intervals=correct_count))
    overall = sum(result.accuracy for result in results) / len(results) if results else 0.
    limitations = ['Fixed guided tempo; pitch mismatch and timing drift cannot be uniquely distinguished.',
                   '12-TET pitch-match score with experimental thresholds; not a validated Hindustani assessment.']
    if any(result.valid_duration < .8 * result.eligible_duration for result in results):
        limitations.append('Incomplete reliable voice coverage: silence, rejected pitch, or dropped acquisition reduces the score.')
    if substantial_mismatch:
        limitations.append('Pitch or timing mismatch detected; alignment confidence is limited.')
    improvements = [f'{result.index + 1}. {result.swara}: {result.accuracy:.1f}% pitch match'
                    for result in results if result.accuracy < 80]
    return SessionReport(overall, results, limitations, improvements, tolerance_cents,
                         min(grace_seconds, .1), frame_seconds)
