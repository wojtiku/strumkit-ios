import { detectSpectralPitch, hasUnfoldedPitchSupport, powerSpectrum, spectralPeaks, type SpectralRanking, type SpectralPeak } from './spectrum';

/** Pure estimator. No browser dependencies; identical code runs in tests/worklet. */
export interface Pitch {
  frequency: number; confidence: number; rms: number;
  /** Independent current-window fundamental corroboration, not a confidence boost. */
  foregroundAgrees?: boolean;
}
export const FRAME_SIZE = 4096;
export const HOP_SIZE = 1024;
// Identity may bridge a dropout, but cannot veto another source indefinitely.
// Match the canonical detector's one-second identity lifetime; actual current
// observations, never rejected candidates, are the only way to renew it.
const FOREGROUND_IDENTITY_MS = 1000;

function filter(samples: Float64Array, rate: number, cutoff: number, q: number, highpass: boolean) {
  const omega = 2 * Math.PI * cutoff / rate;
  const cosine = Math.cos(omega);
  const alpha = Math.sin(omega) / (2 * q);
  const a0 = 1 + alpha;
  const b0 = (highpass ? 1 + cosine : 1 - cosine) / (2 * a0);
  const b1 = (highpass ? -(1 + cosine) : 1 - cosine) / a0;
  const a1 = -2 * cosine / a0;
  const a2 = (1 - alpha) / a0;
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < samples.length; i++) {
    const x = samples[i];
    const y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2;
    samples[i] = y;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
  }
}

function bandpass(samples: Float64Array, rate: number) {
  filter(samples, rate, 100, Math.SQRT1_2, true);
  filter(samples, rate, 1200, 0.541196, false);
  filter(samples, rate, 1200, 1.306563, false);
}

/** Per-stream scratch, explicitly invalidated for EVERY incoming frame. An
 * input buffer's identity is not its contents: the worklet reuses the buffer.
 * Transformed anti-alias input is a different frame and bypasses these caches. */
class FrameAnalysis {
  private input: Float32Array | null = null;
  private rate = 0;
  private power: Float64Array | null = null;
  private detectedPeaks: SpectralPeak[] | null = null;
  private filteredReady = false;
  private filteredSamples = new Float64Array(0);

  begin(input: Float32Array, rate: number) {
    this.input = input; this.rate = rate;
    this.power = null; this.detectedPeaks = null; this.filteredReady = false;
    if (this.filteredSamples.length !== input.length) this.filteredSamples = new Float64Array(input.length);
  }

  filtered(input: Float32Array, rate: number) {
    if (input !== this.input || rate !== this.rate) {
      const filtered = Float64Array.from(input);
      bandpass(filtered, rate);
      return filtered;
    }
    if (!this.filteredReady) {
      this.filteredSamples.set(input); bandpass(this.filteredSamples, rate); this.filteredReady = true;
    }
    return this.filteredSamples;
  }

  peaks(input: Float32Array, rate: number) {
    if (input !== this.input || rate !== this.rate) return spectralPeaks(input, rate);
    this.power ??= powerSpectrum(input);
    return this.detectedPeaks ??= spectralPeaks(input, rate, this.power);
  }

  spectral(input: Float32Array, rate: number, ranking: SpectralRanking = 'prominence') {
    if (input !== this.input || rate !== this.rate) return detectSpectralPitch(input, rate, ranking);
    const peaks = this.peaks(input, rate);
    return detectSpectralPitch(input, rate, ranking, this.power!, peaks);
  }
}

/** Both refinements search the same lag neighborhood and score the same samples.
 * Raw minimization keeps the full window; filtered minimization skips startup.
 */
function refine(signal: Float32Array | Float64Array, sampleRate: number,
  first: number, last: number, windowEnd: number, searchStart: number, scoreStart: number) {
  const difference = (lag: number) => {
    let sum = 0;
    for (let i = searchStart; i < windowEnd; i++) {
      const delta = signal[i] - signal[i + lag];
      sum += delta * delta;
    }
    return sum;
  };
  let best = first, value = Infinity;
  for (let lag = first; lag <= last; lag++) {
    const candidate = difference(lag);
    if (candidate < value) { value = candidate; best = lag; }
  }
  const left = difference(best - 1), right = difference(best + 1);
  const curvature = left - 2 * value + right;
  const offset = curvature ? Math.max(-1, Math.min(1, (left - right) / (2 * curvature))) : 0;
  let error = 0, energy = 0;
  for (let i = scoreStart; i < windowEnd; i++) {
    const x = signal[i], y = signal[i + best];
    energy += x * x + y * y;
    error += (x - y) * (x - y);
  }
  return { frequency: sampleRate / (best + offset), residual: energy ? error / energy : Infinity };
}

