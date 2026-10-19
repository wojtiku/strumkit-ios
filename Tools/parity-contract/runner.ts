import { createHash } from 'node:crypto';
import { createPitchDetector } from './reference-source/pitch';
import { TunerTracker, TUNINGS, centsBetween, type Reading } from './reference-source/tuning';
import { TunerPresentation } from './reference-source/presentation';
import { TuningFeedback } from './reference-source/feedback';
import type { TestCase } from './corpus';

export interface GoldenTraceFrame {
  frameIndex: number;
  sampleIndex: number;
  timeMs: number;
  workletTimeMs: number;
  detector: {
    frequency: number | null;
    confidence: number | null;
    rms: number;
    foregroundAgrees?: boolean;
    oddOnly?: boolean;
  };
  tracker: {
    target: {
      note: string;
      frequency: number;
      index: number;
    } | null;
    rawCents: number | null;
    smoothedCents: number | null;
    readingFrequency: number | null;
    inTune: boolean;
  };
  publication: {
    action: 'published' | 'held' | 'empty' | 'skipped';
    note: string | null;
    cents: number | null;
    frequency: number | null;
    inTune: boolean | null;
  };
  confirmation: {
    event: boolean;
    stringIndex: number | null;
    note: string | null;
  };
}

export interface GoldenTrace {
  name: string;
  category: string;
  sampleRate: number;
  sampleCount: number;
  sampleSha256: string;
  frameCount: number;
  clockConvention: 'window-end';
  workletOffsetMs: number;
  confirmedNotes: string[];
  frames: GoldenTraceFrame[];
}

export function hashSamples(samples: Float32Array): string {
  const bytes = new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength);
  return createHash('sha256').update(bytes).digest('hex');
}

export function hashTrace(trace: GoldenTrace): string {
  const canonical = JSON.stringify(trace);
  return createHash('sha256').update(canonical).digest('hex');
}

export function runTestCase(testCase: TestCase): GoldenTrace {
  const sampleRate = testCase.sampleRate;
  const detector = createPitchDetector();
  const tracker = new TunerTracker();
  if (testCase.tuning) tracker.tuning = testCase.tuning;
  if (testCase.auto !== undefined) tracker.auto = testCase.auto;
  const presentation = new TunerPresentation();
  const feedback = new TuningFeedback();

  const frames: GoldenTraceFrame[] = [];
  const confirmedNotes: string[] = [];

  const workletOffsetMs = (128 / sampleRate) * 1000;

  const processFrame = (frame: Float32Array, sampleIndex: number, timeMs: number, frameIndex: number) => {
    testCase.onFrame?.(frameIndex, tracker, presentation, feedback);

    const workletTimeMs = timeMs - workletOffsetMs;

    let energy = 0;
    for (let i = 0; i < frame.length; i++) energy += frame[i] * frame[i];
    const rms = frame.length > 0 ? Math.sqrt(energy / frame.length) : 0;

    const raw = detector(frame, sampleRate, timeMs);
    const tracked = tracker.push(raw, timeMs);
    const confirmed = feedback.observe(tracked);
    if (confirmed && tracked) {
      confirmedNotes.push(tracked.note);
    }
    const published = presentation.push(tracked, timeMs);

    let pubAction: 'published' | 'held' | 'empty' | 'skipped';
    let pubNote: string | null = null;
    let pubCents: number | null = null;
    let pubFreq: number | null = null;
    let pubInTune: boolean | null = null;

    if (published === undefined) {
      pubAction = 'skipped';
    } else if (published === null) {
      pubAction = 'empty';
    } else {
      pubNote = published.note;
      pubCents = published.cents;
      pubFreq = published.frequency;
      pubInTune = published.inTune;
      if (tracked !== null && tracked.cents === published.cents && tracked.note === published.note) {
        pubAction = 'published';
      } else {
        pubAction = 'held';
      }
    }

    const currentTuning = TUNINGS[tracker.tuning] ?? TUNINGS.standard;
    const targetObj = tracked
      ? {
          note: tracked.note,
          frequency: currentTuning[tracked.index]?.frequency ?? 0,
          index: tracked.index,
        }
      : null;

    const rawCents = raw && targetObj ? centsBetween(raw.frequency, targetObj.frequency) : null;

    frames.push({
      frameIndex,
      sampleIndex,
      timeMs,
      workletTimeMs,
      detector: {
        frequency: raw?.frequency ?? null,
        confidence: raw?.confidence ?? null,
        rms: raw?.rms ?? rms,
        ...(raw && 'foregroundAgrees' in raw ? { foregroundAgrees: raw.foregroundAgrees } : {}),
        ...(raw && 'oddOnly' in raw ? { oddOnly: (raw as any).oddOnly } : {}),
      },
      tracker: {
        target: targetObj,
        rawCents,
        smoothedCents: tracked ? tracked.cents : null,
        readingFrequency: tracked ? tracked.frequency : null,
        inTune: tracked ? tracked.inTune : false,
      },
      publication: {
        action: pubAction,
        note: pubNote,
        cents: pubCents,
        frequency: pubFreq,
        inTune: pubInTune,
      },
      confirmation: {
        event: confirmed,
        stringIndex: tracked ? tracked.index : null,
        note: tracked ? tracked.note : null,
      },
    });
  };

  if (testCase.customFrames) {
    for (let i = 0; i < testCase.customFrames.length; i++) {
      const { frame, timeMs } = testCase.customFrames[i];
      const sampleIndex = Math.round((timeMs / 1000) * sampleRate);
      processFrame(frame, sampleIndex, timeMs, i);
    }
  } else {
    let frameIndex = 0;
    for (let start = 0; start + 4096 <= testCase.samples.length; start += 1024) {
      const sampleIndex = start + 4096;
      const timeMs = (sampleIndex / sampleRate) * 1000;
      const frame = testCase.samples.subarray(start, start + 4096);
      processFrame(frame, sampleIndex, timeMs, frameIndex++);
    }
  }

  return {
    name: testCase.name,
    category: testCase.category,
    sampleRate,
    sampleCount: testCase.samples.length,
    sampleSha256: hashSamples(testCase.samples),
    frameCount: frames.length,
    clockConvention: 'window-end',
    workletOffsetMs,
    confirmedNotes,
    frames,
  };
}
