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