const validFrequency = (frequency: number) => Number.isFinite(frequency) && frequency >= 110 && frequency <= 1100;

/** Independent onset refinement; preserve eligibility and measured confidence.
 * A weak YIN score is not a correctness probability. Only an agreeing harmonic
 * series can supply the frequency, never a nominal tuning note.
 */
export function refineOnsetPitch(input: Float32Array, sampleRate: number, pitch: Pitch | null, analysis?: FrameAnalysis): Pitch | null {
  if (!pitch || pitch.confidence < 0.75 || pitch.confidence >= 0.98) return pitch;
  const spectral = analysis ? analysis.spectral(input, sampleRate) : detectSpectralPitch(input, sampleRate);
  if (!spectral || Math.abs(1200 * Math.log2(spectral.frequency / pitch.frequency)) > 50) return pitch;
  return { ...pitch, frequency: spectral.frequency };
}

/** Independent fractional-delay repetition after the existing bandpass. */
export function filteredPeriodResidual(input: Float32Array, sampleRate: number, frequency: number, analysis?: FrameAnalysis) {
  const signal = analysis ? analysis.filtered(input, sampleRate) : Float64Array.from(input);
  if (!analysis) bandpass(signal, sampleRate);
  const lag = sampleRate / frequency, whole = Math.floor(lag), fraction = lag - whole;
  let error = 0, energy = 0;
  for (let i = Math.ceil(sampleRate * 0.012); i + whole + 1 < signal.length; i++) {
    const delayed = signal[i + whole] * (1 - fraction) + signal[i + whole + 1] * fraction;
    error += (signal[i] - delayed) ** 2;
    energy += signal[i] ** 2 + delayed ** 2;
  }
  return energy > 0 ? error / energy : Infinity;
}

/** One instance per capture/file stream. Refine the first five eligible windows
 * while periodicity develops, then permit only corroborated harmonic repairs.
 * Do not prolong startup across a pause/dropout. The pure detectPitch function
 * remains available as the non-streaming estimator control.
 */
