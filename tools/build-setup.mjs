// Builds supabase/setup_all.sql: every migration in order, in one file that is safe to run twice,
// ending with a check of how many tables exist and how many have Row Level Security on.
// Usage: node tools/build-setup.mjs
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dir = join(root, 'supabase', 'migrations');
const files = readdirSync(dir).filter(f => f.endsWith('.sql')).sort();

let out = `-- =====================================================================
-- First Choice Laptops, Stock Manager: complete database setup
-- Generated from supabase/migrations by tools/build-setup.mjs. Do not edit by hand.
--
-- Paste the whole file into the Supabase SQL Editor on a new project and click Run.
-- It is safe to run again: every step checks first.
-- The last result shows how many tables were made and how many have access rules on.
-- =====================================================================

`;
for (const f of files) {
  out += `\n-- ---------------------------------------------------------------------\n-- ${f}\n-- ---------------------------------------------------------------------\n`;
  out += readFileSync(join(dir, f), 'utf8').replace(/\r\n/g, '\n').trimEnd() + '\n';
}
out += `
-- ---------------------------------------------------------------------
-- Check: both numbers must be the same (every table has its access rules on)
-- ---------------------------------------------------------------------
select count(*) as tables, count(*) filter (where c.relrowsecurity) as tables_with_rls_on
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r';
`;
writeFileSync(join(root, 'supabase', 'setup_all.sql'), out);
console.log(`wrote supabase/setup_all.sql from ${files.length} files (${Math.round(out.length / 1024)} KB)`);
