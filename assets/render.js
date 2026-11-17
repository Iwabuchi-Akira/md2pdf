/* Browser port of the reference renderer. Keep the Markdown and math rules in
 * sync with render.cjs in the original md2pdf installation. The libraries are
 * vendored with the executable; no network or Node.js is used at runtime. */
(() => {
  'use strict';

  window.md2pdfRender = (source, fileUrl, pdfTargets = {}) => {
    const random = crypto.getRandomValues(new Uint8Array(12));
    const prefix = `PDF${Array.from(random, byte => byte.toString(16).padStart(2, '0')).join('')}`;
    const code = [];
    // Protect code before math and math before Markdown tables. In particular,
    // the bars in |x| must never become table separators.
    source = source.replace(/(^[ \t]*(`{3,}|~{3,})[^\n]*\n[\s\S]*?^[ \t]*\2[ \t]*$|(`+)[^\n]*?\3(?!`))/gm, value => {
      code.push(value);
      return `${prefix}CODE${code.length - 1}END`;
    });
    const maths = [];
    source = source.replace(/\\\[([\s\S]*?)\\\]|\\\(([\s\S]*?)\\\)|\$\$([\s\S]*?)\$\$|(?<!\\)\$([^$\n]+?)\$/g, (_, a, b, c, d) => {
      const displayMode = a !== undefined || c !== undefined;
      const html = window.katex.renderToString(a ?? b ?? c ?? d, {
        displayMode, throwOnError: true, strict: false, output: 'html',
      });
      maths.push(displayMode ? `<div class="math-block">${html}</div>` : html);
      return `${prefix}MATH${maths.length - 1}END`;
    });
    source = source.replace(new RegExp(`${prefix}CODE(\\d+)END`, 'g'), (_, n) => code[n]);

    const md = window.markdownit({ html: false, linkify: true });
    md.renderer.rules.link_open = (tokens, index, options, env, self) => {
      const href = tokens[index].attrGet('href');
      if (href && !/^[a-z][a-z\d+.-]*:|^#|^\/\//i.test(href)) {
        const resolved = new URL(href, fileUrl);
        const hash = resolved.hash;
        resolved.hash = '';
        const target = Object.hasOwn(pdfTargets, resolved.href) ? pdfTargets[resolved.href] : undefined;
        tokens[index].attrSet('href', target ? target + hash : resolved.href + hash);
      }
      return self.renderToken(tokens, index, options);
    };
    let body = md.render(source);
    body = body.replace(new RegExp(`<p>${prefix}MATH(\\d+)END</p>`, 'g'), (_, n) => maths[n]);
    return body.replace(new RegExp(`${prefix}MATH(\\d+)END`, 'g'), (_, n) => maths[n]);
  };

  window.md2pdfPreparePrint = async () => {
    await document.fonts.ready;
    await Promise.all([...document.images].map(async img => {
      try { await img.decode(); }
      catch { throw new Error(`画像を読み込めません: ${img.src}`); }
    }));
    for (const el of document.querySelectorAll('.katex-display > .katex')) {
      const box = el.closest('.math-block') || el.parentElement;
      el.style.display = 'inline-block';
      const ratio = box.clientWidth / Math.max(el.scrollWidth, el.getBoundingClientRect().width);
      if (ratio < 1) el.style.zoom = String(ratio);
    }
  };
})();
