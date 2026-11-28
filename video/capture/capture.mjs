// Captures clean, intentional screenshots of the real ATAM_FLOW dashboard for the tutorial videos.
// The app runs from its production build against the same fully mocked backend the browser tests use, so every screen is the
// real interface with synthetic data. Nothing touches the live Supabase project or n8n.
//
// For each screenshot it also records where the interesting elements are (as fractions of the screen), so the video can zoom
// and highlight them without hand-measuring. Output: public/shots/<id>.png and src/shots.json.
//
// Usage (from video/):  node capture/capture.mjs [scene ...]     (build the dashboard first: cd ../apps/dashboard && npm run build)
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const E2E = path.join(ROOT, 'apps', 'dashboard', 'e2e');
const OUT = path.join(HERE, '..', 'public', 'shots');
const MANIFEST = path.join(HERE, '..', 'src', 'shots.json');
mkdirSync(OUT, { recursive: true });

// The mocked backend lives at the top of the browser test. Reuse it as it is (everything before the line that starts the server)
// rather than copying it, so the videos always show what the tests show. The generated file is git-ignored.
const lines = readFileSync(path.join(E2E, 'exceptions.e2e.mjs'), 'utf8').split('\n');
const cut = lines.findIndex((l) => l.startsWith('const server = spawn'));
if (cut < 0) throw new Error('Could not find where the browser test starts its server; the capture harness needs updating.');
writeFileSync(path.join(E2E, '_capture_harness.gen.mjs'), lines.slice(0, cut).join('\n') + '\nexport { newPage, signIn, settle, goto, APP, PORT };\n');
const { newPage, signIn, settle, goto, APP, PORT } = await import(path.join(E2E, '_capture_harness.gen.mjs'));
const { chromium } = createRequire(import.meta.url)('playwright');
const F = await import(path.join(E2E, 'fixtures2.mjs'));

const manifest = existsSync(MANIFEST) ? JSON.parse(readFileSync(MANIFEST, 'utf8')) : {};
const only = process.argv.slice(2);

// A rect can be one locator, a list of locators (their union), or { all: locator } (union of every match). Boxes are exact.
async function boxOf(spec) {
  const isAll = spec && !Array.isArray(spec) && spec.all && typeof spec.all !== 'function';   // { all: locator }, not a Locator (which has its own all() method)
  const locs = Array.isArray(spec) ? spec : isAll ? await spec.all.all() : [spec];
  const boxes = [];
  for (const l of locs) { const b = await l.first().boundingBox().catch(() => null); if (b) boxes.push(b); }
  if (!boxes.length) return null;
  const x0 = Math.min(...boxes.map((b) => b.x)), y0 = Math.min(...boxes.map((b) => b.y)), x1 = Math.max(...boxes.map((b) => b.x + b.width)), y1 = Math.max(...boxes.map((b) => b.y + b.height));
  return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
}
async function snap(page, id, rects = {}, opts = {}) {
  await settle(page, true);
  const vp = page.viewportSize();
  const entry = { file: `shots/${id}.png`, rects: {} };
  for (const [name, spec] of Object.entries(rects)) {
    const box = await boxOf(spec);
    if (!box) { console.log(`  ! ${id}: no element for "${name}"`); continue; }
    let w = box.width / vp.width, h = box.height / vp.height, x = box.x / vp.width, y = box.y / vp.height;
    const minW = opts.minW ?? 0, minH = opts.minH ?? 0;   // exact boxes: highlights hug the element; the camera adds its own breathing room
    if (w < minW) { x -= (minW - w) / 2; w = minW; } if (h < minH) { y -= (minH - h) / 2; h = minH; }
    x = Math.max(0, Math.min(x, 1 - w)); y = Math.max(0, Math.min(y, 1 - h));
    entry.rects[name] = { x: +x.toFixed(4), y: +y.toFixed(4), w: +w.toFixed(4), h: +h.toFixed(4) };
  }
  await page.screenshot({ path: path.join(OUT, `${id}.png`) });
  manifest[id] = entry;
  console.log(`  ✓ ${id}`);
}

