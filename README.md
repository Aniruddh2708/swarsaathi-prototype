# SwarSaathi — Swift singing-pitch prototype

This repository uses the uploaded Swift/SwiftUI implementation as its codebase. The original AVAudioEngine/YIN design, SwiftUI appearance, illustrative Shuddha ratios and 25/50-cent feedback thresholds are retained. The previous Python and browser implementations are superseded.

The feasibility demonstration is due **October 29, 2026**. **57 Linux core tests passed. The [macOS CI run](https://github.com/Aniruddh2708/swarsaathi-prototype/actions/runs/40476104346) also passed the Apple Accelerate core-test step and iOS simulator build for commit `a585f7b`. Real-device singing, microphone routing and latency validation remain pending.** Synthetic tests do not establish microphone accuracy.

## Run on your iPad or iPhone from your iMac

1. Install a compatible Xcode version (Xcode 16 or newer) on the iMac. The app requires iOS/iPadOS 17 or newer.
2. Download this repository from GitHub using **Code → Download ZIP**, then extract it. Open **`SwarSaathi.xcodeproj`** in Xcode.
3. In Xcode, open **Settings → Accounts** and add your Apple ID. Select the **SwarSaathi** target, then **Signing & Capabilities**, enable automatic signing and choose your team. Use a unique bundle identifier if Xcode requests one.
4. Connect the iPad/iPhone to the iMac, unlock it, trust the computer and enable **Settings → Privacy & Security → Developer Mode** if requested. Select that device as Xcode's run destination.
5. Press **Run**. Resolve any build/signing errors before the demonstration, and allow microphone access when the app asks.
6. Record comfortable low, middle and high vowels. Each sample ends automatically after about 3.2 seconds. Hold a steady pitch without strain. Similar low/middle pitches are allowed; the combined measured span must still contain the selected exercise.
7. Listen to the suggested Sa reference, then **confirm** it if comfortable. Any adjustment or new recording requires listening and confirmation again.
8. Select **Sa Re Ga Re Sa**, choose the BPM, play the complete exercise reference, then start. Follow the three-beat count-in and the moving target. Targets continue through mistakes and silence.
9. Review the full-exercise score and share the JSON report. Test this exact device/microphone route before carrying it to the evaluator.

The app runs locally on the device after installation; analysis does not require an internet connection. It is a native app, so GitHub Pages does not install or update it. New source changes require another Xcode build/install, or a separately configured distribution method.

## Development and regression tests

On a Mac with Xcode selected:

```sh
swift test --configuration release --jobs 2
xcodebuild -project SwarSaathi.xcodeproj -scheme SwarSaathi \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

`Package.swift` builds the same Foundation/DSP core used by the app. On Apple platforms YIN uses Accelerate; the Linux test adapter implements the same constant-window difference formula. Apple UI and AVAudioEngine adapters are excluded from the portable package. A passing package suite does not establish an iOS build or working device capture.

For repeatable Mac/Linux core validation, run `sh scripts/test.sh`. The cloud installer, `sh scripts/install_swift.sh`, installs Swift 6.2.1 on Debian 12 x86_64 when needed and verifies its detached release signature against the bundled official Swift release public key. It does not disable TLS or artifact verification. Cloud-specific setup and test commands are also recorded in the environment configuration. The GitHub workflow runs core tests on macOS and builds the iOS simulator target when Actions is available.

## What the measurements mean

- The input bar shows microphone RMS level, not recording progress or correctness. It need not fill completely.
- YIN confidence measures periodicity of an analysis window; 0.9 is not a 90% singing score.
- Sa is a trial tonic fitted to the measured sample span and the exercise's required ratios. Three vowels do not establish a unique personal Sa or a complete vocal range.
- The score counts pitch-match coverage across **every scheduled note**, including missing, unreliable and wrong-pitch portions. It uses raw microphone-derived YIN values. Smoothing is for display only.
- The original just-style ratios remain Sa = 1, Re = 9/8, Ga = 5/4 and so forth. Western note names provide a reference for choosing the tonic; the swaras were not converted to twelve-tone equal temperament.

Read [the complete source audit](docs/AUDIT.md), [validation evidence and device procedure](docs/VALIDATION.md), and [milestone report](docs/MILESTONES.md).
