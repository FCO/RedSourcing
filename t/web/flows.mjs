/* Read-only checks against a monitor containing a traced workflow. */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir, readFile } from 'node:fs/promises';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_PATH || 'playwright');
const base = process.env.CONSOLE_URL || 'http://127.0.0.1:3001';
const output = process.env.SCREENSHOT_DIR || '/tmp/redsourcing-flow-screenshots';
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true, ...(process.env.CHROMIUM_PATH ? {executablePath: process.env.CHROMIUM_PATH} : {}) });
const page = await browser.newPage({ viewport: { width: 1920, height: 1050 } });
// A captured page can replay a dense production-shaped graph entirely offline.
// All requests are intercepted; no commands or application handlers are called.
let fixtureFragment = '';
if (process.env.FLOW_FIXTURE_HTML) {
  const html = (await readFile(process.env.FLOW_FIXTURE_HTML, 'utf8')).replace(/data-live-url="[^"]*"/, 'data-live-url=""');
  await page.route('**/*', async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/monitor/flow') return route.fulfill({contentType: 'text/html', body: html});
    if (path === '/monitor/flow-fragment') return route.fulfill({contentType: 'text/html', body: fixtureFragment});
    const asset = path.replace(/^\/assets\//, '');
    if (['app.css', 'live.js', 'vendor/htmx-4.0.0.min.js'].includes(asset)) {
      return route.fulfill({contentType: asset.endsWith('.css') ? 'text/css' : 'application/javascript',
        body: await readFile(new URL(`../../resources/${asset}`, import.meta.url))});
    }
    return route.abort();
  });
}
const errors = [];
page.on('pageerror', error => errors.push(error.message));
try {
  assert.equal((await page.goto(base + '/monitor/flow')).status(), 200);
  const cards = page.locator('[data-flow-node]');
  await cards.first().waitFor();
  await page.waitForFunction(() => document.querySelector('.flow-path'));
  if (process.env.FLOW_FIXTURE_HTML) fixtureFragment = await page.locator('#flow-view').evaluate(node => node.outerHTML);
  assert.ok(await cards.count() > 3, 'fixture contains a workflow');
  assert.ok(await page.locator('optgroup[label="Actions"] option').count() >= 2, 'actions have their own selector group');
  assert.ok((await page.locator('optgroup[label="Actions"]').textContent()).includes('Command ·'), 'action options include execution types');
  assert.equal(await page.evaluate(() => {
    const nodes = new Map([...document.querySelectorAll('[data-flow-node]')].map(node => [node.dataset.flowNode, +node.dataset.flowStage]));
    return [...document.querySelectorAll('[data-flow-source]')].every(edge => nodes.get(edge.dataset.flowTarget) > nodes.get(edge.dataset.flowSource));
  }), true, 'all connectors point forward through causal columns');
  assert.equal(await cards.locator('time').count(), await cards.count(), 'persisted cards show dates beside their type');
  await cards.first().hover();
  const tooltip = page.locator('#flow-inspector');
  await tooltip.waitFor({ state: 'visible' });
  assert.ok((await tooltip.textContent()).includes(await cards.first().getAttribute('aria-label')), 'hover shows full name');
  assert.ok((await tooltip.textContent()).includes('Payload') || (await tooltip.textContent()).includes('Identity'), 'hover shows record metadata');
  const previewOutsideDiagram = () => page.evaluate(() => {
    const preview = document.querySelector('.flow-preview').getBoundingClientRect();
    const diagram = document.querySelector('.flow-scroll').getBoundingClientRect();
    return preview.right <= diagram.left || preview.left >= diagram.right
      || preview.bottom <= diagram.top || preview.top >= diagram.bottom;
  });
  const previewPlacement = () => page.evaluate(() => {
    const preview = document.querySelector('.flow-preview').getBoundingClientRect();
    const diagram = document.querySelector('.flow-scroll').getBoundingClientRect();
    return {side: preview.left >= diagram.right, below: preview.top >= diagram.bottom};
  });
  assert.equal(await previewOutsideDiagram(), true, 'preview reserves its own space outside the diagram');
  assert.equal((await previewPlacement()).side, true, 'landscape preview stays beside the diagram, including dense flows');
  await page.locator('.flow-preview-heading').hover();
  assert.equal(await tooltip.isVisible(), true, 'preview remains readable after leaving the card');
  await page.screenshot({ path: `${output}/flow-hover.png`, fullPage: true });
  await page.keyboard.press('Escape');
  await page.evaluate(() => {
    window.dispatchEvent(new Event('resize')); window.dispatchEvent(new Event('resize'));
  });
  await tooltip.waitFor({ state: 'hidden' });
  const event = page.locator('[data-flow-node^="event:"]').filter({has: page.locator('.pill.event')}).first();
  await event.focus();
  await tooltip.waitFor({state: 'visible'});
  assert.ok((await tooltip.textContent()).includes('Payload'), 'keyboard focus shows event details');
  await page.keyboard.press('Escape');
  const checkRoutes = () => page.evaluate(() => {
    const board = document.querySelector('.flow-board'), origin = board.getBoundingClientRect();
    const boxes = [...board.querySelectorAll('[data-flow-node]')].map(node => ({id: node.dataset.flowNode, box: node.getBoundingClientRect()}));
    const paths = [...board.querySelectorAll('.flow-path')];
    const collisions = [], lengthRatios = [], endpoints = new Map();
    paths.forEach(path => {
      const length = path.getTotalLength();
      const start = path.getPointAtLength(0), end = path.getPointAtLength(length);
      const source = board.querySelector(`[data-flow-node="${CSS.escape(path.dataset.flowSource)}"]`);
      const target = board.querySelector(`[data-flow-node="${CSS.escape(path.dataset.flowTarget)}"]`);
      if (source.dataset.flowStage !== target.dataset.flowStage) {
        lengthRatios.push(length / Math.hypot(end.x - start.x, end.y - start.y));
      }
      for (const [id, point] of [[path.dataset.flowSource, path.getPointAtLength(0)],
        [path.dataset.flowTarget, path.getPointAtLength(length)]]) {
        const key = `${id}/${Math.round(point.x)}`;
        if (!endpoints.has(key)) endpoints.set(key, []);
        endpoints.get(key).push(point.y);
      }
      for (let offset = 0; offset <= length; offset += 4) {
        const point = path.getPointAtLength(offset);
        const x = point.x + origin.left, y = point.y + origin.top;
        for (const {id, box} of boxes) {
          if (id === path.dataset.flowSource || id === path.dataset.flowTarget) continue;
          if (x > box.left + 2 && x < box.right - 2 && y > box.top + 2 && y < box.bottom - 2) collisions.push(id);
        }
      }
    });
    const gaps = values => values.sort((a,b) => a-b).slice(1).map((value,index) => value - values[index]);
    const portGaps = [...endpoints.values()].flatMap(gaps);
    return {lengthRatios, portGaps, count: paths.length, curved: paths.every(path => /C/.test(path.getAttribute('d'))), corners: paths.some(path => /[LQ]/.test(path.getAttribute('d'))), collisions};
  });
  const routed = await checkRoutes();
  assert.ok(routed.count > 0);
  assert.equal(routed.curved, true, 'connections use smooth curves');
  assert.equal(routed.corners, false, 'no orthogonal corners');
  assert.ok(routed.lengthRatios.every(ratio => ratio <= 1.1), 'cross-column curves stay close to the direct distance');
  assert.ok(routed.portGaps.every(gap => gap >= 12), 'incoming and outgoing arrows have separate endpoints');
  // Add one browser-only fixture link straight through the middle columns to
  // verify direct paths behind cards. This changes no persisted tracing evidence.
  const blocked = await page.evaluate(() => {
    const board = document.querySelector('.flow-board');
    const source = board.querySelector('[data-flow-stage="0"]');
    const target = [...board.querySelectorAll('[data-flow-node]')].at(-1);
    const edge = document.createElement('span'); edge.hidden = true;
    edge.dataset.flowSource = source.dataset.flowNode;
    edge.dataset.flowTarget = target.dataset.flowNode;
    edge.dataset.flowFixture = 'obstructed'; board.append(edge);
    window.dispatchEvent(new Event('resize'));
    return {source: edge.dataset.flowSource, target: edge.dataset.flowTarget};
  });
  const blockedRoute = await page.locator('.flow-path').evaluateAll((paths, edge) =>
    paths.find(path => path.dataset.flowSource === edge.source && path.dataset.flowTarget === edge.target).getAttribute('d'), blocked);
  assert.equal((blockedRoute.match(/C/g) || []).length, 1, 'obstructed connection takes one direct curve');
  const crowded = await checkRoutes();
  assert.ok(crowded.collisions.length > 0, 'direct connections may cross intermediate cards');
  assert.ok(crowded.lengthRatios.every(ratio => ratio <= 1.1), 'obstructed curves take no overhead detour');
  const cardsCoverWires = await page.evaluate(() => {
    const svg = document.querySelector('.flow-connectors');
    return [...document.querySelectorAll('.flow-node')].every(node => {
      const color = getComputedStyle(node).backgroundColor;
      return Number(getComputedStyle(node.closest('.flow-stage')).zIndex) > Number(getComputedStyle(svg).zIndex)
        && color !== 'transparent' && !color.endsWith(', 0)');
    });
  });
  assert.equal(cardsCoverWires, true, 'opaque cards paint above crossing connectors');
  assert.ok(crowded.portGaps.every(gap => gap >= 12), 'additional blocked link has a distinct endpoint');
  await page.evaluate(() => {
    document.querySelector('[data-flow-fixture]').remove(); window.dispatchEvent(new Event('resize'));
  });
  await page.screenshot({ path: `${output}/flow.png`, fullPage: true });
  const acceptedFocus = await page.locator('#flow-stream').inputValue();
  const acceptedInternal = await page.locator('input[name="internal"]').isChecked();
  // Reproduce the live-property drift caused by option morphing. The response's
  // authoritative focus must restore both controls, even when focus is unchanged.
  await page.evaluate(() => {
    const select = document.querySelector('#flow-stream');
    select.value = select.options[0].value;
    const internal = document.querySelector('input[name="internal"]');
    internal.checked = !internal.checked;
  });
  const refreshed = page.waitForResponse(response => response.url().includes('/flow-fragment?'));
  await page.evaluate(() => document.body.dispatchEvent(new CustomEvent('redsourcing:update', { bubbles: true })));
  assert.equal((await refreshed).status(), 200);
  await page.waitForFunction(() => document.querySelector('.flow-path'));
  await page.waitForFunction(value => document.querySelector('#flow-stream').value === value, acceptedFocus);
  assert.equal(await page.locator('input[name="internal"]').isChecked(), acceptedInternal, 'internal choice survives live morph');
  assert.ok((await checkRoutes()).lengthRatios.every(ratio => ratio <= 1.1), 'direct routes survive live fragment replacement');
  await page.setViewportSize({width: 1440, height: 1000});
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert.equal(await previewOutsideDiagram(), true, 'laptop preview reserves its own space');
  assert.equal((await previewPlacement()).side, true, 'landscape laptop preview stays beside the diagram');
  assert.ok((await checkRoutes()).lengthRatios.every(ratio => ratio <= 1.1), 'laptop routes stay direct');
  await page.setViewportSize({width: 844, height: 390});
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert.equal((await previewPlacement()).side, true, 'landscape phone preview stays beside the diagram');
  assert.equal(await previewOutsideDiagram(), true, 'landscape phone preview covers no cards');
  assert.equal(await page.locator('body').evaluate(element => element.scrollWidth > innerWidth), false, 'landscape phone fits the viewport');
  await page.screenshot({path: `${output}/flow-phone-landscape.png`, fullPage: true});
  await page.setViewportSize({width: 390, height: 844});
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert.equal(await page.locator('body').evaluate(element => element.scrollWidth > innerWidth), false, 'mobile diagram scrolls inside its container');
  assert.ok((await checkRoutes()).lengthRatios.every(ratio => ratio <= 1.1), 'mobile routes stay direct');
  assert.equal(await previewOutsideDiagram(), true, 'mobile preview sits below the diagram without covering it');
  assert.equal((await previewPlacement()).below, true, 'portrait phone preview moves below the diagram');
  await page.evaluate(() => document.activeElement?.blur());
  await cards.first().focus();
  await tooltip.waitFor({state: 'visible'});
  // Auto-scroll/mouseleave used to dismiss a keyboard-focused popup shortly
  // after it appeared. Wait beyond the dismissal delay to catch that regression.
  await page.waitForTimeout(200);
  assert.equal(await tooltip.isVisible(), true, 'focused popup survives automatic scrolling');
  const bounds = await tooltip.boundingBox();
  assert.ok(bounds.x >= 0 && bounds.x + bounds.width <= 390, 'mobile preview fits the page width');
  const focusRefresh = page.waitForResponse(response => response.url().includes('/flow-fragment?'));
  await page.evaluate(() => document.body.dispatchEvent(new CustomEvent('redsourcing:update', { bubbles: true })));
  assert.equal((await focusRefresh).status(), 200);
  await tooltip.waitFor({state: 'visible'});
  await page.screenshot({path: `${output}/flow-mobile.png`, fullPage: true});
  await page.getByRole('button', {name: 'Clear card preview'}).click();
  await tooltip.waitFor({state: 'hidden'});
  assert.equal(await page.locator('.flow-preview-empty').isVisible(), true, 'clear restores preview instructions');
  if (!process.env.FLOW_FIXTURE_HTML) {
    const entity = await page.locator('#flow-stream').inputValue();
    const action = await page.locator('optgroup[label="Actions"] option').last().getAttribute('value');
    await page.locator('#flow-stream').selectOption(action);
    await Promise.all([page.waitForResponse(response => response.url().includes('/flow-fragment?focus=action')),
      page.getByRole('button', {name: 'Show flow'}).click()]);
    await page.waitForFunction(value => {
      const view = document.querySelector('#flow-view');
      return view.dataset.flowFocus === value && view.querySelector('select').value === value;
    }, action);
    const selected = page.locator(`[data-flow-node="${action.replaceAll('"', '\\"')}"]`);
    assert.equal(await selected.getAttribute('data-flow-stage'), '0', 'chosen action starts its downstream view');
    const refresh = page.waitForResponse(response => response.url().includes('/flow-fragment?focus=action'));
    await page.evaluate(() => document.body.dispatchEvent(new CustomEvent('redsourcing:update', {bubbles: true})));
    await refresh;
    await page.waitForFunction(value => document.querySelector('#flow-stream').value === value, action);
    await page.locator('#flow-stream').selectOption(entity);
    await page.locator('input[name="internal"]').check();
    await Promise.all([page.waitForResponse(response => response.url().includes('/flow-fragment?') && response.url().includes('internal=1')),
      page.getByRole('button', {name: 'Show flow'}).click()]);
    await page.locator('.flow-node .pill.snapshot').first().waitFor();
    assert.equal(await page.locator('input[name="internal"]').isChecked(), true, 'internal snapshots are selectable through the form');
  }
  assert.deepEqual(errors, [], 'no browser script errors');
  console.log('Flow timestamps, separate preview, direct curves behind cards, live refresh and mobile layout verified.');
} finally { await browser.close(); }
