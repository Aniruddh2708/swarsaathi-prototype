// Dependency-free browser port of the desktop mathematics. No targets enter YIN.
export const cents = (f, sa) => 1200 * Math.log2(f / sa);
export const reliable = o => o?.voiced && Number.isFinite(o.frequency) && o.frequency > 0 &&
  Number.isFinite(o.quality) && o.quality >= .8 && o.quality <= 1;
export function quantile(values, q) {
  if (!values.length) return null;
  const a = [...values].sort((x,y) => x-y), p = (a.length-1)*q, i = Math.floor(p);
  return a[i] + (a[Math.min(i+1,a.length-1)]-a[i])*(p-i);
}
export const median = a => quantile(a,.5);
const clip = (v,l,h) => Math.max(l,Math.min(h,v));

function fft(re, im, inverse=false) {
  const n = re.length;
  for (let i=1,j=0;i<n;i++) {
    let bit=n>>1;
    for (;j&bit;bit>>=1) j^=bit;
    j^=bit;
    if (i<j) { [re[i],re[j]]=[re[j],re[i]]; [im[i],im[j]]=[im[j],im[i]]; }
  }
  for (let len=2;len<=n;len*=2) {
    const angle=(inverse?2:-2)*Math.PI/len, cr=Math.cos(angle), ci=Math.sin(angle);
    for (let start=0;start<n;start+=len) {
      let wr=1,wi=0;
      for (let j=0;j<len/2;j++) {
        const a=start+j,b=a+len/2, vr=re[b]*wr-im[b]*wi, vi=re[b]*wi+im[b]*wr;
        re[b]=re[a]-vr; im[b]=im[a]-vi; re[a]+=vr; im[a]+=vi;
        const next=wr*cr-wi*ci; wi=wr*ci+wi*cr; wr=next;
      }
    }
  }
  if (inverse) for (let i=0;i<n;i++) { re[i]/=n; im[i]/=n; }
}
export function differenceReference(x,maxLag) {
  const d=new Float64Array(maxLag+1);
  for (let lag=1;lag<=maxLag;lag++) for (let j=0;j<x.length-lag;j++) d[lag]+=(x[j]-x[j+lag])**2;
  return d;
}
export function differenceFFT(x,maxLag) {
  if (!Number.isInteger(maxLag)||maxLag<1||maxLag>=x.length) throw Error('Invalid YIN lag');
  let size=1; while (size<2*x.length-1) size*=2;
  const re=new Float64Array(size),im=new Float64Array(size),energy=new Float64Array(x.length+1);
  re.set(x);
  for (let j=0;j<x.length;j++) energy[j+1]=energy[j]+x[j]*x[j];
  fft(re,im);
  for (let j=0;j<size;j++) { re[j]=re[j]**2+im[j]**2; im[j]=0; }
  fft(re,im,true);
  const d=new Float64Array(maxLag+1);
  for (let lag=1;lag<=maxLag;lag++) d[lag]=Math.max(0,energy[x.length-lag]+energy[x.length]-energy[lag]-2*re[lag]);
  return d;
}
export function detect(samples, sampleRate, timestamp=0) {
  const empty={timestamp,frequency:null,quality:0,rms:0,voiced:false};
  if (!Number.isFinite(sampleRate)||sampleRate<8000||!Number.isFinite(timestamp)) throw Error('Invalid audio clock/rate');
  if (samples.length<8 || !samples.every(Number.isFinite)) return empty;
  const mean=samples.reduce((a,b)=>a+b,0)/samples.length;
  const x=Float64Array.from(samples,v=>v-mean);
  empty.rms=Math.sqrt(x.reduce((a,b)=>a+b*b,0)/x.length);
  if (empty.rms<.008) return empty;
  const minLag=Math.max(2,Math.floor(sampleRate/1100));
  const maxLag=Math.min(Math.ceil(sampleRate/65),Math.floor(x.length/2.5)-1);
  if (maxLag<=minLag+1) return empty;
  const d=differenceFFT(x,maxLag+1),cm=new Float64Array(d.length).fill(1);
  let sum=0;
  for (let lag=1;lag<d.length;lag++) { sum+=d[lag]; if (sum>Number.MIN_VALUE) cm[lag]=lag*d[lag]/sum; }
  let chosen=null;
  for (let lag=minLag;lag<=maxLag;lag++) if (cm[lag]<.15) {
    while (lag<maxLag && cm[lag+1]<cm[lag]) lag++;
    chosen=lag; break;
  }
  if (chosen===null) return {...empty,quality:clip(1-Math.min(...cm.slice(minLag,maxLag+1)),0,1)};
  const q=clip(1-cm[chosen],0,1),den=cm[chosen-1]-2*cm[chosen]+cm[chosen+1];
  const shift=Math.abs(den)<1e-15?0:clip(.5*(cm[chosen-1]-cm[chosen+1])/den,-1,1);
  const period=chosen+shift,frequency=sampleRate/period;
  if (q<.8||!Number.isFinite(frequency)||frequency<65||frequency>1100||x.length/period<2.5) return {...empty,quality:q};
  return {...empty,frequency,quality:q,voiced:true};
}

