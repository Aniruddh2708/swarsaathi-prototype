# Implementation and validation ledger

The requested software has been implemented in the originally empty repository. The final software regression run executed **99 tests: 99 passed, 0 failed, 0 errors, 0 skipped, 0 expected failures**. Exact test names, outcomes, and timings are in `artifacts/test_results.json`; console output is in `artifacts/test_run.log`. Hardware cases are **unrun**, not silently counted as skipped or passed unit tests.

The cloud instance runs Python 3.12.14 on Debian. Native PortAudio loads, but enumeration returns no input devices. An attempted real recording fails actionably and creates no WAV. There is no display or `/dev/snd`. The hardware portion of every relevant acceptance checkpoint therefore remains pending. Independent software milestones proceeded without declaring those checkpoints passed.

## Milestone 0 — Working environment

- **Implemented:** pinned four-package requirements, modular source tree, virtual environment, microphone enumeration, selected-device PCM WAV recording, supported sample-rate fallback, and repeatable managed-cloud setup/runtime wrappers.
- **Tests passed:** 20 tests in `tests.test_capture`, covering capture plus reference audio. `pip check`, imports/native PortAudio loading, and module compilation passed. The cloud installer was exercised again successfully with retained dependencies.
- **Tests failed:** no current software failures. Actual device enumeration exits 2 with `[]`; actual recording exits 2 with an actionable device error. These establish a hardware blocker, not successful recording.
- **Hardware tested:** PortAudio queried in the cloud; no microphone exists and no genuine audio was captured or played.
- **Measured results:** zero input devices; failed capture creates no audio file. Details: `artifacts/hardware_status.json`.
- **Files changed:** `requirements.txt`, `.gitignore`, package initializers, `audio/capture.py`, `audio/reference_audio.py`, `tools/microphone.py`, `scripts/cloud_install.sh`, `scripts/cloud_run.sh`, `tests/test_capture.py`.
- **Remaining limitations:** Windows/driver/device access and audible playback require the actual laptop.
- **Next action:** on Windows, install using README, then run `python -m tools.microphone devices` and `python -m tools.microphone record --device INDEX --seconds 4 --output recordings/anchal_middle_01.wav` using the installed environment and a fresh filename.

## Milestone 1 — Real pitch detection

- **Implemented:** DC removal, RMS gate, exact FFT-accelerated YIN difference/CMNDF, trough selection, interpolation, voiced quality, independent continuous-cents smoothing, PCM WAV analysis and per-frame CSV logging.
- **Tests passed:** 16 tests in `tests.test_pitch_detector` plus 6 end-to-end synthetic audio tests in `tests.test_pipeline`. The optimized difference matches a simple direct calculation, including lag-dependent energy.
- **Tests failed:** none currently. The pipeline originally exposed a calibration ranking failure documented under Milestone 2; its original fixture remains in the passing suite.
- **Hardware tested:** none; generated test signals and WAV round trips only. Anchal's WAV is unavailable.
- **Measured results:** 44 clean synthetic cases at 44.1/48 kHz and 2,048/4,096 samples; maximum absolute error **0.432464 cents**, median **0.018583 cents**. FFT/direct maximum difference **3.64e-12**. A warmed 1,000-call 4,096-sample detector-only benchmark measured **0.223 ms median / 0.383 ms p95** on this cloud CPU. These figures are neither human accuracy nor response latency.
- **Files changed:** `audio/pitch_detector.py`, `tools/analyze_wav.py`, `tools/validate.py`, `tests/test_pitch_detector.py`, `tests/test_pipeline.py`.
- **Remaining limitations:** real voices, octave ambiguity, noise conditions, and microphone-to-visible-response latency need recorded/physical evaluation.
- **Next action:** analyze Anchal's genuine low/middle/high PCM WAVs; inspect raw frequency stability and compare independently labelled regions as described in `VALIDATION.md`.

## Milestone 2 — Find My Sa

