// Fails if an exported n8n workflow in n8n/workflows/ contains something that looks like a secret.
// n8n exports hold credential references (id + name), not values, but parameters can still hold pasted keys or passwords.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = fileURLToPath(new URL('../n8n/workflows/', import.meta.url));
const SUSPECT_KEY = /pass(word)?|secret|api[-_]?key|token|authorization|bearer/i;
const PATTERNS = [
  [/eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}/, 'JWT'],
  [/sb_secret_[A-Za-z0-9_-]+/, 'Supabase secret key'],
  [/Bearer\s+[A-Za-z0-9._-]{20,}/, 'hard-coded bearer token']
];

const findings = [];
function walk(node, path, file) {
  if (Array.isArray(node)) return node.forEach((v, i) => walk(v, `${path}[${i}]`, file));
  if (node && typeof node === 'object') {
    for (const [k, v] of Object.entries(node)) {
      if (typeof v === 'string' && SUSPECT_KEY.test(k) && v.length >= 8 && !v.startsWith('=') && !v.includes('{{')) findings.push(`${file}: ${path}.${k} holds a literal value`);
      walk(v, `${path}.${k}`, file);
    }
  }
}

const files = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith('.json')) : [];
for (const f of files) {
  const raw = readFileSync(join(dir, f), 'utf8');
  for (const [re, label] of PATTERNS) if (re.test(raw)) findings.push(`${f}: contains a ${label}`);
  try { walk(JSON.parse(raw), '$', f); } catch { findings.push(`${f}: not valid JSON`); }
}

if (findings.length) {
  console.error('Possible secrets in n8n exports:\n - ' + findings.join('\n - '));
  process.exit(1);
}
console.log(`n8n export check passed (${files.length} workflow file(s) scanned).`);
