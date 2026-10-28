**SwarSaathi — shareable technology-stack description**

SwarSaathi is a native iPhone/iPad feasibility prototype for guided singing-pitch practice. It captures a single singer's voice, estimates fundamental frequency with the YIN algorithm, recommends an exercise-compatible Sa from three comfortable vowel samples, and compares live singing with a timed Alankaar. Results show overall and per-note pitch matching. Audio analysis runs on the device and does not require internet after installation.

| Layer | Technology | Role in this application |
| --- | --- | --- |
| Programming language | Swift | Audio-processing logic, musical calculations, application state and tests. |
| User interface | SwiftUI | Recording screens, controls, navigation, live pitch guide and result cards. `Canvas` and `TimelineView` draw the live guide. |
| Microphone and playback | AVFoundation | `AVAudioEngine` receives microphone samples; `AVAudioSession` manages the audio route and interruptions; `AVAudioApplication` requests permission on iOS 17+; `AVAudioPlayer` plays generated reference tones. |
| Numerical processing | Accelerate / vDSP | Efficient sum-of-squares and dot-product operations for YIN on Apple platforms. |
| Application services | Foundation, Dispatch | Timers, local files, JSON serialization, a processing worker, synchronization and bounded audio handoff. |
| Timing | QuartzCore | `CACurrentMediaTime()` provides a monotonic clock for practice progression. |
| Device integration | UIKit | Settings access, note-change haptics and keeping the display awake during practice. |
| Development | Xcode, Swift Package Manager | Xcode builds/signs the iOS app; Swift Package Manager builds and tests the shared calculation code. |
| Testing and source management | XCTest, Git, GitHub Actions | Regression tests, version history, macOS tests and iOS Simulator compilation. GitHub hosts source and build automation. |
| Stored results | Local JSON files | Timestamped pitch observations, target definitions, thresholds, results and diagnostics. Reports can be shared explicitly. |

The architecture follows **Model–View–ViewModel (MVVM)**: SwiftUI views show information; view models coordinate recording and practice; shared models perform calculations. The implementation has no external Swift package dependencies. It targets iOS/iPadOS 17 or newer, using Swift 5 language mode and a Swift Package tools declaration of 5.9.

| Calculation or design | What it does |
| --- | --- |
| DC-offset removal and RMS | Centers each audio window and checks whether its signal level is sufficient for analysis. |
| YIN fundamental-frequency estimation | Compares the waveform against delayed copies, normalizes the differences, selects a repetition period and refines it by interpolation. Frequency equals sample rate divided by period. |
| Robust calibration statistics | Uses the median pitch, reliable-voice coverage and pitch spread to assess each low/middle/high sample. |
| Range-constrained tonic recommendation | Fits exercise pitches within the measured range, ranks candidate Sa values near the comfortable middle, and requires singer confirmation. |
| Musical frequency ratios | Generates Sa/Re/Ga and other targets from the confirmed Sa using illustrative Shuddha ratios. |
| Fixed target timeline | Advances one note per beat using elapsed monotonic time, regardless of singing mistakes. |
| Cents-based pitch comparison | Measures musical distance with `1200 × log2(observed frequency / target frequency)`. |
| Full-exercise scoring | Scores every expected time cell, including missed notes. A separate practice metric allows brief adjacent-note transitions; the strict metric remains available. |
| Bounded processing queues | Keep audio work off the microphone callback, limit backlog and isolate each recording from earlier recordings. |

YIN is an **algorithm**, Swift is a **language**, and AVFoundation/SwiftUI are **frameworks**. Xcode is the **development environment**. This implementation uses deterministic digital signal processing; it does not use a trained neural network, a cloud inference service, a Python backend or a remote database.

**Verification:** application revision `38b52e1` has an executed 75-test portable regression suite, plus successful Apple core tests and an iOS Simulator build. New calibration tests processed 24 synthetic harmonic-rich, noisy, vibrato signals through the shared worker/YIN path; maximum error in the resulting sample medians was 0.672 cents. Independent fixtures verified score arithmetic and JSON replay. These results establish behavior on the specified tests; they do not establish near-perfect accuracy on real singers. Real-device singing, route behavior and end-to-end latency need separate validation.

**Scope:** the prototype recommends a starting Sa for an exercise and measures pitch matching. Three vowels do not identify a unique permanent personal Sa, an entire vocal range or a raga. The score is not an overall assessment of musicianship. Exported JSON contains estimated pitch observations, not the original microphone waveform. Reference WAV audio is generated separately and stops before microphone recording.

Supporting material: [beginner/evaluator guide](EVALUATOR_GUIDE.md), [complete implementation and formulas](TECHNICAL_WALKTHROUGH.md), [test evidence](evidence/clarity-core.log), and [successful Apple build for the application revision](https://github.com/Aniruddh2708/swarsaathi-prototype/actions/runs/40626528026).
