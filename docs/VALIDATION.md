# Validation evidence and Apple-device gate

Updated October 27, 2026. Numerical measurements below use synthetic inputs on Linux x86_64. The macOS CI core-test step (Apple Accelerate) and Xcode iOS simulator build subsequently passed. AVAudioEngine on a physical device and real singing remain **unvalidated**.

## Reproduced baseline

The original detector was exercised in an isolated baseline package. Only a Linux adapter for the same constant-window vDSP math was added so it could execute outside Apple platforms.

Command: `swift test --configuration release --jobs 2` in the isolated baseline package, using Swift 6.2.1 and writable compiler caches.

Actual result: **6 tests executed, 5 passed, 1 failed**. The failing `testSmootherDoesNotBridgeUnvoicedFrame` returned approximately `220.00000000000006` Hz after nil microphone pitch. Root cause: the original smoother deliberately bridged the first missing frame with its previous output. The regression remains in the current suite. The minimal correction returns nil and resets smoothing on unvoiced/invalid input; raw detector values remain separate from display smoothing. See the [preserved baseline log](evidence/baseline.log).

The baseline passed clean known tones, harmonic-rich tones, raw octave transitions, silence and the configured 70 Hz lower boundary. No reproduced failure supported changing the core YIN selection or interpolation, so those were retained.

The uploaded source is preserved unchanged in commit `d48e4be326df061a101d11114fd6c8b532065a1e`. From a full Git clone, `sh scripts/test_original_baseline.sh` reconstructs that detector with only the portability adapter and runs the original six tests. Its nonzero exit is intentional: it reproduces the one silence-smoothing failure. The [reproduced log](evidence/baseline-reproduced.log) records this check; `sh scripts/test.sh` is the current release gate.

## Executed synthetic pitch measurements

The expanded detector suite covers 44 clean cases across 44.1/48 kHz, 2048/4096-sample windows and known frequencies from 75 through 1000 Hz, plus a separate default 70 Hz boundary test.

| Measurement | Observed result | Scope |
| --- | --- | --- |
| Maximum absolute clean-tone error | 0.438624 cents | 44 deterministic synthetic cases |
| Median absolute clean-tone error | 0.022117 cents | Same cases |
| Initial expanded detector suite | 13 tests, 0 failures | Linux scalar equivalent of original difference math |
| Latest reviewed detector compute median / p95 | 0.785775 / 0.999226 ms | 500 calls, 2048 samples at 44.1 kHz; host-dependent |
| Analysis-window duration | 46.440 ms at 44.1 kHz; 42.667 ms at 48 kHz | Calculated, not measured end-to-end latency |
| Center-to-end sample availability | At least half the analysis window | Excludes input/output buffering, scheduling, smoothing and display |

Tests additionally cover harmonic mixtures, deterministic moderate noise, DC offsets, the actual RMS silence gate, undersized/nonfinite buffers, invalid configurations, raw/display separation and real octave changes. A scalar/Accelerate floating-point comparison allowance is not a relaxed pitch-match threshold. The singing thresholds remain 25 and 50 cents.

## Scoring regression discovered during review

A newly added test reproduced a draft bug: at 120 BPM, singing only the middle 300 ms of every 500 ms note, with the first/last 100 ms silent, scored 100%. The draft had excluded both edges, counting only 1.5 seconds of a 2.5-second exercise. The correction scores each complete scheduled note. Silent edges remain in the denominator, and nonuniform sparse evidence cannot fill missing cells. This is a scoring-policy fix; no pitch threshold was relaxed.

Other regressions cover all-silent attempts, one correct note with the rest missing, sharp/flat and octave errors, early stop, duplicate/conflicting evidence, low confidence, shifted timing, real analysis-hop cadence and shared target/reference definitions. Calibration tests cover raw coverage, absent recording ends, instability/octaves, contradictory statistics, fitted range and confirmation invalidation. Pipeline tests cover bounded queues, memory ownership, overflow, reset, concurrent producer/consumer integrity, window timestamps and generation isolation.

Review also reproduced and corrected these smaller failures before the final rerun:

