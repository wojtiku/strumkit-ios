/** Windowed spectrum used to recover harmonic structure when time-domain SNR is low. */
export function powerSpectrum(input: Float32Array): Float64Array {
  const size = 2 ** Math.ceil(Math.log2(input.length * 2));
  const real = new Float64Array(size);
  const imaginary = new Float64Array(size);
  let mean = 0;
  for (const sample of input) mean += sample;
  mean /= input.length;
  for (let i = 0; i < input.length; i++) {
    real[i] = (input[i] - mean) * (0.5 - 0.5 * Math.cos(2 * Math.PI * i / (input.length - 1)));
  }
  for (let i = 1, j = 0; i < size; i++) {
    let bit = size >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { const value = real[i]; real[i] = real[j]; real[j] = value; }
  }
  for (let length = 2; length <= size; length <<= 1) {
    const angle = -2 * Math.PI / length;
    const stepR = Math.cos(angle), stepI = Math.sin(angle);
    for (let start = 0; start < size; start += length) {
      let wr = 1, wi = 0;
      for (let j = 0; j < length / 2; j++) {
        const a = start + j, b = a + length / 2;
        const r = wr * real[b] - wi * imaginary[b];
        const im = wr * imaginary[b] + wi * real[b];
        real[b] = real[a] - r; imaginary[b] = imaginary[a] - im;
        real[a] += r; imaginary[a] += im;
        const nextR = wr * stepR - wi * stepI;
        wi = wr * stepI + wi * stepR; wr = nextR;
      }
    }
  }
  const power = new Float64Array(size / 2);
  for (let i = 0; i < power.length; i++) power[i] = real[i] ** 2 + imaginary[i] ** 2;
  return power;
}

export interface SpectralPeak { frequency: number; power: number; prominence: number }

/** Actual in-range energy or a coprime partial series, not a single high tone's
 * many mathematically possible subharmonics. Used only when out-of-band input
 * dominates, so a loud interferer cannot set a relative floor for quiet notes. */
export function hasUnfoldedPitchSupport(peaks: SpectralPeak[], minimumPower: number) {
  const audible = peaks.filter(p => p.prominence >= 15 && p.power >= minimumPower);
  if (audible.some(p => p.frequency >= 110 && p.frequency <= 1100)) return true;
  const gcd = (a: number, b: number): number => b ? gcd(b, a % b) : a;
  for (const peak of audible) for (let divisor = 2; divisor <= 8; divisor++) {
    const candidate = peak.frequency / divisor;
    if (candidate < 110 || candidate > 1100) continue;
    const harmonics = new Set(audible.flatMap(partial => {
      const harmonic = Math.round(partial.frequency / candidate);
      return harmonic >= 1 && harmonic <= 12
        && Math.abs(partial.frequency / harmonic - candidate) <= Math.max(1.5, candidate * 0.008) ? [harmonic] : [];
    }));
    if (harmonics.size >= 3 && [...harmonics].reduce(gcd) === 1) return true;
  }
  return false;
}

export function spectralPeaks(input: Float32Array, sampleRate: number, power = powerSpectrum(input)): SpectralPeak[] {
  const binHz = sampleRate / (power.length * 2);
  const peaks: SpectralPeak[] = [];
  for (let i = Math.ceil(110 / binHz); i < Math.min(power.length - 20, 6000 / binHz); i++) {
    if (power[i] <= power[i - 1] || power[i] <= power[i + 1]) continue;
    let background = 0, count = 0;
    // Exclude the window main lobe; compare against nearby noise, not global RMS.
    for (let j = Math.max(1, i - 18); j <= i + 18; j++) {
      if (Math.abs(j - i) <= 5) continue;
      background += power[j]; count++;
    }
    const prominence = power[i] / Math.max(background / count, 1e-24);
    if (prominence < 4) continue;
    const a = Math.log(Math.max(power[i - 1], 1e-24));
    const b = Math.log(Math.max(power[i], 1e-24));
    const c = Math.log(Math.max(power[i + 1], 1e-24));
    const offset = Math.max(-0.5, Math.min(0.5, (a - c) / (2 * (a - 2 * b + c)) || 0));
    peaks.push({ frequency: (i + offset) * binHz, power: power[i], prominence });
  }
  return peaks.sort((a, b) => b.power - a.power).slice(0, 40);
}

