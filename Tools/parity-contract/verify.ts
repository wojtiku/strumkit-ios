import { createHash } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadAllCases } from './corpus';
import { runTestCase, hashTrace } from './runner';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');

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
  console.log('1. Verifying reference source files and SHA-256 hashes...');
  for (const [file, expectedHash] of Object.entries(EXPECTED_SOURCE_HASHES)) {
    const filePath = resolve(HERE, 'reference-source', file);
    if (!existsSync(filePath)) {
      throw new Error(`Missing pinned source file: ${filePath}`);
    }
    const content = readFileSync(filePath);
    const actualHash = createHash('sha256').update(content).digest('hex');
    if (actualHash !== expectedHash) {
      throw new Error(`Source hash mismatch for ${file}: expected ${expectedHash}, got ${actualHash}`);
    }
    console.log(`  ✔ reference-source/${file}: ${actualHash}`);
  }
}

function verifyAppBundleExclusion() {
  console.log('\n2. Verifying app bundle exclusion in project.yml...');
  const projectYmlPath = resolve(ROOT, 'project.yml');
  const projectYml = readFileSync(projectYmlPath, 'utf8');

  // Check that targets.StrumKit.sources only includes StrumKit
  const strumKitTargetMatch = projectYml.match(/targets:\s*\n\s*StrumKit:[\s\S]*?sources:\s*\n([\s\S]*?)(?=\n\s*\w+:|$)/);
  if (!strumKitTargetMatch) {
    throw new Error('Could not find StrumKit target sources in project.yml');
  }

  const strumKitSources = strumKitTargetMatch[1];
  console.log(`  StrumKit target sources block:\n${strumKitSources.trimEnd()}`);

  if (strumKitSources.includes('Tools') || strumKitSources.includes('parity-contract') || strumKitSources.includes('Fixtures')) {
    throw new Error(`App bundle target StrumKit includes test/tools directories! Found: ${strumKitSources}`);
  }

  if (!strumKitSources.includes('- path: StrumKit')) {
    throw new Error('App bundle target StrumKit does not have expected path: StrumKit');
  }

  console.log('  ✔ App bundle target StrumKit strictly excludes Tools, parity-contract, and test fixtures.');
}

