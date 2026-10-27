"""Single source of truth for the 12-TET prototype melody and its timeline."""
from __future__ import annotations

from dataclasses import dataclass
import json
import math
from pathlib import Path


@dataclass(frozen=True)
class Note:
    swara: str
    semitone_offset: int
    octave_offset: int = 0
    beats: float = 1.0

    @property
    def cents(self) -> float:
        return 100.0 * (self.semitone_offset + 12 * self.octave_offset)


@dataclass(frozen=True)
class Alankar:
    id: str
    name: str
    notes: tuple[Note, ...]


@dataclass(frozen=True)
class TimedNote:
    index: int
    note: Note
    start: float
    end: float
    frequency: float

    @property
    def cents(self) -> float:
        return self.note.cents

    @property
    def swara(self) -> str:
        return self.note.swara


@dataclass(frozen=True)
class Timeline:
    alankar: Alankar
    sa_hz: float
    bpm: float
    notes: tuple[TimedNote, ...]

    @property
    def duration(self) -> float:
        return self.notes[-1].end

    def at(self, timestamp: float) -> TimedNote | None:
        return next((n for n in self.notes if n.start <= timestamp < n.end), None)

    def graph_points(self) -> tuple[list[float], list[float]]:
        """Duplicate endpoints yield exact steps in the graph, including octaves."""
        return ([t for n in self.notes for t in (n.start, n.end)],
                [n.cents for n in self.notes for _ in range(2)])


def load_alankars(path: str | Path | None = None) -> list[Alankar]:
    source = Path(path) if path else Path(__file__).resolve().parents[1] / 'data' / 'alankars.json'
    raw = json.loads(source.read_text(encoding='utf-8'))
    result = []
    seen = set()
    for item in raw:
        if item['id'] in seen:
            raise ValueError('Duplicate Alankar id')
        seen.add(item['id'])
        notes = tuple(Note(**n) for n in item['notes'])
        if not notes or any(not math.isfinite(n.beats) or n.beats <= 0 for n in notes):
            raise ValueError('Each Alankar needs notes with positive finite beat durations')
        if any(type(n.semitone_offset) is not int or type(n.octave_offset) is not int for n in notes):
            raise ValueError('Note offsets must be integers')
        result.append(Alankar(item['id'], item['name'], notes))
    if not result:
        raise ValueError('The exercise library is empty')
    return result


def build_timeline(alankar: Alankar, sa_hz: float, bpm: float = 72) -> Timeline:
    if not math.isfinite(sa_hz) or sa_hz <= 0 or not math.isfinite(bpm) or not 30 <= bpm <= 180:
        raise ValueError('Sa must be positive and finite; BPM must be between 30 and 180')
    now = 0.0
    notes = []
    for index, note in enumerate(alankar.notes):
        end = now + note.beats * 60.0 / bpm
        notes.append(TimedNote(index, note, now, end, sa_hz * 2 ** (note.cents / 1200)))
        now = end
    return Timeline(alankar, sa_hz, bpm, tuple(notes))