function createPitchDetectorCore(ranking: SpectralRanking, repairFallback: boolean, repairWaveform: boolean, refineWeak: boolean, analysis: FrameAnalysis) {
  let accepted = 0, frames = 0;
  let anchor: { frequency: number; time: number } | null = null;
  let waveformAnchor: { frequency: number; time: number } | null = null;
  let precisionEvidence: { frequency: number; first: number; last: number } | null = null;
  const agrees = (a: number, b: number, cents = 50) => Math.abs(1200 * Math.log2(a / b)) <= cents;
  return (input: Float32Array, sampleRate: number, sampleTime?: number): Pitch | null => {
    const time = sampleTime ?? frames * HOP_SIZE / sampleRate * 1000;
    frames++;
    if (anchor && time - anchor.time > 300) anchor = null;
    if (waveformAnchor && time - waveformAnchor.time > 300) waveformAnchor = null;
    const pitch = detectPitch(input, sampleRate, ranking, analysis);
    if (pitch && pitch.confidence >= 0.75) accepted++;
    let result = accepted <= 5 ? refineOnsetPitch(input, sampleRate, pitch, analysis) : pitch;
    // Repair only a weak spectral fallback that has selected a higher harmonic
    // of a freshly measured fundamental. Do not veto raw input, fill nulls,
    // choose new targets from power, or reinterpret waveform estimates.
    if (repairFallback && ranking === 'prominence' && result && 'oddOnly' in result && result.confidence < 0.95
      && anchor && time - anchor.time <= 64) {
      const alternative = detectPitch(input, sampleRate, 'supported-power', analysis);
      const candidate = accepted <= 5 ? refineOnsetPitch(input, sampleRate, alternative, analysis) : alternative;
      if (candidate && candidate.frequency < result.frequency && agrees(candidate.frequency, anchor.frequency, 5)
        && [0.5, 1 / 3].some(ratio => agrees(candidate.frequency, result!.frequency * ratio))) {
        const peaks = analysis.peaks(input, sampleRate);
        const powerAt = (frequency: number) => Math.max(0, ...peaks
          .filter(peak => Math.abs(peak.frequency - frequency) <= Math.max(1.5, frequency * 0.015))
          .map(peak => peak.power));
        if (powerAt(candidate.frequency) > powerAt(result.frequency)) result = candidate;
      }
    }
    // YIN periodicity and spectral harmonic-count grades are different evidence.
    // Only strong waveform estimates establish a new anchor; fresh agreeing
    // observations can continue it. Nothing held is emitted as raw pitch.
    if (result && (result.confidence >= 0.95 && !('oddOnly' in result)
      || anchor && agrees(result.frequency, anchor.frequency))) anchor = { frequency: result.frequency, time };
    // Keep a separate octave-continuation anchor: waveform repairs must not
    // feed back into the independently validated spectral-fallback decisions.
    if (repairWaveform && ranking === 'prominence' && result && result.confidence >= 0.75 && result.confidence < 0.95
      && !('oddOnly' in result) && waveformAnchor && time - waveformAnchor.time <= 64
      && agrees(result.frequency * 2, waveformAnchor.frequency, 20)) {
      const peaks = analysis.peaks(input, sampleRate), peak = peaks[0];
      if (peak && peak.frequency <= 1100 && peak.prominence >= 50 && agrees(peak.frequency, result.frequency * 2)) {
        const frequency = result.frequency * 2, lower = peak.frequency / 2;
        const powerAt = (hz: number) => Math.max(0, ...peaks
          .filter(p => Math.abs(p.frequency - hz) <= Math.max(1.5, hz * 0.015)).map(p => p.power));
        let unexplained = Math.max(powerAt(result.frequency), powerAt(lower));
        const visibleFundamental = peaks.some(p => p.prominence >= 15
          && Math.abs(p.frequency - lower) <= Math.max(1.5, lower * 0.015));
        for (let harmonic = 1; harmonic <= 12; harmonic++) if (harmonic % 2)
          unexplained = Math.max(unexplained, powerAt(lower * harmonic));
        if (validFrequency(frequency) && !visibleFundamental && unexplained < peak.power * 0.1
          && filteredPeriodResidual(input, sampleRate, frequency, analysis) <= 0.35) result = { ...result, frequency };
      }
    }
    if (result && (result.confidence >= 0.95 && !('oddOnly' in result)
      || waveformAnchor && agrees(result.frequency, waveformAnchor.frequency))) waveformAnchor = { frequency: result.frequency, time };
    // A persistent single-tone peak can improve a noisy waveform fit. Keep
    // this downstream of harmonic anchors and reject conflicting strong
    // partials: a stretched/mixed series is not a single-tone measurement.
    if (!refineWeak || ranking !== 'prominence' || accepted <= 5 || !result
      || result.confidence < 0.75 || result.confidence >= 0.95 || 'oddOnly' in result) {
      precisionEvidence = null;
      return result;
    }
    const peaks = analysis.peaks(input, sampleRate);
    const peak = peaks.find(p => validFrequency(p.frequency) && p.prominence >= 1000 && agrees(p.frequency, result!.frequency, 20));
    if (!peak || filteredPeriodResidual(input, sampleRate, peak.frequency, analysis) > 0.5 || peaks.some(p => {
      const harmonic = Math.round(p.frequency / peak.frequency);
      const difference = Math.abs(1200 * Math.log2(p.frequency / (peak.frequency * harmonic)));
      return p.frequency >= peak.frequency * 0.75 && harmonic <= 8 && p.power >= peak.power * 0.1 && difference > 5;
    })) {
      precisionEvidence = null;
      return result;
    }
    if (!precisionEvidence || time - precisionEvidence.last > 32 || !agrees(peak.frequency, precisionEvidence.frequency, 5))
      precisionEvidence = { frequency: peak.frequency, first: time, last: time };
    else precisionEvidence = { ...precisionEvidence, frequency: peak.frequency, last: time };
    return time - precisionEvidence.first >= 64 ? { ...result, frequency: peak.frequency } : result;
  };
}

