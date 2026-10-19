import type { Reading } from './tuning';

/** Calm the display without reducing detector cadence or adding pitch latency. */
export class TunerPresentation {
  private latest: Reading | null = null;
  private lastReading = -Infinity;
  private lastDisplay = -Infinity;

  reset() {
    this.latest = null;
    this.lastReading = -Infinity;
    this.lastDisplay = -Infinity;
  }

  /** Undefined skips rendering; null clears an expired reading. Times are milliseconds. */
  push(reading: Reading | null, time: number): Reading | null | undefined {
    if (reading) {
      this.latest = reading;
      this.lastReading = time;
    }
    if (time - this.lastDisplay < 1000 / 12) return undefined;
    this.lastDisplay = time;
    if (time - this.lastReading >= 1000) this.latest = null;
    return this.latest;
  }
}
