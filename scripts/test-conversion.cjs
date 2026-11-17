#!/usr/bin/env node
// Development-only integration checks. Use MD2PDF_BROWSER_PATH to select the
// pinned browser in a development checkout; nothing is installed by this test.
// node scripts/test-conversion.cjs [BINARY] [OUTPUT_DIR]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const binary = path.resolve(process.argv[2] || 'target/release/md2pdf');
const output = path.resolve(process.argv[3] || 'tmp/pdfs/conversion-tests');
fs.mkdirSync(output, { recursive: true });
const directory = fs.mkdtempSync(path.join(output, 'run-'));

function run(args, { success, message, env = {} }) {
  const result = spawnSync(binary, args, {
    cwd: directory,
    env: { ...process.env, ...env },
    encoding: 'utf8',
    timeout: 90_000,
  });
  if (result.error) throw result.error;
  assert.equal(result.signal, null, `Unexpected signal: ${result.signal}`);
  assert.equal(result.status === 0, success, `${binary} ${args.join(' ')}\n${result.stdout}\n${result.stderr}`);
  if (message) assert.match(result.stderr + result.stdout, message);
  return result;
}

// Resolve a relative Japanese filename and create a nested, spaced output path.
const sourceName = '日本語 メモ.md';
const source = '# 日本語の確認\n\n空白を含むファイル名から変換します。$a^2+b^2=c^2$\n';
fs.writeFileSync(path.join(directory, sourceName), source);
const outputName = path.join('出力 資料', 'レポート.pdf');
run([sourceName, '-o', outputName], { success: true, message: /保存しました/ });
const validPDF = fs.readFileSync(path.join(directory, outputName));
assert.equal(validPDF.subarray(0, 5).toString(), '%PDF-');
assert.ok(validPDF.length > 1000, 'The PDF should contain rendered content');
assert.equal(fs.readFileSync(path.join(directory, sourceName), 'utf8'), source);
console.log('PASS Japanese/spaced input, relative paths, and nested PDF output');

// Reuse a real PDF as the pre-existing output. A later invalid formula must be
// found before any earlier output is overwritten.
const firstPDF = path.join(directory, '日本語 メモ.pdf');
fs.writeFileSync(firstPDF, validPDF);
fs.writeFileSync(path.join(directory, 'invalid.md'), '# Invalid formula\n\n$\\notARealKaTeXCommand$\n');
run([sourceName, 'invalid.md'], { success: false, message: /Undefined control sequence/ });
assert.ok(fs.readFileSync(firstPDF).equals(validPDF), 'Earlier PDF changed despite a later invalid formula');
assert.ok(!fs.existsSync(path.join(directory, 'invalid.pdf')), 'Invalid formula produced a PDF');
console.log('PASS later invalid math preserves the earlier pre-existing PDF');

// A failed image load must also leave the existing destination intact.
fs.writeFileSync(path.join(directory, 'missing-image.md'), '# Missing image\n\n![missing](does-not-exist.png)\n');
const missingPDF = path.join(directory, 'missing-image.pdf');
fs.writeFileSync(missingPDF, validPDF);
run(['missing-image.md'], { success: false, message: /画像を読み込めません/ });
assert.ok(fs.readFileSync(missingPDF).equals(validPDF), 'Missing image replaced the pre-existing PDF');
console.log('PASS missing image preserves its pre-existing PDF');

// Use a deliberately invalid browser path. An argument error (or --help) must
// finish before browser discovery/launch, even when no browser is installed.
const noBrowser = { MD2PDF_BROWSER_PATH: path.join(directory, 'browser-must-not-start') };
const unknown = run([sourceName, '--unknown-option'], {
  success: false, message: /不明なオプション/, env: noBrowser,
});
assert.doesNotMatch(unknown.stderr, /Chromium/);
run(['--help'], { success: true, message: /使い方/, env: noBrowser });
assert.ok(fs.readFileSync(firstPDF).equals(validPDF));
console.log('PASS unknown option and --help complete before browser discovery');
console.log(`Conversion integration checks passed. Outputs: ${directory}`);