/** Fresh null recovery is downstream of estimator/precision history. Measured
 * priors corroborate identity only; neither a held frequency nor a target note
 * may supply raw pitch. Strong single-tone and weaker paired-partial recovery
 * have separate evidence requirements. */
function createRecoveredPitchDetector(ranking: SpectralRanking, repairFallback: boolean,
  repairWaveform: boolean, refineWeak: boolean, recoverNull: boolean, analysis: FrameAnalysis) {
  const detector = createPitchDetectorCore(ranking, repairFallback, repairWaveform, refineWeak, analysis);
  let frames = 0;
  let stableAnchor: { frequency: number; time: number } | null = null;
  let pairedAnchor: { frequency: number; time: number } | null = null;
  let evidence: { frequency: number; time: number }[] = [];
  const agrees = (a: number, b: number, cents: number) => Math.abs(1200 * Math.log2(a / b)) <= cents;
  return (input: Float32Array, rate: number, sampleTime?: number): Pitch | null => {
    const time = sampleTime ?? frames * HOP_SIZE / rate * 1000;
    frames++;
    let result = detector(input, rate, time);
    if (!recoverNull || ranking !== 'prominence') return result;
    if (stableAnchor && time - stableAnchor.time > 300) { stableAnchor = null; evidence = []; }
    evidence = evidence.filter(p => time - p.time <= 200);
    let peaks: ReturnType<typeof spectralPeaks> | null = null;
    let rms: number | null = null;
    const observedRms = () => {
      if (rms !== null) return rms;
      let mean = 0, energy = 0;
      for (const value of input) mean += value;
      mean /= input.length;
      for (const value of input) energy += (value - mean) ** 2;
      return rms = Math.sqrt(energy / input.length);
    };
    if (result) {
      if (result.confidence >= 0.95 && !('oddOnly' in result) || stableAnchor && agrees(result.frequency, stableAnchor.frequency, 50)) {
        stableAnchor = { frequency: result.frequency, time };
        evidence.push(stableAnchor);
      }
    } else if (stableAnchor && evidence.length >= 3 && evidence.at(-1)!.time - evidence[0].time >= 64
      && agrees(Math.max(...evidence.map(p => p.frequency)), Math.min(...evidence.map(p => p.frequency)), 5)
      && observedRms() >= 0.000015) {
      peaks = analysis.peaks(input, rate);
      const peak = peaks[0];
      if (peak && validFrequency(peak.frequency) && peak.prominence >= 500 && agrees(peak.frequency, stableAnchor.frequency, 5)
        && filteredPeriodResidual(input, rate, peak.frequency, analysis) <= 0.5) {
        result = { frequency: peak.frequency, confidence: 0.8, rms: observedRms() };
        stableAnchor = { frequency: result.frequency, time };
        evidence.push(stableAnchor);
      }
    }
    if (pairedAnchor && time - pairedAnchor.time > 200) pairedAnchor = null;
    if (result) {
      if (result.confidence >= 0.95 && !('oddOnly' in result) || pairedAnchor && agrees(result.frequency, pairedAnchor.frequency, 50))
        pairedAnchor = { frequency: result.frequency, time };
      return result;
    }
    if (!pairedAnchor) return null;
    peaks ??= analysis.peaks(input, rate);
    const fundamental = peaks.find(p => validFrequency(p.frequency) && p.prominence >= 4.5 && agrees(p.frequency, pairedAnchor!.frequency, 30));
    if (!fundamental) return null;
    const second = peaks.find(p => p.prominence >= 8 && agrees(p.frequency / 2, fundamental.frequency, 40));
    if (!second || second.power < fundamental.power * 0.2 || second.power > fundamental.power * 2
      || peaks.some(p => p.frequency >= 110 && p.frequency < fundamental.frequency * 0.75
        && p.prominence >= 6 && p.power >= fundamental.power * 0.1)) return null;
    const frequency = (fundamental.frequency * fundamental.power + second.frequency / 2 * second.power)
      / (fundamental.power + second.power);
    if (!validFrequency(frequency) || filteredPeriodResidual(input, rate, frequency, analysis) > 0.7 || observedRms() < 0.000015) return null;
    pairedAnchor = { frequency, time };
    return { frequency, confidence: 0.8, rms: observedRms() };
  };
}

