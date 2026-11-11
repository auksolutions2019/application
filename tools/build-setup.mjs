// Builds supabase/setup_all.sql: every migration in order, in one file that is safe to run twice,
// ending with a check of how many tables exist and how many have Row Level Security on.
// Also writes setup_part1.sql, setup_part2.sql and setup_part3.sql: the same SQL in parts, for when the
// Supabase SQL Editor refuses one big query.
// Usage: node tools/build-setup.mjs
import { readFileSync, readdirSync, writeFileSync, unlinkSync } from 'node:fs';
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
-- If the SQL Editor says the query is too big, run setup_part1.sql, setup_part2.sql and setup_part3.sql instead.
-- =====================================================================

${body}${check}`;
writeFileSync(join(root, 'supabase', 'setup_all.sql'), out);

// The same SQL in parts, for when the SQL Editor refuses one big query. Each split is at a statement
// boundary: inside 0004_rpc.sql (between two functions) and at the start of 0007_backup_import.sql.
const SPLITS = [NL + 'create or replace function public.add_sale_payment(', NL + '-- ---------------------------------------------------------------------' + NL + '-- 0007_backup_import.sql'];
const cuts = SPLITS.map(m => { const i = body.indexOf(m); if (i < 0 || body.indexOf(m, i + 1) >= 0) throw new Error('split point not found exactly once: ' + m.trim().slice(0, 50)); return i + 1; });
const N = cuts.length + 1, bounds = [0, ...cuts, body.length];
const head = (n, extra) => `-- =====================================================================
-- First Choice Laptops, Stock Manager: database setup, PART ${n} OF ${N}
-- Generated from supabase/migrations by tools/build-setup.mjs. Do not edit by hand.
-- The same SQL as setup_all.sql, split because the SQL Editor may refuse one big query.
-- Run the parts in order (1, 2, 3), each in a new query. All are safe to run again.
${extra}-- =====================================================================
`;
const sizes = [];
for (let n = 1; n <= N; n++) {
  const last = n === N, chunk = body.slice(bounds[n - 1], bounds[n]);
  const txt = head(n, last ? `-- The last result shows how many tables were made and how many have access rules on.${NL}` : '')
    + (n > 1 ? NL : '') + chunk + (last ? check : `${NL}-- End of part ${n}. Now run setup_part${n + 1}.sql in a new query.${NL}`);
  writeFileSync(join(root, 'supabase', `setup_part${n}.sql`), txt); sizes.push(Math.round(txt.length / 1024));
}
for (const f of readdirSync(join(root, 'supabase'))) {   // remove parts left over from an older split
  const m = f.match(/^setup_part(\d+)\.sql$/); if (m && +m[1] > N) unlinkSync(join(root, 'supabase', f));
}
console.log(`wrote supabase/setup_all.sql (${Math.round(out.length / 1024)} KB) and ${N} parts (${sizes.map(k => k + ' KB').join(', ')}) from ${files.length} files`);
