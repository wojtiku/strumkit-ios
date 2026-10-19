/**
 * Minimal, dependency-free RIFF/WAVE reader used by the fixture analyzer and tests.
 *
 * Chunk-based rather than fixed-offset so that `LIST`/metadata chunks in the middle of a
 * file (the supplied fixtures carry a `LIST INFO` chunk) and unknown chunks are handled
 * without guessing. Supported sample encodings:
 *
 *   - WAVE_FORMAT_PCM (0x0001): 16/24/32-bit integer
 *   - WAVE_FORMAT_IEEE_FLOAT (0x0003): 32/64-bit float
 *   - WAVE_FORMAT_EXTENSIBLE (0xFFFE): the real encoding is taken from the SubFormat GUID
 *
 * The supplied quiet/tuning fixtures are 32-bit IEEE float wrapped in EXTENSIBLE, so the
 * EXTENSIBLE path is exercised by real files, not only by the synthetic encoder below.
 */

export type SampleFormat = 'pcm16' | 'pcm24' | 'pcm32' | 'float32' | 'float64';

export interface WavData {
  /** Raw wFormatTag from the `fmt ` chunk (0x0001, 0x0003 or 0xFFFE). */
  containerFormat: number;
  /** Resolved sample encoding after unwrapping WAVE_FORMAT_EXTENSIBLE. */
  format: SampleFormat;
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  /** Samples per channel actually present in the file. */
  frames: number;
  durationSeconds: number;
  /** Mono mixdown (channel average) normalised to [-1, 1]. */
  samples: Float32Array;
}

export class WavParseError extends Error {}

const FOURCC_RIFF = 0x46464952; // "RIFF" little-endian
const FOURCC_WAVE = 0x45564157; // "WAVE"
const FOURCC_FMT = 0x20746d66; // "fmt "
const FOURCC_DATA = 0x61746164; // "data"

const FORMAT_PCM = 0x0001;
const FORMAT_IEEE_FLOAT = 0x0003;
const FORMAT_EXTENSIBLE = 0xfffe;

/** KSDATAFORMAT_SUBTYPE_* GUIDs: first four bytes little-endian give the format tag. */
const SUBTYPE_PCM = 0x00000001;
const SUBTYPE_IEEE_FLOAT = 0x00000003;

const text = (bytes: Uint8Array, offset: number, length: number) =>
  String.fromCharCode(...bytes.subarray(offset, offset + length));

function matchFormat(format: number, bits: number): SampleFormat | null {
  if (format === FORMAT_PCM) {
    if (bits === 16) return 'pcm16';
    if (bits === 24) return 'pcm24';
    if (bits === 32) return 'pcm32';
    return null;
  }
  if (format === FORMAT_IEEE_FLOAT) {
    if (bits === 32) return 'float32';
    if (bits === 64) return 'float64';
    return null;
  }
  return null;
}

interface Chunk {
  id: string;
  start: number;
  size: number;
}

function* chunks(bytes: Uint8Array): Generator<Chunk> {
  let offset = 12; // skip "RIFF" + size + "WAVE"
  while (offset + 8 <= bytes.length) {
    const id = text(bytes, offset, 4);
    const size = bytes[offset + 4] | (bytes[offset + 5] << 8) | (bytes[offset + 6] << 16) | (bytes[offset + 7] << 24);
    const start = offset + 8;
    // Streaming writers sometimes leave a bogus (0xFFFFFFFF) size; clamp so the walk ends.
    const available = Math.max(0, bytes.length - start);
    const clamped = size < 0 || size > available ? available : size >>> 0;
    yield { id, start, size: clamped };
    offset = start + clamped + (clamped & 1); // chunks are word aligned
  }
}

export function parseWav(bytes: Uint8Array): WavData {
  if (bytes.length < 12) throw new WavParseError(`too short to be a RIFF file (${bytes.length} bytes)`);
  if ((bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)) !== FOURCC_RIFF) {
    throw new WavParseError(`missing RIFF header, found "${text(bytes, 0, 4)}"`);
  }
  if (text(bytes, 8, 4) !== 'WAVE') throw new WavParseError(`RIFF container is not WAVE, found "${text(bytes, 8, 4)}"`);

  let formatTag = 0;
  let sampleRate = 0;
  let channels = 0;
  let bits = 0;
  let blockAlign = 0;
  let hasFmt = false;
  let data: Chunk | null = null;

  for (const chunk of chunks(bytes)) {
    if (chunk.id === 'fmt ') {
      if (chunk.size < 16) throw new WavParseError(`fmt chunk is ${chunk.size} bytes, need at least 16`);
      const view = new DataView(bytes.buffer, bytes.byteOffset + chunk.start, chunk.size);
      formatTag = view.getUint16(0, true);
      channels = view.getUint16(2, true);
      sampleRate = view.getUint32(4, true);
      blockAlign = view.getUint16(12, true);
      bits = view.getUint16(14, true);
      if (formatTag === FORMAT_EXTENSIBLE) {
        if (chunk.size < 40) throw new WavParseError(`EXTENSIBLE fmt chunk is ${chunk.size} bytes, need 40`);
        // SubFormat GUID begins at byte 24; its leading u32 carries the real format tag.
        const subFormat = view.getUint32(24, true);
        if (subFormat === SUBTYPE_PCM) formatTag = FORMAT_PCM;
        else if (subFormat === SUBTYPE_IEEE_FLOAT) formatTag = FORMAT_IEEE_FLOAT;
        else throw new WavParseError(`unsupported EXTENSIBLE SubFormat 0x${subFormat.toString(16)}`);
      }
      hasFmt = true;
    } else if (chunk.id === 'data' && !data) {
      data = chunk;
    }
  }

  if (!hasFmt) throw new WavParseError('no fmt chunk found');
  if (!data) throw new WavParseError('no data chunk found');
  if (!channels) throw new WavParseError('fmt chunk declares 0 channels');
  if (!sampleRate) throw new WavParseError('fmt chunk declares 0 sample rate');

  const format = matchFormat(formatTag, bits);
  if (!format) throw new WavParseError(`unsupported encoding: format 0x${formatTag.toString(16)}, ${bits}-bit`);

  const bytesPerSample = bits / 8;
  if (!blockAlign) blockAlign = bytesPerSample * channels;
  const frameCount = Math.floor(data.size / blockAlign);

  const view = new DataView(bytes.buffer, bytes.byteOffset + data.start, data.size);
  const samples = new Float32Array(frameCount);
  for (let frame = 0; frame < frameCount; frame++) {
    let mix = 0;
    for (let channel = 0; channel < channels; channel++) {
      const at = frame * blockAlign + channel * bytesPerSample;
      let value: number;
      if (format === 'pcm16') value = view.getInt16(at, true) / 32768;
      else if (format === 'pcm24') {
        const raw = view.getUint8(at) | (view.getUint8(at + 1) << 8) | (view.getUint8(at + 2) << 16);
        value = (raw & 0x800000 ? raw - 0x1000000 : raw) / 8388608; // sign-extend from 24 bits
      }
      else if (format === 'pcm32') value = view.getInt32(at, true) / 2147483648;
      else if (format === 'float32') value = view.getFloat32(at, true);
      else value = view.getFloat64(at, true);
      mix += value;
    }
    samples[frame] = mix / channels;
  }

  return {
    containerFormat: chunksFmtTag(bytes) ?? formatTag,
    format,
    sampleRate,
    channels,
    bitsPerSample: bits,
    frames: frameCount,
    durationSeconds: frameCount / sampleRate,
    samples,
  };
}

