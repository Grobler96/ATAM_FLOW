// End-to-end check of the Exceptions page in a real browser, with the network mocked (no real data, no real accounts).
// Usage: npm run build && node e2e/exceptions.e2e.mjs   (screenshots go to $SHOTS or ./e2e/shots)
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { rows, history } from './fixtures.mjs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const SHOTS = process.env.SHOTS || new URL('./shots', import.meta.url).pathname;
mkdirSync(SHOTS, { recursive: true });
const PORT = 4173, URL_ = `http://localhost:${PORT}/`;
const SB = 'https://aobosyvlhgkxhjxkfzlz.supabase.co', N8N = 'https://atamcpi.app.n8n.cloud';
const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' };
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: 'u1', role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 })}.sig`;
const session = { access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: 'r', user: { id: 'u1', aud: 'authenticated', role: 'authenticated', email: 'sam@atam.test', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() } };

let failures = 0;
const ok = (cond, msg) => { if (cond) console.log('  ok  ' + msg); else { failures += 1; console.log('  FAIL ' + msg); } };

async function newPage(browser, o = {}) {
  const ctx = await browser.newContext({ viewport: o.viewport || { width: 390, height: 844 }, deviceScaleFactor: o.dsf || 1, colorScheme: o.scheme || 'light', permissions: [] });
  const page = await ctx.newPage();
  const state = { rows: o.rows ?? rows, role: o.role ?? 'manager', lastDetection: o.lastDetection === undefined ? new Date(Date.now() - 12 * 60000).toISOString() : o.lastDetection,
    badLogin: o.badLogin ?? false, restFails: o.restFails ?? false, n8n: [], n8nStatus: o.n8nStatus ?? 200, n8nBody: o.n8nBody ?? null, signedIn: o.signedIn ?? false };
  await page.route(`${SB}/**`, async (route) => {
    const req = route.request(), u = new URL(req.url());
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    const json = (body, status = 200) => route.fulfill({ status, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify(body) });
    if (u.pathname.startsWith('/auth/v1/token')) return state.badLogin ? json({ error: 'invalid_grant', error_description: 'Invalid login credentials' }, 400) : json(session);
    if (u.pathname.startsWith('/auth/v1/user')) return json(session.user);
    if (u.pathname.startsWith('/auth/v1/logout')) return route.fulfill({ status: 204, headers: cors });
    if (state.restFails && u.pathname.startsWith('/rest/v1/ui_exceptions')) return json({ message: 'boom' }, 500);
    if (u.pathname === '/rest/v1/ui_exceptions') return json(state.rows);
    if (u.pathname === '/rest/v1/ui_status') return json({ last_detection_at: state.lastDetection, server_time: new Date().toISOString() });
    if (u.pathname === '/rest/v1/rpc/ui_my_role') return json(state.role);
    if (u.pathname === '/rest/v1/ui_exception_history') return json(history.map((h) => ({ ...h, exception_id: 'x' })));
    if (u.pathname === '/rest/v1/ui_order_accountability') return u.search.includes('636') || u.search.includes('700101') ? json({ order_id: 'o-1' }) : route.fulfill({ status: 406, headers: cors, body: '{}' });
    return json([]);
  });
  await page.route(`${N8N}/**`, async (route) => {
    const req = route.request();
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    state.n8n.push({ url: req.url(), auth: req.headers()['authorization'], body: req.postDataJSON() });
    return route.fulfill({ status: state.n8nStatus, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify(state.n8nBody ?? { ok: true }) });
  });
  return { ctx, page, state };
}
async function signIn(page) {
  await page.goto(URL_);
  await page.getByLabel('Email').fill('sam@atam.test'); await page.getByLabel('Password').fill('secret');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.getByRole('heading', { name: /Exceptions/ }).waitFor();
  await page.waitForSelector('.list > li, .state', { timeout: 8000 });
}

const server = spawn('npx', ['vite', 'preview', '--port', String(PORT), '--strictPort'], { cwd: new URL('..', import.meta.url).pathname, stdio: 'ignore' });
await new Promise((r) => setTimeout(r, 2500));
const browser = await chromium.launch();
try {
  console.log('sign-in');
  { const { page, ctx } = await newPage(browser, { badLogin: true, dsf: 2 });
    await page.goto(URL_); await page.getByLabel('Email').fill('x@atam.test'); await page.getByLabel('Password').fill('nope'); await page.getByRole('button', { name: 'Sign in' }).click();
    await page.getByRole('alert').waitFor(); ok((await page.getByRole('alert').innerText()).includes('do not match'), 'wrong password shows a plain-English error');
    await page.screenshot({ path: join(SHOTS, 'login-phone.png') }); await ctx.close(); }

  console.log('page, filters, drawer, actions (phone, light)');
  { const { page, ctx, state } = await newPage(browser, { dsf: 2 });
    await signIn(page);
    ok((await page.locator('.list > li').count()) === rows.length, `all ${rows.length} open issues listed`);
    const first = await page.locator('.list > li').first().innerText();
    ok(/critical/i.test(first) && first.includes('#700101'), 'critical and overdue issue is first');
    const kpi = (l) => page.locator('.kpi', { hasText: l }).locator('.kpi-v').innerText();
    ok((await kpi('Open')) === String(rows.length) && (await kpi('Critical')) === '3', 'KPI strip counts match');
    ok((await kpi('At stake')).startsWith('£'), 'money at stake shown');
    ok((await page.getByText('Machine downtime').first().innerText()).length > 0 && (await page.locator('.chip', { hasText: 'Machine downtime' }).locator('b').innerText()) === '0', 'machine downtime group shown with 0 (not tracked yet)');
    await page.screenshot({ path: join(SHOTS, 'exceptions-phone-light.png') });

    await page.locator('.chip', { hasText: 'Orders at risk' }).click();
    ok((await page.locator('.list > li').count()) === 1, 'Orders at risk filters to 1');
    await page.locator('.chip', { hasText: 'All open' }).click();
    await page.getByPlaceholder(/Search/).fill('ralawise');
    ok((await page.locator('.list > li').count()) === 2, 'search finds the two Ralawise items');
    await page.getByPlaceholder(/Search/).fill('');
    await page.locator('.kpi', { hasText: 'No owner' }).click();
    ok((await page.locator('.list > li').count()) === rows.filter((r) => r.needs_owner).length, 'No owner KPI filters');
    await page.locator('.kpi', { hasText: 'No owner' }).click();
    await page.locator('.chip', { hasText: '> 7 days' }).click();
    ok((await page.locator('.list > li').count()) === rows.filter((r) => r.age_bucket === '> 7 days').length, 'age filter works');
    await page.locator('.chip', { hasText: '> 7 days' }).click();

    await page.locator('.list > li').first().click();
    await page.getByRole('dialog').waitFor();
    ok((await page.getByText('Escalated').count()) >= 0 && (await page.getByText('Recommended action').count()) === 1, 'drawer opens with recommended action');
    await page.getByText('History').waitFor(); await page.waitForSelector('.timeline li');
    ok((await page.locator('.timeline li').count()) === 2, 'history timeline loads');
    await page.screenshot({ path: join(SHOTS, 'drawer-phone-light.png') });
    await page.getByRole('button', { name: /Take it/ }).click();
    await page.getByRole('button', { name: 'Assign', exact: true }).click();
    await page.getByText('Assigned.').waitFor();
    const call = state.n8n.at(-1);
    ok(call.url.endsWith('/exceptions') && call.auth === `Bearer ${jwt}` && call.body.action === 'assign' && call.body.params.owner === 'sam@atam.test' && !!call.body.params.exception_id, 'assign sends the right request with the login token');

    await page.keyboard.press('Escape');
    await page.locator('.list > li').first().click();
    await page.getByRole('button', { name: 'Resolve', exact: true }).click();
    ok(await page.getByRole('button', { name: 'Mark resolved' }).isDisabled(), 'resolve is disabled until a note is written');
    await page.getByLabel('Note (required)').fill('Customer agreed a new date');
    await page.getByRole('button', { name: 'Mark resolved' }).click();
    await page.getByText('Resolved.').waitFor();
    ok(state.n8n.at(-1).body.action === 'resolve' && state.n8n.at(-1).body.params.note === 'Customer agreed a new date', 'resolve sends method and note');

    await page.keyboard.press('Escape');
    await page.locator('.list > li').first().click();
    await page.getByRole('button', { name: 'Write off' }).click();
    ok(await page.getByRole('button', { name: 'Write off' }).last().isDisabled(), 'write-off needs an amount and a reason');
    await page.keyboard.press('Escape'); await page.getByRole('dialog').waitFor({ state: 'detached' });
    ok(true, 'Escape closes the drawer');

    await page.getByRole('button', { name: 'Raise an issue' }).click();
    await page.getByLabel('What is wrong?').fill('Customer reports faded print');
    await page.getByLabel('Order number (optional)').fill('700101');
    await page.getByRole('button', { name: 'Raise issue' }).click();
    await page.getByText('Issue raised.').waitFor();
    const raise = state.n8n.at(-1).body;
    ok(raise.action === 'raise' && raise.params.links[0].id === 'o-1' && raise.params.severity === 'medium', 'raising an issue links the order');
    await ctx.close(); }

  console.log('unpublished workflow and failures');
  { const { page, ctx } = await newPage(browser, { n8nStatus: 404, n8nBody: {} });
    await signIn(page);
    await page.getByRole('button', { name: 'Check now' }).click();
    await page.getByText(/not switched on yet/).waitFor(); ok(true, 'a 404 from n8n is explained plainly');
    await page.locator('.list > li').first().click(); await page.getByRole('button', { name: /Take it/ }).click(); await page.getByRole('button', { name: 'Assign', exact: true }).click();
    await page.getByRole('alert').filter({ hasText: 'not switched on' }).waitFor(); ok(true, 'drawer action shows the same explanation and stays open');
    await ctx.close(); }
  { const { page, ctx } = await newPage(browser, { restFails: true });
    await page.goto(URL_); await page.getByLabel('Email').fill('a@b.c'); await page.getByLabel('Password').fill('x'); await page.getByRole('button', { name: 'Sign in' }).click();
    await page.getByText(/Could not load the issues/).waitFor(); ok(true, 'a failed load shows an error with a retry'); await ctx.close(); }
  { const { page, ctx } = await newPage(browser, { rows: [] });
    await signIn(page); ok((await page.getByText(/Nothing is wrong right now/).count()) === 1, 'empty state is reassuring and specific'); await ctx.close(); }
  { const { page, ctx } = await newPage(browser, { lastDetection: new Date(Date.now() - 5 * 3600000).toISOString() });
    await signIn(page); ok((await page.getByText(/may be out of date/).count()) === 1, 'stale detector warning'); await ctx.close(); }
  { const { page, ctx } = await newPage(browser, { role: 'viewer' });
    await signIn(page); ok((await page.getByRole('button', { name: 'Raise an issue' }).count()) === 0 && (await page.getByText('view-only').count()) >= 1, 'viewers cannot raise or act');
    await page.locator('.list > li').first().click(); ok((await page.getByRole('button', { name: 'Resolve' }).count()) === 0, 'viewer sees no action buttons'); await ctx.close(); }
  { const { page, ctx } = await newPage(browser, { role: 'production' });
    await signIn(page); await page.locator('.list > li').first().click();
    ok((await page.getByRole('button', { name: 'Write off' }).count()) === 0 && (await page.getByRole('button', { name: 'Resolve', exact: true }).count()) === 1, 'production staff can resolve but not write off'); await ctx.close(); }
  { const { page, ctx } = await newPage(browser);
    await signIn(page); await ctx.setOffline(true); await page.waitForSelector('text=You are offline');
    ok((await page.locator('.list > li').count()) === rows.length, 'offline keeps showing the last data with a banner'); await ctx.close(); }

  console.log('screenshots (desktop light, desktop dark, phone dark)');
  { const { page, ctx } = await newPage(browser, { viewport: { width: 1280, height: 900 }, dsf: 1 }); await signIn(page); await page.screenshot({ path: join(SHOTS, 'exceptions-desktop-light.png') });
    await page.locator('.list > li').nth(1).click(); await page.waitForSelector('.timeline li'); await page.screenshot({ path: join(SHOTS, 'drawer-desktop-light.png') }); await ctx.close(); }
  { const { page, ctx } = await newPage(browser, { viewport: { width: 1280, height: 900 }, scheme: 'dark' }); await signIn(page); await page.screenshot({ path: join(SHOTS, 'exceptions-desktop-dark.png') }); await ctx.close(); }
  { const { page, ctx } = await newPage(browser, { scheme: 'dark', dsf: 2 }); await signIn(page); await page.screenshot({ path: join(SHOTS, 'exceptions-phone-dark.png') }); await ctx.close(); }
} finally {
  await browser.close(); server.kill();
}
console.log(failures ? `\n${failures} check(s) FAILED` : '\nALL E2E CHECKS PASSED');
process.exit(failures ? 1 : 0);
