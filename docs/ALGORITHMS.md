# Algorithms and experimental thresholds

These are prototype engineering settings, not established Hindustani vocal assessment criteria. Sa is relative. Three measured vowels can support a conservative recommendation for the selected demonstration exercises; they cannot discover an immutable personal tonic or establish an exhaustive vocal range.

## Independent audio path

`audio/capture.py` requests mono float32 input at 44,100 Hz, trying the device default, 48,000 Hz, and 44,100 Hz if needed. Callback blocks are 512 samples. The callback copies samples into a bounded 24-block queue and updates counters; pitch detection, rendering, logging, and file writing happen outside it. A worker builds overlapping analysis windows with a 512-sample hop. The GUI defaults to 2,048 samples and offers 4,096 for lower voices; the capture class and WAV analyzer default to 4,096.

Input timestamps map PortAudio ADC time to a monotonic clock. Pitch timestamps refer to analysis-window centers. Missing blocks or timestamp discontinuities reset window assembly rather than splice unrelated audio into a false continuous observation. Metrics distinguish captured/dropped samples, input overruns, discontinuities, analyzed frames, worker errors, queue delay, processing duration, and frame-center age after analysis. Worker processing/age median and p95 use bounded recent measurements. They are measured counters, not hard real-time guarantees.

At 44.1 kHz, 4,096 samples span about 92.9 ms and a 512-sample hop spans 11.6 ms. A window's look-ahead relative to its center, hardware buffering, worker scheduling, smoothing, and GUI refresh all contribute to response delay. Detector computation time alone is not end-to-end latency.

## YIN estimator

`audio/pitch_detector.py` removes DC and rejects frames below the RMS silence gate. For a finite mono window `x` of length `N`, it evaluates the overlapping squared difference:

```text
d(τ) = Σ[j=0 … N−τ−1] (x[j] − x[j+τ])²
d′(0) = 1
d′(τ) = τ d(τ) / Σ[k=1 … τ] d(k)
```

The FFT implementation uses zero-padded linear autocorrelation plus both lag-dependent energy sums. Tests compare it against a direct NumPy reference; a fixed-energy autocorrelation shortcut is not used. YIN chooses the first qualifying CMNDF trough, descends to its local minimum, and applies parabolic interpolation. It rejects insufficient cycles, invalid/out-of-range frequencies, and low-quality estimates.

| Setting | Default |
| --- | --- |
| F0 search | 65–1,100 Hz |
| RMS gate | 0.008 full scale after DC removal |
| CMNDF trough threshold | 0.15 |
| Minimum quality | 0.8 |
| Quality definition | Clipped `1 − CMNDF(selected lag)` |
| Minimum evidence in window | 2.5 periods |

Quality describes periodicity evidence; it is not probability of correct pitch or a measured accuracy percentage. A harmonic-rich real voice, accompaniment, room noise, or octave ambiguity can still mislead a periodicity detector. Rejected frames remain unvoiced rather than receive an invented frequency.

The graph smoother works in continuous cents relative to confirmed Sa: `1200 log2(f / Sa)`. It uses a three-frame rolling median. Changes over 80 cents reset that median; jumps over 700 cents require two consecutive agreeing voiced frames within 80 cents. Silence yields an immediate trace break and clears history after 250 ms. A new Sa resets smoothing. Neither detector nor smoother receives expected target pitches. Scoring uses raw reliable detections, independently of graph smoothing.

## Find My Sa

`calibration/find_my_sa.py` summarizes each low/middle/high recording independently:

| Acceptance rule | Default |
| --- | --- |
| Trim | First and last 300 ms |
| Accepted quality | At least 0.8 |
| Reliable voice | At least 1.0 second and 70% of usable duration |
| Accepted analysis frames | At least 20 |
| Per-observation temporal support | At most 50 ms, limited by measured hop |
| Stability report | `1.4826 × median absolute deviation` in cents |
| Rejection spread | 90th minus 10th percentile above 80 cents |
| Adjacent stage separation | At least 100 cents; low < middle < high |

Duplicate timestamps count once. Missing temporal support cannot be filled by a few repeated observations. The accepted median frequency is robust against isolated outliers; the separate central spread rejects broad drift or alternating pitches.

