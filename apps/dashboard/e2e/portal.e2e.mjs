// End-to-end check of the decorator portal in a real browser, backend mocked, synthetic data only.
// Usage: npm run build && node e2e/portal.e2e.mjs
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const PORT = 4174, APP = `http://localhost:${PORT}/portal.html`, SB = 'https://aobosyvlhgkxhjxkfzlz.supabase.co';
const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' };
let failures = 0; const ok = (c, m) => { if (c) console.log('  ok  ' + m); else { failures += 1; console.log('  FAIL ' + m); } };

const ITEMS = [{ item_id: 'i1', order_ref: '#636584', customer: 'HH Associates Ltd', sku: 'POLO-NVY-M', product: 'Polo shirt', colour: 'Navy', size: 'M', qty_sent: 24, qty_outstanding: 24, counted: null, damaged: null, issue: null, issue_note: null, issue_resolved: false },
  { item_id: 'i2', order_ref: '#636020', customer: 'Alloy Bodies Ltd', sku: 'POLO-NVY-L', product: 'Polo shirt', colour: 'Navy', size: 'L', qty_sent: 10, qty_outstanding: 10, counted: null, damaged: null, issue: null, issue_note: null, issue_resolved: false }];
const session = { access_token: 'tok', refresh_token: 'ref', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, token_type: 'bearer', user: { id: 'u1', email: 'sam@stitchers.test', aud: 'authenticated', role: 'authenticated', app_metadata: {}, user_metadata: {}, created_at: '2026-11-01T00:00:00Z' } };

