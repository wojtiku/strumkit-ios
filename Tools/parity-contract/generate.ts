import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadAllCases } from './corpus';
import { runTestCase, hashTrace, type GoldenTrace } from './runner';

const HERE = dirname(fileURLToPath(import.meta.url));

const EXPECTED_SOURCE_HASHES: Record<string, string> = {
  'pitch.ts': '009c7b4c357fe729012da21394c69e433264a525b6c0e38216e3fb7bd7ca4fe1',
  'spectrum.ts': '90c67aec8cf7769380da5dfb93d95a1b61725feb9fcfc814b0a7b022e57b1b81',
  'tuning.ts': 'a744f4cc7033e885b2d48608b1e9327e4fb22606a781be1de2870f3de9aa83ff',
  'audio-worklet.ts': '99e5390bee0d655ee2a30c02b9dbf0594bb1202843e7573421f7e04a6a340f9c',
  'presentation.ts': 'f16d7bc502a6350e6a4db29b542621174acd652ad7db75fe0eca6767ba0bcc0f',
  'feedback.ts': '5b90171a9e113c12cdcbaa0243dd4a5260036e52c550476d6ae28c714cab5ab1',
  'main.ts': 'dd31f09b268ac673abef9cba337a032caaec0799975c4fa3fe372f307ec322b7',
};

function verifySourceHashes() {
  for (const [file, expectedHash] of Object.entries(EXPECTED_SOURCE_HASHES)) {
    const filePath = resolve(HERE, 'reference-source', file);
    const content = readFileSync(filePath);
    const actualHash = createHash('sha256').update(content).digest('hex');
    if (actualHash !== expectedHash) {
      throw new Error(`Source hash mismatch for ${file}: expected ${expectedHash}, got ${actualHash}`);
    }
  }
}

export function generateCorpusAndTraces() {
  verifySourceHashes();

  const cases = loadAllCases();
  console.log(`Loaded ${cases.length} cases.`);

  const manifestCases: any[] = [];
  let totalFrames = 0;

  const categoryCounts: Record<string, number> = {};

  for (const testCase of cases) {
    categoryCounts[testCase.category] = (categoryCounts[testCase.category] ?? 0) + 1;
    const trace = runTestCase(testCase);
    totalFrames += trace.frameCount;

    const traceRelDir = `traces/${testCase.category}`;
    const traceDir = resolve(HERE, traceRelDir);
    mkdirSync(traceDir, { recursive: true });

    const traceRelPath = `${traceRelDir}/${testCase.name}.json`;
    const traceFullPath = resolve(HERE, traceRelPath);
    const traceJson = JSON.stringify(trace, null, 2);
    writeFileSync(traceFullPath, traceJson, 'utf8');

    const traceSha256 = hashTrace(trace);

    manifestCases.push({
      name: testCase.name,
      category: testCase.category,
      description: testCase.description,
      sampleRate: testCase.sampleRate,
      sampleCount: testCase.samples.length,
      sampleSha256: trace.sampleSha256,
      frameCount: trace.frameCount,
      traceFile: traceRelPath,
      traceSha256,
      confirmedNotes: trace.confirmedNotes,
    });
  }

  const manifest = {
    schemaVersion: 1,
    authority: {
      gitCommit: '6a5a4f30304f392ff9dec9997633f83c295e1e1b',
      nativeBaseCommit: 'b5075fd94bcb7d9df8161c98536fe08d09bcdd27',
      author: 'Wojciech Urbański <wojtiku@gmail.com>',
      sourceHashes: EXPECTED_SOURCE_HASHES,
    },
    numericBudgets: {
      frequencyAbsoluteHz: 0.000001,
      rawCentsAbsolute: 0.000001,
      smoothedCentsAbsolute: 0.000001,
      confidenceAbsolute: 0.000000001,
      rmsAbsolute: 0.0000000001,
      rmsRelative: 0.0000001,
      sampleIndexExact: true,
      timestampConversionErrorMaxMs: 0.000001,
    },
    discreteRules: {
      nullMaskExact: true,
      targetNotesExact: true,
      targetIndicesExact: true,
      publicationSlotsExact: true,
      inTuneTransitionsExact: true,
      confirmationEventsExact: true,
      optionalFlagsExact: true,
    },
    clockConventions: {
      windowSizeSamples: 4096,
      hopSizeSamples: 1024,
      workletOffsetQuantumSamples: 128,
      workletOffsetFormula: 'sampleIndex - 128',
      windowEndFormula: 'sampleIndex',
      workletTimeMsFormula: '(sampleIndex - 128) / sampleRate * 1000',
      windowEndTimeMsFormula: 'sampleIndex / sampleRate * 1000',
    },
    summary: {
      totalCases: cases.length,
      categoryCounts,
      productCases:
        (categoryCounts['product-fixtures'] ?? 0) +
        (categoryCounts['product-controlled-44100'] ?? 0) +
        (categoryCounts['product-controlled-48000'] ?? 0),
      stressCases:
        (categoryCounts['stress-standard'] ?? 0) +
        (categoryCounts['stress-odd'] ?? 0),
      targetedCases: categoryCounts['targeted'] ?? 0,
      totalFrames,
    },
    cases: manifestCases,
  };

  mkdirSync(resolve(HERE, 'schema'), { recursive: true });
  writeFileSync(resolve(HERE, 'schema', 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');

  console.log(`Successfully generated manifest and traces:`);
  console.log(`- Total cases: ${cases.length}`);
  console.log(`- Product cases: ${manifest.summary.productCases} (17 fixtures, 19 ctrl @ 44.1k, 19 ctrl @ 48k)`);
  console.log(`- Stress cases: ${manifest.summary.stressCases} (96 standard, 96 odd)`);
  console.log(`- Targeted cases: ${manifest.summary.targetedCases}`);
  console.log(`- Total frames: ${totalFrames}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  generateCorpusAndTraces();
}