export class Smoother {
  constructor() { this.reset(); }
  reset() { this.values=[]; this.last=null; this.pending=null; this.sa=null; }
  process(o,sa) {
    if (this.sa!==sa || (this.last!==null && o.timestamp-this.last>.25)) this.reset();
    this.sa=sa;
    if (!reliable(o)) { this.pending=null; return null; }
    const value=cents(o.frequency,sa);
    if (this.values.length) {
      const delta=value-median(this.values);
      if (Math.abs(delta)>700 && (this.pending===null||Math.abs(value-this.pending)>80)) {
        this.pending=value; return null;
      }
      if (Math.abs(delta)>80) this.values=[];
    }
    this.pending=null; this.last=o.timestamp; this.values.push(value);
    if (this.values.length>3) this.values.shift();
    return median(this.values);
  }
}

function inconclusive(reason) { throw Error(`Calibration inconclusive — please retry. ${reason}`); }
export function summarizeSample(observations) {
  const rows=[...new Map(observations.filter(o=>Number.isFinite(o.timestamp)).map(o=>[o.timestamp,o])).values()]
    .sort((a,b)=>a.timestamp-b.timestamp);
  if (rows.length<20) inconclusive('Too few measured frames.');
  const start=rows[0].timestamp+.3,end=rows.at(-1).timestamp-.3,usable=end-start;
  if (usable<1) inconclusive('Recording too short.');
  const hop=Math.min(.05,median(rows.slice(1).map((o,i)=>o.timestamp-rows[i].timestamp)));
  const accepted=rows.filter(o=>o.timestamp>=start && o.timestamp<=end && reliable(o));
  let voiced=0,previous=-Infinity;
  for (const o of accepted) {
    const left=Math.max(start,o.timestamp-hop/2),right=Math.min(end,o.timestamp+hop/2);
    voiced+=Math.max(0,right-Math.max(left,previous)); previous=Math.max(previous,right);
  }
  if (accepted.length<20||voiced<1-1e-9||voiced/usable<.7-1e-9) inconclusive(
    `Reliable voice: ${voiced.toFixed(2)} s (${(100*voiced/usable).toFixed(0)}% of the usable clip; ${accepted.length} accepted frames). `+
    'Need at least 1.00 s, 70% coverage and 20 accepted frames. Hold one comfortable steady “Aa” throughout recording. A single good Hz reading is not enough.');
  const hz=median(accepted.map(o=>o.frequency)),errors=accepted.map(o=>cents(o.frequency,hz));
  const spread=quantile(errors,.9)-quantile(errors,.1);
  if (spread>80) inconclusive(`Pitch is unstable (${spread.toFixed(0)}-cent spread).`);
  return {median_hz:hz,stability_cents:1.4826*median(errors.map(x=>Math.abs(x-median(errors)))),
    spread_cents:spread,voiced_seconds:voiced,usable_seconds:usable,voiced_fraction:voiced/usable,accepted_frames:accepted.length};
}
export function noteName(hz) {
  const midi=Math.floor(69+12*Math.log2(hz/440)+.5);
  return ['C','C♯','D','D♯','E','F','F♯','G','G♯','A','A♯','B'][((midi%12)+12)%12]+(Math.floor(midi/12)-1);
}
export function recommendSa(summaries,library) {
  if (summaries.length!==3) inconclusive('Three samples are required.');
  for (const s of summaries) if (!Number.isFinite(s.median_hz)||s.median_hz<=0||s.voiced_seconds<1-1e-9||s.voiced_fraction<.7-1e-9||s.accepted_frames<20||s.spread_cents>80) inconclusive('Unreliable measurements.');
  const [low,middle,high]=summaries.map(s=>s.median_hz);
  if (cents(middle,low)<100) inconclusive(`Middle (${middle.toFixed(2)} Hz) is ${cents(middle,low).toFixed(0)} cents relative to Low (${low.toFixed(2)} Hz). Middle must be at least 100 cents (one semitone) higher. Change pitch, not loudness, and stay comfortable.`);
  if (cents(high,middle)<100) inconclusive(`High (${high.toFixed(2)} Hz) is ${cents(high,middle).toFixed(0)} cents relative to Middle (${middle.toFixed(2)} Hz). High must be at least 100 cents (one semitone) higher. Do not strain.`);
  const intervals=library.flatMap(a=>a.notes.map(n=>n.semitone_offset+12*n.octave_offset));
  const min=Math.min(...intervals),max=Math.max(...intervals),safeLow=low*2**(50/1200),safeHigh=high/2**(50/1200);
  const first=Math.ceil(69+12*Math.log2(safeLow/2**(min/12)/440)-1e-10);
  const last=Math.floor(69+12*Math.log2(safeHigh/2**(max/12)/440)+1e-10);
  const candidates=[];
  for (let midi=first;midi<=last;midi++) {
    const hz=440*2**((midi-69)/12); candidates.push({hz,cost:Math.abs(cents(hz*2**((min+max)/24),middle))});
  }
  if (!candidates.length) inconclusive(`No safe semitone-grid Sa fits the full exercise range. Your measured low-to-high span is ${(cents(high,low)/100).toFixed(1)} semitones; these exercises need at least ${max-min+1} including the 50-cent safety margin at each edge. Do not strain to extend your voice.`);
  const best=Math.min(...candidates.map(c=>c.cost)),near=candidates.filter(c=>c.cost<=best+5+1e-9);
  const hz=near[0].hz;
  return {sa_hz:hz,note_name:noteName(hz),low_hz:safeLow,high_hz:safeHigh,measured_hz:[low,middle,high],
    explanation:`Measured low/middle/high: ${[low,middle,high].map(f=>f.toFixed(2)).join(' / ')} Hz. `+
    `50-cent inward safety margins fit all ${min}–${max}-semitone exercises. `+
    (near.length>1?'Similar candidates are ambiguous; the lower safe tonic is selected within the five-cent ranking band. ':'The exercise midpoint is placed near your measured middle. ')+
    'Three short vowels give an approximate comfortable range, not a fixed personal Sa or an exhaustive vocal assessment.'};
}
export function buildTimeline(alankar,sa,bpm=72) {
  if (!Number.isFinite(sa)||sa<=0||!Number.isFinite(bpm)||bpm<30||bpm>180) throw Error('Invalid Sa or BPM');
  let time=0;
  const notes=alankar.notes.map((n,index)=>{
    if (!(n.beats>0)||!Number.isInteger(n.semitone_offset)||!Number.isInteger(n.octave_offset)) throw Error('Invalid note');
    const pitch=100*(n.semitone_offset+12*n.octave_offset),start=time;
    time+=n.beats*60/bpm;
    return {...n,index,start,end:time,cents:pitch,frequency:sa*2**(pitch/1200)};
  });
  if (!notes.length) throw Error('Empty exercise');
  return {alankar:alankar.name,sa_hz:sa,bpm,notes,duration:time};
}
export function scoringInterval(note,grace=.1) {
  const g=Math.min(Math.max(0,grace),.1,.2*(note.end-note.start)); return [note.start+g,note.end-g];
}
const swaras=['Sa','komal Re','Re','komal Ga','Ga','Ma','tivra Ma','Pa','komal Dha','Dha','komal Ni','Ni'];
export function compare(timeline,o) {
  const n=timeline.notes.find(n=>o.timestamp>=n.start&&o.timestamp<n.end);
  if (!n) return {status:'Transition / Unscored Boundary',error:null,note:null};
  const error=reliable(o)?cents(o.frequency,n.frequency):null;
  const semitone=reliable(o)?Math.floor(cents(o.frequency,timeline.sa_hz)/100+.5):null;
  const observed=semitone===null?null:`${swaras[((semitone%12)+12)%12]} (${Math.floor(semitone/12)>=0?'+':''}${Math.floor(semitone/12)} octave)`;
  const [start,end]=scoringInterval(n);
  let status;
  if (o.timestamp<start||o.timestamp>=end) status='Transition / Unscored Boundary';
  else if (error===null) status='No Reliable Voice';
  else if (Math.abs(error)<=30+1e-9) status='On Pitch';
  else if (semitone!==Math.round(n.cents/100)) status='Wrong Swara';
  else status=error>0?'Slightly High':'Slightly Low';
  return {status,error,observed,note:n};
}
export function scoreSession(timeline,observations) {
  const unique=new Map();
  for (const o of observations) if (Number.isFinite(o.timestamp)&&!unique.has(o.timestamp)) unique.set(o.timestamp,o);
  const rows=[...unique.values()].sort((a,b)=>a.timestamp-b.timestamp);
  let mismatch=false;
  const notes=timeline.notes.map(n=>{
    const [start,end]=scoringInterval(n),duration=end-start,count=Math.max(1,Math.ceil(duration/.02-1e-10));
    const width=duration/count,selected=new Map();
    for (const o of rows) if (o.timestamp>=start && o.timestamp<end) {
      const cell=Math.min(count-1,Math.floor((o.timestamp-start)/width)),mid=start+(cell+.5)*width;
      if (!selected.has(cell)||Math.abs(o.timestamp-mid)<Math.abs(selected.get(cell).timestamp-mid)) selected.set(cell,o);
    }
    const errors=[...selected.values()].filter(reliable).map(o=>Math.abs(cents(o.frequency,n.frequency)));
    const correct=errors.filter(e=>e<=30+1e-9).length;
    if (errors.length&&errors.filter(e=>e>50).length/errors.length>=.1) mismatch=true;
    return {index:n.index,swara:n.swara,accuracy:100*correct/count,eligible_duration:duration,
      valid_duration:errors.length*width,correct_duration:correct*width,missing_duration:(count-errors.length)*width,
      median_abs_cents:median(errors),attempted:errors.length>=.5*count,
      expected_intervals:count,valid_intervals:errors.length,correct_intervals:correct};
  });
  const limitations=['Fixed guided tempo; timing drift and pitch error cannot be uniquely distinguished.',
    '12-TET approximation and experimental ±30-cent pitch tolerance; not a validated Hindustani assessment.'];
  if (notes.some(n=>n.valid_duration<.8*n.eligible_duration)) limitations.push('Incomplete reliable voice: silence, rejected pitch or missing acquisition reduces the score.');
  if (mismatch) limitations.push('Pitch or timing mismatch detected; alignment confidence is limited.');
  return {overall_accuracy:notes.reduce((sum,n)=>sum+n.accuracy,0)/notes.length,notes,limitations,
    tolerance_cents:30,grace_seconds:.1,frame_seconds:.02};
}
export function synthesizeTimeline(timeline,rate=44100) {
  const output=new Float32Array(Math.round(timeline.duration*rate));
  for (const n of timeline.notes) {
    const first=Math.round(n.start*rate),last=Math.round(n.end*rate),fade=Math.min(Math.round(.01*rate),Math.floor((last-first)/2));
    for (let i=first;i<last;i++) {
      const envelope=fade>1?Math.min(1,(i-first)/(fade-1),(last-1-i)/(fade-1)):1;
      output[i]=.2*Math.max(0,envelope)*Math.sin(2*Math.PI*n.frequency*(i-first)/rate);
    }
  }
  return output;
}
