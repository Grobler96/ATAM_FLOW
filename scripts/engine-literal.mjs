// Prints packages/engine/scheduler.js (comments kept, module.exports line removed, n8n glue appended) as a JSON string literal,
// ready to paste into the "Plan production (engine)" Code node. Keep the n8n copy in sync whenever the engine changes.
import { readFileSync } from 'node:fs';
const src = readFileSync(new URL('../packages/engine/scheduler.js', import.meta.url), 'utf8')
  .split('\n').filter((l) => !/^\s*\/\/ /.test(l) || /ATAM_FLOW/.test(l))
  .filter((l) => !l.startsWith('if (typeof module')).join('\n');
process.stdout.write(JSON.stringify(src + '\n\nconst plan = buildPlan($input.first().json);\nreturn [{ json: plan }];\n'));