const SCENES = {
  // ---- Tutorial: a tour of the Command Centre -------------------------------------------------------------
  async cc(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: true });
    await signIn(page); await page.waitForSelector('.kpi'); await page.waitForTimeout(600);
    const kpi = (t) => page.locator('.kpi', { hasText: t });
    await snap(page, 'cc-home', {
      sidebar: page.locator('.sidebar'), search: page.getByPlaceholder(/Search orders/), quick: page.getByRole('button', { name: /Quick actions/ }),
      kpis: page.locator('section[aria-label="Key numbers"]'), kpiOverdue: kpi('Overdue orders'), kpiRisk: kpi('Orders at risk'), kpiBlocked: kpi('Blocked by stock'),
      attention: page.locator('.panel', { hasText: 'What needs attention now' }).first(), pulse: page.locator('.panel', { hasText: 'Production pulse' }).first(),
      scopeBar: page.locator('.scope-banner, [class*="scope"]').first(),
    });
    await page.keyboard.press('Control+k'); await page.getByRole('dialog', { name: 'Command palette' }).waitFor(); await page.keyboard.type('acme', { delay: 40 }); await page.waitForTimeout(500);
    await snap(page, 'cc-palette', { palette: page.getByRole('dialog', { name: 'Command palette' }) });
    await page.keyboard.press('Escape'); await page.waitForTimeout(300);
    await page.getByRole('button', { name: /Quick actions/ }).click(); await page.getByRole('menu').waitFor();
    await snap(page, 'cc-quick', { menu: page.getByRole('menu'), quick: page.getByRole('button', { name: /Quick actions/ }) });
    await page.keyboard.press('Escape'); await page.mouse.click(700, 500); await page.waitForTimeout(300);
    await goto(page, '#/'); await page.waitForSelector('.kpi');
    await kpi('Overdue orders').click(); await page.waitForSelector('.dt-row'); await page.waitForTimeout(500);
    await snap(page, 'cc-drill', { table: page.locator('.dt').first(), tabs: page.locator('.dt .chip').first() });
    await ctx.close();
  },

  // ---- Tutorial: create and approve a purchase order ------------------------------------------------------
  async po(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2 });
    await signIn(page); await goto(page, '#/purchasing'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(500);
    await snap(page, 'po-list', { create: page.getByRole('button', { name: 'Create PO' }), table: page.locator('.dt').first(), tabs: page.locator('.seg').first() });
    await page.getByRole('button', { name: 'Create PO' }).click(); await page.getByRole('dialog').waitFor(); await page.waitForTimeout(500);
    await snap(page, 'po-create', { dialog: page.getByRole('dialog') });
    await page.keyboard.press('Escape'); await page.waitForTimeout(300);
    await page.locator('.dt-row', { hasText: 'AF-PO-1001' }).click(); await page.getByRole('dialog').waitFor(); await page.waitForTimeout(500);
    await snap(page, 'po-drawer', { drawer: page.getByRole('dialog').first(), approve: page.getByRole('button', { name: /^Approve/ }) });
    await page.getByRole('button', { name: /^Approve/ }).first().click(); await page.getByText('Who can approve it').waitFor(); await page.waitForTimeout(400);
    await snap(page, 'po-approve', { dialog: page.getByRole('dialog').last(), rules: page.getByText('Who can approve it'), confirm: page.getByRole('button', { name: 'Approve PO' }) });
    await page.getByRole('button', { name: 'Approve PO' }).click(); await page.waitForTimeout(700);
    await snap(page, 'po-done', { toast: page.locator('.toast').first() });
    await ctx.close();
  },

  // ---- Tutorial: generate and print labels ----------------------------------------------------------------
  async labels(browser) {
    const { page, ctx } = await newPage(browser, { role: 'warehouse', dsf: 2 });
    await signIn(page); await goto(page, '#/labels'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(500);
    await snap(page, 'lb-list', { generate: page.getByRole('button', { name: 'Generate labels' }), table: page.locator('.dt').first(), tabs: page.locator('.dt .chip').first() });
    await page.getByRole('button', { name: 'Generate labels' }).click(); await page.getByRole('dialog').waitFor(); await page.waitForTimeout(500);
    await snap(page, 'lb-generate', { dialog: page.getByRole('dialog') });
    await page.keyboard.press('Escape'); await page.waitForTimeout(300);
    await page.locator('.dt-row').first().click(); await page.getByRole('dialog').waitFor(); await page.waitForTimeout(600);
    await snap(page, 'lb-preview', { drawer: page.getByRole('dialog').first(), formats: page.locator('.seg').last(), print: page.getByRole('button', { name: /^Print/ }).last() });
    await ctx.close();
  },

  // ======================= Batch 2: daily staff work =======================
  // ---- Find any order, fast ----
  async orders(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: false });
    await signIn(page); await goto(page, '#/orders'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(600);
    const dt = page.locator('.dt').first(), chips = page.locator('.dt .chip').first().locator('xpath=..');
    await snap(page, 'od-list', { table: dt, chips, search: page.getByPlaceholder(/Search order/), saveExport: [page.getByRole('button', { name: 'Save view' }), page.getByRole('button', { name: 'Export CSV' })] });
    await page.locator('.dt .chip', { hasText: 'Overdue' }).first().click(); await page.waitForTimeout(500);
    await snap(page, 'od-overdue', { table: dt, chip: page.locator('.dt .chip', { hasText: 'Overdue' }).first(), due: page.locator('.dt-row').first() });
    await page.locator('.dt .chip', { hasText: 'All open' }).first().click(); await page.getByPlaceholder(/Search order/).fill('acme'); await page.waitForTimeout(600);
    await snap(page, 'od-search', { search: page.getByPlaceholder(/Search order/), table: dt });
    await page.getByPlaceholder(/Search order/).fill(''); await page.waitForTimeout(300);
    await page.locator('.dt-row').first().click(); await page.getByRole('dialog').waitFor(); await page.waitForTimeout(700);
    await snap(page, 'od-drawer', { drawer: page.getByRole('dialog').first() });
    await ctx.close();
  },
  // ---- Why the system says this ----
  async order(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: false });
    await signIn(page); await goto(page, '#/orders/700101'); const dlg = page.getByRole('dialog').first(); await dlg.waitFor(); await page.waitForTimeout(800);
    await snap(page, 'ow-overview', { drawer: dlg, facts: dlg.locator('.facts').first(), why: dlg.locator('.panel', { hasText: 'Why the system says this' }).first(),
      tabs: dlg.getByRole('tablist').first(), send: dlg.getByRole('button', { name: 'Send to a decorator' }), buttons: dlg.getByRole('button', { name: 'Print worksheet' }).locator('xpath=..') });
    await dlg.getByRole('tab', { name: /Lines & stock/ }).click(); await page.waitForTimeout(600);
    await snap(page, 'ow-lines', { table: dlg.locator('table').first(), tabs: dlg.getByRole('tablist').first() });
    await ctx.close();
  },
  // ---- Stock and shortage advice ----
  async stock(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: false });
    await signIn(page); await goto(page, '#/stock'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(600);
    const chips = page.locator('.dt .chip').first().locator('xpath=..');
    await snap(page, 'st-list', { table: page.locator('.dt').first(), chips, columns: page.locator('.dt-row').first() });
    await page.locator('.dt .chip', { hasText: 'Short for orders' }).click(); await page.waitForTimeout(500);
    await snap(page, 'st-short', { chip: page.locator('.dt .chip', { hasText: 'Short for orders' }), table: page.locator('.dt').first() });
    await page.locator('.dt-row').first().click(); const dlg = page.getByRole('dialog').first(); await dlg.waitFor(); await page.waitForTimeout(800);
    await snap(page, 'st-drawer', { drawer: dlg,
      advice: [dlg.getByText(/what to do about the shortage/i), dlg.locator('.callout', { hasText: /tell the customer|wait|substitute|reorder|split/i }).first()],
      orders: [dlg.getByText(/orders that need it/i), dlg.getByText('#700101').first()], reorder: dlg.locator('.callout', { hasText: 'Reorder recommendation' }).first(),
      incoming: dlg.getByText(/incoming purchase orders/i) });
    await ctx.close();
  },
  // ---- Review supplier emails ----
  async emails(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: false });
    await signIn(page); await goto(page, '#/purchasing'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(500);
    await snap(page, 'em-list', { emailsTab: page.getByRole('tab', { name: /Emails/ }), chase: page.getByRole('button', { name: 'Draft chases for late POs' }), tabs: page.getByRole('tab', { name: /Emails/ }).locator('xpath=..') });
    await page.getByRole('tab', { name: /Emails/ }).click(); await page.waitForTimeout(700);
    const panel = page.locator('.panel', { hasText: 'Outgoing emails waiting for you' }).first();
    await snap(page, 'em-queue', { panel, row: panel.locator('xpath=.//*[contains(text(),"COM-")]/ancestor::div[1]'), subject: page.getByText(/Stock Shortage/).first(), badge: page.getByText('PENDING REVIEW'),
      approve: page.getByRole('button', { name: 'Approve & send' }), cancel: page.getByRole('button', { name: 'Cancel' }).first(), buttons: [page.getByRole('button', { name: 'Approve & send' }), page.getByRole('button', { name: 'Cancel' }).first()], to: page.getByText(/To nobody/) });
    await ctx.close();
  },
  // ---- Book a delivery in ----
  async goodsin(browser) {
    const { page, ctx } = await newPage(browser, { role: 'warehouse', dsf: 2, focusDefault: false });
    await signIn(page); await goto(page, '#/goods-in'); await page.waitForTimeout(600);
    await snap(page, 'gi-start', { picker: page.locator('select').first(), heading: page.getByRole('heading', { name: 'Goods in' }) });
    await page.locator('select').first().selectOption({ index: 1 }); await page.waitForTimeout(800);
    await snap(page, 'gi-form', { picker: page.locator('select').first(), card: page.locator('.panel', { hasText: 'AF-PO-1002' }).first(), lines: page.locator('table').first(),
      more: page.getByText('Yes, more to come').first(), moreAll: { all: page.getByText('Yes, more to come') }, fields: [page.getByText('Supplier delivery note / ref'), page.getByText('Received by')],
      notes: [page.getByText('Photos of the delivery or problem'), page.getByText('Notes', { exact: true })], book: page.getByRole('button', { name: 'Book in delivery' }), summary: page.getByText(/Booking in/).locator('xpath=..') });
    await ctx.close();
  },
  // ---- Artwork, proofs and job packs ----
  async artwork(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: false });
    await signIn(page); await goto(page, '#/artwork'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(600);
    await snap(page, 'aw-list', { table: page.locator('.dt').first(), chips: page.locator('.dt .chip').first().locator('xpath=..'), tabs: page.getByRole('tab', { name: /Customer proofs/ }).locator('xpath=..'), status: page.locator('.dt-row').first() });
    await goto(page, '#/artwork/700101'); const dlg = page.getByRole('dialog').first(); await dlg.waitFor(); await page.waitForTimeout(900);
    await snap(page, 'aw-drawer', { drawer: dlg, areas: dlg.getByRole('region', { name: 'Artwork areas' }), proofs: [dlg.getByText(/customer proofs/i).first(), dlg.getByText(/a proof is a picture/i)] });
    await dlg.getByText(/job packs/i).last().scrollIntoViewIfNeeded(); await page.waitForTimeout(500);
    await snap(page, 'aw-packs', { drawer: dlg, packs: [dlg.getByText(/job packs/i).last(), dlg.getByText(/JP-2026-/).first(), dlg.getByRole('button', { name: 'Mark as sent' }).last()] });
    await ctx.close();
  },
  // ---- Quality checks and rework ----
  async quality(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: false });
    await signIn(page); await goto(page, '#/quality'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(600);
    await snap(page, 'qa-list', { table: page.locator('.dt').first(), tabs: page.getByRole('tab', { name: /Checklist/ }).locator('xpath=..'), record: page.getByRole('button', { name: 'Record check' }).first(), row: page.locator('.dt-row').first() });
    await page.getByRole('button', { name: 'Record check' }).first().click(); await page.getByRole('dialog').waitFor(); await page.waitForTimeout(700);
    await snap(page, 'qa-record', { dialog: page.getByRole('dialog').first() });
    await page.keyboard.press('Escape'); await page.waitForTimeout(300);
    await page.getByRole('tab', { name: /Checklist/ }).click(); await page.waitForTimeout(600);
    await snap(page, 'qa-checklist', { panel: page.locator('.panel', { hasText: 'What gets checked' }).first(), notice: page.locator('.callout', { hasText: 'Not confirmed yet' }).first(), items: page.locator('.panel', { hasText: 'What gets checked' }).first() });
    await page.getByRole('tab', { name: /Rework/ }).click(); await page.waitForTimeout(600);
    await snap(page, 'qa-rework', { table: page.locator('.dt').first(), row: page.locator('.dt-row').first(), tabs: page.getByRole('tab', { name: /Checklist/ }).locator('xpath=..') });
    await ctx.close();
  },
  // ---- Dispatch and courier labels ----
  async dispatch(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: false });
    await signIn(page); await goto(page, '#/dispatch'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(600);
    await snap(page, 'dp-list', { kpis: page.locator('.kpi').first().locator('xpath=..'), table: page.locator('.dt').first(), handover: page.getByRole('button', { name: 'Hand over (scan)' }), heading: page.locator('.page-head').first() });
    await page.locator('.dt-row', { hasText: '#700101' }).click(); const dlg = page.getByRole('dialog').first(); await dlg.waitFor(); await page.waitForTimeout(800);
    await snap(page, 'dp-pack', { drawer: dlg, form: [dlg.getByText(/pack and make labels/i).first(), dlg.getByRole('button', { name: 'Pack and make labels' })], button: dlg.getByRole('button', { name: 'Pack and make labels' }), deliver: dlg.getByText(/deliver to/i).first() });
    await page.keyboard.press('Escape'); await page.waitForTimeout(300);
    await page.locator('.dt .chip', { hasText: 'Blocked' }).click(); await page.locator('.dt-row', { hasText: '#700103' }).click(); await dlg.waitFor(); await page.waitForTimeout(800);
    await snap(page, 'dp-blocked', { drawer: dlg, why: dlg.locator('.callout', { hasText: 'Not ready to go out' }).first() });
    await page.keyboard.press('Escape'); await page.waitForTimeout(300);
    await page.locator('.dt .chip', { hasText: 'With courier' }).click(); await page.waitForTimeout(600);
    await snap(page, 'dp-courier', { chips: page.locator('.dt .chip').first().locator('xpath=..'), table: page.locator('.dt').first(), handover: page.getByRole('button', { name: 'Hand over (scan)' }), heading: page.locator('.page-head').first() });
    await ctx.close();
  },
  // ---- Exceptions ----
  async exceptions(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: false });
    await signIn(page); await goto(page, '#/exceptions'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(700);
    await snap(page, 'ex-list', { kpis: { all: page.locator('.kpi') }, need: page.locator('.panel', { hasText: 'Needs a person' }).first(), raise: page.getByRole('button', { name: 'Raise an issue' }), check: page.getByRole('button', { name: 'Check now' }), heading: page.locator('.page-head').first() });
    await page.locator('.dt-row').first().click(); const dlg = page.getByRole('dialog').first(); await dlg.waitFor(); await page.waitForTimeout(800);
    await snap(page, 'ex-drawer', { drawer: dlg, recommended: dlg.locator('.callout', { hasText: 'Recommended action' }).first(), impact: dlg.locator('.callout', { hasText: 'Customer impact' }).first(),
      actions: [dlg.getByRole('button', { name: /Take it/ }), dlg.getByRole('button', { name: 'Write off' })], history: dlg.getByText('History', { exact: true }) });
    await page.keyboard.press('Escape'); await page.waitForTimeout(300);
    await page.getByRole('button', { name: 'Raise an issue' }).click(); await page.getByRole('dialog').waitFor(); await page.waitForTimeout(700);
    await snap(page, 'ex-raise', { dialog: page.getByRole('dialog').first() });
    await ctx.close();
  },
  // ---- The holding pen ----
  async pen(browser) {
    const { page, ctx } = await newPage(browser, { role: 'manager', dsf: 2, focusDefault: false, views: { ui_pen: F.pen, ui_pen_log: F.penLog } });
    await signIn(page); await goto(page, '#/pen'); await page.waitForSelector('.dt-row'); await page.waitForTimeout(700);
    await snap(page, 'pn-list', { explain: page.getByText(/An order goes into the pen/).locator('xpath=..'), table: page.locator('.dt').first(), chips: page.locator('.dt .chip').first().locator('xpath=..'), wrong: page.locator('.dt-row').first(), activity: page.locator('.panel', { hasText: 'Recent activity' }).first() });
    await page.locator('.dt-row').first().click(); const dlg = page.getByRole('dialog').first(); await dlg.waitFor(); await page.waitForTimeout(800);
    await snap(page, 'pn-case', { drawer: dlg, why: [dlg.getByText(/why it is held/i), dlg.locator('.callout').first()], history: dlg.getByText('History', { exact: true }), open: dlg.getByRole('button', { name: 'Open the order' }), readonly: dlg.getByText(/not available on this screen/) });
    await ctx.close();
  },
};

const server = spawn('npx', ['vite', 'preview', '--port', String(PORT), '--strictPort'], { cwd: path.join(ROOT, 'apps', 'dashboard'), stdio: 'ignore' });
await new Promise((r) => setTimeout(r, 2500));
const browser = await chromium.launch();
let failed = 0;
try {
  for (const [name, run] of Object.entries(SCENES)) {
    if (only.length && !only.includes(name)) continue;
    console.log(name);
    try { await run(browser); } catch (e) { failed++; console.log(`  ✗ ${name} failed: ${String(e.message).split('\n')[0]}`); }
  }
} finally {
  writeFileSync(MANIFEST, JSON.stringify(manifest, null, 1) + '\n');
  await browser.close(); server.kill();
}
process.exit(failed ? 1 : 0);
