const path = require('path');
const fs = require('fs');
const { chromium } = require('/opt/homebrew/lib/node_modules/playwright');

const DIR = __dirname;
const only = process.argv.slice(2);
const names = fs
  .readdirSync(DIR)
  .filter((f) => f.endsWith('.html') && f !== 'index.html')
  .map((f) => f.replace(/\.html$/, ''))
  .filter((n) => !only.length || only.includes(n));

(async () => {
  const browser = await chromium.launch();
  const out = {};
  for (const n of names) {
    const dpr = n === 'wide-2560' ? 1 : 2;
    const ctx = await browser.newContext({ deviceScaleFactor: dpr, viewport: { width: 1600, height: 1000 } });
    const page = await ctx.newPage();
    await page.goto('file://' + path.join(DIR, n + '.html'));
    await page.waitForLoadState('load');
    await page.evaluate(() => Promise.all(Array.from(document.images).map((i) => (i.complete ? 1 : new Promise((r) => (i.onload = i.onerror = r))))));
    const frame = await page.$('#frame');
    await frame.screenshot({ path: path.join(DIR, n + '.png') });
    out[n] = await page.evaluate(() => {
      const R = (e) => {
        if (!e) return null;
        const b = e.getBoundingClientRect();
        return { x: b.x, y: b.y, w: b.width, h: b.height };
      };
      const sel = (s) => R(document.querySelector(s));
      return { win: sel('.win'), sheet: sel('.sheet'), stage: sel('.stage'), pic: sel('.pic'), dock: sel('.dock'), rail: sel('.rail') };
    });
    await ctx.close();
    console.log('rendered', n);
  }
  await browser.close();
  fs.writeFileSync(path.join(DIR, '.measure.json'), JSON.stringify(out, null, 1));
})();
