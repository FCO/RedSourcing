/* Optional cross-process test. Start Hearth and bin/red-sourcing.raku web-monitor on the SAME DB. */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_PATH || 'playwright');
const app = process.env.HEARTH_URL || 'http://127.0.0.1:3000';
const consoleURL = process.env.CONSOLE_URL || 'http://127.0.0.1:3001';
const browser = await chromium.launch({ headless: true,
  ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}) });
try {
  const page = await browser.newPage();
  await page.goto(consoleURL + '/monitor');
  await page.getByText('Live', { exact: true }).waitFor();
  const html = await (await page.request.get(app + '/repairs/r-window')).text();
  const csrf = html.match(/name="csrf" value="([^"]+)"/)[1];
  const marker = 'Separate console live proof ' + Date.now();
  const post = await page.request.post(app + '/actions/message', {
    headers: { 'HX-Request': 'true' },
    form: { csrf, 'repair-id': 'r-window', author: 'Agency', body: marker }
  });
  assert.equal(post.status(), 200);
  await page.waitForFunction(text => document.querySelector('#monitor-view').textContent.includes(text), marker);
  const report = await (await page.request.get(consoleURL + '/monitor/report')).json();
  assert.ok(report.events.some(e => e.data.body === marker));
  assert.equal(report.instances.filter(i => i.error).length, 0);
  console.log('Separate console received committed changes over SSE and refreshed its HTML.');
} finally {
  await browser.close();
}
