import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseWav } from './wav';
import { TUNINGS } from './reference-source/tuning';

const HERE = dirname(fileURLToPath(import.meta.url));

export interface TestCase {
  name: string;
  category: 'product-fixtures' | 'product-controlled-44100' | 'product-controlled-48000' | 'stress-standard' | 'stress-odd' | 'targeted';
  description: string;
  sampleRate: number;
  samples: Float32Array;
  tuning?: string;
  auto?: boolean;
  onFrame?: (frameIndex: number, tracker: any, presentation: any, feedback: any) => void;
  customFrames?: { frame: Float32Array; timeMs: number }[];
}

interface Tone {
  note: string | null;
  seconds: number;
  cents?: number;
  amplitude?: number;
  noise?: number;
  wobble?: boolean;
  harmonics?: number[];
  decayTau?: number;
}

function makeControlledCase(name: string, rate: number, tones: Tone[]): Float32Array {
  const samples: number[] = [];
  let phase = 0, seed = 731;
  for (const tone of tones) {
    const target = TUNINGS.standard.find(t => t.note === tone.note);
    const frequency = target ? target.frequency * 2 ** ((tone.cents ?? 0) / 1200) : null;
    const count = Math.round(tone.seconds * rate);
    for (let i = 0; i < count; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const noise = (seed / 2 ** 32 * 2 - 1) * (tone.noise ?? 0);
      const hz = (frequency ?? 440) * (tone.wobble ? 2 ** (4 * Math.sin(i / rate * 25) / 1200) : 1);
      phase = (phase + 2 * Math.PI * hz / rate) % (2 * Math.PI);
      const fadeIn = Math.min(1, i / (rate * 0.008));
      const carrier = tone.harmonics
        ? tone.harmonics.reduce((sum, weight, harmonic) => sum + weight * Math.sin((harmonic + 1) * phase), 0)
        : 0.6 * Math.sin(phase) + 0.25 * Math.sin(2 * phase) + 0.15 * Math.sin(3 * phase);
      const envelope = tone.decayTau ? Math.exp(-i / rate / tone.decayTau) : 1;
      const value = frequency ? (tone.amplitude ?? 0.1) * fadeIn * envelope * carrier : 0;
      samples.push(value + noise);
    }
  }
  return Float32Array.from(samples);
}

function getControlledDefinitions(rate: number): { name: string; tones: Tone[]; description: string }[] {
  return [
    ...TUNINGS.standard.map(t => ({ name: `steady-${t.note}`, tones: [{ note: t.note, seconds: 2.5 }], description: `Steady ${t.note} 2.5s` })),
    { name: 'quiet-A4', tones: [{ note: 'A4', seconds: 2.5, amplitude: 0.003, noise: 0.0005 }], description: 'Quiet A4 with low SNR' },
    { name: 'noisy-C4', tones: [{ note: 'C4', seconds: 2.5, amplitude: 0.04, noise: 0.015 }], description: 'Noisy C4 tone' },
    { name: 'wobble-A4', tones: [{ note: 'A4', seconds: 3, wobble: true }], description: 'Wobbling A4 vibrato' },
    { name: 'peg-adjustment', tones: [{ note: 'A4', seconds: 1.5, cents: -30 }, { note: 'A4', seconds: 1.5, cents: 30 }], description: 'Peg turn from -30 to +30 cents' },
    { name: 'string-transitions', tones: TUNINGS.standard.map(t => ({ note: t.note, seconds: 1.8 })), description: 'Sequence through standard strings G4-C4-E4-A4' },
    { name: 'room-noise', tones: [{ note: null, seconds: 2.5, noise: 0.01 }], description: 'Room noise / silence' },
    { name: 'release-to-silence', tones: [{ note: 'G4', seconds: 1.5 }, { note: null, seconds: 2 }], description: 'G4 ringing out into silence' },
    ...['C4', 'G4'].map(note => ({
      name: `missing-fundamental-${note}`,
      tones: [{ note, seconds: 3, harmonics: [0, 1, 0.6, 0.4, 0.25, 0.15], amplitude: 0.05 }],
      description: `Missing fundamental on ${note}`,
    })),
    ...['C4', 'G4'].map(note => ({
      name: `odd-partials-${note}`,
      tones: [{ note, seconds: 3, harmonics: [0, 0, 1, 0, 0.6, 0, 0.4, 0, 0.25], amplitude: 0.05 }],
      description: `Odd partials series on ${note}`,
    })),
    { name: 'decaying-G4', tones: [{ note: 'G4', seconds: 3, amplitude: 0.12, decayTau: 0.5 }], description: 'Decaying G4 pluck' },
    { name: 'decaying-noisy-G4', tones: [{ note: 'G4', seconds: 3, amplitude: 0.12, decayTau: 0.5, noise: 0.0005 }], description: 'Decaying noisy G4 pluck' },
    { name: 'steady-plus3-A4', tones: [{ note: 'A4', seconds: 3, cents: 3 }], description: 'A4 detuned by +3 cents' },
    { name: 'outside-target-C5', tones: [{ note: 'A4', seconds: 3, cents: 300 }], description: 'C5 (+300 cents outside ukulele target range)' },
  ];
}

