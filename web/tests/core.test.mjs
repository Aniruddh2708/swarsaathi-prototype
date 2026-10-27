import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {performance} from 'node:perf_hooks';
import {detect,differenceFFT,differenceReference,cents,Smoother,summarizeSample,recommendSa,buildTimeline,
  compare,scoreSession,synthesizeTimeline} from '../core.mjs';
const library=JSON.parse(readFileSync(new URL('../../data/alankars.json',import.meta.url)));
const tone=(hz,rate=44100,n=4096)=>Float32Array.from({length:n},(_,i)=>.25*Math.sin(2*Math.PI*hz*i/rate));
const timeline=buildTimeline(library[0],220,72);
const observations=(variant='correct')=>{
  const result=[];
  for (let t=.005;t<timeline.duration;t+=.01) {
    const n=timeline.notes.find(n=>t>=n.start&&t<n.end);
    const voiced=variant!=='silent' && !(variant==='missing' && n.index===2);
    result.push({timestamp:t,frequency:voiced?n.frequency*2**((variant==='wrong'?200:variant==='sharp'?40:variant==='flat'?-40:0)/1200):null,quality:voiced?.99:0,voiced});
  }
  return result;
};
function measured(hz) {
  const signal=tone(hz,44100,3*44100),rows=[];
  for (let start=0;start+4096<=signal.length;start+=512) rows.push(detect(signal.slice(start,start+4096),44100,(start+2048)/44100));
  return summarizeSample(rows);
}
test('FFT difference matches direct lag-dependent reference, including DC',()=>{
  const x=Float64Array.from({length:4096},(_,i)=>.4*Math.sin(i*.117)+.27*Math.cos(i*.017)+.3);
  const fast=differenceFFT(x,739),slow=differenceReference(x,739);
  assert.ok(Math.max(...fast.map((v,i)=>Math.abs(v-slow[i])))<1e-8);
});
test('44 clean-tone cases at two rates and windows are within ten cents',()=>{
  let worst=0;
  for (const rate of [44100,48000]) for (const n of [2048,4096]) for (const hz of [70,82.41,110,146.83,196,233.08,329.63,440,659.25,880,1000]) {
    const o=detect(tone(hz,rate,n),rate);assert.ok(o.voiced,`${hz}/${rate}/${n}`);worst=Math.max(worst,Math.abs(cents(o.frequency,hz)));
  }
  assert.ok(worst<10);console.log(`Clean synthetic maximum error: ${worst.toFixed(6)} cents`);
});
test('harmonics, moderate deterministic noise and DC offset retain F0',()=>{
  for (const hz of [82.41,196,440,880]) {
    let seed=42;
    const x=Float32Array.from({length:4096},(_,i)=>{
      seed=(1664525*seed+1013904223)>>>0;const p=2*Math.PI*hz*i/44100;
      return .2*Math.sin(p)+.1*Math.sin(2*p)+.05*Math.sin(3*p)+.02*(seed/2**32-.5)+.3;
    });
    const o=detect(x,44100);assert.ok(o.voiced);assert.ok(Math.abs(cents(o.frequency,hz))<10);
  }
});
test('silence, low volume, invalid samples and noise never become reliable tones',()=>{
  for (const x of [new Float32Array(4096),Float32Array.from(tone(220),v=>v*.001),new Float32Array(4096).fill(NaN)]) assert.equal(detect(x,44100).voiced,false);
  let seed=89;const noise=Float32Array.from({length:4096},()=>{seed=(1664525*seed+1013904223)>>>0;return seed/2**32-.5;});
  assert.equal(detect(noise,44100).voiced,false);
});
test('raw detector preserves octave transitions and smoother has no target',()=>{
  const a=detect(tone(220),44100,0),b=detect(tone(440),44100,.012),c=detect(tone(440),44100,.024);
  assert.ok(Math.abs(cents(b.frequency,a.frequency)-1200)<1);
  const s=new Smoother();s.process(a,220);assert.equal(s.process(b,220),null);assert.ok(Math.abs(s.process(c,220)-1200)<1);
  assert.equal(s.process({timestamp:.04,frequency:null,quality:0,voiced:false},220),null);
});
test('real DSP observations drive conservative calibration and octave-repeatable Sa',()=>{
  const summaries=[130.81,174.61,261.63].map(measured),doubled=[261.62,349.22,523.26].map(measured);
  const a=recommendSa(summaries,library),b=recommendSa(doubled,library);
  assert.ok(Math.abs(b.sa_hz/a.sa_hz-2)<1e-10);
  assert.ok(a.explanation.includes('ambiguous'));
  for (const exercise of library) for (const n of buildTimeline(exercise,a.sa_hz).notes) {
    assert.ok(n.frequency>=a.low_hz&&n.frequency<=a.high_hz);
  }
});
test('calibration rejects silent, short, unstable and narrow-range evidence',()=>{
  const silent=Array.from({length:250},(_,i)=>({timestamp:i*.012,frequency:null,voiced:false,quality:0}));
  assert.throws(()=>summarizeSample(silent),/Reliable voice: 0.00 s.*0%.*70%/);
  assert.throws(()=>summarizeSample(silent.slice(0,10)),/inconclusive/);
  const unstable=silent.map((o,i)=>({...o,frequency:i%2?150:200,quality:.99,voiced:true}));
  assert.throws(()=>summarizeSample(unstable),/unstable/);
  const summary=measured(220);
  assert.throws(()=>recommendSa([summary,{...summary,median_hz:240},{...summary,median_hz:260}],library),/inconclusive/);
});
test('isolated good pitch readings do not imply a sustained accepted sample',()=>{
  const rows=Array.from({length:250},(_,i)=>({timestamp:i*.012,
    frequency:i===100?121.1:null,quality:i===100?.9:0,voiced:i===100}));
  assert.throws(()=>summarizeSample(rows),/Reliable voice: 0.01 s.*1 accepted frames/);
});
test('measured close low/middle samples explain rejection despite good coverage',()=>{
  const summaries=[221.90,223.57,321.32].map(measured);
  assert.ok(summaries.every(s=>s.voiced_fraction>.99));
  assert.throws(()=>recommendSa(summaries,library),/Middle.*13 cents.*100 cents/);
  const ordered=[summaries[0],{...summaries[1],median_hz:260},summaries[2]];
  assert.throws(()=>recommendSa(ordered,library),/span is 6.4 semitones.*at least 8/);
});
test('perfect, wrong, sharp, flat, missed and silent tracks have transparent scores',()=>{
  for (const [variant,expected] of [['correct',100],['wrong',0],['sharp',0],['flat',0],['missing',80],['silent',0]])
    assert.ok(Math.abs(scoreSession(timeline,observations(variant)).overall_accuracy-expected)<1e-9,variant);
});
test('stale and duplicate observations cannot fill missing intervals',()=>{
  const one=[{timestamp:.2,frequency:220,voiced:true,quality:1}];
  const a=scoreSession(timeline,one),b=scoreSession(timeline,Array(100).fill(one[0]));
  assert.deepEqual(a,b);assert.ok(a.overall_accuracy<1);
});
test('small transition grace is bounded and late singing loses score',()=>{
  const track=observations().map(o=>({...o,timestamp:o.timestamp+.3}));
  const report=scoreSession(timeline,track);assert.ok(report.overall_accuracy<90);
  assert.ok(report.limitations.some(s=>s.includes('alignment')));
});
test('comparison keeps raw cents, note identity, silence and octave separate',()=>{
  assert.equal(compare(timeline,{timestamp:.2,frequency:220,quality:1,voiced:true}).status,'On Pitch');
  assert.equal(compare(timeline,{timestamp:.2,frequency:220*2**(40/1200),quality:1,voiced:true}).status,'Slightly High');
  assert.equal(compare(timeline,{timestamp:.2,frequency:440,quality:1,voiced:true}).status,'Wrong Swara');
  assert.equal(compare(timeline,{timestamp:.2,frequency:null,quality:0,voiced:false}).status,'No Reliable Voice');
  assert.equal(compare(timeline,{timestamp:.02,frequency:220,quality:1,voiced:true}).status,'Transition / Unscored Boundary');
});
test('reference audio, target timing and shifted Sa use one shared timeline',()=>{
  for (const a of library) {
    const t=buildTimeline(a,196,72),shifted=buildTimeline(a,392,72),audio=synthesizeTimeline(t);
    assert.equal(audio.length,Math.round(t.duration*44100));
    for (const n of t.notes) {
      assert.equal(shifted.notes[n.index].frequency/n.frequency,2);
      const start=Math.round((n.start+.15)*44100),o=detect(audio.slice(start,start+4096),44100);
      assert.ok(o.voiced);assert.ok(Math.abs(cents(o.frequency,n.frequency))<10);
    }
  }
});
test('AudioWorklet bounded handoff copies real samples, timestamps centers and mutes output',()=>{
  let Processor;
  const sent=[],sandbox={Float32Array,Math,sampleRate:48000,currentFrame:0,
    AudioWorkletProcessor:class {constructor(){this.port={postMessage:m=>sent.push(m)};}},
    registerProcessor:(_name,type)=>{Processor=type;}};
  vm.runInNewContext(readFileSync(new URL('../capture-worklet.js',import.meta.url),'utf8'),sandbox);
  const p=new Processor({processorOptions:{windowSize:2048}}),out=[new Float32Array(128).fill(1)];
  for (let i=0;i<40;i++) {sandbox.currentFrame=i*128;p.process([[Float32Array.from({length:128},(_,j)=>(i*128+j)/10000)]],[out]);}
  assert.equal(sent.length,3);assert.equal(p.dropped,2048);assert.ok(out[0].every(x=>x===0));
  const first=new Float32Array(sent[0].samples);assert.equal(first.length,2048);assert.ok(Math.abs(first[2047]-.2047)<1e-6);
  assert.equal(sent[0].timestamp,(2047-2047/2)/48000);
  p.port.onmessage();sandbox.currentFrame=5120;
  for (let i=0;i<4;i++) {sandbox.currentFrame=5120+i*128;p.process([[new Float32Array(128)]],[out]);}
  assert.equal(sent.length,4);assert.equal(sent[3].droppedSamples,2048);
});
test('synthetic audio-to-score pipeline penalizes wrong or missing singing',()=>{
  const sa=recommendSa([130,195,310].map(measured),library).sa_hz,t=buildTimeline(library[0],sa);
  const independent=[0,2,4,2,0],rate=44100,beat=60/72;
  for (const [variant,expected] of [['correct',100],['missing',80],['wrong',0],['silent',0]]) {
    const signal=new Float32Array(Math.round(5*beat*rate));
    for (let i=0;i<signal.length;i++) {
      const note=Math.min(4,Math.floor(i/rate/beat));
      if (variant==='silent'||variant==='missing'&&note===2) continue;
      const hz=sa*2**((independent[note]+(variant==='wrong'?2:0))/12),phase=2*Math.PI*hz*i/rate;
      signal[i]=.22*Math.sin(phase)+.08*Math.sin(2*phase)+.04*Math.sin(3*phase);
    }
    const rows=[];for (let start=0;start+4096<=signal.length;start+=512) rows.push(detect(signal.slice(start,start+4096),rate,(start+2048)/rate));
    assert.ok(Math.abs(scoreSession(t,rows).overall_accuracy-expected)<2,variant);
  }
});
test('detector-only synthetic timing measurement, not device latency',()=>{
  const signal=tone(220),times=[];
  for (let i=0;i<120;i++) {const start=performance.now();detect(signal,44100);if(i>=20) times.push(performance.now()-start);}
  times.sort((a,b)=>a-b);console.log(`JS detector-only synthetic timing: median ${times[50].toFixed(3)} ms, p95 ${times[95].toFixed(3)} ms`);
});
