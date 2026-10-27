"""Three-view desktop workflow. No target is ever fed into the pitch detector."""
from __future__ import annotations

import csv
from collections import deque
from dataclasses import asdict
from datetime import datetime, timezone
import json
import logging
import math
from pathlib import Path
import queue
import time
import uuid

import numpy as np
from PyQt6.QtCore import QTimer
from PyQt6.QtWidgets import (
    QComboBox, QDoubleSpinBox, QHBoxLayout, QHeaderView, QLabel, QMainWindow,
    QProgressBar, QPushButton, QSpinBox, QStackedWidget, QTableWidget,
    QTableWidgetItem, QVBoxLayout, QWidget,
)

from audio.capture import AudioCapture, AudioError, list_input_devices
from audio.pitch_detector import PitchEstimate, PitchSmoother, YinDetector
from audio.reference_audio import ReferencePlayer, synthesize_timeline, synthesize_tone
from calibration.find_my_sa import SessionState, recommend_sa, summarize_sample
from practice.alankars import build_timeline, load_alankars
from practice.pitch_comparator import compare
from practice.scoring import Observation, score_session
from ui.pitch_graph import PitchGraph

LOG = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parents[1]
PROMPTS = (
    ('Comfortable Low', "Sing a comfortably low 'Aa' sound for a few seconds. Do not strain."),
    ('Comfortable Middle', "Sing 'Aa' at your natural, comfortable middle pitch."),
    ('Comfortable High', "Sing a comfortably high 'Aa' sound without forcing your voice."),
)


def _label(text='', large=False):
    widget = QLabel(text)
    widget.setWordWrap(True)
    if large:
        widget.setStyleSheet('font-size: 20px; font-weight: 600;')
    return widget


