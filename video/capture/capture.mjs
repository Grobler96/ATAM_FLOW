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

const manifest = existsSync(MANIFEST) ? JSON.parse(readFileSync(MANIFEST, 'utf8')) : {};
const only = process.argv.slice(2);

async function snap(page, id, rects = {}) {
  await settle(page, true);
  const vp = page.viewportSize();
  const entry = { file: `shots/${id}.png`, rects: {} };
  for (const [name, loc] of Object.entries(rects)) {
    const box = await loc.first().boundingBox().catch(() => null);
    if (!box) { console.log(`  ! ${id}: no element for "${name}"`); continue; }
    entry.rects[name] = { x: +(box.x / vp.width).toFixed(4), y: +(box.y / vp.height).toFixed(4), w: +(box.width / vp.width).toFixed(4), h: +(box.height / vp.height).toFixed(4) };
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
