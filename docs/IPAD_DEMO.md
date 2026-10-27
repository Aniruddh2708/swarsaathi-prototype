# iPad / iPhone demo

The browser application is a separate JavaScript adaptation of the Python desktop prototype. It implements the same measured low/middle/high calibration, independent YIN detector, dynamic Sa-based Alankars, fixed-tempo comparison, equal-note-weighted score and missing-voice penalties. Both use the **same** `data/alankars.json` definitions. The existing desktop source and tests remain available.

## Publish the HTTPS site once

1. Open `https://github.com/Aniruddh2708/swarsaathi-prototype/settings/pages` while signed into a GitHub account that can manage this repository.
2. Under **Build and deployment**, set **Source** to **Deploy from a branch**.
3. Select branch **main**, folder **/ (root)**, and click **Save**.
4. Wait until GitHub says the site is deployed. The repository's Actions tab shows the Pages build/deployment result if there is an error.
5. Open the URL GitHub displays. The expected URL is `https://aniruddh2708.github.io/swarsaathi-prototype/`; its root redirects to `web/`.

Hosting is a separate operation from pushing code. GitHub API requests from this managed environment were denied by the network proxy, so automatic Pages configuration/live-site verification was unavailable here. No GitHub credential value was requested or extracted. Pages availability depends on repository/account settings; if GitHub does not offer these controls, report its exact message before changing repository visibility or account settings.

The site has no backend, database, build step, third-party browser packages, paid API, analytics or model download. All scripts and exercise data are served from the same site. Hosting serves static source files; microphone samples remain on the device. Exported reports are downloaded locally only when you tap **Save report**. No raw voice recording is stored automatically.

## On the iPad (preferred screen) or iPhone

Use an updated Safari. Open the HTTPS page directly in Safari rather than an embedded messenger browser. Device microphone use requires HTTPS; an HTTP address pointing to an iMac on the local network will not provide equivalent secure microphone access.

1. Turn up playback volume, check silent mode/audio routing, and preferably use headphones.
2. Tap **Enable microphone**, allow microphone access, and sing a short vowel. Check the input meter and measured Hz. If denied, allow microphone access for the site in Safari's website settings and retry.
3. Record a comfortably low **Aa** for three seconds. Next record your comfortable middle, then comfortable high without strain. Unreliable samples are rejected and the current stage can be retried. The message below Record reports accepted voice seconds, coverage and frame counts when sustained voice is insufficient; a rejected sample resets the bar. A last-frame Hz reading does not establish a reliable whole recording. Hold one steady vowel throughout the clip, rather than singing a melody. Use 4,096 samples for lower voices if the shorter window is unreliable.
4. Review suggested Sa, approximate safe range and explanation. Tap **Play suggested Sa**, then **Confirm this Sa** if comfortable, or retry calibration.
5. Choose an Alankar and BPM. Listen to the **complete** reference. Start becomes available only after playback finishes; changing the exercise or tempo invalidates that reference.
6. Tap **Start practice**, follow the three-beat visual count-in, and sing one repetition. Reference output stops before microphone evaluation.
7. Inspect actual-vs-expected pitch, raw cents error, note coverage and final score. **Save report** downloads JSON containing measured calibration, raw observations, targets, missing durations, score and diagnostic timings. **Practice again** requires listening to the reference again. **Finish** releases capture and playback.

Keep Safari visible and the device unlocked during each attempt. Switching apps, backgrounding or an audio interruption ends capture; practice is explicitly marked incomplete and remaining voice is missing. These interruptions must not produce an apparently completed good performance. Stop audio before changing headsets or devices, then start a new attempt.

## Browser audio and timing contract

- `getUserMedia` requests mono input with echo cancellation, noise suppression and automatic gain control disabled. Browser/OS support varies; actual track settings and sample rate are saved in the report. The app uses the actual `AudioContext.sampleRate`, including 44.1/48 kHz.
- The AudioWorklet only copies microphone samples into overlapping 2,048/4,096-sample windows at a 512-sample hop. A three-credit handoff bounds pending work. With no credit, frames are dropped, counted, and left missing from scoring.
- A separate module Worker runs DC removal, RMS silence gate, exact FFT YIN lag-dependent energies/CMNDF/interpolation and quality rejection. No target information is supplied to this worker.
- Raw pitch drives scoring. Continuous-cents median smoothing affects only graph display; unvoiced regions and large timestamp gaps break the trace. Genuine octave errors remain visible and incorrect.
- Capture timestamps use the AudioWorklet's sample clock and window center. Reference timing and count-in use the same AudioContext clock. Graph timers render this timeline; they do not define the observed timestamps.
- The reference melody, graph and scorer use the one selected structured timeline. Web Audio output stops and microphone tracks are released between recording/playback stages.
- Experimental defaults match the desktop model: RMS .008, periodicity quality .8, pitch tolerance ±30 cents, at most 100-ms/20%-per-edge grace, at most 20-ms scoring cells. Missing/unvoiced cells stay in the denominator and expected notes have equal weight. No flexible-tempo alignment is claimed.
- Calibration excludes 300-ms edges, requires at least one second/70% voice/20 accepted frames, rejects 80-cent central spread, insets measured boundaries 50 cents, first attempts to fit the full exercise library, otherwise fits a shorter existing exercise and disables exercises outside the same measured boundaries, and selects a deterministic lower tonic for ranking costs within five cents. It reports uncertainty rather than claiming a fixed personal scale.

