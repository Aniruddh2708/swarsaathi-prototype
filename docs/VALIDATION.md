# Validation and evaluation-laptop protocol

## Evidence and pending checkpoints

Synthetic regression checks exercise YIN mathematics, pitch/silence rejection, calibration, target generation, independent pitch comparison, scoring, and audio lifecycle behavior. Unit tests using mocked devices verify software behavior; they do not prove that a real microphone or Windows host API works.

The current cloud machine loads the native PortAudio backend but enumerates **no input devices** (`[]`, diagnostic exit status 2). No genuine Anchal voice recording, live input, audible reference, Windows execution, physical disconnect, or visual-delay measurement has been performed here. Every real-hardware acceptance checkpoint remains pending. A headless GUI check, if reported, is software evidence only.

The detector measurement in `artifacts/detector_metrics.json` covered 44 generated clean-tone cases: maximum absolute error **0.433 cents** and median **0.0186 cents**. The refreshed warmed 1,000-call detector-only benchmark on this cloud CPU measured **0.223 ms median / 0.383 ms p95**, using 4,096 samples at 44,100 Hz. FFT/direct-reference maximum absolute difference was approximately `3.64e-12`. These are synthetic and CPU-computation results, not real-vocal accuracy or microphone-to-graph delay. Preserve the current artifact and test-run report when reproducing measurements; performance varies by machine.

Run the current suite from the repository root:

```powershell
python -m tools.run_tests --output artifacts/test_results.json
```

On the managed cloud instance:

```sh
QT_QPA_PLATFORM=offscreen sh scripts/cloud_run.sh -m tools.run_tests --output artifacts/test_results.json
```

Read the runner's executed, failed, errored, and skipped counts plus process exit status. See [MILESTONES.md](MILESTONES.md) for the final run's exact results. A zero-test run, skipped hardware test, or generated signal is not a real singing acceptance pass.

## Prepare the actual evaluation setup

Use the laptop, Windows version, microphone, headphones, and host API intended for the demonstration. Install with Python 3.11/3.12 as described in [README.md](../README.md). Record Python/package versions, device names/index/host API, selected sample rate, analysis window, room conditions, microphone distance/gain, confirmed Sa, Alankar, and BPM. Keep the same configuration between paired trials. Ask Anchal to sing comfortably and stop any strained exercise.

1. Enable Windows microphone permissions and desktop-app access. Close competing input applications.
2. Run `python -m tools.microphone devices` and retain its output. Choose a genuine input index.
3. Record a four-second vowel with the exact device and listen to it. Verify the recording is Anchal's voice, sufficiently audible, and free of clipping or reference leakage.
4. Confirm reference output is audible through headphones, at a comfortable level, and stops before evaluated microphone capture.

For example, replace device `1` with the enumerated index and use new filenames for each attempt:

```powershell
python -m tools.microphone record --device 1 --seconds 4 --output recordings/anchal_low_run1.wav
python -m tools.microphone record --device 1 --seconds 4 --output recordings/anchal_middle_run1.wav
python -m tools.microphone record --device 1 --seconds 4 --output recordings/anchal_high_run1.wav
python -m tools.analyze_wav recordings/anchal_middle_run1.wav --output artifacts/anchal_middle_run1_pitch.csv
```

Repeat all three recordings as `run2` under comparable comfortable singing conditions. These standalone WAVs provide replayable evidence; they do not replace the GUI's actual measured calibration or establish a true personal Sa.

## Anchal's required user journey

For each trial, launch `python main.py` and complete the actual guided low/middle/high calibration. Retain sample median Hz, reliable voiced duration/coverage, stability/spread, accepted or rejected status, suggested Sa/frequency, safe range, candidate explanation, and the confirmed Sa. Repeat the complete calibration twice without tuning thresholds between runs.

Compare both runs' measurements and recommended tonic. Different comfortable singing can legitimately produce different recommendations. Investigate substantial differences using the WAVs and pitch CSV: low level, unstable singing, noise, octave errors, missing frames, or an unsuitable measured range. Report uncertainty rather than forcing both runs to agree. If either run is inconclusive, retry and retain the rejected attempt's reason.

After confirmation, select an Alankar, review expected notes and BPM, listen to the reference, start practice, follow the count-in, and sing one repetition. Verify that playback, graph, and target frequencies all reflect that confirmed tonic. Capture the final percentage, note-wise report, actual pitch trace, and timing/coverage limitations. Repeat after a new valid confirmed Sa and confirm targets transpose consistently; do not manually replace calibration with a fixed demonstration tonic.

Use one fixed Alankar/BPM/Sa for the following paired performance trials. Repeat each at least twice; preserve every attempt, including poor results.

