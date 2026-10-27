import {AudioEngine} from './audio.mjs';
import {cents,reliable,quantile,summarizeSample,recommendSa,buildTimeline,compare,scoreSession,synthesizeTimeline,Smoother} from './core.mjs';
const $=id=>document.getElementById(id);
const prompts=[['Comfortable low','Sing a comfortably low “Aa” for three seconds. Do not strain.'],
  ['Comfortable middle','Sing “Aa” at your natural, comfortable middle pitch for three seconds.'],
  ['Comfortable high','Sing a comfortably high “Aa” for three seconds without forcing your voice.']];
const state={mode:'idle',library:[],stage:0,summaries:[],calibration:[],stageRows:[],recommendation:null,sa:null,
  timeline:null,referenceComplete:false,observations:[],trace:[],processing:[],ages:[],report:null,dropped:0,frames:0,lastPitch:null,export:null};
const smoother=new Smoother();
const engine=new AudioEngine(onPitch,audioError);
let timer=null,lastScore=-Infinity;
function message(text,error=false) {$('message').textContent=text;$('message').classList.toggle('error',error);}
function show(view) {
  ['calibration','setup','practice'].forEach((id,i)=>{$(id).hidden=id!==view;$(`step${i+1}`).classList.toggle('current',id===view);});
}
function controls() {
  const active=['opening','calibration','practice','playback'].includes(state.mode);
  for (const id of ['enable','device','window','retry','playSa','confirm','exercise','bpm','reference','back']) $(id).disabled=active;
  $('enable').disabled=active||!state.library.length;
  $('record').disabled=active||state.stage>=3||!state.library.length;
  $('start').disabled=active||!state.referenceComplete;
  $('stop').hidden=!active&&state.mode!=='monitor';
  $('again').hidden=state.mode!=='results'; $('export').hidden=state.mode!=='results'; $('finish').hidden=state.mode!=='results';
}
function stageUI() {
  const stage=Math.min(state.stage,2);
  $('stage').textContent=state.stage<3?`SAMPLE ${state.stage+1} OF 3`:'YOUR MEASURED RECOMMENDATION';
  $('stageName').textContent=state.stage<3?prompts[stage][0]:'Listen, then confirm';
  $('instruction').textContent=state.stage<3?prompts[stage][1]:'Review the proposed Sa and range. Listen to the tone, then confirm if comfortable.';
  $('record').textContent=state.stage<3?`Record ${prompts[stage][0].toLowerCase()} · 3 seconds`:'Samples complete';
  $('recommendation').hidden=!state.recommendation;
  controls();
}
function reset() {
  stopAudio();Object.assign(state,{mode:'idle',stage:0,summaries:[],calibration:[],stageRows:[],recommendation:null,sa:null,referenceComplete:false,report:null});
  $('samples').replaceChildren(...['Low','Middle','High'].map(name=>{const li=document.createElement('li');li.textContent=`${name}: not recorded`;return li;}));
  $('recordProgress').value=0;stageUI();show('calibration');message('Record three new comfortable samples. Never strain to reach a note.');
}
function stopAudio() {
  engine.stopPlayback();engine.close();clearInterval(timer);timer=null;
  if (state.mode==='playback') state.referenceComplete=false;
  state.mode='idle';$('level').value=0;controls();
}
function describeError(error) {
  if (error.name==='NotAllowedError') return 'Microphone permission was denied. Allow microphone access for this website in Safari, then tap Enable microphone.';
  if (error.name==='NotFoundError') return 'No microphone was found. Check the device microphone or connected headset.';
  return error.message||String(error);
}
function audioError(error) {
  if (state.mode==='practice') finish(true,describeError(error));
  else {stopAudio();message(describeError(error),true);}
}
async function open(mode) {
  clearInterval(timer);timer=null;engine.stopPlayback();state.mode='opening';controls();
  try {
    const opened=await engine.open(Number($('window').value),$('device').value);
    if (!opened) return false;
    await refreshDevices();
    if (!engine.stream) return false;
    state.mode=mode;state.lastPitch=null;controls();
    timer=setInterval(tick,33);return true;
  } catch(error) {audioError(error);return false;}
}
async function refreshDevices() {
  try {
    const selected=$('device').value,devices=(await navigator.mediaDevices.enumerateDevices()).filter(d=>d.kind==='audioinput');
    $('device').replaceChildren(new Option('Default microphone',''),...devices.map((d,i)=>new Option(d.label||`Microphone ${i+1}`,d.deviceId)));
    if ([...$('device').options].some(o=>o.value===selected)) $('device').value=selected;
  } catch { /* Enumeration is optional; the permission-selected microphone still works. */ }
}
function onPitch(data) {
  const o=data.observation;
  state.lastPitch=o.timestamp; state.dropped=data.droppedSamples;state.frames=data.frames;
  $('level').value=o.rms;
  $('detected').textContent=reliable(o)?`${o.frequency.toFixed(1)} Hz · quality ${o.quality.toFixed(2)}`:'No reliable voice';
  if (state.mode==='calibration' && o.timestamp>=state.recordStart && o.timestamp<=state.recordStart+3) state.stageRows.push(o);
  if (state.mode!=='practice') return;
  const t=o.timestamp-state.sessionStart;
  if (t<0||t>=state.timeline.duration) return;
  const observation={...o,timestamp:t};state.observations.push(observation);
  const value=smoother.process(o,state.sa);
  if (state.trace.length&&t-state.trace.at(-1).t>.05) state.trace.push({t:(state.trace.at(-1).t+t)/2,c:null});
  state.trace.push({t,c:value});
  state.processing.push(data.processingMs);state.ages.push(Math.max(0,engine.time-o.timestamp)*1000);
  const comparison=compare(state.timeline,observation);
  $('feedback').textContent=comparison.status;
  $('actual').textContent=reliable(o)?`${comparison.observed||'—'} · ${o.frequency.toFixed(1)} Hz`:'No reliable voice';
  $('deviation').textContent=comparison.error!==null?`Raw deviation: ${comparison.error>=0?'+':''}${comparison.error.toFixed(1)} cents`:'Raw deviation unavailable';
}
async function record() {
  if (state.stage>=3) return;
  state.stageRows=[];
  if (!await open('calibration')) return;
  state.recordStart=engine.time;
  message(`Recording ${prompts[state.stage][0].toLowerCase()}. Sing steadily for three seconds.`);
}
function finishSample() {
  engine.close();clearInterval(timer);state.mode='idle';
  try {
    const summary=summarizeSample(state.stageRows);
    state.summaries.push(summary);state.calibration.push(state.stageRows);
    $('samples').children[state.stage].textContent=`${['Low','Middle','High'][state.stage]}: ${summary.median_hz.toFixed(2)} Hz · stability ${summary.stability_cents.toFixed(1)} cents · ${(summary.voiced_fraction*100).toFixed(0)}% reliable voice`;
    state.stage++;
    if (state.stage===3) {
      state.recommendation=recommendSa(state.summaries,state.library);
      $('saName').textContent=`Suggested Sa: ${state.recommendation.note_name} · ${state.recommendation.sa_hz.toFixed(2)} Hz`;
      $('range').textContent=`Conservative comfortable range: ${state.recommendation.low_hz.toFixed(1)}–${state.recommendation.high_hz.toFixed(1)} Hz`;
      $('explanation').textContent=state.recommendation.explanation;
      message('Listen to the proposed Sa, then confirm or retry calibration.');
    } else message('Sample accepted. Continue with the next comfortable pitch.');
  } catch(e) {message(describeError(e)+(state.stage===3?' Tap Retry calibration for a new set of samples.':''),true);}
  stageUI();
}
function selection() {
  engine.stopPlayback();state.referenceComplete=false;
  const bpm=Number($('bpm').value);
  if (!Number.isFinite(bpm)||bpm<40||bpm>120) {message('Choose a tempo between 40 and 120 BPM.',true);state.timeline=null;controls();return;}
  const alankar=state.library[Number($('exercise').value)];
  $('sequence').textContent=alankar.notes.map(n=>n.swara).join(' → ');
  if (state.sa) state.timeline=buildTimeline(alankar,state.sa,bpm);
  $('referenceStatus').textContent='Listen to the complete reference before starting.';controls();
}
async function play(isSa=false) {
  const timeline=isSa?buildTimeline({name:'Sa',notes:[{swara:'Sa',semitone_offset:0,octave_offset:0,beats:2}]},state.recommendation.sa_hz,60):state.timeline;
  if (!timeline) {message('Choose a valid BPM first.',true);return;}
  state.referenceComplete=false;state.mode='playback';controls();
  message(isSa?'Playing the suggested Sa. Microphone capture is stopped.':'Playing the reference. Listen through the final note.');
  try {
    const completed=await engine.play(synthesizeTimeline(timeline));
    if (state.mode!=='playback') return;
    state.mode='idle';
    if (!isSa) {state.referenceComplete=completed;$('referenceStatus').textContent=completed?'Reference complete. Ready for practice.':'Playback stopped. Replay the complete reference.';}
    message(completed?'Reference complete.': 'Reference interrupted.');controls();
  } catch(e) {audioError(e);}
}
async function start() {
  if (!state.referenceComplete||!state.sa||!state.timeline) return;
  Object.assign(state,{observations:[],trace:[],processing:[],ages:[],dropped:0,frames:0,report:null});smoother.reset();
  if (!await open('practice')) return;
  state.sessionStart=engine.time+3*60/state.timeline.bpm;lastScore=-Infinity;
  $('practiceTitle').textContent=`${state.timeline.alankar} · Sa ${state.sa.toFixed(2)} Hz · ${state.timeline.bpm} BPM`;
  $('limitations').textContent='Fixed guided tempo. Follow the expected note and keep Safari visible.';
  $('improvements').textContent='';$('results').replaceChildren();$('metrics').textContent='';$('deviation').textContent='Raw deviation unavailable';
  $('actual').textContent='Waiting for your voice';$('feedback').textContent='Count-in';$('score').textContent='Pitch-match progress pending';
  show('practice');message('Follow the three-beat visual count-in, then sing one repetition.');draw(0);
}
function table(report,elapsed=null) {
  $('results').replaceChildren(...report.notes.map(n=>{
    const tr=document.createElement('tr'),target=state.timeline.notes[n.index];
    const pending=elapsed!==null&&elapsed<target.start,current=elapsed!==null&&elapsed>=target.start&&elapsed<target.end;
    tr.classList.toggle('current',current);
    const cells=[`${n.index+1}. ${n.swara}${pending?' · pending':current?' · current':''}`,pending?'—':`${n.accuracy.toFixed(1)}%`,
      pending?'—':`${(100*n.valid_duration/n.eligible_duration).toFixed(0)}%`,pending?'—':`${n.missing_duration.toFixed(2)} s`,
      pending||n.median_abs_cents===null?'—':`${n.median_abs_cents.toFixed(1)} cents`];
    for (const text of cells) {const td=document.createElement('td');td.textContent=text;tr.append(td);}return tr;
  }));
}
function tick() {
  if (engine.context?.state!=='running' && ['practice','calibration','monitor'].includes(state.mode)) {audioError(Error('Audio was interrupted. Keep Safari visible and retry the attempt.'));return;}
  if (state.mode==='calibration') {
    const elapsed=engine.time-state.recordStart;$('recordProgress').value=Math.min(3,elapsed);
    if (elapsed>3+.5*Number($('window').value)/engine.sampleRate+.15) finishSample();
  }
  if (state.mode!=='practice') return;
  const elapsed=engine.time-state.sessionStart;
  if (elapsed<0) {$('feedback').textContent=`Count-in · ${Math.ceil(-elapsed*state.timeline.bpm/60)}`;$('expected').textContent='Prepare to sing Sa';return;}
  const note=state.timeline.notes.find(n=>elapsed>=n.start&&elapsed<n.end);
  if (note) $('expected').textContent=`${note.index+1}/${state.timeline.notes.length} · ${note.swara} · ${note.frequency.toFixed(1)} Hz`;
  if (state.lastPitch===null||engine.time-state.lastPitch>.25) {$('feedback').textContent='No Reliable Voice';$('actual').textContent='No fresh microphone pitch';}
  draw(Math.min(elapsed,state.timeline.duration));
  if (elapsed-lastScore>.2) {const report=scoreSession(state.timeline,state.observations);table(report,elapsed);$('score').textContent=`Pitch-match progress: ${report.overall_accuracy.toFixed(1)}% of full exercise (unfinished notes included)`;lastScore=elapsed;}
  if (elapsed>state.timeline.duration+.5*Number($('window').value)/engine.sampleRate+.15) finish();
}
function finish(incomplete=false,reason='') {
  if (state.mode!=='practice') return;
  engine.close();clearInterval(timer);engine.stopPlayback();state.mode='results';
  state.report=scoreSession(state.timeline,state.observations);
  if (incomplete) state.report.limitations.push('Session incomplete; remaining expected voice counts as missing.');
  if (reason) state.report.limitations.push(reason);
  if (state.dropped) state.report.limitations.push('Audio frames were dropped. Inspect acquisition counters before interpreting this attempt.');
  $('score').textContent=`${incomplete?'Incomplete attempt · ':''}Overall Pitch Accuracy: ${state.report.overall_accuracy.toFixed(1)}%`;
  $('feedback').textContent=incomplete?'Attempt interrupted':'Session complete';table(state.report);draw(state.timeline.duration);
  $('limitations').textContent=state.report.limitations.join(' ');
  const needs=state.report.notes.filter(n=>n.accuracy<80).map(n=>`${n.index+1}. ${n.swara} (${n.accuracy.toFixed(0)}%)`);
  $('improvements').textContent=needs.length?`Needs practice: ${needs.join(', ')}`:'No note below 80% in this attempt.';
  const diagnostics={sample_rate:engine.sampleRate,window_samples:Number($('window').value),hop_samples:512,
    audio_track_settings:engine.settings,
    dropped_samples:state.dropped,analysis_frames:state.frames,
    detector_processing_ms:{median:quantile(state.processing,.5),p95:quantile(state.processing,.95)},
    frame_center_to_main_thread_ms:{median:quantile(state.ages,.5),p95:quantile(state.ages,.95)}};
  $('metrics').textContent=`Analyzed frames: ${state.frames}; dropped samples: ${state.dropped}. Processing timings in the saved report exclude acoustic and visible response latency.`;
  state.export={created_utc:new Date().toISOString(),source:'device_microphone',incomplete,
    calibration:{recommendation:state.recommendation,samples:state.summaries,observations:state.calibration},
    confirmed_sa_hz:state.sa,timeline:state.timeline,observations:state.observations,report:state.report,diagnostics,
    limitations:'Browser capture has not been independently validated on this iPad/iPhone. Synthetic accuracy is not human-vocal accuracy.'};
  controls();message(reason||'Attempt complete. Review each note, then practise again or finish.',!!reason);
}
function draw(elapsed=0) {
  if (!state.timeline||$('practice').hidden) return;
  const canvas=$('graph'),rect=canvas.getBoundingClientRect(),ratio=window.devicePixelRatio||1;
  const w=Math.max(280,rect.width),h=rect.height;
  if (canvas.width!==Math.round(w*ratio)||canvas.height!==Math.round(h*ratio)) {canvas.width=Math.round(w*ratio);canvas.height=Math.round(h*ratio);}
  const ctx=canvas.getContext('2d');ctx.setTransform(ratio,0,0,ratio,0,0);ctx.clearRect(0,0,w,h);
  const pitches=state.trace.filter(p=>p.c!==null&&Number.isFinite(p.c)).map(p=>p.c);
  const low=Math.floor((Math.min(0,...state.timeline.notes.map(n=>n.cents),...pitches)-100)/100)*100;
  const high=Math.ceil((Math.max(...state.timeline.notes.map(n=>n.cents),...pitches)+100)/100)*100;
  const x=t=>52+(w-68)*t/state.timeline.duration,y=c=>16+(h-52)*(high-c)/(high-low);
  ctx.font='11px system-ui';ctx.lineWidth=1;
  for (let c=low;c<=high;c+=high-low>1600?400:200) {ctx.strokeStyle='#29434b';ctx.beginPath();ctx.moveTo(52,y(c));ctx.lineTo(w-16,y(c));ctx.stroke();ctx.fillStyle='#b4c9c9';ctx.fillText(String(c),8,y(c)+4);}
  ctx.fillStyle='#b4c9c9';ctx.fillText('cents',8,12);
  for (let t=0;t<=state.timeline.duration;t+=Math.max(1,Math.ceil(state.timeline.duration/8))) ctx.fillText(`${t}s`,x(t)-5,h-12);
  ctx.strokeStyle='#b3c2bb';ctx.lineWidth=2;ctx.beginPath();
  for (const [i,n] of state.timeline.notes.entries()) {if (!i) ctx.moveTo(x(n.start),y(n.cents));else ctx.lineTo(x(n.start),y(n.cents));ctx.lineTo(x(n.end),y(n.cents));}ctx.stroke();
  ctx.strokeStyle='#37dbc0';ctx.lineWidth=2;ctx.beginPath();let gap=true;
  for (const p of state.trace) {if (p.c===null||!Number.isFinite(p.c)) {gap=true;continue;}if (gap) ctx.moveTo(x(p.t),y(p.c));else ctx.lineTo(x(p.t),y(p.c));gap=false;}ctx.stroke();
  ctx.strokeStyle='#dfb367';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(x(elapsed),16);ctx.lineTo(x(elapsed),h-36);ctx.stroke();
}
$('enable').onclick=async()=>{if (state.mode==='monitor') {stopAudio();message('Microphone stopped.');}else if (await open('monitor')) message('Microphone enabled. Speak or sing and check the input level.');};
$('record').onclick=record;$('retry').onclick=reset;$('playSa').onclick=()=>play(true);
$('confirm').onclick=()=>{if (!state.recommendation) return;stopAudio();state.sa=state.recommendation.sa_hz;$('confirmed').textContent=`Confirmed Sa: ${state.recommendation.note_name} · ${state.sa.toFixed(2)} Hz`;show('setup');selection();message('Choose an Alankar and listen to its reference.');};
$('exercise').onchange=selection;$('bpm').onchange=selection;$('reference').onclick=()=>play();$('start').onclick=start;
$('back').onclick=()=>{stopAudio();show('calibration');stageUI();};
$('stop').onclick=()=>{if (state.mode==='practice') finish(true,'Stopped before the full exercise completed.');else {stopAudio();stageUI();message('Audio stopped. Incomplete samples were not accepted.');}};
$('again').onclick=()=>{stopAudio();state.referenceComplete=false;show('setup');selection();message('Listen to the reference again before the next attempt.');};
$('finish').onclick=()=>{stopAudio();show('setup');selection();message('Finished. Microphone and playback are stopped.');};
$('export').onclick=()=>{if (!state.export) return;const url=URL.createObjectURL(new Blob([JSON.stringify(state.export,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=`swarsaathi-${new Date().toISOString().replace(/[:.]/g,'-')}.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),60000);};
document.addEventListener('visibilitychange',()=>{if (document.hidden) {if (state.mode==='practice') finish(true,'Safari was backgrounded or the screen locked. Keep it visible and retry.');else {stopAudio();message('Audio stopped while Safari was hidden. Tap a recording or playback button to continue.');}}});
window.addEventListener('pagehide',()=>stopAudio());window.addEventListener('resize',()=>draw(state.mode==='practice'?engine.time-state.sessionStart:state.timeline?.duration||0));
try {
  const response=await fetch('../data/alankars.json');if (!response.ok) throw Error(`Exercise library failed to load (${response.status})`);
  state.library=await response.json();if (!state.library.length) throw Error('No exercises are available.');
  $('exercise').replaceChildren(...state.library.map((a,i)=>new Option(a.name,i)));stageUI();selection();
  message(window.isSecureContext?'Ready. Enable the microphone, then record your comfortable low sample.':'Open the HTTPS published page to enable the microphone.',!window.isSecureContext);
} catch(e) {message(describeError(e),true);}