function verifyInventoryAndReproducibility() {
  console.log('\n3. Verifying manifest inventory and trace reproducibility...');
  const manifestPath = resolve(HERE, 'schema', 'manifest.json');
  if (!existsSync(manifestPath)) {
    throw new Error(`Manifest not found at ${manifestPath}. Run generate.ts first.`);
  }

  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

  // Validate budgets
  if (manifest.numericBudgets.frequencyAbsoluteHz !== 1e-6) throw new Error('Budget mismatch: frequency');
  if (manifest.numericBudgets.rawCentsAbsolute !== 1e-6) throw new Error('Budget mismatch: rawCents');
  if (manifest.numericBudgets.smoothedCentsAbsolute !== 1e-6) throw new Error('Budget mismatch: smoothedCents');
  if (manifest.numericBudgets.confidenceAbsolute !== 1e-9) throw new Error('Budget mismatch: confidence');
  if (manifest.numericBudgets.rmsAbsolute !== 1e-10) throw new Error('Budget mismatch: rmsAbsolute');
  if (manifest.numericBudgets.rmsRelative !== 1e-7) throw new Error('Budget mismatch: rmsRelative');
  if (!manifest.numericBudgets.sampleIndexExact) throw new Error('Budget mismatch: sampleIndexExact');
  console.log('  ✔ Numeric budgets frozen correctly in manifest.');

  // Validate discrete rules
  if (!manifest.discreteRules.nullMaskExact) throw new Error('Rule mismatch: nullMaskExact');
  if (!manifest.discreteRules.targetNotesExact) throw new Error('Rule mismatch: targetNotesExact');
  if (!manifest.discreteRules.publicationSlotsExact) throw new Error('Rule mismatch: publicationSlotsExact');
  if (!manifest.discreteRules.inTuneTransitionsExact) throw new Error('Rule mismatch: inTuneTransitionsExact');
  if (!manifest.discreteRules.confirmationEventsExact) throw new Error('Rule mismatch: confirmationEventsExact');
  console.log('  ✔ Exact discrete decision requirements frozen in manifest.');

  // Validate product case inventory
  const fixtureCount = manifest.summary.categoryCounts['product-fixtures'] ?? 0;
  const ctrl441Count = manifest.summary.categoryCounts['product-controlled-44100'] ?? 0;
  const ctrl48Count = manifest.summary.categoryCounts['product-controlled-48000'] ?? 0;
  const productCount = fixtureCount + ctrl441Count + ctrl48Count;

  if (fixtureCount !== 17) throw new Error(`Expected 17 fixtures, got ${fixtureCount}`);
  if (ctrl441Count !== 19) throw new Error(`Expected 19 controlled cases @ 44.1k, got ${ctrl441Count}`);
  if (ctrl48Count !== 19) throw new Error(`Expected 19 controlled cases @ 48k, got ${ctrl48Count}`);
  if (productCount !== 55) throw new Error(`Expected 55 product cases, got ${productCount}`);
  console.log(`  ✔ 55 Product cases validated (17 fixtures, 19 ctrl @ 44.1k, 19 ctrl @ 48k).`);

  // Validate stress matrices
  const standardStress = manifest.summary.categoryCounts['stress-standard'] ?? 0;
  const oddStress = manifest.summary.categoryCounts['stress-odd'] ?? 0;
  if (standardStress !== 96) throw new Error(`Expected 96 standard stress cases, got ${standardStress}`);
  if (oddStress !== 96) throw new Error(`Expected 96 odd stress cases, got ${oddStress}`);
  console.log(`  ✔ 192 Stress cases validated (96 standard harmonics + 96 odd harmonics).`);

  // Validate targeted cases
  const targetedCount = manifest.summary.categoryCounts['targeted'] ?? 0;
  if (targetedCount < 30) throw new Error(`Expected >= 30 targeted cases, got ${targetedCount}`);
  console.log(`  ✔ ${targetedCount} Targeted cases validated (44.1/48/96k, silence, short/NaN/Inf, resets, slack, gaps, quiet onset, alias, 3-15c steps, boundaries).`);

  // Re-generate in memory and check bit-identical hash equality
  console.log('\n4. Re-running export from pinned own-code source to verify bit-identical trace reproducibility...');
  const cases = loadAllCases();
  if (cases.length !== manifest.cases.length) {
    throw new Error(`Case count mismatch: manifest has ${manifest.cases.length}, generator produced ${cases.length}`);
  }

  const manifestMap = new Map<string, any>(manifest.cases.map((c: any) => [c.name, c]));

  let checkedFrames = 0;
  for (const testCase of cases) {
    const manifestEntry = manifestMap.get(testCase.name);
    if (!manifestEntry) {
      throw new Error(`Case ${testCase.name} not found in manifest!`);
    }

    const replayedTrace = runTestCase(testCase);
    const replayedSampleHash = replayedTrace.sampleSha256;
    const replayedTraceHash = hashTrace(replayedTrace);

    if (replayedSampleHash !== manifestEntry.sampleSha256) {
      throw new Error(`Sample hash mismatch for ${testCase.name}: manifest ${manifestEntry.sampleSha256}, replayed ${replayedSampleHash}`);
    }

    if (replayedTraceHash !== manifestEntry.traceSha256) {
      throw new Error(`Trace hash mismatch for ${testCase.name}: manifest ${manifestEntry.traceSha256}, replayed ${replayedTraceHash}`);
    }

    // Verify trace file on disk matches byte-for-byte
    const diskPath = resolve(HERE, manifestEntry.traceFile);
    if (!existsSync(diskPath)) {
      throw new Error(`Trace file on disk missing: ${diskPath}`);
    }
    const diskTraceJson = readFileSync(diskPath, 'utf8');
    const diskTrace = JSON.parse(diskTraceJson);
    const diskTraceHash = hashTrace(diskTrace);
    if (diskTraceHash !== manifestEntry.traceSha256) {
      throw new Error(`Disk trace hash mismatch for ${testCase.name}: manifest ${manifestEntry.traceSha256}, on disk ${diskTraceHash}`);
    }

    checkedFrames += replayedTrace.frameCount;
  }

  console.log(`  ✔ All ${cases.length} cases and ${checkedFrames} frames produce bit-identical sample and trace hashes on re-export!`);
  console.log('\n=== Parity Contract Verification Passed Successfully ===\n');
}

export function runVerification() {
  verifySourceHashes();
  verifyAppBundleExclusion();
  verifyInventoryAndReproducibility();
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  runVerification();
}
