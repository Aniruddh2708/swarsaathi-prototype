# SwarSaathi

SwarSaathi supports guided singing practice through microphone-based pitch
detection, a singer-confirmed Sa, and timed Alankaar exercises. It displays live
pitch feedback and reports overall and per-note pitch matching.

Audio processing and report storage run locally. An installed application does
not require an internet connection for practice.

## Features

- Record comfortable low, middle, and high notes and confirm a suggested Sa.
- Select **Sa Re Ga Re Sa** or **Basic Ascent & Descent**.
- Set a fixed tempo between 40 and 120 BPM.
- Listen to the reference note or melody before recording.
- Follow a complete target phrase with a live microphone pitch trace.
- Review results across the full exercise, including missed notes.
- Export a local JSON report for inspection or score replay.

## Getting started

1. Open `SwarSaathi.xcodeproj` in Xcode 16 or newer on macOS.
2. Select the **SwarSaathi** target. Under **Signing & Capabilities**, select a
   development team and enable automatic signing for device installation.
3. Select a compatible physical device as the run destination and build the
   application. Allow microphone access when prompted.
4. Record the three comfortable notes, confirm Sa, and select an exercise.
5. Select **Start Practice**, sing after the count-in, and review the result.

See the [development guide](docs/DEVELOPMENT.md) for build requirements and
commands. Use the [user guide](docs/USER_GUIDE.md) for recording and practice
instructions.

## Documentation

| Document | Contents |
| --- | --- |
| [Technology stack](docs/TECH_STACK.md) | Frameworks, algorithms, and component responsibilities. |
| [Architecture](docs/ARCHITECTURE.md) | Audio pipeline, target timeline, graph, scoring, and report format. |
| [User guide](docs/USER_GUIDE.md) | Calibration, reference playback, practice, and result interpretation. |
| [Development](docs/DEVELOPMENT.md) | Build setup, automated checks, and local report replay. |

## Repository structure

```text
App/                      Application configuration
Sources/SwarSaathi/        Interface, audio processing, and musical calculations
Tests/SwarSaathiCoreTests/ Shared-core regression tests
Tools/                    Local report replay utility
docs/                     Project documentation
scripts/                  Toolchain, test, and report-replay commands
SwarSaathi.xcodeproj/      Application project and shared scheme
Package.swift             Shared calculation library and test package
```

## Pitch matching

The target timeline advances at the selected tempo independently of microphone
input. The graph uses a smoothed voice trace; scoring uses accepted raw pitch
observations. Missing and unreliable observations remain in the full-exercise
denominator.

The main practice metric accepts sustained notes within ±50 cents and permits
brief transitions around internal note changes. A strict timed metric is also
retained. These percentages describe pitch matching within the scheduled
exercise.