- **Implemented:** three-stage measured calibration, edge trimming, robust median/stability/coverage rejection, conservative range margins, full exercise-range fitting on a musical pitch grid, transparent candidate selection, confirmation and retry with session state.
- **Tests passed:** 26 tests in `tests.test_calibration`; the 6 pipeline tests additionally exercise synthesized audio through the real YIN estimator and calibration.
- **Tests failed:** zero currently. A near-tied midpoint ranking originally selected C#3 and D4 for octave-related measured ranges, giving ratio 2.118926 instead of 2. The cause was tiny interpolation differences at a candidate-ranking boundary. A configurable five-cent near-tie band now chooses the lower safe candidate and discloses ambiguity. Original tied audio, ±1-cent perturbation, outside-band and configurable-band regressions pass. Evidence: `artifacts/debug_history.json`.
- **Hardware tested:** none; no synthetic result is represented as Anchal's range or tonic.
- **Measured results:** the labelled synthetic input 130.81/174.61/261.63 Hz yields measured medians approximately 130.81050/174.61054/261.63180 Hz and a C#3 recommendation; octave-related input gives C#4, ratio exactly 2. These are test data only.
- **Files changed:** `calibration/find_my_sa.py`, `tests/test_calibration.py`, calibration wiring in `ui/main_window.py`.
- **Remaining limitations:** three short vowels are only approximate comfortable-range evidence; genuine repeatability and singability remain unverified.
- **Next action:** Anchal completes two genuine calibrations under comparable conditions, reviews/listens to the recommendation, and confirms a comfortable tonic. Retain failures and uncertainty.

## Milestone 3 — Alankar target engine

- **Implemented:** three editable JSON Alankars, per-note relative intervals/octaves/beats/indexes, dynamic confirmed-Sa frequencies, BPM-based timing, a shared timeline for graph/audio/comparison/scoring, and sine reference synthesis.
- **Tests passed:** target/transposition/boundary assertions in the 6 comparator tests, reference synthesis assertions in the 20 capture/reference tests, and dynamic-Sa checks in the 6 pipeline and 13 GUI tests. These counts overlap the module totals, not additional tests.
- **Tests failed:** none currently.
- **Hardware tested:** none; generated waveform contents and duration were verified, not audible output.
- **Measured results:** changing confirmed Sa by an octave doubles target and observed synthetic frequencies consistently; scoring the transposed performance against the old tonic fails appropriately. Graph points and reference note frequencies share the timeline.
- **Files changed:** `data/alankars.json`, `practice/alankars.py`, `audio/reference_audio.py`, applicable comparator/pipeline/UI tests.
- **Remaining limitations:** exercise definitions and 12-TET approximation need teacher review; actual speaker/headphone output is untested.
- **Next action:** listen to each reference on the evaluation laptop and verify comfortable levels, notes, timing, and transposition after a second valid calibration.

## Milestone 4 — Live pitch comparison

- **Implemented:** bounded audio-to-worker and worker-to-GUI handoffs, ADC-to-monotonic window-center timestamps, count-in, independent raw observations, swara/error feedback, transition grace, gap/silence trace breaks, octave visibility, acquisition-loss counters, and stale-input feedback.
- **Tests passed:** 6 tests in `tests.test_comparator`, capture discontinuity/overflow/disconnect tests, and GUI tests for actual YIN handoff, wrong octaves, unvoiced data, and timestamped practice. No expected pitch is passed to YIN.
- **Tests failed:** none currently.
- **Hardware tested:** simulated devices and generated/explicitly injected test inputs only.
- **Measured results:** overflowing bounded queues increments loss counters and resets the next analysis window; raw wrong-octave data remains incorrect even when graph smoothing rejects the first isolated jump. Missing observations cannot populate target values.
- **Files changed:** `audio/capture.py`, `practice/pitch_comparator.py`, `ui/main_window.py`, `ui/pitch_graph.py`, related tests.
- **Remaining limitations:** fixed guided tempo does not implement flexible realignment. Physical microphone/GUI behavior remains untested.
- **Next action:** Anchal sings known notes, intentionally substitutes a swara, then stops singing; verify corresponding independent trace, mismatch, and missing-voice behavior.

## Milestone 5 — Accuracy meter

