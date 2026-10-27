# SwarSaathi prototype

A Python desktop proof of concept for **Find My Sa → guided Alankar practice → pitch-match feedback**. The selected repository was initially empty; this implementation follows the supplied prototype specification.

The detector measures microphone audio independently of the expected melody. Sa is a comfortable tonic recommendation from three short voice samples, not an objectively fixed personal scale. The initial pitch model is a documented 12-tone equal-tempered (12-TET) approximation; it is not a validated Hindustani assessment standard.

**Validation status:** software regression checks and synthetic detector measurements are available. This cloud machine has no microphone input devices. Anchal's real singing, Windows audio, speaker playback, microphone disconnection, and visible graph delay must still be checked on the evaluation laptop. See [the validation protocol](docs/VALIDATION.md) and [milestone evidence](docs/MILESTONES.md).

## Install on Windows

Use 64-bit Python **3.11 or 3.12** and run these commands in the repository directory. This example uses PowerShell and invokes the virtual environment directly, so activation policy does not need to change.

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m pip check
.\.venv\Scripts\python.exe main.py
```

Substitute `py -3.11` when using Python 3.11. If activation is permitted, run `.\.venv\Scripts\Activate.ps1`; the launch command is then `python main.py`. The remaining examples use that activated environment. Without activation, replace `python` with `.\.venv\Scripts\python.exe`.

The only direct packages are NumPy, sounddevice, PyQt6, and pyqtgraph. pip also installs their required runtime dependencies: CFFI/pycparser for sounddevice and Qt6/PyQt6-sip for PyQt6. No paid API, model download, server, database, or account is required. Official Windows sounddevice wheels supply PortAudio.

On a Linux desktop, install the distribution's PortAudio runtime (`libportaudio2` on Debian/Ubuntu) before installing the Python requirements. A working desktop display and native Qt libraries are also required. The managed Debian cloud environment uses repository wrappers to load its locally extracted, package-verified PortAudio library:

```sh
sh scripts/cloud_install.sh
sh scripts/cloud_run.sh -m tools.microphone devices
QT_QPA_PLATFORM=offscreen sh scripts/cloud_run.sh -m unittest discover -v
QT_QPA_PLATFORM=offscreen sh scripts/cloud_run.sh main.py --smoke-test
```

Offscreen Qt checks exercise software without a desktop. They do not demonstrate actual microphone capture, audible playback, or a visible GUI. This is a desktop application; there is no browser preview.

## Check the microphone first

In Windows **Settings → Privacy & security → Microphone**, enable microphone access and access for desktop apps. Select the intended recording device in Windows sound settings, then enumerate genuine input devices:

```powershell
python -m tools.microphone devices
python -m tools.microphone record --device 1 --seconds 4 --output recordings/anchal_middle_01.wav
python -m tools.analyze_wav recordings/anchal_middle_01.wav --output artifacts/anchal_middle_01_pitch.csv
```

Replace `1` with an input device index returned on this laptop. Indices can change after reconnecting hardware. Omit `--device` to use the system default. Device listings include the host API; if duplicate names appear, try a working Windows host API and confirm it with a recording. Input initially requests 44,100 Hz, mono float32, with a supported-rate fallback including 48,000 Hz. `--sample-rate 48000` requests 48 kHz for the recording utility. Existing WAV recordings are never overwritten; choose a new filename for a retry.

Listen to the actual WAV before trusting an analysis. Use headphones for reference playback, a quiet room, and a comfortable consistent microphone distance. Start with moderate input gain: the signal should be audible without clipping. Do not sing louder or strain to force acceptance. The detector's default RMS gate is 0.008 of full scale; low-level or noisy audio can correctly produce no reliable pitch. See [thresholds and scoring](docs/ALGORITHMS.md).

WAV analysis accepts uncompressed integer PCM WAV, including 16-bit files created by the recorder. It writes one row per analysis window and prints measured summary statistics. Add `--sa <confirmed-frequency-in-Hz>` for relative cents. Use `--expected-hz` **only for a known constant labelled test tone**; it does not establish ground truth for a singer or a changing melody. Use a fresh CSV output path to preserve earlier analysis.

## Demonstration journey

1. Launch `python main.py`, select the actual microphone, and begin **Find My Sa**. Use **Refresh devices** and optional microphone monitoring to check input. Sing a steady, comfortably low “Aa,” then a comfortable middle “Aa,” then a comfortably high “Aa” without forcing the voice. Each **Record** action captures three seconds. Retry an unreliable current stage, or use **Retry calibration** to start all three stages again.
2. Review the measured range, suggested note/frequency, and explanation. Play the reference, then **Confirm Sa** or retry calibration. Three short samples only estimate a conservative comfortable range. An inconclusive result calls for a retry, not reduced safety margins or a fixed substitute tonic.
3. Select an Alankar and BPM (40–120 in the GUI; default 72). The library contains Sa–Re–Ga–Re–Sa; Sa–Re–Ga–Ma–Pa–Ma–Ga–Re–Sa; and Sa–Ga–Re–Ma–Ga–Pa. Play its reference melody completely to enable **Start Practice**. Changing selection or tempo requires replaying the reference.
4. Start practice, follow the three-beat visual count-in and fixed guided tempo, and sing one repetition. Reference output stops before microphone evaluation. Watch expected versus actual pitch, raw cents error, and On Pitch / Slightly High / Slightly Low / Wrong Swara / No Reliable Voice feedback. Boundary grace regions are unscored. The live meter measures progress against the full exercise, including unfinished notes, so it normally rises during a good attempt.
5. Review overall pitch-match percentage, note-wise coverage/correctness, and sections requiring improvement. Use **Practice Again** (listen to the reference again) or **Finish** (release devices). **Stop and report incomplete session** retains an interrupted attempt with remaining voice missing. Results carry timing and detector limitations; the percentage is exercise pitch match, not detector accuracy.

The confirmed Sa remains in memory for the current application session and drives every target and reference frequency. Calibration is required again after a fresh launch. Exercise definitions in `data/alankars.json` are intended for teacher review; audio, graph, comparison, and scoring share these definitions.

## Tests and diagnostic evidence

```powershell
python -m unittest discover -v
python -m tools.run_tests --output artifacts/test_results.json
```

The JSON test runner preserves a failing exit status and records test outcomes for the current run. Tests use generated tones or explicitly labelled simulated observations; they are not recordings of Anchal. Detector benchmark results in `artifacts/detector_metrics.json`, when generated, describe this machine and run only. Read [the validation protocol](docs/VALIDATION.md) before making any accuracy or latency claim.

`python main.py --smoke-test` opens and automatically closes the desktop window for a startup check; it does not validate physical input/output. The application writes `logs/swarsaathi.log` and automatically creates unique directories:

- `artifacts/calibration_<UTC timestamp>_<id>/calibration.json`: measured summaries, raw pitch observations, and recommendation before confirmation. Its `confirmed:false` describes that export stage.
- `artifacts/practice_<UTC timestamp>_<id>/report.json`: confirmed Sa, shared timeline, note report, limitations, acquisition counters, detector processing times, and frame-center age at GUI consumption.
- The same practice directory's `observations.csv`: independent raw F0, quality, voicing, expected F0, cents error, and comparison status.

GUI sessions do not automatically save raw WAV audio. Use the microphone recording utility for replayable voice fixtures. Frame-center age is a software timing measurement, not acoustic response latency. Export errors appear in the application; check that files were actually written.

Keep WAV recordings, per-frame CSV, session reports, test results, and error logs together when investigating a failure. Record the device name/host API, sample rate, window size, BPM, confirmed Sa, exact reproduction steps, and whether the input was real or synthetic. `recordings/`, `logs/`, `artifacts/`, and `.venv/` are ignored local output locations; archive evidence explicitly if it must be retained outside this checkout.

## Troubleshooting

| Symptom | Next check |
| --- | --- |
| No input devices | Confirm microphone connection, Windows permissions, system recording selection, and device enumeration on the actual laptop. Cloud enumeration returning `[]` is not a microphone test pass. |
| Device busy or stream cannot open | Close other microphone applications, re-enumerate inputs, try the correct host API/index, and check the Windows device format. Capture tries supported rate fallbacks. |
| Linux PortAudio unavailable | Install the distribution runtime or use the managed-cloud wrapper. Keep library loading separate from proof that hardware exists. |
| Quiet, clipped, noisy, or octave-unstable pitch | Listen to the saved WAV; adjust distance/gain and room noise, use headphones, retry a steady vowel, and compare 2,048 versus 4,096 samples where available. Do not snap observations to the target. |
| Calibration inconclusive | Check all three usable recordings, distinct low/middle/high ordering, sustained voice coverage, and range fit. Stay comfortable; a range too narrow for these exercises is a valid rejection. |
| Low score despite a plausible swara label | Check raw cents deviation, missing voice, note timing, octave, and coverage. A nearby note identity does not imply pitch is within ±30 cents. |
| Delayed or broken graph | Inspect dropped samples, overruns, worker/queue delays, and processing measurements. Reduce unrelated CPU load; measure visible delay separately. |
| Microphone disconnected | Stop the affected attempt, retain diagnostics, reconnect and refresh/reselect the device, then start a new attempt. Never treat a truncated or interrupted session as a completed hardware validation. |

For supported thresholds and formulas, see [ALGORITHMS.md](docs/ALGORITHMS.md). For the required real singing and reliability checks, see [VALIDATION.md](docs/VALIDATION.md).
