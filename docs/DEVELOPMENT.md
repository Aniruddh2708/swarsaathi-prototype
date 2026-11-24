# Development

## Requirements

- macOS with Xcode 16 or newer for the application build.
- A compatible physical recording device for microphone use. The project
  deployment target is version 17.0; consult the Xcode project for supported
  device families and SDK settings.
- A development team selected in Xcode for signed device installation.
- Swift tools 5.9 or newer for the shared calculation package. The package uses
  Swift 5 language mode.

The application target uses Apple frameworks. The portable Swift package builds
the shared calculation core rather than the application interface or microphone
adapter.

## Build the application

Open `SwarSaathi.xcodeproj`, select the **SwarSaathi** scheme, and choose a run
destination. For physical devices, configure automatic signing and microphone
permission.

To compile an unsigned simulator build:

```sh
xcodebuild -project SwarSaathi.xcodeproj -scheme SwarSaathi \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

## Run automated checks

```sh
sh scripts/test.sh
```

The suite covers pitch estimation, calibration, exercise timing, scoring,
audio handoff, and recording isolation. On macOS, the script uses the Xcode
toolchain. On Linux it accepts `SWARSAATHI_SWIFT`, otherwise uses Swift from
`PATH` or the repository-local toolchain.

To run a focused group:

```sh
sh scripts/test.sh --filter PitchDetectorTests
```

The GitHub Actions workflow runs the shared-core tests on macOS and compiles
the simulator target. These checks are separate from recording on a physical
device.

## Optional Linux toolchain

`scripts/install_swift.sh` installs Swift 6.2.1 for Debian 12 x86_64. It verifies
the release signature using the bundled public Swift release key before
extracting the toolchain.

```sh
sh scripts/install_swift.sh
sh scripts/test.sh
```

The installer defaults to `.local/swift` and `.cache/swift-download` within the
repository. `SWARSAATHI_TOOLS_ROOT` and `SWARSAATHI_DOWNLOAD_CACHE` override
these locations. `SWARSAATHI_SWIFT_CACHE` overrides the test cache location.

## Replay a local report

```sh
sh scripts/replay_report.sh path/to/practice.json
```

The utility reads the report and runs its observations through the production
scorer. It does not alter the observations or upload the report.
`SWARSAATHI_SWIFTC` can select a compiler on Linux.

## Validate an independently labelled recording

Use a mono, 16-bit PCM WAV and a headerless CSV with increasing time in seconds
and reference frequency in Hz. Include unvoiced instants as zero on a regular
time grid spanning the complete recording. Preserve the file time origin.

```sh
sh scripts/validate_recording.sh singer.wav reference.csv
```

The utility runs the production pitch detector on overlapping PCM windows at
the file's sample rate. It associates each reference time with the nearest
window centre within half a hop. Times outside the available windows have no
detected pitch. It counts all supplied labels, including silence, missing
voiced detections, false voicing, and errors within 50 cents of an octave.
Median and p95 pitch error are conditional on both sources reporting voice.
The within-50-cent rate uses every reference-voiced instant as its denominator.
The command uses the Swift compiler selected by `SWARSAATHI_SWIFTC` or `PATH`.

## Physical-device validation

| Question | Evidence to collect |
| --- | --- |
| Does the microphone capture each take? | Repeat permission, recording, cancellation, stop/restart, route changes, interruptions and backgrounding on the supported iPhones and iPads. Test built-in, wired and Bluetooth inputs. Record OS version, route, actual rate and diagnostic counters for each attempt. |
| Can singers follow the guide in time? | Use an externally synchronized pitched onset and a high-frame-rate recording of the sound and screen. Measure onset to visible feedback across routes, tempos and device load. Compare with the report's capture-centre-to-main-delivery p95; this telemetry excludes screen rendering and acoustic delay. |
| Which voices and environments work? | With consent, collect a held-out set across low/high registers, voice qualities, ornaments, noise and room acoustics. Independently label F0 and voicing. Report per-singer pitch error, missed and false voicing, octave errors and within-band coverage. Keep clean and noisy conditions separate. |
| Is the suggested Sa comfortable? | Collect repeated low/middle/high takes. Have singers and teachers independently select comfortable tonics before revealing the suggestion. Record agreement in cents, confirmation or adjustment and exercise availability. |
| Does the percentage reflect the exercise? | Have teachers mark timing, intonation and transitions independently at several tempos. Include a missing note, silence, early stop, late entry and wrong octave. Compare with strict match, practice match and captured/voiced slot counts. |
| Is practice usable over time? | Check low-tone audibility, count-in visibility/haptics, real note-change display delay, sustained CPU, memory, battery, heat, queue loss and recovery on the oldest supported hardware. |

Keep raw recordings and participant reports private. Set release criteria for the
intended singers and routes before evaluating held-out results. An offline WAV
comparison exercises DSP; device validation also covers the entire capture,
display and playback path.

## Contribution guidelines

- Keep microphone observations independent of expected targets.
- Preserve full-exercise scoring, including missing observations.
- Add focused regression coverage for changes to audio or scoring behaviour.
- Exercise recording, interruption, and stop/restart flows on physical hardware
  when changing audio integration.
- Keep recordings, exported reports, signing files, credentials, build output,
  and generated logs out of version control.
