"""Optional browser integration validation. Requires development-only Playwright.

All audio in this test is explicitly SYNTHETIC. getUserMedia is replaced only
inside the test browser with an oscillator-generated MediaStream; samples still
travel through the production AudioWorklet, Worker, YIN, calibration and scorer.
No simulation mode is included in the delivered application.
Run a repository-root HTTP server, then python tools/test_browser.py.
"""
import argparse
import json
from pathlib import Path
import re
import time

from playwright.sync_api import sync_playwright, expect


FIXTURE = """() => {
  const ctx = new AudioContext(), osc = ctx.createOscillator(), gain = ctx.createGain();
  const destination = ctx.createMediaStreamDestination();
  osc.type = 'sine'; osc.frequency.value=130; gain.gain.value=.22;
  osc.connect(gain); gain.connect(destination); osc.start();
  window.fixture = {
    frequency(hz) { osc.frequency.cancelScheduledValues(ctx.currentTime); osc.frequency.setValueAtTime(hz,ctx.currentTime); },
    silence(on) {gain.gain.value=on?0:.22;},
    sequence(sa,beat) {
      const start=ctx.currentTime;
      [0,2,4,2,0].forEach((note,i)=>osc.frequency.setValueAtTime(sa*2**(note/12),start+i*beat));
    },
    stream:null
  };
  navigator.mediaDevices.getUserMedia = async () => {
    await ctx.resume();
    window.fixture.stream = destination.stream.clone();
    return window.fixture.stream;
  };
}"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', default='http://127.0.0.1:8765/web/')
    parser.add_argument('--browser', choices=['chromium', 'webkit'], default='chromium')
    args = parser.parse_args()
    output = Path('artifacts/browser_test_results.json')
    checks, errors = [], []
    began = time.perf_counter()
    try:
        with sync_playwright() as p:
            browser_type = getattr(p, args.browser)
            options = dict(headless=True)
            if args.browser == 'chromium':
                options.update(executable_path='/usr/bin/chromium', args=['--no-sandbox', '--autoplay-policy=no-user-gesture-required'])
            browser = browser_type.launch(**options)
            context = browser.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, accept_downloads=True)
            page = context.new_page()
            page.on('pageerror', lambda e: errors.append(str(e)))
            page.goto(args.base_url)
            expect(page.locator('#record')).to_be_enabled()
            assert page.locator('#recommendation').is_hidden()
            assert page.locator('#start').is_disabled()
            checks.append('Initial mobile UI has no invented Sa, pitch or practice readiness')
            assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
            page.screenshot(path='artifacts/web_mobile_initial.png', full_page=True)
            checks.append('390-pixel layout fits the viewport')

            # Permission denial must be actionable and must not create results.
            page.evaluate("() => { navigator.mediaDevices.getUserMedia=async()=>{throw new DOMException('Denied','NotAllowedError')}; }")
            page.locator('#enable').click()
            expect(page.locator('#message')).to_contain_text('permission was denied')
            assert page.locator('#recommendation').is_hidden()
            checks.append('Microphone permission denial is actionable without fake success')

            page.evaluate(FIXTURE)
            page.evaluate('fixture.silence(true)')
            page.locator('#record').click()
            expect(page.locator('#message')).to_contain_text('inconclusive', timeout=7000)
            expect(page.locator('#stage')).to_have_text('SAMPLE 1 OF 3')
            checks.append('Actual silent audio through the worklet rejects calibration')
            page.evaluate('fixture.silence(false)')
            for stage, hz in enumerate([130, 195, 310]):
                page.evaluate('(hz)=>fixture.frequency(hz)', hz)
                page.locator('#record').click()
                expect(page.locator('#samples li').nth(stage)).not_to_contain_text('not recorded', timeout=7000)
            expect(page.locator('#recommendation')).to_be_visible()
            assert errors == [], errors
            checks.append('Three synthesized vowels traverse live capture/YIN and yield measured Sa')
            page.locator('#confirm').click()
            expect(page.locator('#setup')).to_be_visible()
            sa = float(re.search(r'([\d.]+) Hz', page.locator('#confirmed').inner_text()).group(1))
            page.locator('#bpm').fill('120')
            page.locator('#bpm').dispatch_event('change')
            assert page.locator('#start').is_disabled()
            page.locator('#reference').click()
            expect(page.locator('#start')).to_be_enabled(timeout=7000)
            checks.append('Complete genuine Web Audio reference playback gates practice')
            page.evaluate('(sa)=>fixture.frequency(sa)', sa)
            page.locator('#start').click()
            # Schedule inside the browser's animation clock, rather than after
            # Python/Playwright polling (which previously started ~280 ms late).
            page.evaluate("""(sa) => new Promise(resolve => {
              const frame=()=>{
                if(document.getElementById('expected').textContent.includes('1/5')) {
                  fixture.sequence(sa,.5);resolve();
                } else requestAnimationFrame(frame);
              };frame();
            })""", sa)
            expect(page.locator('#feedback')).to_have_text('Session complete', timeout=6000)
            score = float(re.search(r'([\d.]+)%', page.locator('#score').inner_text()).group(1))
            assert page.locator('#results tr').count() == 5
            with page.expect_download() as download_info:
                page.locator('#export').click()
            report_path = Path('artifacts/browser_synthetic_report.json')
            download_info.value.save_as(report_path)
            report = json.loads(report_path.read_text())
            assert report['observations'] and report['confirmed_sa_hz'] > 0
            assert report['diagnostics']['detector_processing_ms']['p95'] is not None
            assert score > 85, dict(score=score, notes=report['report']['notes'], diagnostics=report['diagnostics'])
            checks.append(f'Independent synthetic sung melody traverses microphone pipeline: {score}% pitch match')
            checks.append('Downloaded JSON contains raw observed pitches, calibrated Sa, targets, score and diagnostics')
            page.screenshot(path='artifacts/web_mobile_results.png', full_page=True)
            page.set_viewport_size({'width': 1024, 'height': 1366})
            assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
            page.screenshot(path='artifacts/web_tablet_results.png', full_page=True)
            checks.append('1024-pixel tablet results layout fits the viewport')

            page.locator('#again').click()
            page.locator('#reference').click()
            expect(page.locator('#start')).to_be_enabled(timeout=7000)
            page.evaluate('fixture.silence(true)')
            page.locator('#start').click()
            expect(page.locator('#feedback')).to_have_text('Session complete', timeout=8000)
            assert '0.0%' in page.locator('#score').inner_text()
            checks.append('Silent live-audio attempt scores zero with full missing-voice denominator')

            page.locator('#again').click()
            page.locator('#reference').click()
            expect(page.locator('#start')).to_be_enabled(timeout=7000)
            page.locator('#start').click()
            expect(page.locator('#practice')).to_be_visible()
            page.evaluate('fixture.stream.getAudioTracks()[0].dispatchEvent(new Event("ended"))')
            expect(page.locator('#message')).to_contain_text('disconnected')
            expect(page.locator('#score')).to_contain_text('Incomplete')
            checks.append('Device-ended event creates an explicitly incomplete result and releases capture')
            page.locator('#again').click()
            page.locator('#reference').click()
            expect(page.locator('#start')).to_be_enabled(timeout=7000)
            page.locator('#start').click()
            expect(page.locator('#practice')).to_be_visible()
            page.evaluate("""() => {
              Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});
              document.dispatchEvent(new Event('visibilitychange'));
            }""")
            expect(page.locator('#score')).to_contain_text('Incomplete')
            expect(page.locator('#limitations')).to_contain_text('backgrounded')
            checks.append('Background visibility event marks practice incomplete and stops capture')
            assert not errors, errors
            browser.close()
        result = dict(successful=True, checks=checks, page_errors=errors)
    except Exception as e:
        result = dict(successful=False, checks=checks, page_errors=errors, error=str(e))
        raise
    finally:
        output.parent.mkdir(exist_ok=True)
        output.write_text(json.dumps(dict(**result, seconds=time.perf_counter()-began,
            browser=args.browser, audio_source='EXPLICITLY SYNTHETIC oscillator MediaStream, not a real singer',
            hardware_tested=False, safari_device_tested=False), indent=2), encoding='utf-8')
        print(output.read_text())


if __name__ == '__main__':
    main()