## Software validation and device acceptance

Run the dependency-free browser mathematics/transport suite from the repository root:

```sh
node --test web/tests/core.test.mjs
```

It checks exact FFT/direct difference equality, 44 clean-tone cases, harmonics/noise/DC/silence, octave smoothing, calibration through actual synthetic DSP frames, shifted Sa, independent wrong/sharp/flat/missing/silent observations, bounded worklet timing/copies/drop counts and full synthetic audio-to-score paths. Its synthetic worst error is approximately 0.433 cents. Node computation timing is not iPad response delay.

Optional developer integration: serve the repository root with Python's HTTP server and run `python3 tools/test_browser.py` against that internal test server. This needs Playwright and a local Chromium executable; it is a development test dependency already available in the managed environment, not a package required by the demo. The script explicitly replaces microphone input with oscillator-generated MediaStreams and exercises the production AudioWorklet/Worker/YIN path, all calibration stages, reference completion, practice, exported reports, silence and device-ended errors. Outcomes are in `artifacts/browser_test_results.json`. Test-generated reports are synthetic evidence, regardless of the production report's `source` field. They are not recordings of a person.

The Chromium integration test does not establish iOS/Safari compatibility. WebKit was not installed in the validation machine. **Physical iPad/iPhone recording, audible playback, Anchal's calibration, headset routing, background/phone-call behavior and visible response latency remain pending.** Use the real-voice protocol in `VALIDATION.md` on the actual device, including correct/wrong/missing/silent and timing-drift attempts. Retain raw report evidence and independently labelled voice if claiming detector accuracy.

Recorded managed-machine results: **100 Python tests passed; 18 Node tests passed; 13 Chromium end-to-end checks passed with no page errors**. The full synthetic browser journey measured 100% pitch match for the independently generated known melody and 0% for silence. Layouts at 390 and 1,024 CSS pixels fit their viewports. These are synthetic/software outcomes, not real-vocal accuracy. The latest Node detector-only benchmark measured approximately 0.813-ms median / 1.164-ms p95 on this cloud CPU, excluding acquisition/rendering/device latency. Raw browser timing and observation evidence is in `artifacts/browser_synthetic_report.json`; integration outcomes are in `artifacts/browser_test_results.json`.

Debugging evidence: the initial integration fixture scheduled its generated melody after a Python polling round trip and started transitions approximately 280 ms late. Its saved raw trace correctly produced reduced pitch match (about 44–51%). Scheduling was moved into the browser's animation clock; the scorer, ±30-cent threshold and transition grace were unchanged. An additional harness race dispatched the device-ended event before capture startup completed; the fixture now waits for the live practice view before testing an in-practice disconnect. Original failure logs were retained in ignored artifacts. The production app also cancels stale async microphone requests, initializes the worklet once per AudioContext and clears old timers between capture stages.

If the page loads but the microphone fails, record the exact message, Safari/iPadOS version, selected input, headset type and permissions. If tuning/coverage looks wrong, save the report before retrying. Do not change tolerances to manufacture a higher score. Three short vowels can be inconclusive on real voices even when synthetic tests pass.

Current browser calibration policy (updated after real-device feedback): the earlier mandatory 100-cent gap between named stages was a prototype assumption, not a musical requirement, and has been removed from the browser journey. Similar samples are retained as valid evidence, while their lack of independent range information is disclosed. Raw labelled measurements are preserved. Inset boundaries use the lowest and highest actual measured medians, so small ordering differences do not force a singer to change their voice. Silence, insufficient coverage and unstable pitch still fail the existing unchanged quality checks.

The app first fits the full library. If that is impossible, it fits an existing shorter Alankar with the same 50-cent inward margins and disables every exercise whose notes would extend outside those boundaries at the proposed Sa. If none fits, calibration remains inconclusive. Reference and practice use only an enabled exercise; practice also checks every target against the boundaries. Pitch-match tolerance, grace periods, missing-voice penalties and raw observed frequencies are unchanged. The Python desktop retains its original stricter calibration workflow.

For reported samples 221.90 / 223.57 / 321.32 Hz, the browser recommends a trial Sa of A-sharp3/B-flat3, 233.08 Hz, for Alankar 1. Targets Sa/Re/Ga are 233.08 / 261.63 / 293.66 Hz, inside the inset interval (approximately 228.4–312.2 Hz). Alankars 2 and 3 reach Pa at approximately 349.23 Hz, so remain unavailable at this Sa. The user must listen and confirm comfort; this is not an objectively determined personal tonic. Regressions cover the exact values, identical and slightly reversed low/middle samples, insufficient evidence, absent usable range and the full browser path with unavailable choices.
