/* Read-only browser checks against an independent monitor with persisted data. */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir } from 'node:fs/promises';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_PATH || 'playwright');
const base = process.env.CONSOLE_URL || 'http://127.0.0.1:3001';
const output = process.env.SCREENSHOT_DIR || '/tmp/redsourcing-detail-screenshots';
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
const errors = [];
page.on('pageerror', error => errors.push(error.message));
try {
  assert.equal((await page.goto(base + '/monitor')).status(), 200);
  await page.getByText('Live', { exact: true }).waitFor();
  const name = page.locator('.instance h3 .name-link').first();
  await name.hover();
  const complete = await name.getAttribute('title');
  assert.ok(complete?.length);
  assert.equal(await name.getAttribute('aria-label'), complete);
  const links = await page.locator('a[href*="/detail?"]').evaluateAll(elements =>
    Object.fromEntries(elements.map(element => {
      const url = new URL(element.getAttribute('href'), location.href);
      return [url.searchParams.get('view'), url.href];
    })));
  const chart = page.locator('.entity-chart a').first();
  assert.ok(await chart.locator(':scope > title').textContent());
  assert.equal(new URL(await chart.getAttribute('href'), base).searchParams.get('view'), 'stream');
  // Test a real click, then retain its selected record through HTMX invalidation.
  await name.click();
  await page.locator('#monitor-detail').waitFor();
  const heading = await page.locator('#monitor-detail h1').first().textContent();
  const refreshed = page.waitForResponse(response => response.url().includes('/detail-fragment?'));
  await page.evaluate(() => document.body.dispatchEvent(new CustomEvent('redsourcing:update', { bubbles: true })));
  assert.equal((await refreshed).status(), 200);
  assert.equal(await page.locator('#monitor-detail h1').first().textContent(), heading);
  await page.screenshot({ path: `${output}/stream.png`, fullPage: true });
  for (const view of ['stream', 'type', 'event', 'command']) {
    assert.ok(links[view], `seeded monitor has a ${view} link`);
    assert.equal((await page.goto(links[view])).status(), 200, `${view} page`);
    await page.getByRole('heading', { name: 'Record details', exact: true }).waitFor();
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(links.stream);
  assert.equal(await page.locator('body').evaluate(element => element.scrollWidth > innerWidth), false, 'mobile detail fits viewport');
  await page.screenshot({ path: `${output}/stream-mobile.png`, fullPage: true });
  assert.deepEqual(errors, [], 'no browser script errors');
  console.log('Full-name hover, stream/type/event/command navigation, live detail refresh and mobile layout verified.');
} finally {
  await browser.close();
}
