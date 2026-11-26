# Audio research sprint 02 (provisional)

Base: 452056910f22561862ccada6f3e9588061bc0bee. No product integration or score-policy change. New Swift Package research code is not yet consumed by existing Xcode app.

SwarRecognizer uses existing illustrative Shuddha ratios and independent accepted raw F0. Komal/Tivra need explicit profiles. Equal temperament in tests is a fixture only. No forced target label.

PitchDetector records final rejection stage without changing accepted F0. noReliablePeriodicity includes absent acceptable dip/estimate; this is a stage, not a physiological cause. Gain2 is a non-clipping numeric gain perturbation; long-window doubles frame size at unchanged hop. Both offline experiments, never adopted by default. Label alignment and denominator copied from existing validator. CI downloads the already-used public fixture at exact mirdata revision and logs file hashes, missed reasons, false voicing, octave errors and F0 agreement. No recordings committed.

## Workspace 04
Freeze exact commit and thresholds before collecting independent labels. Exclude development recording and variants from holdout, split by singer, collect consented beginners across Sa/range, annotate F0 and exact variant/octave independently, preregister steady/transition eligibility. Primary quiet record-only condition; denominator includes all eligible labelled voiced instants including abstentions. Report false voice, octave errors, per-singer and singer-cluster confidence intervals. Distinguish F0 from Swara recognition and timed exercise score. No 95% claim until accepted by independent QA. Keep private audio out of public repository.

Commands: swift test --configuration release --jobs 2; sh scripts/diagnose_development_recording.sh voice.wav reference.csv baseline (also gain2, long-window).