/** Require several mutually consistent partials; do not snap estimates to uke notes. */
export type SpectralRanking = 'prominence' | 'supported-power';
export function detectSpectralPitch(input: Float32Array, sampleRate: number, ranking: SpectralRanking = 'prominence',
  power = powerSpectrum(input), peaks = spectralPeaks(input, sampleRate, power)): { frequency: number; confidence: number; oddOnly: boolean } | null {
  let totalPower = 0;
  for (const value of power) totalPower += value;
  type Candidate = { frequency: number; score: number; count: number; oddOnly: boolean; strongCount: number; matchedPower: number };
  let best: Candidate | null = null, bestOdd: Candidate | null = null;
  for (const peak of peaks) {
    for (let harmonic = 1; harmonic <= 8; harmonic++) {
      const candidate = peak.frequency / harmonic;
      if (candidate < 110 || candidate > 1100) continue;
      let score = 0, weightSum = 0, frequencySum = 0, count = 0, matchedPower = 0;
      let hasLowPartial = false;
      const oddPartials = new Set<number>();
      let strongCount = 0, strongWeight = 0, strongFrequency = 0;
      for (const partial of peaks) {
        const h = Math.round(partial.frequency / candidate);
        if (h < 1 || h > 12) continue;
        const error = Math.abs(partial.frequency / h - candidate);
        if (error > Math.max(1.5, candidate * 0.008)) continue;
        const weight = Math.min(partial.prominence, 100) / Math.sqrt(h);
        score += weight;
        weightSum += weight;
        frequencySum += weight * partial.frequency / h;
        count++;
        matchedPower += partial.power;
        if (partial.power >= peaks[0].power * 0.01) {
          strongCount++;
          strongWeight += weight;
          strongFrequency += weight * partial.frequency / h;
        }
        if (h <= 2) hasLowPartial = true;
        if ([3, 5, 7].includes(h) && partial.prominence >= 15 && partial.power >= peaks[0].power * 0.01
          && error <= Math.max(0.4, candidate * 0.002)) oddPartials.add(h);
      }
      if (count < 3 || score < 50) continue;
      if (!hasLowPartial) {
        if (oddPartials.size !== 3) continue;
        // Resampling can add vanishingly small but locally prominent peaks.
        // Do not let those artifacts bias this new, independently gated path.
        weightSum = strongWeight;
        frequencySum = strongFrequency;
        count = strongCount;
        // A coprime odd series can reveal an absent fundamental, but require
        // independent waveform repetition rather than accepting peak ratios alone.
        const lag = sampleRate / (frequencySum / weightSum);
        const whole = Math.floor(lag), fraction = lag - whole;
        let difference = 0, energy = 0;
        for (let i = 0; i < input.length - whole - 1; i++) {
          const delayed = input[i + whole] * (1 - fraction) + input[i + whole + 1] * fraction;
          difference += (input[i] - delayed) ** 2;
          energy += input[i] ** 2 + delayed ** 2;
        }
        if (energy === 0 || difference / energy > 0.35) continue;
      }
      // Prefer a real fundamental over its subharmonics with the same matched peaks.
      score *= 1 + 0.03 * Math.log2(candidate / 110);
      // Alternate family ranking, not a new hard support veto. Eligibility
      // and precision weights remain unchanged; callers corroborate a change.
      // Do not rank weak artifact
      // families above stronger families solely on local noise contrast.
      if (ranking === 'supported-power') score *= Math.sqrt(matchedPower / Math.max(totalPower, 1e-24));
      const result = { frequency: frequencySum / weightSum, score, count, oddOnly: !hasLowPartial, strongCount, matchedPower };
      if (!best || score > best.score) best = result;
      if (result.oddOnly && (!bestOdd || score > bestOdd.score)) bestOdd = result;
    }
  }
  // Only displace an artifact-supported winner, not another well-supported series.
  if (bestOdd && best && best.strongCount < 3) best = bestOdd;
  // Validate the winner without promoting a different, previously losing series.
  // Rough Hann main-lobe factor 3; reject only negligible (<1%) energy support.
  if (best && 3 * best.matchedPower < 0.01 * totalPower) return null;
  return best ? { frequency: best.frequency, confidence: Math.min(0.98, 0.8 + best.count * 0.02), oddOnly: best.oddOnly } : null;
}
