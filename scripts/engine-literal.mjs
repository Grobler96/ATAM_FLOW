// Prints an engine from packages/engine as a JSON string literal for the matching n8n Code node
// (comments kept except trailing ones, module.exports line removed, n8n glue appended).
// Usage: node scripts/engine-literal.mjs scheduler | allocator | selector
// Keep the n8n copy in sync whenever an engine changes (a Code node cannot import repo files).
import { readFileSync } from 'node:fs';
const which = process.argv[2] || 'scheduler';
const glue = {
  scheduler: ['scheduler.js', 'const plan = buildPlan($input.first().json);\nreturn [{ json: plan }];\n'],
  allocator: ['allocator.js', 'const plan = buildAllocationPlan($input.first().json);\nreturn [{ json: plan }];\n'],
  selector: ['selector.js', "const input = $input.first().json;\nconst req = $('Dashboard: selection').first().json.body || {};\nif (req.params && req.params.overrides) input.overrides = req.params.overrides;\nreturn [{ json: buildSelection(input) }];\n"]
}[which];
if (!glue) { console.error('unknown engine'); process.exit(1); }
const src = readFileSync(new URL('../packages/engine/' + glue[0], import.meta.url), 'utf8')
  .split('\n').filter((l) => !/^\s*\/\/ /.test(l) || /ATAM_FLOW/.test(l))
  .filter((l) => !l.startsWith('if (typeof module')).join('\n');
process.stdout.write(JSON.stringify(src + '\n\n' + glue[1]));