- **Implemented:** bounded transition grace, 20-ms-or-shorter eligible cells, raw reliable pitch comparison, missing/unvoiced denominator, equal-note aggregate weighting, note-wise durations/counts/errors/attempts, uncertainty/improvement text and auditable report models.
- **Tests passed:** 12 tests in `tests.test_scoring`; end-to-end audio and GUI tests additionally exercise the same production scorer.
- **Tests failed:** none currently. An early regression showed median pitch error could hide minority timing drift; the warning now checks mismatched-cell coverage, while retaining the original timing test and unchanged scoring denominator.
- **Hardware tested:** none; independently generated audio or explicit simulated tracks only.
- **Measured results:** end-to-end synthetic audio scores: correct **100%**, all wrong **0%**, one of five notes missing **80%**, 40 cents sharp **0%**, silent **0%**. Simulated temporal tests yield **50%** for half-silent notes and **75%** for 300-ms late transitions. These validate formula behavior; they are not human performance measurements.
- **Files changed:** `practice/scoring.py`, `tests/test_scoring.py`, scoring/report wiring in `ui/main_window.py`.
- **Remaining limitations:** ±30 cents is an experimental pitch-match tolerance. Detector error and singing error cannot be separated without independent ground truth.
- **Next action:** run paired correct/wrong/sharp/flat/missing/silent real performances, retaining every attempt and raw observations; compare affected-note scores without adjusting thresholds to improve results.

## Milestone 6 — Complete minimal GUI

- **Implemented:** Find My Sa, selection/reference, live graph/results; microphone/window controls, three-second stages, confirm/retry, complete-reference gate, count-in/current note, raw cents, live note progress, final report, Practice Again/Finish, cleanup, logging and JSON/CSV exports.
- **Tests passed:** 13 offscreen GUI integration tests in `tests.test_ui`; separate `main.py --smoke-test` starts all three views, runs the Qt event loop, and exits successfully. No microphone was substituted in that startup check.
- **Tests failed:** zero currently. Final review reproduced a previous attempt's mismatch warning persisting into the next attempt. A one-line session-start reset fixes it; a new regression failed before the fix and passes after it. Original failure output is saved in `artifacts/timing_warning_before.log`.
- **Hardware tested:** offscreen Qt only; mocked input/output in GUI integration tests. The actual startup displays an honest no-microphone state.
- **Measured results:** software integration covers staged calibration → confirmation → reference completion → timestamped practice → score and JSON/CSV export. Wrong raw pitch stays independent of graph smoothing; silent/incomplete attempts score zero. No visible-delay figure was measured.
- **Files changed:** `main.py`, `ui/main_window.py`, `ui/pitch_graph.py`, `tests/test_ui.py`.
- **Remaining limitations:** Windows execution, audible references, real voice interaction, native device recovery, and visible frame rate/response require the target laptop.
- **Next action:** execute the full actual user journey from `README.md` on that laptop; retain logs, reports and visual-latency observations.

## Milestone 7 — Evaluation and reliability

- **Implemented:** regression runner with per-test outcome JSON, repeatable labelled synthetic benchmark/pipeline/WAV fixtures, Windows setup and microphone guidance, detailed algorithms/thresholds, real-singing/latency/disconnection protocol, and known limitations.
- **Tests passed:** final full suite **99/99**, no skips or failures; Python dependency consistency, imports, compilation, desktop startup, synthetic WAV analysis, and installer refresh pass. `artifacts/detector_metrics.json`, `test_results.json`, `test_run.log`, `synthetic_practice.wav`, and `synthetic_practice_pitch.csv` retain current software evidence.
- **Tests failed:** no unresolved software regressions. Actual microphone enumeration/recording are blocked by absent hardware. Genuine recorded-voice regression, live Anchal testing, and Windows reliability tests are **unrun**.
- **Hardware tested:** native backend query in the cloud only; no real input or output device.
- **Measured results:** see prior milestone measurements and current artifacts. There is no measured real-vocal accuracy, stable vocal-detection delay, or visible-response latency.
- **Files changed:** `tools/run_tests.py`, `tools/validate.py`, `README.md`, `docs/ALGORITHMS.md`, `docs/VALIDATION.md`, this ledger and generated ignored artifacts.
- **Remaining limitations:** the final demonstration is not accepted until the genuine-voice journey is repeatable on the intended laptop. No source was pushed and no fresh-task restoration/publication was tested.
- **Next action:** follow `VALIDATION.md` on the evaluation laptop. The environment draft has `install_script` and `start_skill` saved; review/save those changes in environment settings, then publish the prepared environment separately. Publishing does not validate audio hardware.
