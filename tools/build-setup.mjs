// Builds supabase/setup_all.sql: every migration in order, in one file that is safe to run twice,
// ending with a check of how many tables exist and how many have Row Level Security on.
// Also writes setup_part1.sql and setup_part2.sql: the same SQL in two halves, for when the
// Supabase SQL Editor refuses one big query.
// Usage: node tools/build-setup.mjs
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dir = join(root, 'supabase', 'migrations');
const files = readdirSync(dir).filter(f => f.endsWith('.sql')).sort();
const NL = '\n';

let body = '';
for (const f of files) {
  body += `${NL}-- ---------------------------------------------------------------------${NL}-- ${f}${NL}-- ---------------------------------------------------------------------${NL}`;
  body += readFileSync(join(dir, f), 'utf8').replace(/\r\n/g, NL).trimEnd() + NL;
}
const check = `
-- ---------------------------------------------------------------------
-- Check: both numbers must be the same (every table has its access rules on)
-- ---------------------------------------------------------------------
select count(*) as tables, count(*) filter (where c.relrowsecurity) as tables_with_rls_on
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r';
`;

const out = `-- =====================================================================
-- First Choice Laptops, Stock Manager: complete database setup
-- Generated from supabase/migrations by tools/build-setup.mjs. Do not edit by hand.
--
-- Paste the whole file into the Supabase SQL Editor on a new project and click Run.
-- It is safe to run again: every step checks first.
-- The last result shows how many tables were made and how many have access rules on.
-- If the SQL Editor says the query is too big, run setup_part1.sql and then setup_part2.sql instead.
-- =====================================================================

${body}${check}`;
writeFileSync(join(root, 'supabase', 'setup_all.sql'), out);

// Two halves, split at a statement boundary inside 0004_rpc.sql (between two functions).
const SPLIT = NL + 'create or replace function public.add_sale_payment(';
const cut = body.indexOf(SPLIT);
if (cut < 0 || body.indexOf(SPLIT, cut + 1) >= 0) throw new Error('split point not found exactly once');
const head = (n, extra) => `-- =====================================================================
-- First Choice Laptops, Stock Manager: database setup, PART ${n} OF 2
-- Generated from supabase/migrations by tools/build-setup.mjs. Do not edit by hand.
-- The same SQL as setup_all.sql, split in two because the SQL Editor may refuse one big query.
-- Run part 1 first, then part 2 in a new query. Both are safe to run again.
${extra}-- =====================================================================
`;
const part1 = head(1, '') + body.slice(0, cut + 1) + `${NL}-- End of part 1. Now run setup_part2.sql in a new query.${NL}`;
const part2 = head(2, `-- The last result shows how many tables were made and how many have access rules on.${NL}`)
  + `${NL}-- 0004_rpc.sql (continued)${NL}` + body.slice(cut + 1) + check;
writeFileSync(join(root, 'supabase', 'setup_part1.sql'), part1);
writeFileSync(join(root, 'supabase', 'setup_part2.sql'), part2);
console.log(`wrote supabase/setup_all.sql (${Math.round(out.length / 1024)} KB), setup_part1.sql (${Math.round(part1.length / 1024)} KB) and setup_part2.sql (${Math.round(part2.length / 1024)} KB) from ${files.length} files`);
