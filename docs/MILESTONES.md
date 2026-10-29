# Feasibility milestones — October 27, 2026

The target demonstration is October 29. The original Swift app architecture and appearance are retained, with focused fixes and executable core validation. The Apple core-test and simulator-build gates passed in [CI](https://github.com/Aniruddh2708/swarsaathi-prototype/actions/runs/40476104346). Real-device gates remain open.

| Milestone | Actual files changed or added | Validation and result | Remaining risk |
| --- | --- | --- | --- |
| 1. Audit and YIN baseline | `docs/AUDIT.md`; isolated baseline outside the app | Inspected all eleven original Swift files. Executed six baseline tests: five passed; one reproduced the stale pitch during silence. Clean known-frequency tests reached max 0.438624-cent error. | Original Apple path/device behavior unrun. |
| 2. Pitch evidence and safe processing | `PitchDetector.swift`, `AudioPipeline.swift`, `AudioProcessingRun.swift`, `PitchEngine.swift`; detector/pipeline/processing test files | Expanded deterministic detector suite passed 13 tests, bounded mailbox seven and processing worker four. Worker regressions exercise actual shared preprocessing, capture-center timestamps, discontinuities and generation separation. | AVAudioEngine adapter requires real hardware; scalar compute timings are not end-to-end latency. |
| 3. Measured Sa and confirmation | `Calibration.swift`, `ScaleViewModel.swift`, `ScaleDiscoveryView.swift`, `CalibrationTests.swift` | Pure regressions exercise coverage, instability, range fit, similar low/middle samples, invalid statistics and reference/confirmation lifecycle. | Three samples approximate a span; real singer comfort and reference output unvalidated here. |
| 4. Fixed progression, reference and full scoring | `MusicTheory.swift`, `PracticeTimeline.swift`, `ReferenceAudio.swift`, `PracticeViewModel.swift`, `PracticeView.swift`, `PitchGraphView.swift`, `SummaryView.swift`, `PracticeTimelineTests.swift` | Reproduced the draft silent-edge scoring bug, removed its excluded edges and retained a regression. Full timeline and missing/wrong-note cases are executed in the core suite. Pitch thresholds were not relaxed. | Live timing, UX and playback/capture switching need device tests. |
| 5. Native packaging and repeatable checks | `Package.swift`, `SwarSaathi.xcodeproj`, `App/Info.plist`, `.github/workflows/swift.yml`, README/validation docs | Portable Swift package executes shared core. Project/plist/scheme structure and Swift syntax checks passed, followed by actual successful macOS core tests and Xcode simulator compilation for `a585f7b`. | Signed iPad/iPhone deployment, real singing and device latency still pending. |

The reviewed complete release run passed **57 XCTest tests with zero failures** in 0.846 seconds. It includes two synthetic signal-to-worker-to-score integration tests. Commands, exact measurements and additional reproduced calibration/summary failures are in [VALIDATION.md](VALIDATION.md). Preserve failed-test evidence, its root cause, the minimal correction, the regression rerun and earlier passing tests for each future failure. Do not present an unexecuted Apple or hardware stage as passed.

The previous Python/browser source is replaced in the repository at the user's request. It remains recoverable in prior Git history; it is not mixed into the new Swift app.

## Usability follow-up after device feedback

Changed calibration capture policy/view model and controls, confirmation state,
practice restart/reference controls, graph, scorer/summary, and regression tests.
Calibration now keeps collecting inconclusive input until an eight-second limit;
reference playback is optional; the entire target sequence is visible upfront.
Practice match adds a disclosed 100 ms transition allowance alongside unchanged
strict timed match and full missing-voice denominator.

Reproduced the early calibration rejection and mandatory playback confirmation
in failing regressions, then applied the minimal policy changes. Reproduced
strict-only treatment of small transitions before adding the separate metric.
`sh scripts/test.sh` passed **67 tests, zero failures** in 0.957 s; see
[evidence](evidence/usability-release.log). Swift source syntax and Xcode project
source membership checks passed. A local audit replayer uses the production
scorer without changing observations. The supplied report is not published.
Actual button tapping, graph readability and patient capture still require a
fresh on-device trial; an Apple CI build does not substitute for those checks.


## Interface clarity and independent measurement audit — October 28

Changed `ScaleDiscoveryView.swift`, `ScaleViewModel.swift`, `PracticeView.swift`,
`PracticeViewModel.swift`, `PitchGraphView.swift`, and `SummaryView.swift`. Removed the post-analysis
chart and duplicate finished-state panels; retained the live guide, one overall
pitch-match percentage and each-note boxes. Percentages use one decimal. Details
and report sharing are optional. Calibration errors give a short retry instruction;
full rejection reasons and raw observations remain in the saved diagnostic report.
A complete calibration retry clears confirmation and all three samples. Technical
formulas and implementation details are documented in `TECHNICAL_WALKTHROUGH.md`.

Added `CalibrationPipelineTests.swift` (3 tests), `ScoreAuditTests.swift` (5 tests),
and `docs/evidence/clarity-core.log`. Command:
`sh scripts/test.sh --scratch-path /tmp/core-validation-build`.
All **75 tests passed, zero failures, 4.613 seconds**. No failing regression or
algorithm change was required in this milestone. All Swift sources passed syntax
parsing; Apple compilation is checked separately in CI after pushing.

24 synthetic harmonic/noisy/vibrato vowels passed through the real shared worker
and YIN: maximum sample-median error **0.671688 cents**, median **0.201727 cents**,
minimum coverage **99.282%**. All **8/8** measured tonic recommendations matched
recommendations from known input pitches and fitted the exercise. Independent
scoring arithmetic verified 70 strict + 4 transition matches out of 125 expected
cells: **56% strict, 59.2% practice**. Saved JSON replay reproduced results exactly.

These tests do not establish near-perfect real-singer accuracy, device latency,
or a uniquely correct personal Sa. On-device layout, retry controls, microphone
routes and independently annotated real singing remain the next validation stage.


## Exercise-independent voice calibration — October 29

Reproduced three failures before changing production code. With the same
130/195/310 Hz samples, the five-note and octave exercises returned different
Sa values (174.614116 vs 138.591315 Hz). A usable 220/240/260 Hz voice range was
rejected only because Ga would not fit. An explicitly chosen Sa at 280 Hz was
rejected despite being inside the recorded boundaries because its Ga exceeded
them. See [the failing regressions](evidence/exercise-independence-before.log).
Root cause: exercise ratios constrained calibration, candidate ranking and
confirmation/adjustment validation.

Changed `Calibration.swift`, `MusicTheory.swift`, `ScaleViewModel.swift`,
`ScaleDiscoveryView.swift`, `PracticeViewModel.swift` and `PracticeView.swift`.
`recommend(samples:)` now has no exercise/tuning input or reference to Alankaar.
A disclosed initial-reference heuristic balances recorded range center and
comfortable middle in log frequency, with singer confirmation. It never assigns
a unique personal scale. The reference itself must fit the recorded boundaries;
exercise ratios do not constrain it. Calibration audit schema 2 records the new
method and its two reference values rather than obsolete exercise-span fields.

`Alankaar.fits` separately checks every selected target at the fixed confirmed
Sa, including notes below Sa. Exercises remain visible; ones outside the range
show a short explanation and cannot start/play until the user chooses another
or explicitly adjusts and reconfirms Sa. Selecting an exercise never mutates
calibration. Audio detection, recording validity gates, timing and scoring
thresholds are unchanged.

Updated `CalibrationTests.swift` and `CalibrationPipelineTests.swift`; added
`ExerciseRangeTests.swift`. Earlier exercise-specific expectations were moved
or updated to reflect the corrected separation. Targeted command:
`sh scripts/test.sh --filter 'CalibrationTests|CalibrationPipelineTests|ExerciseRangeTests'`
passed **29 tests, zero failures**. Full `sh scripts/test.sh` passed **85 tests,
zero failures in 4.010 s**; [release evidence](evidence/exercise-independence-release.log).
All Swift files passed syntax parsing. The shared synthetic YIN/voice calibration
still matched all eight known-input reference proposals; its sample median
errors are unchanged. No new hardware or singer-comfort validation was executed.

README, the source audit, beginner guide, technical guide and shareable stack
now describe the independent stages. The equal log weighting and semitone grid
are prototype preferences requiring singer/teacher review, not a validated
biological formula. Real-device UI/range-switching checks remain necessary.
