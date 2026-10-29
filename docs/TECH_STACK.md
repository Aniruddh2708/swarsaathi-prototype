# Technology Stack

SwarSaathi provides guided singing practice through microphone pitch analysis,
singer-confirmed Sa selection, timed Alankaar exercises, and per-note feedback.
Audio processing and result storage run locally.

## Technologies

| Technology | Responsibility |
| --- | --- |
| Swift | Application logic, audio processing, musical calculations, and tests. |
| SwiftUI | Recording and practice screens, navigation, live pitch visualization, and result cards. `Canvas` and `TimelineView` render the pitch guide. |
| AVFoundation | `AVAudioEngine` captures microphone samples; `AVAudioSession` manages audio routes and interruptions; `AVAudioApplication` requests microphone access; `AVAudioPlayer` plays reference audio. |
| Accelerate / vDSP | Vector sum-of-squares and dot-product operations used by the YIN pitch detector. |
| Foundation | Timers, processing-thread support, file handling, dates, and JSON encoding. |
| Dispatch | Worker coordination, synchronization, main-thread delivery, and processing-time measurement. |
| QuartzCore | A monotonic clock for the count-in and scheduled exercise progression. |
| UIKit | Settings access, note-change haptics, and display-awake behaviour during practice. |
| XCTest | Automated checks for audio processing, calibration, timing, and scoring. |
| Xcode and Swift Package Manager | Application builds and shared-core development. |
| Git, GitHub, and GitHub Actions | Version control, source hosting, and automated build checks. |

The project uses Swift 5 language mode and a Swift Package tools declaration of
5.9. It has no external Swift package dependencies.

## Architecture

The application follows a Model–View–ViewModel structure. SwiftUI views present
controls and results, view models coordinate recording and practice state, and
shared models perform signal-processing and musical calculations.

The microphone callback hands samples to a bounded buffer. A dedicated worker
analyses overlapping windows and delivers timestamped pitch frames. Each
recording has an isolated processing run so earlier audio cannot enter a new
attempt. Missing audio remains missing rather than being reconstructed from
the expected exercise.

## Processing Flow

1. **Capture and prepare audio.** Receive microphone samples at the input's
   actual sample rate. Centre each analysis window and measure RMS signal level
   before pitch estimation.
2. **Estimate pitch.** YIN compares the waveform with delayed copies,
   normalizes their differences, selects a repetition period, and refines it by
   interpolation. Frequency is the sample rate divided by the estimated period.
3. **Confirm Sa.** Validate recorded voice samples, present a reference-pitch
   recommendation, and require the singer's confirmation. Exercise availability
   is checked separately at the confirmed Sa.
4. **Schedule targets.** Generate each swar from the confirmed Sa and the
   configured tuning ratios. A monotonic timeline advances one note per beat
   according to the selected BPM, independently of singing performance.
5. **Display and compare.** Draw scheduled targets alongside the microphone's
   measured pitch. Display smoothing is separate from the raw accepted pitch
   observations used for calibration and scoring.
6. **Score and report.** Evaluate all scheduled notes and save the observations,
   target timeline, thresholds, results, and processing diagnostics as JSON.

## Pitch Comparison and Playback

Pitch difference is calculated as:

```text
cents = 1200 × log2(observed frequency / target frequency)
```

Every scheduled note is divided into scoring cells no longer than 40 ms. The
strict match uses a ±50-cent tolerance. The practice match additionally accepts
adjacent-note pitches and the glide between them within 100 ms on either side
of internal note changes. Both retain the full expected denominator; missing
observations and wrong notes lower the score. Overall results weight each note
equally. These percentages describe pitch matching at the guided tempo.

Reference playback generates sine tones from the same target definitions and
timing used by the graph and scorer. Short fades reduce clicks at note edges.
Playback stops before microphone recording begins.

Reports contain estimated pitch observations rather than recorded microphone
waveforms. Analysis requires no network connection after installation.
