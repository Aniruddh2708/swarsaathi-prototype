export class AudioEngine {
  constructor(onPitch,onError) {
    this.onPitch=onPitch; this.onError=onError; this.generation=0;
    this.context=null; this.stream=null; this.output=null; this.worker=null; this.capture=null; this.workletLoaded=false;
  }
  async unlock() {
    if (!window.isSecureContext) throw Error('Microphone access requires HTTPS. Open the published site in Safari.');
    const Audio=window.AudioContext||window.webkitAudioContext;
    if (!Audio||!navigator.mediaDevices?.getUserMedia||!window.AudioWorkletNode||!window.Worker) throw Error('This browser lacks required audio features. Use an updated Safari on iPad/iPhone.');
    if (!this.context) {
      this.context=new Audio({latencyHint:'interactive'});
      this.context.onstatechange=()=>{
        if (this.context.state!=='running' && (this.stream||this.output)) this.onError(Error('Audio was interrupted. Keep Safari visible, then retry.'));
      };
    }
    await this.context.resume();
    if (this.context.state!=='running') throw Error('Audio is paused. Tap the button again to enable it.');
  }
  async open(windowSize=4096,deviceId='') {
    this.close(); const generation=this.generation;
    await this.unlock();
    const stream=await navigator.mediaDevices.getUserMedia({video:false,audio:{channelCount:1,
      echoCancellation:false,noiseSuppression:false,autoGainControl:false,
      ...(deviceId?{deviceId:{exact:deviceId}}:{})}});
    if (generation!==this.generation) {stream.getTracks().forEach(t=>t.stop()); return false;}
    this.stream=stream;
    this.settings=stream.getAudioTracks()[0]?.getSettings?.()||{};
    try {
      if (!this.workletLoaded) {
        await this.context.audioWorklet.addModule(new URL('./capture-worklet.js',import.meta.url));
        this.workletLoaded=true;
      }
      if (generation!==this.generation) return false;
      this.capture=new AudioWorkletNode(this.context,'swarsaathi-capture',{numberOfInputs:1,numberOfOutputs:1,
        outputChannelCount:[1],processorOptions:{windowSize}});
      this.worker=new Worker(new URL('./pitch-worker.mjs',import.meta.url),{type:'module'});
      this.source=this.context.createMediaStreamSource(stream);
      this.mute=this.context.createGain(); this.mute.gain.value=0;
      this.source.connect(this.capture); this.capture.connect(this.mute); this.mute.connect(this.context.destination);
      this.capture.port.onmessage=({data})=>{if (generation===this.generation) this.worker?.postMessage(data,[data.samples]);};
      this.worker.onmessage=({data})=>{
        if (generation!==this.generation) return;
        this.capture?.port.postMessage('credit');
        if (data.error) this.onError(Error(data.error)); else this.onPitch(data);
      };
      this.worker.onerror=e=>{if (generation===this.generation) this.onError(Error(`Pitch worker failed: ${e.message}`));};
      this.capture.onprocessorerror=()=>this.onError(Error('Microphone audio processing stopped. Retry the attempt.'));
      for (const track of stream.getAudioTracks()) track.onended=()=>{
        if (generation===this.generation) this.onError(Error('Microphone disconnected. Reconnect it and retry.'));
      };
      return true;
    } catch(e) {this.close();throw e;}
  }
  close() {
    this.generation++;
    this.stream?.getTracks().forEach(t=>{t.onended=null;t.stop();}); this.stream=null;
    this.source?.disconnect(); this.capture?.disconnect(); this.mute?.disconnect();
    this.worker?.terminate(); this.worker=null; this.capture=null; this.source=null; this.mute=null;
  }
  stopPlayback() {
    if (this.output) { this.output.onended=null; try {this.output.stop();} catch {} this.output.disconnect(); }
    this.output=null;
    this.playbackResolve?.(false); this.playbackResolve=null;
  }
  async play(samples,rate=44100) {
    this.close(); this.stopPlayback(); await this.unlock();
    const buffer=this.context.createBuffer(1,samples.length,rate); buffer.copyToChannel(samples,0);
    const output=this.context.createBufferSource(); output.buffer=buffer; output.connect(this.context.destination);
    this.output=output;
    return await new Promise((resolve,reject)=>{
      this.playbackResolve=resolve;
      output.onended=()=>{this.output=null;this.playbackResolve=null;output.disconnect();resolve(true);};
      try {output.start();} catch(e) {this.stopPlayback();reject(e);}
    });
  }
  get time() {return this.context?.currentTime??0;}
  get sampleRate() {return this.context?.sampleRate??null;}
}