Candidate selection computes the full minimum/maximum semitone span of the demonstration exercises. The current library spans Sa to Pa: 0–7 semitones. It insets the measured low/high frequencies by 50 cents at each edge, then enumerates A4=440 Hz equal-tempered semitone-grid tonic candidates whose full exercise span fits inside that safe interval. It ranks candidates by how near the exercise's pitch midpoint lies to the measured middle sample. Costs within 5 cents of the minimum are treated as a near-tie: the lower safe candidate wins deterministically and the explanation discloses ambiguity. This ranking tolerance is configurable. It does not average the three frequencies or use gender assumptions.

Invalid, unstable, indistinct, too narrow, or grid-incompatible evidence returns “Calibration inconclusive — please retry.” The recommendation includes measured frequencies, safe range, candidate count, and explanation. Only explicit confirmation adopts a new tonic; a new proposal does not silently replace it. The GUI's explicit **Retry calibration** action clears calibration/session tonic state to begin again. This state is in memory, not a user profile.

## Targets, timing, and feedback

`data/alankars.json` stores each note's swara, semitone offset, octave offset, and beat duration. `practice/alankars.py` builds the one shared timeline:

```text
target Hz = confirmed Sa × 2^((semitone offset + 12 × octave offset) / 12)
note duration seconds = beats × 60 / BPM
error cents = 1200 × log2(observed Hz / target Hz)
```

BPM defaults to 72; the GUI offers 40–120 BPM while timeline construction accepts 30–180 BPM. Positive error means sharp; negative means flat. Graph pitch is unwrapped relative cents, so octave errors remain visible. Reference synthesis uses the same timed note frequencies/durations, with simple sine waves and short fades. Reference playback stops before evaluated input; each attempt has a three-beat visual count-in.

Comparison follows a fixed guided timeline. Each note excludes a grace interval at both edges: the minimum of configured grace, 100 ms, and 20% of that note's duration. Callers cannot inflate grace beyond the cap. This tolerates small boundary transitions; it does not implement flexible-tempo alignment or dynamic time warping.

Reliable voice requires finite positive F0, voiced status, and quality in `[0.8, 1]`. On Pitch means absolute error ≤30 cents. An estimate outside that tolerance but with the same nearest chromatic semitone is Slightly High/Low. A different nearest semitone, including the wrong octave, is Wrong Swara. Unreliable voice is No Reliable Voice; grace regions are Transition / Unscored Boundary. Nearest-swara names are diagnostic labels and never alter observed pitch. A wrong-pitch/timing warning acknowledges that fixed-tempo comparison cannot uniquely separate those causes.

## Auditable score

`practice/scoring.py` partitions each eligible note interval into equal cells no longer than 20 ms by default. Each timestamp can populate only its own cell. If several observations occupy it, the one closest to the midpoint is selected; exact duplicates do not create extra evidence. Observation-to-midpoint distance is capped at 40 ms. Gaps, invalid detections, silence, or dropped acquisition leave cells missing. Samples never extend into neighboring cells.

```text
note pitch match = 100 × correct duration / eligible duration
overall pitch match = arithmetic mean of all expected note percentages
missing duration = eligible duration − reliable voiced duration
```

A correct cell has reliable raw pitch within ±30 cents of that note's target. Every eligible cell remains in the denominator, including missing or wrong singing. Equal weighting across expected notes prevents a long note from dominating. Per-note reports include eligible/valid/correct/missing durations, expected/valid/correct cell counts, median absolute error over valid observations, percentage, and attempted status. “Attempted” requires at least 50% reliable voiced coverage. Notes below 80% pitch match are listed for improvement; a note below 80% reliable coverage also produces an uncertainty warning. These report labels do not change scoring.

The report flags limited alignment confidence if at least 10% of a note's reliable cells exceed 50 cents error. Pitch and timing cannot be uniquely distinguished by this heuristic. Tolerance, voice quality, grace, and scoring-cell parameters are explicit in source/report data; changing them requires a documented experiment rather than an attempt to obtain a higher percentage.

The live meter measures progress against the full exercise, including not-yet-sung expected notes. The final percentage is **singing pitch-match accuracy for this exercise and timeline**. Detector error against known F0, real-voice voicing reliability, musical correctness, and pedagogical suitability are separate metrics requiring their own ground truth and validation.