/** Canonicalize a weak spectral period only with a measured foreground peak.
 * Credible lower/odd-series evidence vetoes reinterpretation. Keep this stage
 * downstream so it cannot change accepted recovery or estimator history. */
function createCanonicalPitchDetector(ranking: SpectralRanking, repairFallback: boolean,
  repairWaveform: boolean, refineWeak: boolean, recoverNull: boolean, repairSpectralOctave: boolean, repairThird: boolean, analysis: FrameAnalysis) {
  const detector = createRecoveredPitchDetector(ranking, repairFallback, repairWaveform, refineWeak, recoverNull, analysis);
  let frames = 0, anchor: { frequency: number; time: number } | null = null;
  const agrees = (a: number, b: number, cents: number) => Math.abs(1200 * Math.log2(a / b)) <= cents;
  return (input: Float32Array, rate: number, sampleTime?: number): Pitch | null => {
    const time = sampleTime ?? frames * HOP_SIZE / rate * 1000;
    frames++;
    const raw = detector(input, rate, time);
    if (!repairSpectralOctave || ranking !== 'prominence') return raw;
    if (anchor && time - anchor.time > 1000) anchor = null;
    let result = raw;
    const multiple = raw && anchor ? (repairThird ? [2, 3] : [2]).find(h => agrees(raw.frequency * h, anchor!.frequency, 20)) : undefined;
    if (raw && 'oddOnly' in raw && multiple && anchor) {
      const peaks = analysis.peaks(input, rate);
      const lowerVisible = peaks.some(p => p.prominence >= 15
        && Math.abs(p.frequency - raw.frequency) <= Math.max(1.5, raw.frequency * 0.015));
      const frequency = raw.frequency * multiple;
      const candidate = peaks.find(p => p.prominence >= 50
        && Math.abs(p.frequency - frequency) <= Math.max(1.5, p.frequency * 0.015));
      const voicedMaximum = Math.max(0, ...peaks.filter(p => p.frequency <= 1100 && p.prominence >= 50).map(p => p.power));
      if (!lowerVisible && validFrequency(frequency) && candidate && candidate.power >= voicedMaximum) {
        const matched = peaks.map(p => ({ ...p, h: Math.round(p.frequency / raw.frequency) }))
          .filter(p => p.h >= 1 && p.h <= 12 && Math.abs(p.frequency / p.h - raw.frequency) <= Math.max(1.5, raw.frequency * 0.008));
        // A stretched upper series can create an incidental weak odd template
        // match. Preserve independent odd evidence, not such incidental matches.
        const unexplained = matched.some(p => p.h % multiple !== 0 && (p.power >= candidate.power * 0.1
          || p.prominence >= 15 && p.power >= candidate.power * 0.01 && matched.every(reference =>
            reference.h >= p.h || reference.power < p.power || reference.prominence < 15
            || p.frequency / p.h >= reference.frequency / reference.h * 2 ** (-5 / 1200))));
        if (!unexplained) result = { ...raw, frequency: multiple === 3 ? candidate.frequency : frequency };
      }
    }
    if (result && (result.confidence >= 0.95 && !('oddOnly' in result)
      || anchor && agrees(result.frequency, anchor.frequency, 50))) anchor = { frequency: result.frequency, time };
    return result;
  };
}

/** Coherent measured foreground continuation, with independent waveform
 * validation for third-period repair and post-dropout spectral acquisition.
 * Diagnostic flags reproduce earlier accepted stages; no target-note prior. */
