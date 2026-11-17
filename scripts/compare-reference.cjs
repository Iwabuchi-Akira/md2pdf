#!/usr/bin/env node
// Development-only verification. Node.js and Poppler are not user dependencies.
// node scripts/compare-reference.cjs /path/to/original/md2pdf [binary] [output]
// Add --html-only to check the port without launching browsers or making PDFs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const htmlOnly = process.argv.includes('--html-only');
const args = process.argv.slice(2).filter(arg => arg !== '--html-only');
if (!args[0]) {
  console.error('Usage: node scripts/compare-reference.cjs REFERENCE_DIR [BINARY] [OUTPUT_DIR] [--html-only]');
  process.exit(2);
}
const reference = path.resolve(args[0]);
const binary = path.resolve(args[1] || 'target/release/md2pdf');
const output = path.resolve(args[2] || 'tmp/pdfs/comparison');
const fixtures = path.resolve(__dirname, '../tests/fixtures');
const { renderMarkdown } = require(path.join(reference, 'render.cjs'));
const context = vm.createContext({
  window: {
    markdownit: require(path.join(reference, 'node_modules/markdown-it')),
    katex: require(path.join(reference, 'node_modules/katex')),
  },
  crypto: webcrypto, URL, Uint8Array,
});
vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../assets/render.js'), 'utf8'), context);

const files = ['sample.md', 'related.md'];
const targets = new Map(files.map(name => {
  const file = path.join(fixtures, name);
  return [pathToFileURL(file).href, file.replace(/\.md$/, '.pdf')];
}));
const browserTargets = Object.fromEntries([...targets].map(([file, pdf]) => [file, pathToFileURL(pdf).href]));
const extraCases = [
  '```js\nconst cost = "$5"; // \\(x\\)\n```\n\n`$not_math$`',
  '| x | y |\n|---|---|\n| $|x|$ | $\\frac{a}{b}$ |',
  '<script>throw new Error("HTML must not execute")</script>\n\n**日本語**',
  '[convert](related.md#fragment) [keep](unconverted.md) [self](#section) https://example.com',
];
let comparisons = 0;
for (const [name, source] of [
  ...files.map(name => [name, fs.readFileSync(path.join(fixtures, name), 'utf8')]),
  ...extraCases.map((source, i) => [`edge-case-${i}.md`, source]),
]) {
  const file = path.join(fixtures, name);
  const expected = renderMarkdown(source, file, targets).match(/<body>([\s\S]*)<\/body>/)[1];
  const actual = context.window.md2pdfRender(source, pathToFileURL(file).href, browserTargets);
  assert.equal(actual, expected, `HTML differs for ${name}`);
  comparisons++;
}
assert.throws(() => context.window.md2pdfRender('$\\notARealKaTeXCommand$', pathToFileURL(path.join(fixtures, 'invalid.md')).href), /Undefined control sequence/);
console.log(`HTML: ${comparisons} cases match the reference exactly; invalid math rejected.`);
if (htmlOnly) process.exit(0);

function run(command, argv, options = {}) {
  const result = spawnSync(command, argv, { encoding: 'utf8', timeout: 120_000, ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status}):\n${result.stdout}\n${result.stderr}`);
  if (result.stdout.trim()) console.log(result.stdout.trim());
  return result.stdout;
}

fs.mkdirSync(output, { recursive: true });
for (const flavor of ['reference', 'rust']) {
  const directory = path.join(output, flavor);
  fs.mkdirSync(directory, { recursive: true });
  for (const name of fs.readdirSync(directory)) {
    if (/^(sample|related)-\d+\.(ppm|png)$/.test(name)) fs.unlinkSync(path.join(directory, name));
  }
  for (const name of fs.readdirSync(fixtures)) {
    fs.copyFileSync(path.join(fixtures, name), path.join(directory, name));
  }
  const input = files.map(name => path.join(directory, name));
  if (flavor === 'reference') run(process.execPath, [path.join(reference, 'convert.cjs'), ...input]);
  else run(binary, input);
  for (const name of files) {
    const stem = path.join(directory, name.replace(/\.md$/, ''));
    // PPM is raw RGB data: equality checks pixels rather than PDF metadata or
    // PNG compression. Also create PNGs for convenient visual inspection.
    run('pdftoppm', ['-r', '96', `${stem}.pdf`, stem]);
    run('pdftoppm', ['-r', '96', '-png', `${stem}.pdf`, stem]);
  }
}
const referenceDir = path.join(output, 'reference');
const rustDir = path.join(output, 'rust');
const referencePages = fs.readdirSync(referenceDir).filter(name => name.endsWith('.ppm')).sort();
const rustPages = fs.readdirSync(rustDir).filter(name => name.endsWith('.ppm')).sort();
assert.deepEqual(rustPages, referencePages, 'PDF page counts differ');
for (const page of referencePages) {
  assert.ok(fs.readFileSync(path.join(referenceDir, page)).equals(fs.readFileSync(path.join(rustDir, page))), `Pixels differ: ${page}`);
}
console.log(`PDF: ${referencePages.length} pages have identical pixels at 96 DPI.`);
console.log(`Outputs: ${output}`);
