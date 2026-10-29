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

## Contribution guidelines

- Keep microphone observations independent of expected targets.
- Preserve full-exercise scoring, including missing observations.
- Add focused regression coverage for changes to audio or scoring behaviour.
- Exercise recording, interruption, and stop/restart flows on physical hardware
  when changing audio integration.
- Keep recordings, exported reports, signing files, credentials, build output,
  and generated logs out of version control.