class MainWindow(QMainWindow):
    """All Qt access stays on the GUI thread, reached through a bounded queue.

    The optional injected clock/factories support deterministic automated tests;
    they do not expose a simulated performance mode to users.
    """

    def __init__(self, *, clock=time.monotonic, capture_factory=AudioCapture,
                 player_factory=ReferencePlayer, artifacts_dir=None):
        super().__init__()
        self.clock, self.capture_factory = clock, capture_factory
        self.artifacts_dir = Path(artifacts_dir) if artifacts_dir else ROOT / 'artifacts'
        self.state = SessionState()
        self.library = load_alankars()
        self.player = player_factory()
        self.capture = None
        self.mode = 'idle'
        self._generation = 0
        self._estimates = queue.Queue(maxsize=256)
        self.ui_queue_drops = 0
        self._worker_times = deque(maxlen=20000)
        self._render_ages = deque(maxlen=20000)
        self._capture_metrics = {}
        self._calibration_summaries = []
        self._calibration_recordings = []
        self._stage_observations = []
        self._stage = 0
        self._recording_started = None
        self._session_start = None
        self._last_estimate_timestamp = None
        self._timeline = None
        self._observations = []
        self._report = None
        self._reference_pending = False
        self._reference_completed = False
        self._last_live_score_time = -math.inf
        self._smoother = PitchSmoother()
        self.setWindowTitle('SwarSaathi — Singing Pitch Prototype')
        self.resize(1120, 840)
        self._build_ui()
        self.refresh_microphones()
        self.timer = QTimer(self)
        self.timer.timeout.connect(self._tick)
        self.timer.start(33)

    def _build_ui(self):
        container = QWidget()
        outer = QVBoxLayout(container)
        title = _label('SwarSaathi', True)
        outer.addWidget(title)
        outer.addWidget(_label('A measured tonic recommendation and guided Alankar pitch practice. '
                               'Prototype uses 12-tone equal temperament and experimental thresholds.'))
        self.views = QStackedWidget()
        outer.addWidget(self.views, 1)
        self.message_label = _label()
        outer.addWidget(self.message_label)
        self.setCentralWidget(container)

        calibration = QWidget()
        layout = QVBoxLayout(calibration)
        layout.addWidget(_label('1 · Find My Sa', True))
        layout.addWidget(_label('Three short samples suggest a comfortable tonic; they do not reveal '
                                'a uniquely fixed personal Sa or measure your full vocal range.'))
        device_row = QHBoxLayout()
        device_row.addWidget(_label('Microphone'))
        self.microphone = QComboBox()
        self.microphone.setMinimumWidth(330)
        device_row.addWidget(self.microphone, 1)
        self.refresh_button = QPushButton('Refresh devices')
        self.refresh_button.clicked.connect(self.refresh_microphones)
        device_row.addWidget(self.refresh_button)
        self.window_size = QComboBox()
        self.window_size.addItem('2048 samples · shorter delay', 2048)
        self.window_size.addItem('4096 samples · lower voices', 4096)
        device_row.addWidget(self.window_size)
        layout.addLayout(device_row)
        meter_row = QHBoxLayout()
        self.monitor_button = QPushButton('Monitor microphone')
        self.monitor_button.clicked.connect(self.toggle_monitor)
        meter_row.addWidget(self.monitor_button)
        self.level = QProgressBar()
        self.level.setRange(0, 100)
        self.level.setFormat('Input level %p%')
        meter_row.addWidget(self.level, 1)
        self.detected_label = _label('No voice measured yet')
        meter_row.addWidget(self.detected_label)
        layout.addLayout(meter_row)
        self.stage_label = _label('', True)
        self.prompt_label = _label()
        layout.addWidget(self.stage_label)
        layout.addWidget(self.prompt_label)
        self.record_button = QPushButton()
        self.record_button.clicked.connect(self.record_calibration)
        layout.addWidget(self.record_button)
        self.sample_labels = [_label(f'{name}: not recorded') for name, _ in PROMPTS]
        for label in self.sample_labels:
            layout.addWidget(label)
        self.recommendation_label = _label()
        layout.addWidget(self.recommendation_label)
        actions = QHBoxLayout()
        self.play_sa_button = QPushButton('Play suggested Sa')
        self.play_sa_button.clicked.connect(self.play_sa)
        self.confirm_button = QPushButton('Confirm Sa')
        self.confirm_button.clicked.connect(self.confirm_sa)
        self.retry_button = QPushButton('Retry calibration')
        self.retry_button.clicked.connect(self.retry_calibration)
        actions.addWidget(self.play_sa_button)
        actions.addWidget(self.confirm_button)
        actions.addWidget(self.retry_button)
        layout.addLayout(actions)
        layout.addStretch()
        self.views.addWidget(calibration)
        self._update_stage_ui()

        setup = QWidget()
        layout = QVBoxLayout(setup)
        layout.addWidget(_label('2 · Alankar selection', True))
        self.confirmed_label = _label('Sa has not been confirmed')
        layout.addWidget(self.confirmed_label)
        self.alankar_choice = QComboBox()
        for exercise in self.library:
            self.alankar_choice.addItem(exercise.name)
        self.alankar_choice.currentIndexChanged.connect(self._selection_changed)
        layout.addWidget(self.alankar_choice)
        self.sequence_label = _label('', True)
        layout.addWidget(self.sequence_label)
        bpm_row = QHBoxLayout()
        bpm_row.addWidget(_label('Guided tempo (BPM)'))
        self.bpm = QSpinBox()
        self.bpm.setRange(40, 120)
        self.bpm.setValue(72)
        self.bpm.valueChanged.connect(self._selection_changed)
        bpm_row.addWidget(self.bpm)
        bpm_row.addStretch()
        layout.addLayout(bpm_row)
        layout.addWidget(_label('Listen to the full reference, then sing once at the guided tempo after '
                                'the three-beat visual count-in. Reference output stops before capture. '
                                'Use headphones to reduce acoustic interference.'))
        self.play_melody_button = QPushButton('Play reference Alankar')
        self.play_melody_button.clicked.connect(self.play_reference)
        layout.addWidget(self.play_melody_button)
        self.stop_reference_button = QPushButton('Stop reference')
        self.stop_reference_button.clicked.connect(self.stop_reference)
        layout.addWidget(self.stop_reference_button)
        self.reference_label = _label('Listen to the full reference before starting.')
        layout.addWidget(self.reference_label)
        self.start_button = QPushButton('Start Practice')
        self.start_button.clicked.connect(self.start_practice)
        self.start_button.setEnabled(False)
        layout.addWidget(self.start_button)
        self.recalibrate_button = QPushButton('Return to calibration')
        self.recalibrate_button.clicked.connect(self.return_to_calibration)
        layout.addWidget(self.recalibrate_button)
        layout.addStretch()
        self.views.addWidget(setup)

        practice = QWidget()
        layout = QVBoxLayout(practice)
        self.practice_title = _label('3 · Live pitch mapping', True)
        self.expected_label = _label('Expected: —')
        self.actual_label = _label('Actual: —')
        self.status_label = _label('No Reliable Voice', True)
        self.timing_label = _label('Fixed guided tempo; substantial drift reduces alignment confidence.')
        for widget in (self.practice_title, self.expected_label, self.actual_label,
                       self.status_label, self.timing_label):
            layout.addWidget(widget)
        self.graph = PitchGraph()
        layout.addWidget(self.graph, 1)
        self.accuracy_label = _label('Pitch accuracy pending', True)
        layout.addWidget(self.accuracy_label)
        self.results = QTableWidget(0, 9)
        self.results.setHorizontalHeaderLabels(['Note', 'Match %', 'Attempted', 'Correct / expected',
                                                'Voiced / expected', 'Missing (s)', 'Median |cents|',
                                                'Eligible (s)', 'Correct (s)'])
        self.results.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        self.results.setMaximumHeight(210)
        self.results.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        layout.addWidget(self.results)
        self.limitations_label = _label()
        layout.addWidget(self.limitations_label)
        actions = QHBoxLayout()
        self.stop_practice_button = QPushButton('Stop and report incomplete session')
        self.stop_practice_button.clicked.connect(lambda: self.finish_practice(incomplete=True))
        self.again_button = QPushButton('Practice Again')
        self.again_button.clicked.connect(self.practice_again)
        self.finish_button = QPushButton('Finish')
        self.finish_button.clicked.connect(self.finish)
        for button in (self.stop_practice_button, self.again_button, self.finish_button):
            actions.addWidget(button)
        layout.addLayout(actions)
        self.views.addWidget(practice)
        self._selection_changed()

    def _message(self, message, error=False):
        self.message_label.setText(message)
        self.message_label.setStyleSheet('color: #dc2626;' if error else '')
        (LOG.error if error else LOG.info)(message)

    def refresh_microphones(self):
        if self.capture is not None:
            self._message('Stop monitoring or recording before changing microphones.', True)
            return
        previous = self.microphone.currentData()
        self.microphone.clear()
        try:
            devices = list_input_devices()
        except AudioError as exc:
            devices = []
            self._message(str(exc), True)
        if devices:
            for device in devices:
                self.microphone.addItem(f"{device['index']}: {device['name']}", device['index'])
            index = self.microphone.findData(previous)
            if index >= 0:
                self.microphone.setCurrentIndex(index)
            self._message('Microphone selected. Monitor input or record your comfortable low sample.')
        else:
            self.microphone.addItem('No microphone available', None)
            self._message('No microphone available here. Connect a microphone on the evaluation laptop '
                          'and refresh devices; no live singing has been measured.', True)
        self.microphone.setEnabled(bool(devices))
        self.monitor_button.setEnabled(bool(devices))
        self.record_button.setEnabled(bool(devices) and self._stage < 3)

    def _start_capture(self, mode):
        self._stop_capture()
        generation = self._generation
        detector = None

        def analyze(frame):
            nonlocal detector
            if detector is None or detector.sample_rate != frame.sample_rate:
                detector = YinDetector(sample_rate=frame.sample_rate)
            began = time.perf_counter()
            estimate = detector.detect(frame.samples, frame.timestamp)
            analysis_ms = (time.perf_counter() - began) * 1000
            try:
                self._estimates.put_nowait((generation, estimate, analysis_ms))
            except queue.Full:
                self.ui_queue_drops += 1

        capture = self.capture_factory(device=self.microphone.currentData(),
                                       window_size=self.window_size.currentData(),
                                       on_frame=analyze)
        try:
            capture.start()
        except (AudioError, OSError, ValueError) as exc:
            capture.stop()
            self._message(str(exc), True)
            return False
        self.capture = capture
        self.mode = mode
        self.refresh_button.setEnabled(False)
        self.microphone.setEnabled(False)
        self.window_size.setEnabled(False)
        return True

    def _stop_capture(self):
        capture, self.capture = self.capture, None
        if capture is not None:
            capture.stop()
            self._capture_metrics = capture.metrics
            self._drain_estimates()
            LOG.info('Capture stopped: %s', self._capture_metrics)
        self._generation += 1
        while not self._estimates.empty():
            try:
                self._estimates.get_nowait()
            except queue.Empty:
                break
        if hasattr(self, 'refresh_button'):
            self.refresh_button.setEnabled(True)
            self.microphone.setEnabled(self.microphone.currentData() is not None)
            self.window_size.setEnabled(True)
            self.monitor_button.setText('Monitor microphone')

    def toggle_monitor(self):
        if self.mode == 'monitor':
            self._stop_capture()
            self.mode = 'idle'
        elif self.mode not in ('calibration', 'practice'):
            self.player.stop()
            if self._start_capture('monitor'):
                self.monitor_button.setText('Stop monitoring')
                self._message('Microphone monitor active. Values below come from the selected input.')

    def _update_stage_ui(self):
        if self._stage < 3:
            title, prompt = PROMPTS[self._stage]
            self.stage_label.setText(f'Step {self._stage + 1} / 3 · {title}')
            self.prompt_label.setText(prompt)
            self.record_button.setText(f'Record {title} · 3 seconds')
        else:
            self.stage_label.setText('Three samples measured')
            self.prompt_label.setText('Listen to the suggested tonic. Confirm if comfortable, or retry.')
            self.record_button.setText('Samples complete')
        recommended = self.state.recommendation is not None
        self.play_sa_button.setEnabled(recommended)
        self.confirm_button.setEnabled(recommended)

    def record_calibration(self):
        if self._stage >= 3 or self.mode == 'calibration':
            return
        self.player.stop()
        self._stage_observations = []
        if not self._start_capture('calibration'):
            return
        self._recording_started = self.clock()
        self.record_button.setEnabled(False)
        self.monitor_button.setEnabled(False)
        self.retry_button.setEnabled(False)
        self._message(f'Recording {PROMPTS[self._stage][0]}. Sing steadily without straining.')

    def _finish_calibration_sample(self):
        self._stop_capture()
        self.mode = 'idle'
        self.monitor_button.setEnabled(self.microphone.currentData() is not None)
        self.retry_button.setEnabled(True)
        try:
            summary = summarize_sample(self._stage_observations)
        except ValueError as exc:
            self._message(str(exc), True)
            self.record_button.setEnabled(self.microphone.currentData() is not None)
            return
        self._calibration_summaries.append(summary)
        self._calibration_recordings.append(list(self._stage_observations))
        self.sample_labels[self._stage].setText(
            f'{PROMPTS[self._stage][0]}: {summary.median_hz:.2f} Hz; '
            f'stability {summary.stability_cents:.1f} cents; '
            f'{summary.voiced_fraction * 100:.0f}% reliable voice coverage')
        self._stage += 1
        if self._stage == 3:
            try:
                offsets = [note.cents / 100 for exercise in self.library for note in exercise.notes]
                recommendation = recommend_sa(*self._calibration_summaries,
                                              min_semitones=min(offsets), max_semitones=max(offsets))
                self.state.propose(recommendation)
                self.recommendation_label.setText(
                    f'Suggested Sa: {recommendation.note_name} · {recommendation.sa_hz:.2f} Hz\n'
                    f'Conservative comfortable range: {recommendation.low_hz:.2f}–'
                    f'{recommendation.high_hz:.2f} Hz\n{recommendation.explanation}')
                self._message('Recommendation measured. Play the reference, then confirm or retry.')
                self._export_calibration()
            except ValueError as exc:
                self.recommendation_label.setText(str(exc))
                self._message(str(exc) + ' Use Retry calibration to collect three new samples.', True)
        else:
            self._message('Sample accepted. Continue with the next comfortable pitch.')
        self.record_button.setEnabled(self._stage < 3 and self.microphone.currentData() is not None)
        self._update_stage_ui()

    def retry_calibration(self):
        self._stop_capture()
        self.player.stop()
        self.mode = 'idle'
        self.state.reset(clear_confirmed=True)
        self._stage = 0
        self._calibration_summaries.clear()
        self._calibration_recordings.clear()
        self._stage_observations.clear()
        self.recommendation_label.clear()
        for label, (name, _) in zip(self.sample_labels, PROMPTS):
            label.setText(f'{name}: not recorded')
        self._update_stage_ui()
        self.record_button.setEnabled(self.microphone.currentData() is not None)
        self.monitor_button.setEnabled(self.microphone.currentData() is not None)
        self.retry_button.setEnabled(True)
        self._message('Calibration reset. Record three new comfortable samples.')

    def play_sa(self):
        if self.state.recommendation is None:
            return
        self._stop_capture()
        self.mode = 'idle'
        try:
            self.player.play(synthesize_tone(self.state.recommendation.sa_hz))
            self._message('Playing suggested Sa. No microphone scoring is active.')
        except (AudioError, ValueError) as exc:
            self._message(str(exc), True)

    def confirm_sa(self):
        if self.state.recommendation is None:
            self._message('Complete a reliable calibration before confirming Sa.', True)
            return
        self._stop_capture()
        self.player.stop()
        self.mode = 'idle'
        hz = self.state.confirm()
        self.confirmed_label.setText(f'Confirmed Sa: {self.state.recommendation.note_name} · {hz:.2f} Hz')
        self.views.setCurrentIndex(1)
        self._selection_changed()
        self._message('Sa confirmed for this session. Select an Alankar and listen to its reference.')

    def return_to_calibration(self):
        self.stop_reference()
        self._stop_capture()
        self.views.setCurrentIndex(0)
        self.mode = 'idle'

    def _selection_changed(self, *_):
        self.player.stop()
        self._reference_pending = self._reference_completed = False
        self.start_button.setEnabled(False)
        self.reference_label.setText('Listen to the full reference before starting.')
        self._set_setup_controls(True)
        exercise = self.library[self.alankar_choice.currentIndex()]
        self.sequence_label.setText(' → '.join(note.swara for note in exercise.notes))
        if self.state.confirmed_sa_hz is not None:
            self._timeline = build_timeline(exercise, self.state.confirmed_sa_hz, self.bpm.value())

    def _set_setup_controls(self, enabled):
        self.alankar_choice.setEnabled(enabled)
        self.bpm.setEnabled(enabled)
        self.play_melody_button.setEnabled(enabled and self.state.confirmed_sa_hz is not None)
        self.stop_reference_button.setEnabled(not enabled)
        self.recalibrate_button.setEnabled(enabled)

    def play_reference(self):
        if self.state.confirmed_sa_hz is None:
            self._message('Confirm a measured Sa before reference playback.', True)
            return
        self._stop_capture()
        self.mode = 'idle'
        self._timeline = build_timeline(self.library[self.alankar_choice.currentIndex()],
                                        self.state.confirmed_sa_hz, self.bpm.value())
        self._reference_completed = False
        self.start_button.setEnabled(False)
        try:
            self.player.play(synthesize_timeline(self._timeline))
        except (AudioError, ValueError) as exc:
            self._message(str(exc), True)
            return
        self._reference_pending = True
        self._set_setup_controls(False)
        self.reference_label.setText('Playing reference. Listen through the final note.')
        self._message('Reference audio and graph use the same note definitions and confirmed Sa.')

    def stop_reference(self):
        self.player.stop()
        self._reference_pending = self._reference_completed = False
        self.start_button.setEnabled(False)
        self._set_setup_controls(True)
        self.reference_label.setText('Playback stopped. Listen to the full reference before starting.')

    def start_practice(self):
        if self.state.confirmed_sa_hz is None or not self._reference_completed or self._timeline is None:
            self._message('Confirm Sa and listen to the complete selected reference before practice.', True)
            return
        self.player.stop()
        self._observations.clear()
        self._worker_times.clear()
        self._render_ages.clear()
        self.ui_queue_drops = 0
        self._report = None
        self._smoother.reset()
        self.timing_label.setText('Fixed guided tempo; substantial drift reduces alignment confidence.')
        if not self._start_capture('practice'):
            return
        self._session_start = self.clock() + 3 * 60 / self._timeline.bpm
        self._last_estimate_timestamp = self._session_start
        self._last_live_score_time = -math.inf
        self.graph.set_timeline(self._timeline)
        self.results.setRowCount(0)
        self.limitations_label.clear()
        self.practice_title.setText(
            f'3 · {self._timeline.alankar.name} · Sa {self._timeline.sa_hz:.2f} Hz · '
            f'{self._timeline.bpm:g} BPM')
        self.stop_practice_button.setEnabled(True)
        self.again_button.setEnabled(False)
        self.finish_button.setEnabled(True)
        self.accuracy_label.setText('Pitch accuracy pending — count-in')
        self.actual_label.setText('Actual: waiting for the session to begin')
        self.views.setCurrentIndex(2)
        self._message('Three-beat visual count-in. Reference output is stopped; recording is active.')

    def _drain_estimates(self):
        while True:
            try:
                generation, estimate, analysis_ms = self._estimates.get_nowait()
            except queue.Empty:
                break
            if generation != self._generation:
                continue
            self._worker_times.append(analysis_ms)
            self._accept_estimate(estimate)

    def _accept_estimate(self, estimate: PitchEstimate):
        """GUI-thread consumer of independently detected microphone observations."""
        self._last_estimate_timestamp = estimate.timestamp
        self.level.setValue(min(100, max(0, round(estimate.rms * 1000))))
        self.detected_label.setText(
            f'{estimate.frequency:.2f} Hz · quality {estimate.quality:.2f}'
            if estimate.voiced and estimate.frequency else 'No reliable voice')
        if self.mode == 'calibration' and self._recording_started is not None:
            if 0 <= estimate.timestamp - self._recording_started <= 3:
                self._stage_observations.append(estimate)
        elif self.mode == 'practice' and self._session_start is not None:
            elapsed = estimate.timestamp - self._session_start
            if not 0 <= elapsed < self._timeline.duration:
                return
            self._observations.append(Observation(elapsed, estimate.frequency,
                                                  estimate.quality, estimate.voiced))
            smoothed = self._smoother.process(estimate, self.state.confirmed_sa_hz)
            self.graph.append_observation(elapsed, smoothed.cents(self.state.confirmed_sa_hz))
            comparison = compare(self._timeline, elapsed, estimate.frequency,
                                 estimate.quality, estimate.voiced)
            self.status_label.setText(comparison.status)
            self.actual_label.setText(
                f'Actual: {estimate.frequency:.2f} Hz · {comparison.observed_swara or "—"} · '
                f'raw deviation {comparison.cents_error:+.1f} cents'
                if comparison.cents_error is not None else 'Actual: No Reliable Voice · raw deviation unavailable')
            if comparison.timing_warning:
                self.timing_label.setText(comparison.timing_warning)
            self._render_ages.append(max(0., (self.clock() - estimate.timestamp) * 1000))

    def _tick(self):
        now = self.clock()
        self._drain_estimates()
        if self._reference_pending and not self.player.playing:
            self._reference_pending = False
            self._reference_completed = bool(getattr(self.player, 'completed', False))
            self._set_setup_controls(True)
            self.start_button.setEnabled(self._reference_completed)
            self.reference_label.setText('Reference complete. Ready for the three-beat count-in.'
                                         if self._reference_completed else
                                         'Reference did not complete. Check output device and replay.')
            if getattr(self.player, 'error', None):
                self._message(self.player.error, True)
        if self.capture is not None and (self.capture.error or not self.capture.running):
            error = self.capture.error or 'Microphone stopped unexpectedly; check connection and permissions.'
            if self.mode == 'practice':
                self.finish_practice(incomplete=True, reason=error)
            else:
                self._stop_capture()
                self.mode = 'idle'
                self.record_button.setEnabled(self._stage < 3 and self.microphone.currentData() is not None)
                self.monitor_button.setEnabled(self.microphone.currentData() is not None)
                self.retry_button.setEnabled(True)
            self._message(error, True)
            return
        if self.mode == 'calibration' and self._recording_started is not None:
            elapsed = now - self._recording_started
            self.prompt_label.setText(PROMPTS[self._stage][1] + f' Recording: {min(3., elapsed):.1f} / 3.0 s')
            rate = self.capture.sample_rate if self.capture else 44100
            settle = self.window_size.currentData() / (2 * rate) + .1
            if elapsed >= 3 + settle:
                self._finish_calibration_sample()
        if self.mode == 'practice' and self._session_start is not None:
            elapsed = now - self._session_start
            if elapsed < 0:
                beats = math.ceil(-elapsed * self._timeline.bpm / 60)
                self.status_label.setText(f'Count-in · {beats}')
                self.expected_label.setText('Expected: prepare to sing Sa')
                return
            note = self._timeline.at(elapsed)
            if note:
                self.expected_label.setText(
                    f'Expected: {note.index + 1} / {len(self._timeline.notes)} · '
                    f'{note.swara} · {note.frequency:.2f} Hz')
            if self._last_estimate_timestamp is None or now - self._last_estimate_timestamp > .25:
                self.status_label.setText('No Reliable Voice')
                self.actual_label.setText('Actual: no fresh microphone estimate in the last 250 ms')
            self.graph.refresh(min(elapsed, self._timeline.duration))
            if now - self._last_live_score_time >= .2:
                interim = score_session(self._timeline, self._observations)
                self.accuracy_label.setText(
                    f'Pitch-match progress: {interim.overall_accuracy:.1f}% of full exercise '
                    '(unfinished notes included)')
                self._populate_note_table(interim, elapsed)
                self._last_live_score_time = now
            rate = self.capture.sample_rate if self.capture else 44100
            settle = self.window_size.currentData() / (2 * rate) + .1
            if elapsed >= self._timeline.duration + settle:
                self.finish_practice()

    def finish_practice(self, incomplete=False, reason=None):
        if self.mode != 'practice' or self._timeline is None:
            return
        self._stop_capture()
        self.player.stop()
        self.mode = 'results'
        self._report = score_session(self._timeline, self._observations)
        self.graph.refresh(self._timeline.duration)
        prefix = 'Incomplete session · ' if incomplete else ''
        self.accuracy_label.setText(f'{prefix}Overall Pitch Accuracy: {self._report.overall_accuracy:.1f}%')
        self.status_label.setText('Session stopped early' if incomplete else 'Session complete')
        self.expected_label.setText('Expected sequence: ' + ' → '.join(n.swara for n in self._timeline.notes))
        self._populate_note_table(self._report)
        limitations = list(self._report.limitations)
        if incomplete:
            limitations.append('Session incomplete: remaining expected voice counts as missing.')
        if reason:
            limitations.append(reason)
        if self._capture_metrics.get('overruns') or self._capture_metrics.get('dropped_samples') or self.ui_queue_drops:
            limitations.append('Audio/observation loss occurred. Inspect acquisition counters before interpreting the score.')
        improvements = self._report.improvement_notes
        self.limitations_label.setText(
            'Needs practice: ' + ('; '.join(improvements) if improvements else 'No note below 80% in this session.')
            + '\n' + ' '.join(limitations))
        self.stop_practice_button.setEnabled(False)
        self.again_button.setEnabled(True)
        try:
            path = self._export_session(incomplete, limitations)
            self._message(f'Pitch-match report and observations saved to {path}. '
                          'This score describes this exercise; it is not detector classification accuracy.')
        except OSError as exc:
            self._message(f'Results remain visible, but export failed: {exc}', True)

    def _populate_note_table(self, report, elapsed=None):
        self.results.setRowCount(len(report.notes))
        for row, note in enumerate(report.notes):
            expected = self._timeline.notes[note.index]
            pending = elapsed is not None and elapsed < expected.start
            current = elapsed is not None and expected.start <= elapsed < expected.end
            suffix = ' · pending' if pending else (' · current' if current else '')
            values = [f'{note.index + 1}. {note.swara}', f'{note.accuracy:.1f}',
                      'Yes' if note.attempted else 'No',
                      f'{note.correct_intervals}/{note.expected_intervals}',
                      f'{note.valid_intervals}/{note.expected_intervals}', f'{note.missing_duration:.2f}',
                      f'{note.median_abs_cents:.1f}' if note.median_abs_cents is not None else 'Unavailable',
                      f'{note.eligible_duration:.2f}', f'{note.correct_duration:.2f}']
            values[0] += suffix
            if pending:
                values[1:] = ['—'] * (len(values) - 1)
            for column, value in enumerate(values):
                self.results.setItem(row, column, QTableWidgetItem(value))

    def practice_again(self):
        self._stop_capture()
        self.player.stop()
        self.mode = 'idle'
        self.views.setCurrentIndex(1)
        self._selection_changed()
        self._message('Listen to the reference again before the next attempt.')

    def finish(self):
        if self.mode == 'practice':
            self.finish_practice(incomplete=True)
        self._stop_capture()
        self.player.stop()
        self.mode = 'idle'
        self._message('Finished. Microphone and playback are stopped. Close the window or Practice Again.')

    def _new_artifact_dir(self, prefix):
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
        path = self.artifacts_dir / f'{prefix}_{stamp}_{uuid.uuid4().hex[:8]}'
        path.mkdir(parents=True, exist_ok=False)
        return path

    def _export_calibration(self):
        try:
            path = self._new_artifact_dir('calibration')
            result = dict(recommendation=asdict(self.state.recommendation),
                          samples=[asdict(s) for s in self._calibration_summaries],
                          observations=[[asdict(r) for r in rows] for rows in self._calibration_recordings],
                          source='microphone', confirmed=False)
            (path / 'calibration.json').write_text(json.dumps(result, indent=2, allow_nan=False), encoding='utf-8')
            LOG.info('Calibration measurements saved: %s', path)
        except OSError as exc:
            self._message(f'Recommendation is available, but calibration export failed: {exc}', True)

    @staticmethod
    def _timing_summary(values):
        return {'count': len(values),
                'median_ms': float(np.median(values)) if values else None,
                'p95_ms': float(np.percentile(values, 95)) if values else None}

    def _export_session(self, incomplete, limitations):
        path = self._new_artifact_dir('practice')
        payload = dict(source='microphone', incomplete=incomplete,
                       alankar=self._timeline.alankar.name,
                       confirmed_sa_hz=self._timeline.sa_hz, bpm=self._timeline.bpm,
                       timeline=asdict(self._timeline), report=asdict(self._report), limitations=limitations,
                       capture_metrics=self._capture_metrics, ui_queue_drops=self.ui_queue_drops,
                       detector_processing=self._timing_summary(self._worker_times),
                       frame_center_to_gui_consumption=self._timing_summary(self._render_ages),
                       latency_note='Frame-center age includes window buffering and GUI queue delay; '
                                    'this is not measured acoustic response latency.')
        (path / 'report.json').write_text(json.dumps(payload, indent=2, allow_nan=False), encoding='utf-8')
        with (path / 'observations.csv').open('x', encoding='utf-8', newline='') as output:
            writer = csv.writer(output)
            writer.writerow(['timestamp_seconds', 'raw_frequency_hz', 'quality', 'voiced',
                             'expected_hz', 'raw_cents_error', 'status'])
            for item in self._observations:
                comparison = compare(self._timeline, item.timestamp, item.frequency, item.quality, item.voiced)
                writer.writerow([item.timestamp, item.frequency, item.quality, item.voiced,
                                 comparison.expected_note.frequency if comparison.expected_note else '',
                                 comparison.cents_error, comparison.status])
        LOG.info('Practice audit saved: %s', path)
        return path

    def closeEvent(self, event):
        self.timer.stop()
        if self.mode == 'practice':
            self.finish_practice(incomplete=True)
        self._stop_capture()
        self.player.stop()
        super().closeEvent(event)
