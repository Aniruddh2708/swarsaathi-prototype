"""Continuous relative-cent graph; observed values come only from microphone DSP."""
from __future__ import annotations

import math

import pyqtgraph as pg


class PitchGraph(pg.PlotWidget):
    def __init__(self, parent=None):
        super().__init__(parent=parent)
        self.setBackground('#101923')
        self.setLabel('bottom', 'Time', units='s')
        self.setLabel('left', 'Pitch relative to confirmed Sa', units='cents')
        self.showGrid(x=True, y=True, alpha=.18)
        self.addLegend()
        self.expected = self.plot(pen=pg.mkPen('#cbd5e1', width=2), name='Expected')
        self.observed = self.plot(pen=pg.mkPen('#38bdf8', width=2), name='Actual voice',
                                  connect='finite')
        self.cursor = pg.InfiniteLine(0, angle=90, pen=pg.mkPen('#fbbf24', width=1))
        self.addItem(self.cursor)
        self.times: list[float] = []
        self.cents: list[float] = []
        self.timeline = None
        self._target_min = self._target_max = 0.

    def set_timeline(self, timeline):
        self.timeline = timeline
        x, y = timeline.graph_points()
        self.expected.setData(x, y)
        self.times.clear()
        self.cents.clear()
        self.observed.setData([], [])
        self.cursor.setValue(0)
        self.setXRange(0, timeline.duration, padding=.02)
        self._target_min, self._target_max = min(y), max(y)
        self.setYRange(min(y) - 150, max(y) + 150, padding=.05)

    def append_observation(self, timestamp, cents):
        if self.times and timestamp - self.times[-1] > .05:
            self.times.append((self.times[-1] + timestamp) / 2)
            self.cents.append(math.nan)
        self.times.append(float(timestamp))
        self.cents.append(float(cents) if cents is not None and math.isfinite(cents) else math.nan)

    def refresh(self, elapsed=None):
        self.observed.setData(self.times, self.cents, connect='finite')
        finite = [value for value in self.cents if math.isfinite(value)]
        low = min([self._target_min, *finite]) - 150
        high = max([self._target_max, *finite]) + 150
        self.setYRange(low, high, padding=.05)
        if elapsed is not None:
            self.cursor.setValue(elapsed)
