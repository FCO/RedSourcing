/* Run with a fresh seeded server: HEARTH_URL=http://127.0.0.1:3000 node t/web/browser.mjs
 * Install the optional dev dependency in the repository root, or provide PLAYWRIGHT_PATH. */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir } from 'node:fs/promises';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_PATH || 'playwright');
const base = process.env.HEARTH_URL || 'http://127.0.0.1:3000';
const monitor = process.env.CONSOLE_URL || 'http://127.0.0.1:3001';
const output = process.env.SCREENSHOT_DIR || '/tmp/redsourcing-hearth-screenshots';
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true,
  ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}) });
const context = await browser.newContext({ viewport: { width: 1440, height: 1040 } });
const errors = [];
context.on('page', page => page.on('pageerror', e => errors.push(e.message)));
const page = await context.newPage();
const wait = async predicate => {
  for (let i = 0; i < 80; i++) { if (await predicate()) return; await new Promise(r => setTimeout(r, 150)); }
  throw new Error('Timed out waiting for application state');
};
const submit = async (form, values, label) => {
  for (const [key, value] of Object.entries(values)) {
    const field = form.locator(`[name="${key}"]`);
    if (await field.evaluate(el => el.tagName === 'SELECT')) await field.selectOption(value);
    else await field.fill(value);
  }
  const response = page.waitForResponse(r => r.request().method() === 'POST');
  await form.getByRole('button', { name: label, exact: true }).click();
  assert.equal((await response).status(), 200, label);
};
try {
  for (const path of ['/', '/properties', '/tenants', '/rent', '/repairs', '/repairs/r-boiler']) {
    assert.equal((await page.goto(base + path)).status(), 200, path);
    await page.waitForFunction(() => window.htmx?.version === '4.0.0');
    await page.getByText('Live', { exact: true }).waitFor();
    assert.equal(await page.locator('body').evaluate(el => el.scrollWidth > innerWidth), false, 'desktop overflow');
    console.log('Page verified:', path);
  }
  await page.goto(base + '/');
  await page.screenshot({ path: `${output}/overview.png`, fullPage: true });
  await page.goto(monitor + '/monitor?kind=saga');
  await page.screenshot({ path: `${output}/console.png`, fullPage: true });
  assert.equal(await page.locator('.instance').count(), 2, 'two isolated saga instances');
  const report = await (await context.request.get(monitor + '/monitor/report')).json();
  console.log('Initial console report verified');
  assert.ok(report.storedOnly || report['stored-only']);
  assert.ok(report.types.some(t => t.name.endsWith('::RepairWorkflow')));
  assert.equal(report.metrics.series.length, 60);
  assert.equal(report.instances.filter(i => i.error).length, 0);

  // Actual HTMX form submission and live projection refresh.
  await page.goto(base + '/tenants');
  await page.locator('#drawer-tenant summary').click();
  await submit(page.locator('#form-tenant'), { name: 'Olivia Hart', email: 'olivia@example.test', phone: '07700 900104' }, 'Save tenant');
  await page.getByText('Olivia Hart', { exact: true }).waitFor();
  console.log('Tenant form and live directory verified');
  await page.goto(base + '/properties');
  await page.locator('#drawer-property summary').click();
  await submit(page.locator('#form-property'), {
    name: 'Orchard Cottage', address: '8 Orchard Walk, Bristol', kind: 'Townhouse', bedrooms: '2', 'monthly-rent': '1200.10'
  }, 'Save property');
  await page.getByRole('heading', { name: 'Orchard Cottage', exact: true }).waitFor();
  console.log('Property form and live portfolio verified');
  const propertyId = await page.locator('#form-tenancy [name=property-id] option').filter({ hasText: 'Orchard Cottage' }).getAttribute('value');
  const tenantId = await page.locator('#form-tenancy [name=tenant-id] option').filter({ hasText: 'Olivia Hart' }).getAttribute('value');
  await submit(page.locator('#form-tenancy'), { 'property-id': propertyId, 'tenant-id': tenantId }, 'Start tenancy');
  await wait(async () => (await page.locator('.property-card').filter({ hasText: 'Orchard Cottage' }).innerText()).includes('Olivia Hart'));
  await page.goto(base + '/rent');
  await submit(page.locator('#form-charge-rent'), { 'property-id': propertyId, period: '2026-10' }, 'Charge rent');
  await page.locator('#drawer-receive-rent summary').click();
  await submit(page.locator('#form-receive-rent'), { 'property-id': propertyId, period: '2026-10', amount: '1200.10', reference: 'browser-orchard' }, 'Record payment');
  await wait(async () => (await page.locator('tr').filter({ hasText: 'Orchard Cottage' }).innerText()).includes('Paid'));

  // Two browser tabs, real SSE, and preserved in-progress chat text.
  const observer = await context.newPage();
  await observer.goto(base + '/repairs/r-boiler');
  await observer.getByText('Live', { exact: true }).waitFor();
  await page.goto(base + '/repairs/r-boiler');
  await submit(page.locator('#form-message-r-boiler'), { author: 'Tenant', body: 'Browser test: the engineer can collect the keys.' }, 'Send message');
  await observer.getByText('Browser test: the engineer can collect the keys.', { exact: true }).waitFor();
  await observer.locator('[name=body]').fill('Unsaved draft survives incoming updates');
  await submit(page.locator('#form-message-r-boiler'), { author: 'Agency', body: 'Browser test: access confirmed.' }, 'Send message');
  await new Promise(r => setTimeout(r, 1000));
  assert.equal(await observer.locator('[name=body]').inputValue(), 'Unsaved draft survives incoming updates');
  await observer.locator('[name=body]').blur();
  await observer.getByText('Browser test: access confirmed.', { exact: true }).waitFor();
  await page.screenshot({ path: `${output}/chat.png`, fullPage: true });

  await page.goto(base + '/repairs');
  await page.getByText('Demo payment controls', { exact: true }).click();
  await submit(page.locator('#form-fail-next-payment'), {}, 'Fail next payment once');
  await page.goto(base + '/repairs/r-boiler');
  await submit(page.locator('#form-finish-r-boiler'), { cost: '185.00' }, 'Mark completed');
  await page.getByRole('button', { name: 'Pay contractor', exact: true }).waitFor();
  await submit(page.locator('#form-pay-repair'), {}, 'Pay contractor');
  await page.getByRole('button', { name: 'Reverse contractor payment', exact: true }).waitFor();
  let paymentReport = await (await context.request.get(monitor + '/monitor/report')).json();
  let saga = paymentReport.instances.find(i => i.kind === 'saga' && i.data['repair-id'] === 'r-boiler');
  assert.equal(saga.data['saga-state'].actions.find(a => a.step === 'send-payment').attempts, 2, 'automatic provider retry');
  await submit(page.locator('#form-compensate'), {}, 'Reverse contractor payment');
  await wait(async () => {
    const r = await (await context.request.get(monitor + '/monitor/report')).json();
    return r.instances.some(i => i.kind === 'saga' && i.data['repair-id'] === 'r-boiler' && i.status === 'compensated');
  });
  await page.getByText('The payment was reversed and the workflow is closed.', { exact: false }).waitFor();
  assert.equal(await page.getByRole('button', { name: 'Pay contractor', exact: true }).count(), 0, 'terminal reversal has no unusable payment action');
  const health = await (await context.request.get(base + '/health')).json();
  assert.equal(health.ok, true);
  const csrf = await context.request.post(base + '/actions/message', { form: { 'repair-id': 'r-boiler', author: 'Tenant', body: 'forged' } });
  assert.equal(csrf.status(), 403, 'missing token is rejected');
  assert.equal((await context.request.get(base + '/repairs/missing')).status(), 404);

  const mobile = await context.newPage();
  await mobile.setViewportSize({ width: 390, height: 844 });
  for (const path of ['/', '/rent', '/repairs/r-boiler']) {
    await mobile.goto(base + path);
    assert.equal(await mobile.evaluate(() => innerWidth), 390, 'actual mobile viewport');
    assert.equal(await mobile.locator('body').evaluate(el => el.scrollWidth > innerWidth), false, `mobile overflow ${path}`);
  }
  await mobile.goto(base + '/');
  await mobile.screenshot({ path: `${output}/mobile.png`, fullPage: true });
  assert.deepEqual(errors, [], 'browser has no uncaught JavaScript errors');
  console.log(`Browser flows passed: HTMX 4 forms, rent, chat SSE, draft preservation, retry, compensation, mobile. Screenshots: ${output}`);
} finally {
  await browser.close();
}
