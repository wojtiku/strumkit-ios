import type { Pitch } from './pitch';

export interface Target { note: string; frequency: number }
function target(note: string, midi: number): Target {
  return { note, frequency: 440 * 2 ** ((midi - 69) / 12) };
}
export const TUNINGS: Record<string, Target[]> = {
  standard: [target('G4', 67), target('C4', 60), target('E4', 64), target('A4', 69)],
  'low-g': [target('G3', 55), target('C4', 60), target('E4', 64), target('A4', 69)],
  d: [target('A4', 69), target('D4', 62), target('F♯4', 66), target('B4', 71)],
  slack: [target('G4', 67), target('C4', 60), target('E4', 64), target('G4', 67)],
};
export const centsBetween = (frequency: number, reference: number) => 1200 * Math.log2(frequency / reference);
export interface Reading { frequency: number; cents: number; index: number; note: string; inTune: boolean; rms: number }
export type GreenPolicy = 'raw' | 'median-guard10' | 'median-guard20' | 'median-guard10-pause100' | 'median-guard20-pause100';
export type MotionTrial = 'product' | 'history-freshness' | 'history-contradiction' | 'history-contradiction5' | 'fast-persistence64' | 'fast-persistence96' | 'fast-persistence64-ramp32' | 'fast-persistence64-away' | 'fast-persistence64-away-rearm' | 'fast-persistence64-away-rearm-bootstrap';

/** Five-frame median rejects brief pluck transients; target hysteresis prevents flicker. */
export class TunerTracker {
  /** Bound same-target catch-up bursts; Infinity retains the uncapped control.
    * Non-raw green policies are offline experiments, never the product default.
    * Directional validation is shipped; explicit 'product' motion retains the
    * pre-validation gain policy for offline baseline reproduction.
    * Bootstrap threshold/seed overrides are offline probes; the validated
    * default uses the 0.98-confidence available-reading mean.
    * Decay motion and measured small-step release preserve genuine response;
    * explicit false reproduces the preceding accepted motion control.
    */
  constructor(private readonly maxSlewCentsPerMs = 0.75, private readonly greenPolicy: GreenPolicy = 'raw', private readonly motionTrial: MotionTrial = 'fast-persistence64-away-rearm-bootstrap', private readonly bootstrapConfidence = 0.98, private readonly bootstrapSeed: 'mean' | 'latest' = 'mean', private readonly decayDamping = motionTrial === 'fast-persistence64-away-rearm-bootstrap') {
    if (!(maxSlewCentsPerMs > 0)) throw new Error('Smoothing slew rate must be positive');
  }
  tuning = 'standard';
  auto = true;
  selected = 0;
  private history: number[] = [];
  private current: number | null = null;
  private pending: number | null = null;
  private pendingCount = 0;
  private pendingSince = -Infinity;
  private pendingTime = -Infinity;
  private smoothed: number | null = null;
  private lastTime = -Infinity;
  private lastPitchTime = -Infinity;
  private responsiveUntil = -Infinity;
  private settledSince: number | null = null;
  private rawDepartureCount = 0;
  private greenEvidenceMs = 0;
  private greenLastQualified = -Infinity;
  private greenPreviousQualified = false;
  private greenPreviousTime = -Infinity;
  private innovationAnchor: number | null = null;
  private innovationDirection = 0;
  private innovationLastTime = -Infinity;
  private innovationEvidenceMs = 0;
  private innovationPlateauMs = 0;
  private recoveringHistory = false;
  private bootstrapStrong = false;
  private bootstrapAvailable = true;
  private decayEnvelope: { time: number; rms: number; cents: number }[] = [];
  private dampedDecay = false;
  private decayMotionUntil = -Infinity;
  private smallPlateau: { cents: number; since: number; ready: boolean } | null = null;
  private smallStep: { direction: number; since: number } | null = null;
  private smallMotionUntil = -Infinity;
  private decayAcquired = -Infinity;
  private observedDecay = false;
  private decayLevel: number | null = null;

