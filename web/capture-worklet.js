// Audio rendering thread: bounded window copies only; YIN runs in a Worker.
class CaptureProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.size=options.processorOptions.windowSize;
    this.ring=new Float32Array(this.size); this.position=0; this.filled=0; this.hop=0;
    this.credit=3; this.dropped=0; this.frames=0;
    this.port.onmessage=()=>{this.credit=Math.min(3,this.credit+1);};
  }
  process(inputs,outputs) {
    for (const output of outputs) for (const channel of output) channel.fill(0);
    const channel=inputs[0]?.[0];
    if (!channel) return true;
    for (let i=0;i<channel.length;i++) {
      this.ring[this.position]=channel[i]; this.position=(this.position+1)%this.size;
      this.filled=Math.min(this.size,this.filled+1); this.hop++;
      if (this.hop===512) {
        this.hop=0;
        if (this.filled<this.size) continue;
        this.frames++;
        if (!this.credit) { this.dropped+=512; continue; }
        this.credit--;
        const window=new Float32Array(this.size);
        window.set(this.ring.subarray(this.position)); window.set(this.ring.subarray(0,this.position),this.size-this.position);
        this.port.postMessage({samples:window.buffer,sampleRate,
          timestamp:(currentFrame+i-(this.size-1)/2)/sampleRate,
          droppedSamples:this.dropped,frames:this.frames},[window.buffer]);
      }
    }
    return true;
  }
}
registerProcessor('swarsaathi-capture',CaptureProcessor);