/** Original (possibly EXTENSIBLE) tag, kept so reports can show what was on disk. */
function chunksFmtTag(bytes: Uint8Array): number | null {
  for (const chunk of chunks(bytes)) {
    if (chunk.id !== 'fmt ' || chunk.size < 2) continue;
    return new DataView(bytes.buffer, bytes.byteOffset + chunk.start, chunk.size).getUint16(0, true);
  }
  return null;
}

export interface EncodeOptions {
  /** Emit WAVE_FORMAT_EXTENSIBLE (needed by some encoders for float). */
  extensible?: boolean;
  /** Extra chunk placed before `data`, e.g. a LIST/INFO chunk. */
  extraChunk?: { id: string; data: Uint8Array };
}

/** Writer used by the WAV tests to build known-good files without touching the fixtures. */
export function encodeWav(input: Float32Array | Float64Array, sampleRate: number, format: SampleFormat = 'float32', options: EncodeOptions = {}): Uint8Array {
  const channels = 1;
  const bytesPerSample = { pcm16: 2, pcm24: 3, pcm32: 4, float32: 4, float64: 8 }[format];
  const dataSize = input.length * bytesPerSample;
  const extensible = options.extensible ?? false;
  const fmtSize = extensible ? 40 : 16;
  const extra = options.extraChunk ? 8 + options.extraChunk.data.length + (options.extraChunk.data.length & 1) : 0;

  const bytes = new Uint8Array(12 + 8 + fmtSize + extra + 8 + dataSize);
  const view = new DataView(bytes.buffer);
  const ascii = (offset: number, value: string) => {
    for (let i = 0; i < value.length; i++) bytes[offset + i] = value.charCodeAt(i);
  };
  const tag = format.startsWith('float') ? FORMAT_IEEE_FLOAT : FORMAT_PCM;

  ascii(0, 'RIFF');
  view.setUint32(4, bytes.length - 8, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, fmtSize, true);
  view.setUint16(20, extensible ? FORMAT_EXTENSIBLE : tag, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * channels * bytesPerSample, true);
  view.setUint16(32, channels * bytesPerSample, true);
  view.setUint16(34, bytesPerSample * 8, true);

  let cursor = 12 + 8 + fmtSize;
  if (extensible) {
    view.setUint16(36, 22, true); // cbSize
    view.setUint16(38, bytesPerSample * 8, true); // valid bits per sample
    view.setUint32(40, 3, true); // channel mask: front centre
    view.setUint32(44, tag, true); // SubFormat GUID prefix identifies PCM vs IEEE float
    view.setUint16(48, 0, true);
    view.setUint16(50, 0x0010, true);
    for (let i = 0; i < 8; i++) bytes[52 + i] = [0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71][i];
  }
  if (options.extraChunk) {
    ascii(cursor, options.extraChunk.id);
    view.setUint32(cursor + 4, options.extraChunk.data.length, true);
    bytes.set(options.extraChunk.data, cursor + 8);
    cursor += extra;
  }
  ascii(cursor, 'data');
  view.setUint32(cursor + 4, dataSize, true);
  const dataAt = cursor + 8;
  for (let i = 0; i < input.length; i++) {
    const sample = Math.max(-1, Math.min(1, input[i]));
    const at = dataAt + i * bytesPerSample;
    if (format === 'pcm16') view.setInt16(at, Math.round(sample * 32767), true);
    else if (format === 'pcm24') {
      const raw = Math.round(sample * 8388607);
      const value = raw < 0 ? raw + 0x1000000 : raw; // 24-bit two's complement
      bytes[at] = value & 0xff;
      bytes[at + 1] = (value >> 8) & 0xff;
      bytes[at + 2] = (value >> 16) & 0xff;
    } else if (format === 'pcm32') view.setInt32(at, Math.round(sample * 2147483647), true);
    else if (format === 'float32') view.setFloat32(at, sample, true);
    else view.setFloat64(at, sample, true);
  }
  return bytes;
}