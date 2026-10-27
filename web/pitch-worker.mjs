import {detect} from './core.mjs';
self.onmessage=({data})=>{
  try {
    const began=performance.now();
    const observation=detect(new Float32Array(data.samples),data.sampleRate,data.timestamp);
    self.postMessage({observation,processingMs:performance.now()-began,droppedSamples:data.droppedSamples,frames:data.frames});
  } catch(e) { self.postMessage({error:e.message}); }
};