async function newPage(browser, o = {}) {
  const ctx = await browser.newContext({ viewport: o.viewport || { width: 420, height: 900 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage(); page.on('pageerror', (e) => console.log('  PAGE ERROR: ' + e.message.slice(0, 200)));
  const st = { state: o.state || 'to_accept', direct: !!o.direct, calls: [], uploads: [], noAccess: !!o.noAccess, idle: o.idle || 0, messages: [], evidence: [], spoil: [], signs: [], uploadRefused: false };
  if (!o.signedOut) await page.addInitScript((s) => localStorage.setItem('atam-portal-auth', JSON.stringify(s)), session);
  const job = () => ({ ok: true, code: 'TP-2026-00007', state: st.state, status: 'dispatched', direct_to_customer: st.direct, ship_to: st.direct && st.state !== 'to_accept' ? [{ order_ref: '#6001', customer: 'Northside FC', address: '1 Practice Street\nTestville\nTE1 1ST', shipping_method: 'Courier' }] : null, dispatch_date: '2026-11-05', expected_return_date: '2026-11-12', carrier_in: 'DPD', tracking_in: 'DPD123', accepted_at: null, declined_reason: null, instructions: 'Left chest only', items: ITEMS, messages: st.messages, evidence: st.evidence, history: [{ event: 'dispatched', at: '2026-11-05T09:00:00Z', note: null }] });
  await page.route(`${SB}/**`, async (route) => {
    const req = route.request(), u = new URL(req.url()); if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    const json = (b, s = 200) => route.fulfill({ status: s, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify(b) });
    if (u.pathname.startsWith('/auth/v1/otp')) { const b = req.postDataJSON?.(); st.calls.push({ fn: 'otp', body: b }); return /uninvited/.test(b?.email ?? '') ? json({ code: 422, error_code: 'otp_disabled', msg: 'Signups not allowed for otp' }, 422) : json({}); }
    if (u.pathname.startsWith('/auth/v1/user')) return json(session.user);
    if (u.pathname.startsWith('/auth/v1/logout')) return route.fulfill({ status: 204, headers: cors });
    if (u.pathname.includes('/storage/v1/object/sign') && req.method() === 'GET') return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/octet-stream', 'content-disposition': 'attachment; filename="left-chest-v2.dst"' }, body: 'DST-DATA' });
    if (u.pathname.includes('/storage/v1/object/sign')) { st.signs.push(u.pathname); return json({ signedURL: '/object/sign/producer-evidence/x.jpg?token=t' }); }
    if (u.pathname.includes('/storage/v1/object/') && req.method() === 'POST' && st.uploadRefused) return route.fulfill({ status: 403, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify({ statusCode: '403', error: 'Unauthorized', message: 'new row violates row-level security policy' }) });
    if (u.pathname.includes('/storage/v1/object/') && req.method() === 'POST') { st.uploads.push(u.pathname); return json({ Key: 'producer-evidence/x' }); }
    const rpc = u.pathname.match(/\/rest\/v1\/rpc\/(\w+)/);
    if (rpc) {
      const fn = rpc[1], body = req.postDataJSON?.() ?? {}; st.calls.push({ fn, body });
      if (fn === 'portal_report_refused') return json({ ok: true });
      if (fn === 'portal_whoami') return st.noAccess ? json({ message: 'ERROR: This login does not have access to the decorator portal. Ask ATAM for an invitation.' }, 400) : json({ ok: true, producer: 'Portal Stitchers', producer_id: 'pa', user: 'Sam', instructions: 'Left chest only', idle_minutes: st.idle });
      if (fn === 'portal_jobs') return json([{ code: 'TP-2026-00007', state: st.state, status: 'dispatched', dispatch_date: '2026-11-05', expected_return_date: '2026-11-12', direct_to_customer: false, units: 34, orders: [{ order_ref: '#636584', customer: 'HH Associates Ltd' }, { order_ref: '#636020', customer: 'Alloy Bodies Ltd' }], unread: 0 }]);
      if (fn === 'portal_job') return json(job());
      if (fn === 'portal_job_pack') return json({ ok: true, packs: [{ pack_ref: 'JP-2026-00001', version: 2, order_ref: '#636584', due_date: '2026-11-12', instructions: 'Left chest only', lines: [{ product: 'Polo shirt', sku_base: 'POLO', colour: 'Navy', methods: ['embroidery'], placement: 'Left chest', sizes: [{ size: 'M', qty: 24 }], total_qty: 24 }], artwork: [{ area: 'Left chest', process: 'embroidery', version: 2, file_format: 'dst', file: 'pa/left-chest-v2.dst', file_name: 'left-chest-v2.dst', stitch_count: 5200, width_mm: 90, height_mm: 40, placement: 'Left chest', approval: 'approved' }, { area: 'Back', process: 'embroidery', version: 1, file_format: null, file: null, file_name: null, stitch_count: null, width_mm: null, height_mm: null, placement: null, approval: 'pending' }] }] });
      if (fn === 'portal_spoilage') return json({ ok: true, reports: st.spoil });
      if (fn === 'portal_report_spoilage') { st.spoil.push({ waste_ref: 'WST-1', sku: 'POLO-NVY-M', qty: body.p_qty, reported_at: '2026-11-06T11:00:00Z', state: 'With ATAM to review', note: body.p_note }); return json({ ok: true, waste_ref: 'WST-1' }); }
      if (fn === 'portal_accept') { st.state = 'accepted'; return json({ ok: true }); }
      if (fn === 'portal_check_in') { st.state = 'checked_in'; return json({ ok: true, clean: !body.p_items.some((i) => i.issue) }); }
      if (fn === 'portal_stage') { st.state = body.p_stage === 'in_production' ? 'in_production' : 'ready_to_ship'; return json({ ok: true }); }
      if (fn === 'portal_ship') { st.state = 'sent_back'; return json({ ok: true }); }
      if (fn === 'portal_message') { st.messages.push({ side: 'producer', author: 'Sam', body: body.p_body, at: '2026-11-06T10:00:00Z' }); return json({ ok: true }); }
      if (fn === 'portal_evidence_add') { st.evidence.push({ id: 'e1', path: body.p_path, kind: body.p_kind, caption: null, at: '2026-11-06T10:00:00Z' }); return json({ ok: true }); }
      return json({ ok: true });
    }
    return json([]);
  });
  return { page, ctx, st };
}
const server = spawn('npx', ['vite', 'preview', '--port', String(PORT), '--strictPort'], { cwd: new URL('..', import.meta.url).pathname, stdio: 'ignore' });
await new Promise((r) => setTimeout(r, 2500));
const browser = await chromium.launch();
try {
  console.log('sign in');
  { const { page, ctx, st } = await newPage(browser, { signedOut: true }); await page.goto(APP); await page.getByRole('heading', { name: 'Sign in' }).waitFor();
    ok((await page.getByText('There is no password to remember').count()) === 1, 'the portal signs in by emailed link, no password');
    await page.getByLabel('Email').fill('sam@stitchers.test'); await page.getByRole('button', { name: 'Email me a sign-in link' }).click(); await page.getByText('If that address has been invited').waitFor();
    ok(st.calls.some((c) => c.fn === 'otp' && c.body.email === 'sam@stitchers.test'), 'the emailed link is requested for that address');
    ok(st.calls.some((c) => c.fn === 'otp' && c.body.create_user === false), 'invite-only: the portal never asks to create an account'); await ctx.close(); }
  { const { page, ctx } = await newPage(browser, { signedOut: true }); await page.goto(APP); await page.getByLabel('Email').fill('uninvited@nowhere.test'); await page.getByRole('button', { name: 'Email me a sign-in link' }).click(); await page.getByText('If that address has been invited').waitFor();
    ok((await page.getByRole('alert').count()) === 0, 'an uninvited address sees the same message as an invited one, so invitations cannot be probed'); await ctx.close(); }
  console.log('portal security');
  { const { page, ctx, st } = await newPage(browser, { idle: 0.03 }); await page.goto(APP); await page.getByRole('heading', { name: /Jobs|Your jobs|Job/ }).first().waitFor().catch(() => {});
    await page.getByRole('heading', { name: 'Sign in' }).waitFor({ timeout: 8000 }); ok((await page.getByText(/signed out after .* minutes of inactivity/).count()) === 1, 'after a quiet spell the portal signs the decorator out and says why'); await ctx.close(); }
  { const { page, ctx, st } = await newPage(browser, { noAccess: true }); await page.goto(APP); await page.getByRole('heading', { name: 'No access' }).waitFor(); await page.waitForTimeout(300);
    ok(st.calls.some((c) => c.fn === 'portal_report_refused'), 'a login that is not an invited decorator is reported so staff can see it'); await ctx.close(); }
  console.log('no access');
  { const { page, ctx } = await newPage(browser, { noAccess: true }); await page.goto(APP); await page.getByRole('heading', { name: 'No access' }).waitFor(); ok((await page.getByText('Ask ATAM for an invitation').count()) === 1, 'a login without an invitation is told so'); await ctx.close(); }
  console.log('direct to customer jobs');
  { const { page, ctx, st } = await newPage(browser, { direct: true, state: 'in_production' }); await page.goto(APP + '#/job/TP-2026-00007'); await page.getByTestId('ship-to').waitFor();
    ok((await page.getByTestId('ship-to').innerText()).includes('1 Practice Street') && (await page.getByTestId('ship-to').innerText()).includes('Do not send it back to ATAM'), 'a direct job shows where to send it and says not to send it back');
    ok(await page.getByRole('button', { name: 'Production is complete' }).isDisabled(), 'a direct job cannot be marked complete without a finished goods photo');
    await page.getByTestId('finished-photo').locator('input[type=file]').setInputFiles({ name: 'done.jpg', mimeType: 'image/jpeg', buffer: Buffer.from('x') }); await page.getByText(/finished goods photo.* added/).waitFor();
    ok(st.calls.some((c) => c.fn === 'portal_evidence_add' && c.body.p_kind === 'finished'), 'the photo is saved as a finished goods photo');
    ok(!(await page.getByRole('button', { name: 'Production is complete' }).isDisabled()), 'with the photo the job can be marked complete'); await ctx.close(); }
  { const { page, ctx } = await newPage(browser, { direct: false, state: 'in_production' }); await page.goto(APP + '#/job/TP-2026-00007'); await page.getByRole('button', { name: 'Production is complete' }).waitFor();
    ok((await page.getByTestId('ship-to').count()) === 0 && (await page.getByTestId('finished-photo').count()) === 0 && !(await page.getByRole('button', { name: 'Production is complete' }).isDisabled()), 'a job that comes back to us shows no customer address and needs no finished goods photo'); await ctx.close(); }
  console.log('the job, start to finish');
  const { page, ctx, st } = await newPage(browser); await page.goto(APP);
  await page.getByRole('heading', { name: 'Your work' }).waitFor();
  ok((await page.getByText('#636584 · HH Associates Ltd').count()) === 1 && (await page.getByText('#636020 · Alloy Bodies Ltd').count()) === 1, 'the list shows the order numbers and customers on the job');
  ok((await page.getByText('Needs your attention').count()) === 1, 'a job to accept is at the top');
  console.log('scan a parcel label');
  await page.getByRole('button', { name: 'Scan a parcel label' }).click(); await page.getByLabel('Scan or type a code').fill('banana'); await page.keyboard.press('Enter');
  await page.getByText('not a parcel label from ATAM').waitFor(); ok(true, 'a code that is not a parcel label is refused with a plain message');
  await page.getByLabel('Scan or type a code').fill('TP-2026-99999'); await page.keyboard.press('Enter'); await page.getByText('is not one of your jobs').waitFor(); ok(true, 'a parcel that is not theirs is refused and nothing opens');
  await page.getByLabel('Scan or type a code').fill('PRO-TP-2026-00007-261109'); await page.keyboard.press('Enter'); await page.getByRole('heading', { name: 'What to do next' }).waitFor(); ok(page.url().includes('#/job/TP-2026-00007'), 'scanning the printed barcode on their parcel opens that job');
  console.log('job pack');
  await page.getByRole('region', { name: 'Job pack' }).waitFor(); ok((await page.getByText('JP-2026-00001 · version 2').count()) === 1 && (await page.getByText('5,200 stitches').count()) === 1, 'the job pack shows the version, specs and sizes');
  ok((await page.getByText('File not stored yet').count()) === 1, 'an area with no stored file says so instead of a dead button');
  { const [dl] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Download left-chest-v2.dst' }).click()]); ok(dl.suggestedFilename() === 'left-chest-v2.dst', 'the artwork file downloads with its own name'); }
  ok(st.signs.some((x) => x.includes('/object/sign/artwork/')), 'the download uses a short-lived signed link from the artwork store');
  await page.goto(APP + '#/'); await page.getByText('TP-2026-00007').first().click(); await page.getByRole('heading', { name: 'What to do next' }).waitFor();
  ok((await page.getByText('Left chest only').count()) >= 1, 'the instructions are shown');
  await page.getByRole('button', { name: 'Accept this job' }).click(); await page.getByText('You have accepted this job').waitFor(); ok(st.calls.some((c) => c.fn === 'portal_accept'), 'the job is accepted');
  await page.getByRole('button', { name: /check them in/ }).click(); await page.getByText('Count what actually arrived').waitFor();
  ok(!(await page.getByRole('button', { name: 'Check in: all correct' }).isDisabled()), 'counts start at what was sent, so a clean check in is one tap');
  await page.getByLabel('Counted POLO-NVY-M').fill('22'); await page.getByLabel('Damaged POLO-NVY-M').fill('1');
  ok(await page.getByRole('button', { name: 'Check in and report the problem' }).isDisabled(), 'a count problem needs words before it can be sent');
  await page.getByLabel('Problem POLO-NVY-M').selectOption('short'); await page.getByLabel('Note POLO-NVY-M').fill('Two polos missing and one stained');
  await page.getByLabel('Photos of the delivery').setInputFiles({ name: 'stain.jpg', mimeType: 'image/jpeg', buffer: Buffer.from('fakejpeg') });
  await page.getByLabel('Photos of POLO-NVY-M').setInputFiles({ name: 'sleeve.jpg', mimeType: 'image/jpeg', buffer: Buffer.from('fakejpeg2') });
  await page.getByRole('button', { name: 'Check in and report the problem' }).click(); await page.getByRole('button', { name: 'Start production' }).waitFor();
  const ci = st.calls.find((c) => c.fn === 'portal_check_in');
  ok(ci && ci.body.p_items.find((i) => i.item_id === 'i1').qty_counted === 22 && ci.body.p_items.find((i) => i.item_id === 'i1').qty_damaged === 1 && ci.body.p_items.find((i) => i.item_id === 'i1').issue === 'short', 'the count, damage and problem type are sent');
  ok(st.uploads.length === 2 && st.calls.some((c) => c.fn === 'portal_evidence_add' && c.body.p_path.startsWith('pa/TP-2026-00007/')), 'the photos are uploaded into the decorator\'s own folder and recorded');
  ok(st.calls.some((c) => c.fn === 'portal_evidence_add' && c.body.p_item === 'i1' && c.body.p_caption === 'POLO-NVY-M') && st.calls.some((c) => c.fn === 'portal_evidence_add' && c.body.p_item === null), 'a photo can belong to one item, and a photo of the whole delivery stays on the job');
  // spoiled units: only once the goods are checked in, one clear form, a plain confirmation
  ok((await page.getByRole('region', { name: 'Spoiled units' }).count()) === 1, 'the spoiled-units section appears once the goods are checked in');
  await page.getByRole('button', { name: 'Report spoiled units' }).click(); ok(await page.getByRole('button', { name: 'Send report' }).isDisabled(), 'a report needs a reason and some words before it can be sent');
  await page.getByLabel('Units spoiled').fill('2'); await page.getByLabel('What happened').selectOption('stained'); await page.getByLabel('Spoilage note').fill('Machine oil on two shirts');
  await page.getByRole('button', { name: 'Send report' }).click(); await page.getByText('ATAM has your report').waitFor();
  const sp = st.calls.find((c) => c.fn === 'portal_report_spoilage');
  ok(sp && sp.body.p_code === 'TP-2026-00007' && sp.body.p_item === 'i1' && sp.body.p_qty === 2 && sp.body.p_what === 'stained' && sp.body.p_evidence === null, 'the report names the job, line, units and what happened');
  ok((await page.getByText('With ATAM to review').count()) === 1, 'the decorator sees their report and where it stands');
  // the upload limit: a refused photo is explained in plain words, not as a database message, and nothing is sent without it
  { st.uploadRefused = true; const before = st.calls.filter((c) => c.fn === 'portal_report_spoilage').length;
    await page.getByRole('button', { name: 'Report spoiled units' }).click(); await page.getByLabel('Units spoiled').fill('1'); await page.getByLabel('What happened').selectOption('stained'); await page.getByLabel('Spoilage note').fill('One more stained shirt');
    await page.getByLabel('Photo (optional)').setInputFiles({ name: 'more.jpg', mimeType: 'image/jpeg', buffer: Buffer.from('fakejpeg3') }); await page.getByRole('button', { name: 'Send report' }).click();
    await page.getByText(/this job may already hold as many files as ATAM allows/).waitFor();
    ok((await page.getByText(/row-level security/).count()) === 0 && st.calls.filter((c) => c.fn === 'portal_report_spoilage').length === before, 'a photo refused by the upload limit is explained in plain words and the report is not sent without it');
    st.uploadRefused = false; await page.getByRole('button', { name: 'Cancel' }).first().click().catch(() => {}); }
  await page.getByRole('button', { name: 'Start production' }).click(); await page.getByRole('button', { name: 'Production is complete' }).waitFor();
  await page.getByRole('button', { name: 'Report a delay' }).click(); ok(await page.getByRole('region', { name: 'What to do next' }).getByRole('button', { name: 'Send', exact: true }).isDisabled(), 'a delay needs a date and a reason'); await page.getByRole('button', { name: 'Cancel' }).click();
  await page.getByRole('button', { name: 'Production is complete' }).click(); await page.getByRole('button', { name: /Send the goods back/ }).waitFor();
  await page.getByRole('button', { name: /Send the goods back/ }).click(); ok(await page.getByRole('button', { name: 'Confirm shipped' }).isDisabled(), 'shipping needs a courier and tracking reference');
  await page.getByLabel('Courier').fill('DPD'); await page.getByLabel('Tracking reference').fill('DPD777'); await page.getByRole('button', { name: 'Confirm shipped' }).click(); await page.getByText('Sent back').first().waitFor();
  ok(st.calls.some((c) => c.fn === 'portal_ship' && c.body.p_tracking === 'DPD777' && c.body.p_items.length === 2), 'the courier, tracking and units are sent');
  await page.getByLabel('Message').fill('Can you confirm delivery by Friday?'); await page.locator('form').getByRole('button', { name: 'Send', exact: true }).click(); await page.getByText('Can you confirm delivery by Friday?').waitFor(); ok(true, 'a message is sent and shown');
  await page.screenshot({ path: new URL('./shots/portal-job.png', import.meta.url).pathname }).catch(() => {});
  ok(!(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 2)), 'no sideways scrolling on a phone');
  await ctx.close();
} finally { await browser.close(); server.kill(); }
console.log(failures === 0 ? 'ALL PORTAL CHECKS PASSED' : failures + ' check(s) FAILED'); process.exit(failures ? 1 : 0);