- Fabricated sample statistics could claim 99% coverage with only one voiced second out of 100 usable seconds. The recommendation now checks that coverage equals voiced/usable duration.
- All-silent summaries invented a numeric zero-cent deviation, including in JSON. Deviation is now optional and absent when no real observed error exists.
- Clearly reversed low/middle/high labels were accepted because range fitting used only their extrema. The recommendation now rejects reversals beyond measured half-spreads plus a five-cent numerical floor. Close/repeated low and middle measurements remain valid; this is not a required pitch gap or a relaxed singing threshold.
- A duration-identity test exposed floating-point reconstruction differences after grace was removed. Duration reporting now uses the scheduled duration times the voiced fraction, with missing duration as its complement; classifications are unchanged.

The reviewed full release run executed **57 XCTest tests, 0 failures in 0.846 seconds**: mailbox 7, processing worker 4, calibration 16, synthetic integration 2, detector 13 and practice 15. See the [reviewed release log](evidence/review-release.log). The synthetic five-note waveform passed through the actual shared processing worker/YIN and scored 100% at 72 BPM from 178 raw observations; a separate corrupted/silent synthetic exercise loses score. These integration tests are explicitly synthetic, not live singing.

## Reproduce the current suite

On a Mac:

```sh
swift test --configuration release --jobs 2
xcodebuild -project SwarSaathi.xcodeproj -scheme SwarSaathi \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

Use `sh scripts/test.sh` for the repository's repeatable Mac/Linux core check. On the managed Debian 12 x86_64 cloud host, `sh scripts/install_swift.sh` provisions Swift 6.2.1 with detached-signature verification against official release-key fingerprint `52BB 7E3D E28A 71BE 22EC 05FF EF80 A866 B47A 981F`. Compiler/package caches are writable workspace paths; no HOME override is needed.

The final combined test count and exact benchmark timing are in the [final release log](evidence/final-release.log); reruns can vary in timing. XCTest's executed test count is authoritative; the trailing Swift Testing message may say zero tests because this project uses XCTest. The Linux installer was also executed into a fresh directory, verifying the downloaded detached signature before extraction; the retained-toolchain rerun succeeded.

## Executed Apple CI gate

For commit `a585f7b5899e534f4b2e5898b08f929798ca55ed`, [GitHub run 40476104346](https://github.com/Aniruddh2708/swarsaathi-prototype/actions/runs/40476104346/job/122094603748) on `macos-15` reported:

- `swift test --configuration release --jobs 2`: success; this compiles and executes the Apple Accelerate path.
- `xcodebuild -project SwarSaathi.xcodeproj -scheme SwarSaathi -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build`: success.
- Job completed successfully at 08:50:21 UTC on October 27, 2026.

The public job step metadata is preserved in [apple-ci.json](evidence/apple-ci.json). Detailed runner logs were unavailable anonymously, so no additional Apple test count, numerical error or latency measurement is inferred. These are executed CI results, separate from the 57-test Linux log. This unsigned simulator build does not establish signed deployment, microphone capture or singing accuracy on the actual device.

## Device and recorded-singing validation — pending

Complete this stage on the exact iPad/iPhone and microphone route to be used on October 29. Simulator or static inspection cannot satisfy it.

1. Record the app revision, Xcode version, device model, OS version, route, sample rate, room conditions and speaker/microphone arrangement. Build/install on the device. Verify permission denial and subsequent Settings recovery.
2. Test built-in microphone first. Capture low/middle/high held vowels at several pitches, including lower voices, ordinary vibrato, breathy onsets, silence, octave changes and background sound. Stop/restart repeatedly and interrupt/background the app. Confirm that rejected evidence stays rejected and old frames never appear in the next recording.
3. Retain real recorded singing as unmodified PCM WAV with consent and describe its provenance. Obtain independent pitch/time annotations or a separate trusted analysis; no human singing sample has an exact known F0 merely because a reference was played. Evaluate frequency error in cents, octave-error rate and voiced/unvoiced coverage against those annotations. Keep difficult, quiet and silent portions in the report. Do not silently replace recordings with synthesized tones.
4. Export calibration diagnostics from the app's Documents/Diagnostics directory and the practice JSON via Share Report or Documents/SwarSaathiReports. Retain every expected target, raw observation, confidence, timestamp, loss counter and incomplete-attempt reason. Recompute reported scores from those records and verify silence/wrong notes reduce the score.
5. Listen to the fitted Sa, confirm it and complete the five-note exercise at the chosen BPM. Then deliberately omit a note, sing an octave wrong, remain silent for a full run and stop early. Verify target advancement is unchanged and each error reduces the full-exercise percentage.
6. Measure microphone-to-visible-feedback latency on the real device with synchronized acoustic/visual events or external recording. Report the method and distribution separately from the detector's compute-time benchmark. Test Bluetooth/AirPods separately; their buffering and route can differ.
7. Test reference playback completion/interruption, capture/playback separation and repeated switching between them. Verify reference tones never become live observations. Keep the initial demo sequential: reference playback, stop, then microphone recording.

Raw PCM recording/file-import analysis is not silently provided by the live observation JSON exporter. If a file-based real-singing harness or in-app PCM recording is added, its output must pass through the same detector/preprocessing and be clearly labeled as file input. The present real-device/recorded-singing stage remains pending until that work and its measurements are executed.

## Remaining risks

- The native project passed its Xcode simulator build. Signed installation and actual microphone capture/playback still need the evaluation device.
- Portable tests measure the shared algorithm, and the Apple Accelerate test step passed in CI. Detailed Apple numerical measurements and AVAudioEngine timing/route behavior still require validation.
- The mailbox is bounded and uses brief locks. Callback scheduling, device CPU pressure and audio-buffer sizing still need profiling. Dropped audio conservatively lowers coverage; it must not be concealed.
- Three sustained vowels only provide rough comfortable-span evidence. Safety margins, coverage gates and the illustrative tuning remain prototype assumptions requiring evaluator review.
- Display smoothing can lag true octave changes. Scoring and calibration use raw accepted YIN observations, so display appearance must not be presented as a detector measurement.
- Fixed-tempo pitch comparison conflates timing and pitch mistakes. The resulting score is not a validated assessment of full musical performance.

## Reported Simulator route crash — follow-up

The user reported an iPhone 17 Pro Simulator / iOS 26.2 crash after connecting
AirPods: Core Audio rejected an explicitly supplied mono 44100 Hz Float32 tap
format. The capture adapter supplied the input node's previously queried output
format to installTap. Audio-route changes can invalidate that format; the thrown
Objective-C NSException is not handled by Swift do/catch.

The adapter now asks the input node to negotiate its native tap format (`nil`),
initializes YIN from the hardware input rate, rejects buffers whose rate differs
from the recording's rate, and ends capture on route/configuration changes until
the singer explicitly retries. No detector or scoring threshold changed.

Validation: `sh scripts/test.sh` reran all 57 portable tests successfully; all
Swift source passed syntax parsing. These checks do not reproduce the Simulator
Core Audio exception. Hardware/Simulator regression remains pending: start on
built-in input, connect/disconnect AirPods during capture, verify clean stop and
retry without a crash or stale-rate observations. Repeat on the actual evaluation
iPad/iPhone. Check macOS microphone permission for Xcode/Simulator separately.

## Patient calibration and practice usability follow-up

Reference playback is now optional at the user's request; measured Sa still
requires explicit confirmation. First and repeated practice starts use the same
range/permission guards, and playback stops before capture. Regression tests
first reproduced the old confirmation gate before the correction. Calibration
now attempts full-recording validation after 3.2 seconds, continues collecting
on instability/insufficient voice until 8 seconds, and then reports rejection if
still inconclusive. It does not choose only successful frames. Coverage, pitch
confidence and held-vowel spread requirements are unchanged.

The complete target phrase is visible before count-in on a fixed left-to-right
axis; a moving playhead indicates elapsed time. Target timing remains independent
of the microphone. Visual interaction still requires on-device inspection.

The original strict timed score remains `accuracyPercent`. New schema version 2
reports also contain `practiceMatchPercent`, `transitionWindowSeconds`, and each
note's `transitionAcceptedFrames`. In the practice metric only, a reliable pitch
between adjacent targets (including their existing ±50-cent bands) can earn
credit within 100 ms either side of an internal boundary. This does not shift the
entire recording or remove any time cells. Silence, poor-confidence voice and
wrong octaves remain zero; held-note pitch tolerance is unchanged. It is a
transparent training allowance, not a validated clinical/musical accuracy metric.

A new deterministic regression reproduced the strict-only behaviour for an
80 ms delayed internal note change: 93.6% rather than the desired transition-aware
100%. The strict 93.6% is preserved alongside the new practice result. Tests also
cover silence at boundaries, a wrong octave, errors beyond the window, unchanged
full denominator, and normal ±40-cent vibrato. No numerical threshold was tuned
to force a particular singer's report to pass.

`sh scripts/replay_report.sh path/to/practice.json` uses the production scorer on
an existing local audit. The user-provided report was replayed locally, without
publishing its observations or treating its pitch estimates as ground-truth audio.
A practice JSON cannot establish why a different calibration recording failed or
prove actual acoustic F0 accuracy; that requires the calibration report/audio.


## Independent calibration and percentage checks — October 28

The [clarity milestone](MILESTONES.md) adds eight executed tests, bringing the
portable suite to **75 tests, zero failures**. See [the full log](evidence/clarity-core.log).
The synthetic calibration check uses 3.2-second PCM vowels with three harmonics,
±20-cent / 5 Hz vibrato, deterministic additive noise and a DC offset. Four
low/middle/high sets at both 44.1 and 48 kHz cover 82.41–620 Hz and include similar
low/middle pitches. Every sample goes through the production processing worker,
DC/RMS preprocessing, YIN, and calibration analyzer. Maximum error of the measured
sample median is 0.671688 cents; all eight tonic choices match known-pitch inputs.
This measures reproducibility of the existing recommendation policy, not the
musical validity of a unique personal tonic or accuracy on a singer dataset.

The independent score fixture specifies all cell outcomes by hand: 125 expected,
70 strictly correct, four additional transition matches, 102 reliable voice cells.
Reported values are 56%, 59.2%, and 81.6%, respectively. Tests also prove a nearby
successful observation cannot replace a closer silent/wrong observation; duplicates,
count-in and tail observations cannot inflate the result; decoded JSON reproduces
the same scores; and a wholly missing note remains zero across six tempos. No
threshold, denominator or detector was modified to improve these results.

UI percentages are rounded to one decimal from those same computed values; raw
values remain in JSON. Short user-facing errors are separate from detailed logged
and exported calibration rejections. Both calibration and practice reports can
be shared from the optional Details section.


## Exercise independence regression — October 29

The previous exercise-constrained calibration policy is superseded. Three new
regressions first reproduced changing Sa when the exercise changes, rejecting
good voice evidence because Ga would not fit, and preventing a manually selected
reference inside the recorded boundaries. The
[before log](evidence/exercise-independence-before.log) preserves all three failures.
After removing exercise inputs from calibration and moving target checks into
`Alankaar.fits`, the focused 29-test selection passed; the
[full run](evidence/exercise-independence-release.log) passed **85 tests, zero
failures in 4.010 seconds**. The original YIN, coverage/spread gates, transition
allowance and score calculation were not modified.

The voice-only reference uses the geometric mean of the measured range center
and comfortable middle, then chooses a nearby semitone-grid pitch within the
same inset boundaries. Its selection metadata is exported in calibration schema
2. This is a reproducible initial suggestion for singer confirmation, not a
validated estimator of a unique personal tonic. Tests verify each voice input
contributes, transposition/repeatability, confirmation/adjustment lifecycle,
serialized policy evidence, and eligibility of different exercise spans without
changing Sa. Synthetic microphone-worker tests still match all eight known-input
voice-only reference proposals at 44.1/48 kHz.

Range checks cover Ga-high, Pa-high, octave-high and lower-register definitions,
unknown/missing swars, invalid ratios, invalid bounds and exact frequency edges.
UI tests on a real device are still needed: select the short phrase, switch to
the octave phrase, verify Sa stays fixed and that availability changes, then go
back and explicitly adjust/reconfirm Sa. A range limitation should not ask the
singer to repeat otherwise valid calibration automatically.
