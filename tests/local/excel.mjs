// Checks the one-time Excel import end to end on a throwaway local database.
// Needs docs/AUK_Laptop_Business_Manager.xlsx (kept out of git). Usage: node excel.mjs
import { PGlite } from '@electric-sql/pglite';
import { createRequire } from 'node:module';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readWorkbook, defaultAnswers, buildPlan, parseSpecs } from '../../lib/excel-plan.js';

const here = dirname(fileURLToPath(import.meta.url)), root = join(here, '..', '..');
const XLSX = createRequire(import.meta.url)(join(root, 'lib', 'xlsx.full.min.js'));
const file = join(root, 'docs', 'AUK_Laptop_Business_Manager.xlsx');
if (!existsSync(file)) { console.log('SKIP: the Excel file is not on this computer'); process.exit(0); }

let pass = 0, fail = 0;
const ok = (c, n, x = '') => { if (c) { pass++; console.log('  PASS', n); } else { fail++; console.log('  FAIL', n, x); } };
const eq = (a, b, n) => ok(String(a) === String(b), n, `(got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`);

console.log('Parsing');
eq(JSON.stringify(parseSpecs('lenovo i5 7th 8/N')), JSON.stringify({ brand: 'Lenovo', brand_other: '', model: '', processor: 'i5', processor_other: '', gen: 7, ram_gb: 8, storage_type: null, storage_gb: null }), '"lenovo i5 7th 8/N"');
eq(parseSpecs('ascer i5 3ed 8/128').brand + ' ' + parseSpecs('ascer i5 3ed 8/128').gen, 'Acer 3', '"ascer i5 3ed" → Acer, 3rd gen');
eq(parseSpecs('HP pentinum 360').processor + ' ' + parseSpecs('HP pentinum 360').model, 'Pentium 360', '"HP pentinum 360" → Pentium, model 360');
eq(parseSpecs('dell i3 6th 4/500 hdd').storage_type, 'HDD', '"4/500 hdd" → HDD');
eq(parseSpecs('t430 ').brand + ' ' + parseSpecs('t430 ').model, 'Lenovo T430', '"t430" → Lenovo T430');

const wb = XLSX.read(readFileSync(file));
const raw = readWorkbook(wb, XLSX);
const ans = defaultAnswers(raw);
const P = buildPlan(raw, ans);
console.log('\nPreview totals', JSON.stringify(P.totals));
console.log('Flags:\n - ' + P.flags.map(f => f.text).join('\n - '));
console.log('Assumptions:\n - ' + P.assumptions.join('\n - '));
console.log('Customers:', Object.entries(P.customers).map(([k, v]) => `${k} → ${v.lead}/${v.type}/${v.name || '(no name)'}`).join('; '));
eq(P.totals.lots, 5, '5 lots'); eq(P.totals.lines, 10, '10 lines'); eq(P.totals.laptops, 183, '183 laptops');
eq(P.totals.cost, 374000, 'lot cost ₹3,74,000 (lot 10 = ₹28,000, line totals)'); eq(P.totals.cost_missing, 50, '50 laptops with cost missing (lot 786)');
eq(P.totals.sales, 45, '45 laptops sold'); eq(P.totals.sales_total, 497400, 'sales ₹4,97,400 = Dashboard');
eq(P.totals.sales_by_month['2026-09'], 267500, 'September ₹2,67,500 = Dashboard'); eq(P.totals.sales_by_month['2026-10'], 229900, 'October ₹2,29,900 = Dashboard');
eq(P.totals.expenses_total, 60900, 'expenses ₹60,900 (not the Excel\'s ₹69)');
eq(ans.lotDates['10'], '2026-09-01', 'lot 10 dated 1 Sep 2026'); eq(ans.lotDates['13'], '2026-10-09', 'lot 13 dated 9 Oct 2026');
ok(P.flags.some(f => f.kind === 'wc') && P.flags.filter(f => f.kind === 'wc').length === 3, '3 sales flagged from the "wc" tab, with a lot 12 / 13 choice');
ok(P.flags.some(f => f.kind === 'dup'), 'possible duplicate on 19 Oct flagged');
ok(!P.flags.some(f => f.kind === 'error'), 'no errors in the plan', JSON.stringify(P.flags.filter(f => f.kind === 'error')));

console.log('\nImport into a fresh local database');
const db = new PGlite();
await db.exec(readFileSync(join(here, 'supabase_stub.sql'), 'utf8'));
for (const f of readdirSync(join(root, 'supabase', 'migrations')).filter(f => f.endsWith('.sql')).sort()) await db.exec(readFileSync(join(root, 'supabase', 'migrations', f), 'utf8'));
const A = { id: '00000000-0000-0000-0000-00000000000a', sess: '10000000-0000-0000-0000-00000000000a' };
await db.query(`insert into auth.users (id, email) values ($1, 'a')`, [A.id]);
await db.query(`select public.bootstrap_first_admin($1, 'Ayan', '9900000001')`, [A.id]);
await db.query(`insert into public.app_sessions (session_id, user_id) values ($1, $2)`, [A.sess, A.id]);
await db.exec(`set role authenticated; select set_config('request.jwt.claims', '${JSON.stringify({ sub: A.id, session_id: A.sess })}', false);`);
const r = (await db.query(`select public.import_excel($1::jsonb) r`, [JSON.stringify(P.plan)])).rows[0].r;
console.log('Imported', JSON.stringify(r));
eq(r.laptops, 183, '183 laptops created'); eq(r.sales, 45, '45 sales'); eq(r.sales_total, 497400, 'sales ₹4,97,400'); eq(r.expenses_total, 60900, 'expenses ₹60,900');
const rep = (await db.query(`select public.report_year(2026) r`)).rows[0].r;
eq(rep.months[8].sales, 267500, 'report: September ₹2,67,500'); eq(rep.months[9].sales, 229900, 'report: October ₹2,29,900');
const lots = (await db.query(`select prefix, note, kind from public.lots where kind <> 'exchange' order by prefix`)).rows;
console.log('Lots:', lots.map(l => `${l.prefix} (${l.kind}; ${l.note})`).join(', '));
ok(lots.some(l => l.prefix.startsWith('01-10-09-26') && /Excel lot 10/.test(l.note)), 'lot 10 keeps its number: 01-10-09-26');
ok(lots.some(l => /Excel lot 786/.test(l.note) && l.kind === 'opening'), 'lot 786 is opening stock with its Excel number in the note');
const e450 = (await db.query(`select count(*) n from public.laptops l join public.sales s on s.laptop_id = l.id and s.status = 'active' where l.model = 'E450'`)).rows[0].n;
eq(e450, 3, 'the 3 E450 sales went to the 3 E450 laptops of lot 10');
const filled = (await db.query(`select count(*) n from public.laptops l join public.lot_lines ln on ln.id = l.line_id where ln.is_mixed and l.status = 'sold' and l.processor is not null`)).rows[0].n;
ok(filled > 20, `sold laptops from Mixed lots got their specs from the sale text (${filled})`);
ok((await db.query(`select count(*) n from public.activity_log where action = 'import'`)).rows[0].n == 1, 'one summary line in Activity');
let again = null; try { await db.query(`select public.import_excel($1::jsonb)`, [JSON.stringify(P.plan)]); } catch (e) { again = e.message; }
ok(again && /only once/.test(again), 'a second import is refused');
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