  private clearInnovation() {
    this.innovationAnchor = null;
    this.innovationDirection = 0;
    this.innovationLastTime = -Infinity;
    this.innovationEvidenceMs = 0;
    this.innovationPlateauMs = 0;
    this.recoveringHistory = false;
  }

  reset() {
    this.history = [];
    this.current = null;
    this.pending = null;
    this.pendingCount = 0;
    this.pendingSince = -Infinity;
    this.pendingTime = -Infinity;
    this.smoothed = null;
    this.bootstrapStrong = false;
    this.bootstrapAvailable = true;
    this.lastTime = -Infinity;
    this.lastPitchTime = -Infinity;
    this.responsiveUntil = -Infinity;
    this.settledSince = null;
    this.rawDepartureCount = 0;
    this.greenEvidenceMs = 0;
    this.greenLastQualified = -Infinity;
    this.greenPreviousQualified = false;
    this.greenPreviousTime = -Infinity;
    this.clearInnovation();
    this.decayEnvelope = []; this.dampedDecay = false; this.decayMotionUntil = -Infinity;
    this.smallPlateau = null; this.smallStep = null; this.smallMotionUntil = -Infinity;
    this.decayAcquired = -Infinity; this.observedDecay = false;
    this.decayLevel = null;
  }

  push(pitch: Pitch | null, time: number): Reading | null {
    const pauseGreen = this.greenPolicy.endsWith('-pause100');
    if (pauseGreen && time - this.greenLastQualified > 100) this.greenEvidenceMs = 0;
    // Identity follows the display hold, independently of the shorter pitch-history lifetime.
    if (this.lastTime !== -Infinity && time - this.lastTime > 1000) this.reset();
    if (time - this.lastPitchTime > 300) {
      this.history = [];
      if (this.motionTrial !== 'history-freshness') this.smoothed = null;
      this.responsiveUntil = -Infinity;
      this.settledSince = null;
      this.rawDepartureCount = 0;
      this.clearInnovation();
    }
    if (!pitch || pitch.confidence < 0.75) {
      if (this.decayDamping) { this.dampedDecay = false; this.decayEnvelope = []; this.smallStep = null; }
      if (this.history.length < 5) this.bootstrapStrong = false;
      if (this.motionTrial.startsWith('fast-persistence')) { this.clearInnovation(); this.responsiveUntil = -Infinity; }
      this.greenPreviousQualified = false;
      this.rawDepartureCount = 0;
      // A brief dropout may hold already-confirmed green, but must not complete
      // an unfinished confirmation while no new pitch evidence is arriving.
      if (this.settledSince !== null && this.lastTime - this.settledSince < 400) this.settledSince = null;
      this.pending = null;
      this.pendingCount = 0;
      return null;
    }
    // Missing estimates are not continuous evidence: limit one catch-up gain,
    // independently of the 300 ms history lifetime and one-second display hold.
    const elapsed = Math.max(1, Math.min(64, time - this.lastPitchTime));
    this.lastPitchTime = time;
    const targets = TUNINGS[this.tuning];
    let index = this.selected;
    if (this.auto) {
      const distances = targets.map(t => Math.abs(centsBetween(pitch.frequency, t.frequency)));
      index = distances.indexOf(Math.min(...distances));
      if (distances[index] > 250) {
        if (this.decayDamping) { this.dampedDecay = false; this.decayEnvelope = []; this.smallStep = null; }
        if (this.history.length < 5) this.bootstrapStrong = false;
        if (this.motionTrial.startsWith('fast-persistence')) { this.clearInnovation(); this.responsiveUntil = -Infinity; }
        this.greenPreviousQualified = false;
        this.rawDepartureCount = 0;
        if (this.settledSince !== null && this.lastTime - this.settledSince < 400) this.settledSince = null;
        this.pending = null;
        this.pendingCount = 0;
        return null;
      }
      if (this.current !== null && index !== this.current && distances[this.current] < distances[index] + 25) index = this.current;
    }
    if (index !== this.current || (this.smoothed === null && time - this.lastTime > 300)) {
      this.clearInnovation();
      this.greenPreviousQualified = false;
      this.greenEvidenceMs = 0;
      this.rawDepartureCount = 0;
      if (this.settledSince !== null && this.lastTime - this.settledSince < 400) this.settledSince = null;
      if (this.pending !== index || time - this.pendingTime > 150) {
        this.pending = index;
        this.pendingCount = 0;
        this.pendingSince = time;
      }
      this.pendingTime = time;
      this.pendingCount++;
      if (this.pendingCount < 2) return null;
      if (this.auto && this.current !== null && index !== this.current && time - this.pendingSince < 160) return null;
      this.current = index;
      this.decayAcquired = this.bootstrapAvailable ? time : -Infinity; this.observedDecay = false; this.decayEnvelope = [];
      this.decayLevel = null;
      this.dampedDecay = false; this.smallPlateau = null; this.smallStep = null;
      this.decayMotionUntil = -Infinity; this.smallMotionUntil = -Infinity;
      this.bootstrapStrong = this.bootstrapAvailable && pitch.confidence >= this.bootstrapConfidence && !('oddOnly' in pitch);
      this.bootstrapAvailable = false;
      this.history = [];
      this.smoothed = null;
      this.responsiveUntil = -Infinity;
      this.settledSince = null;
    }
    this.pending = null;
    this.pendingCount = 0;
    if (this.motionTrial === 'history-freshness' && time - this.lastTime > 300) {
      // Detector eligibility is not current-target numerical freshness. Replace
      // old votes but preserve the needle, so recovery is smoothed, not snapped.
      this.history = [];
      this.responsiveUntil = -Infinity;
      this.settledSince = null;
    }
    const historyAge = time - this.lastTime;
    this.lastTime = time;
    const cents = centsBetween(pitch.frequency, targets[index].frequency);
    if (this.decayDamping) {
      const last = this.decayEnvelope.at(-1);
      if (this.observedDecay && this.decayLevel !== null && pitch.rms >= this.decayLevel) {
        this.observedDecay = false; this.dampedDecay = false; this.decayMotionUntil = time + 300;
      }
      if (!this.smallPlateau || last && time - last.time > 300)
        this.smallPlateau = { cents, since: time, ready: false };
      const plateau = this.smallPlateau;
      const deviation = cents - plateau.cents;
      const corroborated = pitch.confidence >= 0.98 || pitch.confidence >= 0.95 && 'foregroundAgrees' in pitch && pitch.foregroundAgrees === true;
      if (plateau.ready && corroborated && !('oddOnly' in pitch) && Math.abs(deviation) > 12) {
        // The measured plateau release overlaps the >8-cent innovation path
        // through 12 cents. Beyond it, retire decay rather than trapping a turn
        // that crossed the release band between hops.
        this.dampedDecay = false; this.observedDecay = false; this.smallStep = null;
        this.decayMotionUntil = time + 300;
      }
      if (plateau.ready && corroborated && !('oddOnly' in pitch) && Math.abs(deviation) >= 2 && Math.abs(deviation) <= 12) {
        const direction = Math.sign(deviation);
        if (!this.smallStep || this.smallStep.direction !== direction || last && time - last.time > 64)
          this.smallStep = { direction, since: time };
        else if (time - this.smallStep.since >= 64) {
          this.smallMotionUntil = time + 250; this.decayMotionUntil = time + 300;
          this.dampedDecay = false; this.observedDecay = false; this.smallStep = null;
          this.smallPlateau = { cents, since: time, ready: false };
        }
      } else {
        this.smallStep = null;
        if (Math.abs(deviation) > 12 || !plateau.ready && Math.abs(deviation) > 1) this.smallPlateau = { cents, since: time, ready: false };
        // A tightly stable, strong waveform onset can establish a reference
        // before the normal 250-ms plateau. Subsequent motion still needs the
        // independent directional release above; continuous pluck relaxation
        // must not inherit fast gain merely from a large accumulated error.
        else if (pitch.confidence >= 0.95 && !('oddOnly' in pitch)
          && (time - plateau.since >= 250 || !this.observedDecay && this.bootstrapStrong
            && this.history.length < 5 && corroborated
            && time - plateau.since >= 20 && Math.abs(deviation) <= 0.25
            && this.history.every(value => Math.abs(value - plateau.cents) <= 0.25))) plateau.ready = true;
      }
      if (last && (time - last.time > 300 || Math.abs(cents - last.cents) > 8
        && (pitch.confidence >= 0.95 && !('oddOnly' in pitch) || Math.abs(cents - last.cents) > 20))) {
        this.dampedDecay = false; this.observedDecay = false; this.decayEnvelope = []; this.decayMotionUntil = time + 300;
      }
      this.decayEnvelope.push({ time, rms: pitch.rms, cents });
      // Keep at least 64 ms of physical evidence even at high capture rates.
      while (this.decayEnvelope.length > 4 && time - this.decayEnvelope[1].time >= 64 - 1e-9)
        this.decayEnvelope.shift();
      const envelope = this.decayEnvelope;
      if (time - this.decayAcquired <= 500 && pitch.confidence >= 0.98 && !('oddOnly' in pitch)
        && time >= this.decayMotionUntil && envelope.length >= 4
        && time - envelope[0].time >= 64 - 1e-9 && time - envelope[0].time <= 100
        // Preserve the 48-kHz policy (10% in 64 ms) in physical time,
        // rather than applying 10% over a sample-rate-dependent hop count.
        && envelope.every((p, i) => !i
          || p.rms < envelope[i - 1].rms * 0.9 ** ((p.time - envelope[i - 1].time) / 64))) {
        this.dampedDecay = true; this.observedDecay = true;
        this.decayLevel ??= envelope[0].rms;
      }
      if (this.dampedDecay && this.smoothed !== null && Math.abs(cents - this.smoothed) < 1) this.dampedDecay = false;
    }
    this.history.push(cents);
    if (this.history.length > 5) this.history.shift();
    const sorted = [...this.history].sort((a, b) => a - b);
    let median = sorted[Math.floor(sorted.length / 2)];
    const bootstrap = this.motionTrial === 'fast-persistence64-away-rearm-bootstrap';
    if (pitch.confidence < this.bootstrapConfidence || 'oddOnly' in pitch) this.bootstrapStrong = false;
    if (bootstrap && this.bootstrapStrong && this.history.length < 5) {
      // Seed from the currently available observations, not a latched first
      // waveform value. Once all five votes exist, normal tracking resumes.
      median = this.bootstrapSeed === 'latest' ? cents : this.history.reduce((sum, value) => sum + value, 0) / this.history.length;
      this.smoothed = median;
    }
    if (this.motionTrial.startsWith('history-contradiction') && historyAge > 300 && this.smoothed !== null
      && (median - this.smoothed) * (cents - this.smoothed) < 0) {
      this.history = [cents]; median = cents;
      this.responsiveUntil = -Infinity;
      this.settledSince = null;
      this.recoveringHistory = true;
    }
    if (this.recoveringHistory && this.history.length >= (this.motionTrial === 'history-contradiction5' ? 5 : 3)) this.recoveringHistory = false;
    if (this.smoothed === null) {
      this.smoothed = median;
    } else {
      // Calm small fluctuations, but follow a confirmed peg adjustment quickly.
      // Time-based gains behave consistently at different device sample rates.
      let allowFast = !this.recoveringHistory;
      if (this.motionTrial.startsWith('fast-persistence')) {
        if (this.motionTrial.startsWith('fast-persistence64-away-rearm')) {
          // Retire old recovery evidence only after a continuously observed,
          // near-target plateau. Keep the fixed anchor during genuine ramps.
          const continuous = time - this.innovationLastTime <= 64;
          const settled = Math.abs(cents - this.smoothed) <= 2 && Math.abs(median - this.smoothed) <= 2
            && Math.abs(cents) <= 5 && Math.abs(median) <= 5 && Math.abs(this.smoothed) <= 5;
          this.innovationPlateauMs = continuous && settled ? this.innovationPlateauMs + time - this.innovationLastTime : 0;
          if (this.innovationPlateauMs >= 64) {
            this.clearInnovation(); this.responsiveUntil = -Infinity;
          }
        }
        const difference = cents - (this.innovationAnchor ?? this.smoothed);
        const direction = Math.abs(difference) > 8 ? Math.sign(difference) : 0;
        if (!direction) {
          this.clearInnovation(); this.responsiveUntil = -Infinity;
        } else if (direction !== this.innovationDirection || time - this.innovationLastTime > 64) {
          this.clearInnovation(); this.responsiveUntil = -Infinity;
          const currentDifference = cents - this.smoothed;
          if (Math.abs(currentDifference) > 8) {
            this.innovationAnchor = this.smoothed;
            this.innovationDirection = Math.sign(currentDifference);
            this.innovationLastTime = time;
          }
        } else {
          this.innovationEvidenceMs += time - this.innovationLastTime;
          this.innovationLastTime = time;
        }
        const duration = this.motionTrial.startsWith('fast-persistence64') ? 64 : 96;
        allowFast = this.innovationEvidenceMs >= duration - 1e-9
          && Math.sign(median - this.smoothed) === this.innovationDirection
          && Math.sign(cents - this.smoothed) === this.innovationDirection;
        if (this.motionTrial.startsWith('fast-persistence64-away') && Math.abs(median) < Math.abs(this.smoothed)
          && Math.abs(cents) < Math.abs(this.smoothed)
          && (median - this.smoothed) * (cents - this.smoothed) > 0) allowFast = true;
        if (!allowFast) this.responsiveUntil = -Infinity;
      }
      if (allowFast && Math.abs(median - this.smoothed) > 8) this.responsiveUntil = time + 180;
      const nearTarget = Math.abs(cents) <= 5 && Math.abs(median) <= 5 && Math.abs(this.smoothed) <= 5;
      let timeConstant = time < this.responsiveUntil || this.decayDamping && time < this.smallMotionUntil ? 50
        : this.decayDamping && this.observedDecay && !nearTarget ? 500 : 220;
      if (this.decayDamping && this.dampedDecay && !nearTarget) timeConstant = 1000;
      if (this.motionTrial === 'fast-persistence64-ramp32' && timeConstant === 50)
        timeConstant = 220 - 170 * Math.min(1, Math.max(0, (this.innovationEvidenceMs - 64) / 32));
      const gain = 1 - Math.exp(-elapsed / timeConstant);
      const change = gain * (median - this.smoothed);
      const limit = this.maxSlewCentsPerMs * elapsed;
      this.smoothed += Math.max(-limit, Math.min(limit, change));
    }
    // Default: sustained raw evidence, independently of the fast needle.
    // Offline alternatives use the measured median, not the smoothed needle
    // alone. Their immediate and consecutive raw-departure guards remain live.
    this.rawDepartureCount = Math.abs(cents) > 5 ? this.rawDepartureCount + 1 : 0;
    const measuredInRange = this.greenPolicy === 'raw' ? Math.abs(cents) <= 5
      : Math.abs(median) <= 5 && Math.abs(cents) <= (this.greenPolicy.startsWith('median-guard10') ? 10 : 20)
        && this.rawDepartureCount < 2;
    if (measuredInRange && Math.abs(this.smoothed) <= 5) this.settledSince ??= time;
    else this.settledSince = null;
    const qualified = measuredInRange && Math.abs(this.smoothed) <= 5;
    if (pauseGreen) {
      if (!qualified) this.greenEvidenceMs = 0;
      else {
        if (this.greenPreviousQualified && time - this.greenPreviousTime <= 64) this.greenEvidenceMs += Math.max(0, time - this.greenPreviousTime);
        this.greenLastQualified = time;
      }
      this.greenPreviousQualified = qualified;
      this.greenPreviousTime = time;
    }
    const inTune = pauseGreen ? qualified && this.greenEvidenceMs >= 400 - 1e-9
      : this.settledSince !== null && time - this.settledSince >= 400;
    return { frequency: targets[index].frequency * 2 ** (this.smoothed / 1200), cents: this.smoothed, index, note: targets[index].note, inTune, rms: pitch.rms };
  }
}