export function loadAllCases(): TestCase[] {
  const cases: TestCase[] = [];

  // 1. Fixture recordings (17 cases)
  const fixtureWavs = [
    'all-4-with-noise.wav',
    'guitar-chord.wav',
    'quiet_a.wav',
    'quiet_c.wav',
    'quiet_e.wav',
    'quiet_g.wav',
    'tuning_g.wav',
    'uke_a.wav',
    'uke_c.wav',
    'uke_e.wav',
    'uke_g.wav',
  ];
  for (const file of fixtureWavs) {
    const path = resolve(HERE, 'corpus', 'fixtures', file);
    const bytes = readFileSync(path);
    const wav = parseWav(bytes);
    cases.push({
      name: file,
      category: 'product-fixtures',
      description: `Recorded audio fixture: ${file}`,
      sampleRate: wav.sampleRate,
      samples: wav.samples,
    });
  }

  const fixtureM4as = [
    'all-4-with-noise.m4a',
    'quiet_a.m4a',
    'quiet_c.m4a',
    'quiet_e.m4a',
    'quiet_g.m4a',
    'tuning_g.m4a',
  ];
  for (const file of fixtureM4as) {
    const decodedPath = resolve(HERE, 'corpus', 'fixtures', 'decoded', `${file}.wav`);
    const bytes = readFileSync(decodedPath);
    const wav = parseWav(bytes);
    cases.push({
      name: file,
      category: 'product-fixtures',
      description: `Recorded audio fixture (decoded canonical PCM): ${file}`,
      sampleRate: wav.sampleRate,
      samples: wav.samples,
    });
  }

  // 2. Controlled synthetic cases @ 44.1 kHz (19 cases)
  for (const def of getControlledDefinitions(44100)) {
    cases.push({
      name: `${def.name}-44100`,
      category: 'product-controlled-44100',
      description: `${def.description} @ 44.1 kHz`,
      sampleRate: 44100,
      samples: makeControlledCase(def.name, 44100, def.tones),
    });
  }

  // 3. Controlled synthetic cases @ 48 kHz (19 cases)
  for (const def of getControlledDefinitions(48000)) {
    cases.push({
      name: `${def.name}-48000`,
      category: 'product-controlled-48000',
      description: `${def.description} @ 48 kHz`,
      sampleRate: 48000,
      samples: makeControlledCase(def.name, 48000, def.tones),
    });
  }

  // 4. Standard harmonics stress matrix (96 cases)
  for (const rate of [44100, 48000]) {
    for (const [note, target] of [['C4', 261.625565], ['E4', 329.627557], ['G4', 391.995436], ['A4', 440]] as const) {
      for (const fundamental of [0, 0.01, 0.1, 1]) {
        for (const noise of [0.001, 0.01, 0.04]) {
          const frequency = target * 2 ** (-17 / 1200);
          let seed = 76391;
          const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 2 ** 32; };
          const phases = Array.from({ length: 6 }, () => random() * 2 * Math.PI);
          const samples = Float32Array.from({ length: rate * 2 }, (_, i) => {
            const t = i / rate, phase = 2 * Math.PI * frequency * t;
            let value = fundamental * Math.sin(phase + phases[0]);
            for (let h = 2; h <= 6; h++) value += Math.sin(h * phase + phases[h - 1]) / (h - 1);
            return 0.03 * Math.exp(-t) * value + noise * (random() * 2 - 1);
          });
          cases.push({
            name: `${note}-${rate}-fundamental${fundamental}-noise${noise}`,
            category: 'stress-standard',
            description: `Standard stress matrix: ${note} @ ${rate}Hz, fund=${fundamental}, noise=${noise}`,
            sampleRate: rate,
            samples,
          });
        }
      }
    }
  }

  // 5. Odd harmonics stress matrix (96 cases)
  for (const rate of [44100, 48000]) {
    for (const [note, target] of [['C4', 261.625565], ['E4', 329.627557], ['G4', 391.995436], ['A4', 440]] as const) {
      for (const fundamental of [0, 0.01, 0.1, 1]) {
        for (const noise of [0.001, 0.01, 0.04]) {
          const frequency = target * 2 ** (-17 / 1200);
          let seed = 76391;
          const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 2 ** 32; };
          const phases = Array.from({ length: 9 }, () => random() * 2 * Math.PI);
          const samples = Float32Array.from({ length: rate * 2 }, (_, i) => {
            const t = i / rate, phase = 2 * Math.PI * frequency * t;
            let value = fundamental * Math.sin(phase + phases[0]);
            for (let h = 3; h <= 9; h += 2) value += 2 * Math.sin(h * phase + phases[h - 1]) / (h - 1);
            return 0.03 * Math.exp(-t) * value + noise * (random() * 2 - 1);
          });
          cases.push({
            name: `${note}-${rate}-odd-fundamental${fundamental}-noise${noise}`,
            category: 'stress-odd',
            description: `Odd partials stress matrix: ${note} @ ${rate}Hz, fund=${fundamental}, noise=${noise}`,
            sampleRate: rate,
            samples,
          });
        }
      }
    }
  }

  // 6. Targeted test vectors
  // Vector: 44.1 kHz, 48 kHz, 96 kHz rates
  for (const rate of [44100, 48000, 96000]) {
    // Pure A4
    const a4Samples = Float32Array.from({ length: rate * 2 }, (_, i) => 0.1 * Math.sin(2 * Math.PI * 440 * i / rate));
    cases.push({
      name: `vector-rate-${rate}-A4`,
      category: 'targeted',
      description: `Pure sine A4 440Hz at ${rate}Hz sample rate`,
      sampleRate: rate,
      samples: a4Samples,
    });
    // Decaying G4
    const g4Samples = Float32Array.from({ length: rate * 2 }, (_, i) => {
      const t = i / rate;
      return 0.12 * Math.exp(-t / 0.5) * Math.sin(2 * Math.PI * 391.995436 * t);
    });
    cases.push({
      name: `vector-rate-${rate}-decay-G4`,
      category: 'targeted',
      description: `Decaying G4 pluck at ${rate}Hz sample rate`,
      sampleRate: rate,
      samples: g4Samples,
    });
  }

  // Silence vectors
  for (const rate of [44100, 48000]) {
    cases.push({
      name: `vector-silence-zeros-${rate}`,
      category: 'targeted',
      description: `Complete zero samples silence at ${rate}Hz`,
      sampleRate: rate,
      samples: new Float32Array(rate * 2),
    });
    // Sub-threshold noise below SILENCE_RMS (0.000015)
    let seed = 42;
    const subthreshold = Float32Array.from({ length: rate * 2 }, () => {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      return 0.00001 * (seed / 2 ** 32 * 2 - 1);
    });
    cases.push({
      name: `vector-silence-subthreshold-${rate}`,
      category: 'targeted',
      description: `Sub-threshold noise below SILENCE_RMS at ${rate}Hz`,
      sampleRate: rate,
      samples: subthreshold,
    });
  }

  // Degenerate inputs (0-length, NaN, Infinity, DC offset)
  {
    const rate = 48000;
    const dcOffsetSamples = Float32Array.from({ length: rate * 2 }, (_, i) => 0.4 + 0.1 * Math.sin(2 * Math.PI * 440 * i / rate));
    cases.push({
      name: 'vector-dc-offset-A4',
      category: 'targeted',
      description: 'A4 sine with large +0.4 DC offset',
      sampleRate: rate,
      samples: dcOffsetSamples,
    });

    const customFrames: { frame: Float32Array; timeMs: number }[] = [];
    // Frame 0: normal A4
    customFrames.push({ frame: Float32Array.from({ length: 4096 }, (_, i) => 0.1 * Math.sin(2 * Math.PI * 440 * i / rate)), timeMs: 4096 / rate * 1000 });
    // Frame 1: empty buffer
    customFrames.push({ frame: new Float32Array(0), timeMs: 5120 / rate * 1000 });
    // Frame 2: short buffer (64 samples)
    customFrames.push({ frame: new Float32Array(64), timeMs: 6144 / rate * 1000 });
    // Frame 3: buffer containing NaNs
    const nanFrame = new Float32Array(4096).fill(NaN);
    customFrames.push({ frame: nanFrame, timeMs: 7168 / rate * 1000 });
    // Frame 4: buffer containing Infinity
    const infFrame = new Float32Array(4096);
    infFrame[10] = Infinity;
    customFrames.push({ frame: infFrame, timeMs: 8192 / rate * 1000 });
    // Frame 5: recovered normal A4
    customFrames.push({ frame: Float32Array.from({ length: 4096 }, (_, i) => 0.1 * Math.sin(2 * Math.PI * 440 * i / rate)), timeMs: 9216 / rate * 1000 });

    cases.push({
      name: 'vector-short-and-degenerate',
      category: 'targeted',
      description: 'Degenerate inputs: empty, short, NaN, Inf, and recovery',
      sampleRate: rate,
      samples: new Float32Array(4096),
      customFrames,
    });
  }

  // Duplicate targets: Slack tuning (G4, C4, E4, G4)
  {
    const rate = 48000;
    const g4Samples = Float32Array.from({ length: rate * 3 }, (_, i) => 0.1 * Math.sin(2 * Math.PI * 391.995436 * i / rate));
    cases.push({
      name: 'vector-duplicate-targets-slack',
      category: 'targeted',
      description: 'Slack tuning (G4, C4, E4, G4) with two identical G4 target strings',
      sampleRate: rate,
      samples: g4Samples,
      tuning: 'slack',
    });
  }

  // Resets during active tracking
  {
    const rate = 48000;
    const totalLength = rate * 3;
    const samples = Float32Array.from({ length: totalLength }, (_, i) => {
      const t = i / rate;
      const freq = t < 1.5 ? 440 : 261.625565;
      return 0.1 * Math.sin(2 * Math.PI * freq * t);
    });
    cases.push({
      name: 'vector-reset-events',
      category: 'targeted',
      description: 'Mid-stream state reset event between A4 and C4 notes',
      sampleRate: rate,
      samples,
      onFrame: (frameIndex, tracker, presentation, feedback) => {
        // Trigger reset at frame 35 (~750 ms)
        if (frameIndex === 35) {
          tracker.reset();
          presentation.reset();
          feedback.clearReading();
        }
      },
    });
  }

  // Gaps: short (100ms), medium (500ms), long (1200ms)
  {
    const rate = 48000;
    const makeGap = (gapSeconds: number, name: string) => {
      const p1 = Math.round(1.0 * rate);
      const gap = Math.round(gapSeconds * rate);
      const p2 = Math.round(1.0 * rate);
      const total = p1 + gap + p2;
      const samples = new Float32Array(total);
      for (let i = 0; i < p1; i++) samples[i] = 0.1 * Math.sin(2 * Math.PI * 440 * i / rate);
      for (let i = 0; i < p2; i++) samples[p1 + gap + i] = 0.1 * Math.sin(2 * Math.PI * 440 * i / rate);
      return { name, samples };
    };

    const g100 = makeGap(0.1, 'vector-gap-short-100ms');
    cases.push({
      name: g100.name,
      category: 'targeted',
      description: 'Short 100ms gap (< 300ms history limit): smoothing continues',
      sampleRate: rate,
      samples: g100.samples,
    });

    const g500 = makeGap(0.5, 'vector-gap-medium-500ms');
    cases.push({
      name: g500.name,
      category: 'targeted',
      description: 'Medium 500ms gap (> 300ms limit, < 1000ms hold): target re-confirms',
      sampleRate: rate,
      samples: g500.samples,
    });

    const g1200 = makeGap(1.2, 'vector-gap-long-1200ms');
    cases.push({
      name: g1200.name,
      category: 'targeted',
      description: 'Long 1200ms gap (> 1000ms hold): presentation expires to null',
      sampleRate: rate,
      samples: g1200.samples,
    });
  }

  // Quiet onset bootstrap
  {
    const rate = 48000;
    const quietOnset = makeControlledCase('quiet-onset-bootstrap', rate, [
      { note: 'A4', seconds: 2.5, amplitude: 0.003, noise: 0.0005 },
    ]);
    cases.push({
      name: 'vector-quiet-onset-bootstrap',
      category: 'targeted',
      description: 'Quiet A4 onset verifying bootstrap-strong and available-reading mean seed',
      sampleRate: rate,
      samples: quietOnset,
    });
  }

  // Alias interference vectors
  {
    for (const [rate, interferer] of [[44100, 14260], [48000, 11560]] as const) {
      const frequency = 440 * 2 ** (17 / 1200);
      const samples = Float32Array.from({ length: rate * 2 }, (_, i) => {
        const phase = 2 * Math.PI * frequency * i / rate;
        return 0.03 * Math.sin(2 * Math.PI * interferer * i / rate)
          + 0.0006 * Math.sin(phase);
      });
      cases.push({
        name: `vector-alias-electronic-${rate}`,
        category: 'targeted',
        description: `Loud ${interferer}Hz interferer with quiet A4 +17c tone at ${rate}Hz`,
        sampleRate: rate,
        samples,
      });
    }

    // Fold tones near decimation folds
    for (const [rate, frequency] of [[44100, 14700 - 329.6], [48000, 12000 + 392], [96000, 12000 - 440]] as const) {
      const samples = Float32Array.from({ length: rate * 2 }, (_, i) => 0.08 * Math.sin(2 * Math.PI * frequency * i / rate + 1.31));
      cases.push({
        name: `vector-alias-fold-${rate}-${Math.round(frequency)}`,
        category: 'targeted',
        description: `Out-of-band fold tone ${frequency.toFixed(1)}Hz at ${rate}Hz`,
        sampleRate: rate,
        samples,
      });
    }
  }

  // 3-15 cent movement & peg steps
  {
    const rate = 48000;
    for (const cents of [3, 8, 12, 15]) {
      const count1 = rate * 1.0;
      const count2 = rate * 1.5;
      const samples = Float32Array.from({ length: count1 + count2 }, (_, i) => {
        const t = i / rate;
        const currentCents = i < count1 ? 0 : cents;
        const freq = 440 * 2 ** (currentCents / 1200);
        return 0.1 * Math.sin(2 * Math.PI * freq * t);
      });
      cases.push({
        name: `vector-step-${cents}cents`,
        category: 'targeted',
        description: `A4 stepping from 0 to +${cents} cents at ${rate}Hz`,
        sampleRate: rate,
        samples,
      });
    }

    // Peg adjustment (-30 to +30 cents)
    const pegSamples = makeControlledCase('peg-adjust', rate, [
      { note: 'A4', seconds: 1.5, cents: -30 },
      { note: 'A4', seconds: 1.5, cents: 30 },
    ]);
    cases.push({
      name: 'vector-peg-adjustment-48000',
      category: 'targeted',
      description: 'Peg adjustment from -30 cents to +30 cents at 48kHz',
      sampleRate: rate,
      samples: pegSamples,
    });

    // Continuous sweep -20 to +20 cents over 2s
    const sweepSamples = Float32Array.from({ length: rate * 2 }, (_, i) => {
      const t = i / rate;
      const cents = -20 + (t / 2.0) * 40;
      const freq = 440 * 2 ** (cents / 1200);
      return 0.1 * Math.sin(2 * Math.PI * freq * t);
    });
    cases.push({
      name: 'vector-continuous-sweep-40cents',
      category: 'targeted',
      description: 'Continuous pitch sweep from -20c to +20c over 2s at 48kHz',
      sampleRate: rate,
      samples: sweepSamples,
    });
  }

  // Decision boundary vectors
  {
    const rate = 48000;
    // 25 cents target hysteresis boundary
    for (const delta of [-0.1, 0.1]) {
      const cents = 25 + delta;
      const samples = Float32Array.from({ length: rate * 2 }, (_, i) => 0.1 * Math.sin(2 * Math.PI * (440 * 2 ** (cents / 1200)) * i / rate));
      cases.push({
        name: `vector-boundary-hysteresis-25cents-${delta > 0 ? 'plus' : 'minus'}`,
        category: 'targeted',
        description: `Target hysteresis boundary test at ${cents} cents`,
        sampleRate: rate,
        samples,
      });
    }

    // 5 cents inTune boundary
    for (const delta of [-0.01, 0.01]) {
      const cents = 5.0 + delta;
      const samples = Float32Array.from({ length: rate * 2 }, (_, i) => 0.1 * Math.sin(2 * Math.PI * (440 * 2 ** (cents / 1200)) * i / rate));
      cases.push({
        name: `vector-boundary-intune-5cents-${delta > 0 ? 'sharp' : 'within'}`,
        category: 'targeted',
        description: `InTune 5.0-cent boundary test at ${cents.toFixed(2)} cents`,
        sampleRate: rate,
        samples,
      });
    }

    // 400ms confirmation boundary (hold at 0 cents for 380ms vs 420ms)
    for (const holdMs of [380, 420]) {
      const holdSamples = Math.round(holdMs / 1000 * rate);
      const total = rate * 2;
      const samples = Float32Array.from({ length: total }, (_, i) => {
        if (i < holdSamples) return 0.1 * Math.sin(2 * Math.PI * 440 * i / rate);
        return 0; // release
      });
      cases.push({
        name: `vector-boundary-confirmation-${holdMs}ms`,
        category: 'targeted',
        description: `Confirmation 400ms threshold test with ${holdMs}ms hold`,
        sampleRate: rate,
        samples,
      });
    }
  }

  return cases;
}
