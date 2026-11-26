# Audio research sprint 02 (provisional)

Base: 452056910f22561862ccada6f3e9588061bc0bee. No product integration or score-policy change. New Swift Package research code is not yet consumed by existing Xcode app.

SwarRecognizer uses existing illustrative Shuddha ratios and independent accepted raw F0. Komal/Tivra need explicit profiles. Equal temperament in tests is a fixture only. No forced target label.

PitchDetector records final rejection stage without changing accepted F0. noReliablePeriodicity includes absent acceptable dip/estimate; this is a stage, not a physiological cause. Gain2 is a non-clipping numeric gain perturbation; long-window doubles frame size at unchanged hop. Both offline experiments, never adopted by default. Label alignment and denominator copied from existing validator. CI downloads the already-used public fixture at exact mirdata revision and logs file hashes, missed reasons, false voicing, octave errors and F0 agreement. No recordings committed.

## Workspace 04
Freeze exact commit and thresholds before collecting independent labels. Exclude development recording and variants from holdout, split by singer, collect consented beginners across Sa/range, annotate F0 and exact variant/octave independently, preregister steady/transition eligibility. Primary quiet record-only condition; denominator includes all eligible labelled voiced instants including abstentions. Report false voice, octave errors, per-singer and singer-cluster confidence intervals. Distinguish F0 from Swara recognition and timed exercise score. No 95% claim until accepted by independent QA. Keep private audio out of public repository.

Commands: swift test --configuration release --jobs 2; sh scripts/diagnose_development_recording.sh voice.wav reference.csv baseline (also gain2, long-window).

## Focused Alankar research
FocusEvidenceExtractor decodes the actual schema-3 audit contract and requires externally verified session/calibration/revision links and record-only provenance. Rejects incomplete, damaged, uncertain timing, missing route or mismatched target ratio. Identifies interior-cell pitch evidence and conservative timing/neighbor/octave ambiguity; missing and rejected frames cannot be evidence of weakness. Does not change scorer. Thresholds provisional. Real private practice reports not available; tests are synthetic JSON matching audit structure. Actual historical reports lacking verified IDs must remain ineligible.

FocusRecommendationEngine ports Sprint 01 median-of-session-means policy, 30 days, up to 5 eligible sessions per key, >=10 attempts, >=3 sessions and >=2 exact sequences, recurrence <70 in >=2 sessions. Same calibration, Sa, tuning, BPM, source revision, route and evidence policy. Deterministic ranking; range, supported variants, difficulty and tempo constraints. No teacher-approved library is shipped. Test fixtures are explicitly opt-in and cannot be selected by default. Review reference is metadata, not independent verification of a teacher's approval. Source IDs are retained. No persistence/product UI changes; historical cohort comparison and teacher review pending.