export function createPitchDetector(ranking: SpectralRanking = 'prominence', repairFallback = true,
  repairWaveform = repairFallback, refineWeak = repairWaveform, recoverNull = refineWeak,
  repairSpectralOctave = recoverNull, refineForeground = repairSpectralOctave) {
  const analysis = new FrameAnalysis();
  const detector = createCanonicalPitchDetector(ranking, repairFallback, repairWaveform, refineWeak, recoverNull, repairSpectralOctave, refineForeground, analysis);
  let frames = 0, accepted = 0;
  let anchor: { frequency: number; time: number } | null = null;
  let evidence: { frequency: number; first: number; last: number } | null = null;
  const agrees = (a: number, b: number, cents: number) => Math.abs(1200 * Math.log2(a / b)) <= cents;
  return (input: Float32Array, rate: number, sampleTime?: number): Pitch | null => {
    const time = sampleTime ?? frames * HOP_SIZE / rate * 1000;
    frames++;
    analysis.begin(input, rate);
    let raw = detector(input, rate, time);
    if (!refineForeground || ranking !== 'prominence') return raw;
    if (anchor && time - anchor.time > FOREGROUND_IDENTITY_MS) anchor = null;
    let peaks: ReturnType<typeof spectralPeaks> | null = null;
    if (raw && !('oddOnly' in raw) && raw.confidence >= 0.75 && raw.confidence < 0.95 && anchor
      && time - anchor.time <= 64 && agrees(raw.frequency * 3, anchor.frequency, 20)) {
      peaks = analysis.peaks(input, rate);
      const peak = peaks[0];
      if (peak && validFrequency(peak.frequency) && peak.prominence >= 50 && agrees(peak.frequency, raw.frequency * 3, 50)) {
        const lower = peak.frequency / 3;
        const lowerVisible = peaks.some(p => p.prominence >= 15 && Math.abs(p.frequency - lower) <= Math.max(1.5, lower * 0.015));
        const unexplained = peaks.some(p => {
          const h = Math.round(p.frequency / lower);
          return h >= 1 && h <= 12 && h % 3 && Math.abs(p.frequency / h - lower) <= Math.max(1.5, lower * 0.015)
            && p.power >= peak.power * 0.1;
        });
        if (!lowerVisible && !unexplained && filteredPeriodResidual(input, rate, peak.frequency, analysis) <= 0.35) {
          const measured = raw.frequency * 3;
          raw = { ...raw, frequency: agrees(peak.frequency, measured, 5) ? measured : peak.frequency };
        }
      }
    }
    if (raw && 'oddOnly' in raw && anchor && time - anchor.time > 300 && !agrees(raw.frequency, anchor.frequency, 50)
      && filteredPeriodResidual(input, rate, raw.frequency, analysis) > 0.7) raw = null;
    if (!raw) { evidence = null; return null; }
    if (raw.confidence < 0.75) { evidence = null; return raw; }
    anchor = { frequency: raw.frequency, time };
    accepted++;
    if (accepted > 5 && raw.confidence < 0.98 && !('oddOnly' in raw)) {
      peaks ??= analysis.peaks(input, rate);
      const peak = peaks.find(p => validFrequency(p.frequency) && p.prominence >= 1000 && agrees(p.frequency, raw!.frequency, 15));
      const conflicting = peak && peaks.some(p => {
        const h = Math.round(p.frequency / peak.frequency);
        return p.frequency >= peak.frequency * 0.75 && h <= 8 && p.power >= peak.power * 0.1
          && !agrees(p.frequency, peak.frequency * h, 5);
      });
      if (!peak || conflicting || filteredPeriodResidual(input, rate, peak.frequency, analysis) > 0.5) evidence = null;
      else {
        if (!evidence || time - evidence.last > 32 || !agrees(peak.frequency, evidence.frequency, 5))
          evidence = { frequency: peak.frequency, first: time, last: time };
        else evidence = { ...evidence, frequency: peak.frequency, last: time };
        if (time - evidence.first >= 64) raw = { ...raw, frequency: peak.frequency };
      }
    } else evidence = null;
    // Corroboration is provenance, not an inflated confidence score. The motion
    // layer may use it to release damping on a genuine small adjustment.
    if (raw.confidence >= 0.95 && raw.confidence < 0.98 && !('oddOnly' in raw)) {
      peaks ??= analysis.peaks(input, rate);
      const peak = peaks[0];
      if (peak && peak.prominence >= 50 && agrees(peak.frequency, raw.frequency, 5)
        && filteredPeriodResidual(input, rate, raw.frequency, analysis) <= 0.5) return Object.assign({}, raw, { foregroundAgrees: true });
    }
    return raw;
  };
}

