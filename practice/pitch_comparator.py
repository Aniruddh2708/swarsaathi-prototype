"""Independent observed-pitch comparison on a fixed guided-tempo timeline.

Pitch identities use the prototype's 12-TET approximation. They never alter a
measured frequency, and octave differences remain visible and incorrect.
"""
from __future__ import annotations

from dataclasses import dataclass
import math

from practice.alankars import TimedNote, Timeline


SWARAS = ('Sa', 'komal Re', 'Re', 'komal Ga', 'Ga', 'Ma', 'tivra Ma',
          'Pa', 'komal Dha', 'Dha', 'komal Ni', 'Ni')
MIN_QUALITY = 0.8
MAX_GRACE_SECONDS = 0.1


@dataclass(frozen=True)
class Comparison:
    status: str
    cents_error: float | None
    observed_swara: str | None
    expected_note: TimedNote | None
    timing_warning: str | None = None


def reliable(frequency: float | None, quality: float = 1, voiced: bool = True) -> bool:
    """Reject non-finite values rather than allowing NaN to pass comparisons."""
    return (voiced and frequency is not None and math.isfinite(frequency)
            and frequency > 0 and math.isfinite(quality) and MIN_QUALITY <= quality <= 1)


def relative_cents(frequency: float, sa_hz: float) -> float:
    if not math.isfinite(frequency) or frequency <= 0 or not math.isfinite(sa_hz) or sa_hz <= 0:
        raise ValueError('Frequencies must be positive and finite')
    return 1200.0 * math.log2(frequency / sa_hz)


def nearest_swara(frequency: float, sa_hz: float) -> str:
    """Return a chromatic identity with an explicit octave relative to Sa."""
    semitone = math.floor(relative_cents(frequency, sa_hz) / 100 + 0.5)
    octave, index = divmod(semitone, 12)
    return f'{SWARAS[index]} ({octave:+d} octave)'


def scoring_interval(note: TimedNote, grace_seconds: float = .1) -> tuple[float, float]:
    """At most 100 ms and 20% of the note duration are excluded per edge.

    The absolute cap cannot be increased through a caller argument. Smaller
    grace values are permitted, including zero for stricter diagnostics.
    """
    if not math.isfinite(grace_seconds) or grace_seconds < 0:
        raise ValueError('Grace must be finite and nonnegative')
    grace = min(grace_seconds, MAX_GRACE_SECONDS, .2 * (note.end - note.start))
    return note.start + grace, note.end - grace


def compare(timeline: Timeline, timestamp: float, frequency: float | None,
            quality: float = 1, voiced: bool = True, tolerance_cents: float = 30,
            grace_seconds: float = .1) -> Comparison:
    if not math.isfinite(tolerance_cents) or not 0 < tolerance_cents < 50:
        raise ValueError('Pitch tolerance must be greater than 0 and below 50 cents')
    if not math.isfinite(timestamp):
        return Comparison('No Reliable Voice', None, None, None)
    note = timeline.at(timestamp)
    valid = reliable(frequency, quality, voiced)
    observed = nearest_swara(frequency, timeline.sa_hz) if valid else None
    error = relative_cents(frequency, note.frequency) if valid and note else None
    if note is None:
        return Comparison('Transition / Unscored Boundary', error, observed, None)
    start, end = scoring_interval(note, grace_seconds)
    if not start <= timestamp < end:
        return Comparison('Transition / Unscored Boundary', error, observed, note)
    if not valid:
        return Comparison('No Reliable Voice', None, None, note)
    if abs(error) <= tolerance_cents + 1e-9:
        status = 'On Pitch'
    else:
        actual_semitone = math.floor(relative_cents(frequency, timeline.sa_hz) / 100 + .5)
        expected_semitone = round(note.cents / 100)
        status = ('Slightly High' if error > 0 else 'Slightly Low') if actual_semitone == expected_semitone else 'Wrong Swara'
    warning = None
    if status == 'Wrong Swara':
        warning = ('Pitch or timing mismatch: comparison follows the guided tempo; '
                   'it does not realign the observed singing.')
    return Comparison(status, error, observed, note, warning)
