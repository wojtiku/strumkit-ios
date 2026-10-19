import type { Reading } from './tuning';

/** Visual proximity is not measured confirmation. Only fresh tracker readings
 * can change proximity or earn a one-per-string completion event.
 */
export class TuningFeedback {
  private nearby: { note: string; index: number } | null = null;
  private completed = new Set<number>();

  reset() { this.completed.clear(); this.clearReading(); }
  clearReading() { this.nearby = null; }

  observe(reading: Reading | null): boolean {
    if (!reading) return false;
    this.nearby = Number.isFinite(reading.cents) && Math.abs(reading.cents) <= 5
      ? { note: reading.note, index: reading.index } : null;
    if (!reading.inTune || this.completed.has(reading.index)) return false;
    this.completed.add(reading.index);
    return true;
  }

  green(display: { note: string; cents: number; index?: number; inTune?: boolean } | null): boolean {
    if (display?.inTune && display.index !== undefined && this.completed.has(display.index)) return true;
    return !!display && !!this.nearby && this.nearby.note === display.note
      && (display.index === undefined || display.index === this.nearby.index)
      && Number.isFinite(display.cents) && Math.abs(display.cents) <= 5;
  }
}