export function detectPitch(input: Float32Array, sampleRate: number, ranking: SpectralRanking = 'prominence', analysis?: FrameAnalysis): Pitch | null {
  // Independently measure the capture-rate band before interpreting a
  // decimated period. This filtered signal is also used for lag refinement.
  let filteredInput = analysis ? analysis.filtered(input, sampleRate) : Float64Array.from(input);
  if (!analysis) bandpass(filteredInput, sampleRate);
  const stride = Math.max(1, Math.floor(sampleRate / 12000));
  const length = Math.floor(input.length / stride);
  const samples = new Float64Array(length);
  let mean = 0;
  for (let i = 0; i < length; i++) {
    let sum = 0;
    for (let j = 0; j < stride; j++) sum += input[i * stride + j];
    samples[i] = sum / stride;
    mean += samples[i];
  }
  mean /= length;
  let energy = 0;
  for (let i = 0; i < length; i++) {
    samples[i] -= mean;
    energy += samples[i] * samples[i];
  }
  let rms = Math.sqrt(energy / length);
  if (!Number.isFinite(rms) || rms < 0.000015) return null;
  const rate = sampleRate / stride;
  // Quiet phone recordings often contain more high-frequency room/hiss energy
  // than string energy. A uke-specific band-pass retains the fundamental and
  // lower partials before the periodicity test, instead of raising the gate.
  bandpass(samples, rate);
  const start = Math.floor(rate * 0.012); // Discard filter startup transient.
  let physicalEnergy = 0, foldedEnergy = 0, originalEnergy = 0, originalMean = 0;
  const physicalStart = Math.ceil(sampleRate * 0.012);
  for (let i = physicalStart; i < input.length; i++) originalMean += input[i];
  originalMean /= input.length - physicalStart;
  for (let i = physicalStart; i < input.length; i++) originalEnergy += (input[i] - originalMean) ** 2;
  for (let i = physicalStart; i < input.length; i++) physicalEnergy += filteredInput[i] ** 2;
  for (let i = start; i < length; i++) foldedEnergy += samples[i] ** 2;
  const physicalPower = physicalEnergy / (input.length - physicalStart);
  const outOfBandDominates = physicalPower < originalEnergy / (input.length - physicalStart) * 0.01;
  let aliasFiltered = false;
  if (physicalPower < 0.000015 ** 2) return null;
  if (outOfBandDominates) {
    // A very large out-of-band source can leave coherent stop-band residue.
    // Require an actual unfolded partial, not just repetition at a multiple of
    // that source's period. Keep the absolute floor tied to existing eligibility
    // so a genuine quiet string need not compete with the interferer's level.
    const minimumPeakPower = input.length ** 2 * 0.000015 ** 2 / 16;
    if (!hasUnfoldedPitchSupport(analysis ? analysis.peaks(input, sampleRate) : spectralPeaks(input, sampleRate), minimumPeakPower)) return null;
  }
  if (outOfBandDominates || foldedEnergy / (length - start) > physicalPower * 4) {
    aliasFiltered = true;
    // Strong out-of-band input or >6 dB of excess apparent low-band energy
    // makes folding unsafe. Re-analyse a prefiltered decimation,
    // rather than vetoing a genuine weak string mixed with the interference.
    const antiAliased = Float64Array.from(input);
    // Eighth-order Butterworth at half the decimated Nyquist preserves the
    // harmonic series below 3–3.7 kHz, unlike the narrow periodicity bandpass.
    for (const q of [0.50979558, 0.60134489, 0.89997622, 2.56291545])
      filter(antiAliased, sampleRate, rate / 4, q, false);
    input = Float32Array.from(antiAliased);
    filteredInput = Float64Array.from(input);
    bandpass(filteredInput, sampleRate);
    for (let i = 0; i < length; i++) {
      let sum = 0;
      for (let j = 0; j < stride; j++) sum += input[i * stride + j];
      samples[i] = sum / stride;
    }
    bandpass(samples, rate);
    rms = Math.sqrt(physicalPower);
  }
  const maxLag = Math.min(Math.floor(rate / 110), Math.floor(length / 2) - 1);
  const minLag = Math.max(2, Math.floor(rate / 1100));
  const window = length - maxLag;
  const difference = new Float64Array(maxLag + 1);
  difference[0] = 1;
  let cumulative = 0;
  for (let lag = 1; lag <= maxLag; lag++) {
    let sum = 0;
    for (let i = start; i < window; i++) {
      const delta = samples[i] - samples[i + lag];
      sum += delta * delta;
    }
    cumulative += sum;
    difference[lag] = cumulative ? sum * lag / cumulative : 1;
  }
  let best = -1;
  // First good valley, not global minimum: avoids subharmonic/octave errors.
  for (let lag = minLag; lag < maxLag; lag++) {
    if (difference[lag] < 0.16) {
      while (lag + 1 < maxLag && difference[lag + 1] < difference[lag]) lag++;
      best = lag;
      break;
    }
  }
  if (best < 0) {
    for (let lag = minLag + 1; lag < maxLag; lag++) {
      if (best < 0 || difference[lag] < difference[best]) best = lag;
    }
    if (best < 0 || difference[best] > 0.25) {
      const spectral = analysis ? analysis.spectral(input, sampleRate, ranking) : detectSpectralPitch(input, sampleRate, ranking);
      return spectral ? { ...spectral, rms } : null;
    }
  }
  const left = difference[best - 1];
  const center = difference[best];
  const right = difference[best + 1];
  const denominator = left - 2 * center + right;
  const offset = denominator ? Math.max(-1, Math.min(1, 0.5 * (left - right) / denominator)) : 0;
  // Refine on original-rate samples. Parabolic YIN interpolation at the
  // decimated rate alone is biased by ~1 cent on the highest uke strings.
  const approximateLag = (best + offset) * stride;
  const first = Math.max(2, Math.floor(approximateLag) - stride);
  const last = Math.min(input.length / 2 - 2, Math.ceil(approximateLag) + stride);
  const originalWindow = input.length - Math.ceil(last) - 1;
  const scoreStart = Math.ceil(sampleRate * 0.012);
  const raw = refine(input, sampleRate, first, last, originalWindow, 0, scoreStart);
  if (!validFrequency(raw.frequency)) {
    const spectral = analysis ? analysis.spectral(input, sampleRate, ranking) : detectSpectralPitch(input, sampleRate, ranking);
    return spectral?.oddOnly ? { ...spectral, rms } : null;
  }
  const filtered = refine(filteredInput, sampleRate, first, last, originalWindow, scoreStart, scoreStart);
  // Narrow filtering can discard useful harmonics in quiet recordings. Use it
  // only for a fourfold improvement in periodic evidence, not confidence alone.
  // The anti-alias path already transformed the raw input, so refine its
  // steady-state filtered region rather than fitting filter startup at zero.
  const frequency = validFrequency(filtered.frequency) && (aliasFiltered || filtered.residual < 0.25 * raw.residual)
    ? filtered.frequency : raw.frequency;
  // Weak periodic estimates can lock onto twice the true period in a noisy
  // decay. An octave correction needs independent harmonic evidence and a weak
  // observed lower peak; confidence alone is not evidence of an octave error.
  if (aliasFiltered || 1 - center < 0.95) {
    const spectral = analysis ? analysis.spectral(input, sampleRate, ranking) : detectSpectralPitch(input, sampleRate, ranking);
    if (spectral?.oddOnly) return { ...spectral, rms };
    if (spectral && Math.abs(1200 * Math.log2(spectral.frequency / (2 * frequency))) <= 50) {
      const peaks = analysis ? analysis.peaks(input, sampleRate) : spectralPeaks(input, sampleRate);
      const peakPower = (hz: number) => {
        let power = 0;
        for (const peak of peaks) {
          if (Math.abs(peak.frequency - hz) <= Math.max(1.5, hz * 0.015)) power = Math.max(power, peak.power);
        }
        return power;
      };
      const higherPower = peakPower(spectral.frequency);
      // A missing fundamental can still be real: odd lower harmonics cannot be
      // explained by an octave-up series. Check at half the spectral candidate
      // too: weak YIN refinement can drift away from the actual lower partials.
      const lowerFrequency = spectral.frequency / 2;
      let lowerEvidence = Math.max(peakPower(frequency), peakPower(lowerFrequency));
      for (let harmonic = 3; harmonic <= 11; harmonic += 2) {
        lowerEvidence = Math.max(lowerEvidence, peakPower(lowerFrequency * harmonic));
      }
      if (higherPower > 0 && lowerEvidence < 0.1 * higherPower) return { ...spectral, rms };
    }
  }
  return { frequency, confidence: 1 - center, rms };
}