| Trial | What Anchal does | What to inspect |
| --- | --- | --- |
| Correct notes | Follow the known sequence steadily | Independent observed trace, raw cents error, coverage, and the resulting score; no preassigned target score. |
| Wrong note | Deliberately substitute one clearly different swara | Wrong Swara feedback, visible mismatch, lower affected-note result. |
| Sharp | Sustain an intended note perceptibly above its target | Positive cents error and reduced pitch match if beyond tolerance. |
| Flat | Sustain an intended note perceptibly below target | Negative cents error and reduced pitch match if beyond tolerance. |
| Missing note | Remain silent for one expected note | Trace break, missing duration, reduced note/overall score. |
| Entirely silent | Do not sing throughout an attempt | No reliable voice and no inflated score. |
| Timing drift | Sing an identifiable note late beyond grace | Fixed-tempo mismatch or alignment warning; no claim of flexible realignment. |

An intention to sing sharp/flat is not labelled F0 ground truth. Use independent annotation or analysis before attributing a live mismatch specifically to the singer or detector. Do not widen tolerance, extend grace, omit failed attempts, or substitute generated observations to improve the result.

## Real-voice detector ground truth

Retain genuine unprocessed PCM WAVs from Anchal's steady vowels and exercise attempts. Independently label voiced/unvoiced regions and F0 on selected stable sections using a qualified annotator and waveform/period inspection or a separately validated reference method. Record that method, annotation interval, uncertainty, and any ambiguous regions. The target Alankar and the prototype's own estimates cannot serve as the singer's true observed F0.

Compare like-for-like timestamped windows. Report the number and duration of labelled voiced/unvoiced windows, rejected/missing voiced windows, false-voiced windows, median/p95 absolute cents error on aligned valid voiced windows, and octave/gross errors using a declared threshold. Include coverage and failure rates alongside error on accepted frames so rejection cannot hide difficulty. An unsupported “95% accuracy” claim is prohibited. Without independent labels, report plausibility/coverage and illustrative traces only.

## Latency and reliability

Detector processing, buffer/queue delay, stable-estimate delay, and visible response are different measurements. Retain available processing median/p95 and capture counters. Do not equate the warmed synthetic detector benchmark with total latency.

For a practical visible-delay check, use a high-frame-rate external camera that records both the screen and the actual microphone sound. Perform at least 20 clear voice onsets and separated pitch changes at a comfortable level. In the recording, measure time from audible onset/change to the first corresponding reliable plotted response. Record camera frame rate and its timing uncertainty, window size, sound path, and display settings. Report median/p95 and trials with no response. This manual protocol estimates visible response; it does not establish a sub-25 ms guarantee or laboratory latency.

Check the following on real hardware and retain outcomes:

- Run repeated calibration/practice/start/stop/Practice Again/Finish cycles; close during capture and playback. Confirm streams release and the microphone can reopen.
- Disconnect the input during an attempt. The application should expose the failure or loss of input and remain recoverable; no stale trace or success claim should replace the missing voice. Reconnect, re-enumerate/reselect, and complete a fresh attempt. Some host APIs deliver silence rather than an immediate disconnect error; record actual behavior.
- Close or switch output devices during reference playback and inspect the surfaced error. Confirm unrelated input/output streams are not stopped accidentally.
- Observe responsiveness while plotting. Inspect dropped-sample, overrun, timestamp-discontinuity, worker-error, queue-delay, and processing metrics under ordinary laptop load. Save interrupted attempts separately.

## Evidence bundle and failure handling

Retain actual voice WAVs, per-frame pitch CSV, exported session JSON/CSV, application error logs, automated test report, screenshots/video where consent permits, and a short trial ledger. The GUI automatically saves `artifacts/calibration_<UTC timestamp>_<id>/calibration.json` and `artifacts/practice_<UTC timestamp>_<id>/{report.json,observations.csv}`; the log is `logs/swarsaathi.log`. Calibration export occurs before confirmation (`confirmed:false`); the subsequent practice report records the tonic actually confirmed and used. GUI capture does not save raw WAV, so use the separate recording utility for replayable real-voice fixtures.

Include configuration and exact reproduction commands; label synthetic artifacts explicitly and keep original failed evidence. Record pass/fail/pending separately for each hardware checkpoint. The practice report's detector processing and frame-center-to-GUI consumption timing are diagnostic software measurements, not measured acoustic or visible response latency.

For a failure: reproduce it, identify capture/detector/calibration/timing/scoring/UI as precisely as evidence permits, save diagnostics, change one justified parameter or subsystem, add a regression where feasible, rerun the affected trial and previous software checks, and compare measurements. Unresolved hardware or annotation limits remain explicit in the final report. The demonstration is accepted only after the complete genuine-voice journey is repeatable on the intended laptop.
