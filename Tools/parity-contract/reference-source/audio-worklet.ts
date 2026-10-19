import { createPitchDetector, FRAME_SIZE, HOP_SIZE } from './pitch';

declare const currentTime: number;
declare const sampleRate: number;
declare class AudioWorkletProcessor { port: MessagePort }
declare function registerProcessor(name: string, processor: typeof AudioWorkletProcessor): void;

class TunerProcessor extends AudioWorkletProcessor {
  private frame = new Float32Array(FRAME_SIZE);
  private filled = 0;
  private sinceLast = 0;
  private detect = createPitchDetector();

  process(inputs: Float32Array[][]) {
    const channels = inputs[0];
    if (!channels?.[0]) return true;
    const count = channels[0].length;
    this.frame.copyWithin(0, count);
    for (let i = 0; i < count; i++) {
      let sample = 0;
      for (const channel of channels) sample += channel[i];
      this.frame[FRAME_SIZE - count + i] = sample / channels.length;
    }
    this.filled += count;
    this.sinceLast += count;
    if (this.filled >= FRAME_SIZE && this.sinceLast >= HOP_SIZE) {
      this.sinceLast = 0;
      const pitch = this.detect(this.frame, sampleRate, currentTime * 1000);
      let energy = 0;
      for (const sample of this.frame) energy += sample * sample;
      this.port.postMessage({ pitch, time: currentTime * 1000, rms: Math.sqrt(energy / FRAME_SIZE) });
    }
    // Output remains zero. Never monitor the microphone through the speakers.
    return true;
  }
}
registerProcessor('ukulele-pitch', TunerProcessor);
