// Runs all migrations on a throwaway local Postgres (PGlite) and checks the required tests.
// Usage:  cd tests/local && npm install && node run.mjs
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

process.on('uncaughtException', e => {
  console.error(`\nCRASH: ${e.message}${e.query ? `\n  in: ${e.query}` : ''}${e.where ? `\n  at: ${e.where}` : ''}`);
  process.exit(1);
});
const here = dirname(fileURLToPath(import.meta.url));
const migDir = join(here, '..', '..', 'supabase', 'migrations');
const db = new PGlite();

let pass = 0, fail = 0;
const ok = (cond, name, extra = '') => {
  if (cond) { pass++; console.log('  PASS', name); }
  else { fail++; console.log('  FAIL', name, extra); }
};
const eq = (a, b, name) => ok(String(a) === String(b), name, `(got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`);

// ---------- setup ----------
await db.exec(readFileSync(join(here, 'supabase_stub.sql'), 'utf8'));
for (const f of readdirSync(migDir).filter(f => f.endsWith('.sql')).sort()) {
  try { await db.exec(readFileSync(join(migDir, f), 'utf8')); }
  catch (e) { console.error(`Migration ${f} failed: ${e.message}`); process.exit(1); }
  console.log('migrated', f);
}

const U = {
  admin:   { id: '00000000-0000-0000-0000-00000000000a', sess: '10000000-0000-0000-0000-00000000000a', name: 'Ayan',   mobile: '9900000001', role: 'admin' },
  coadmin: { id: '00000000-0000-0000-0000-00000000000b', sess: '10000000-0000-0000-0000-00000000000b', name: 'Raheem', mobile: '9900000002', role: 'coadmin' },
  staff:   { id: '00000000-0000-0000-0000-00000000000c', sess: '10000000-0000-0000-0000-00000000000c', name: 'Worker', mobile: '9900000003', role: 'staff' },
};
await db.query(`insert into auth.users (id, email) values ($1,'a'),($2,'b'),($3,'c')`, [U.admin.id, U.coadmin.id, U.staff.id]);
eq((await db.query(`select public.bootstrap_first_admin($1, 'Ayan', '9900000001') r`, [U.admin.id])).rows[0].r.startsWith('Admin Ayan'), true, 'bootstrap_first_admin creates Ayan as admin');
await db.query(`insert into public.profiles (id, name, mobile, role) values ($1,'Raheem','9900000002','coadmin'),($2,'Worker','9900000003','staff')`, [U.coadmin.id, U.staff.id]);
for (const u of Object.values(U)) await db.query(`insert into public.app_sessions (session_id, user_id) values ($1, $2)`, [u.sess, u.id]);

// Run SQL as a logged-in user (role authenticated + JWT claims), like PostgREST does.
async function as(user, sql, params = []) {
  await db.exec(`set role authenticated; select set_config('request.jwt.claims', '${JSON.stringify({ sub: user.id, session_id: user.sess, role: 'authenticated' })}', false);`);
  try { return await db.query(sql, params); }
  finally { await db.exec(`reset role; select set_config('request.jwt.claims', '', false);`); }
}
// Call an RPC with named arguments.
async function rpc(user, fn, args = {}) {
  const keys = Object.keys(args);
  const sql = `select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`;
  const vals = keys.map(k => (args[k] !== null && typeof args[k] === 'object' && !Array.isArray(args[k])) ? JSON.stringify(args[k])
                          : Array.isArray(args[k]) ? (typeof args[k][0] === 'object' ? JSON.stringify(args[k]) : `{${args[k].join(',')}}`) : args[k]);
  return (await as(user, sql, vals)).rows[0].r;
}
async function rpcErr(user, fn, args) {
  try { await rpc(user, fn, args); return null; } catch (e) { return e; }
}
const one = async (sql, p = []) => (await db.query(sql, p)).rows[0];
const today = (await one(`select private.today()::text d`)).d;
const MM = today.slice(5, 7), YY = today.slice(2, 4);
const lap = async code => one(`select * from public.laptops where code = $1`, [code]);
const passAll = async (user, id) => rpc(user, 'set_all_tests', { p_laptop_id: id });
const inStock = async () => +(await one(`select count(*) n from public.laptops where status = 'in_stock'`)).n;

// ---------- Test 1: lot ----------
console.log('\nTest 1: lot of 20 for ₹3,00,000');
const sup = await rpc(U.admin, 'add_supplier', { p_name: 'Ali Traders', p_phone: '98450 11223' });
eq(sup.code, '01', 'first supplier gets code 01');
const lot1 = await rpc(U.admin, 'create_lot', { p_supplier_id: sup.id, p_lot_no: 1, p_bought_on: today,
  p_lines: [{ brand: 'Dell', model: 'Latitude 5490', processor: 'i5', gen: 8, ram_gb: 8, storage_type: 'SSD', storage_gb: 256, qty: 20, cost: 300000 }] });
eq(lot1.codes[0], `01-01-${MM}-${YY}-001`, 'first sticker');
eq(lot1.codes[19], `01-01-${MM}-${YY}-020`, 'last sticker');
eq(lot1.codes.length, 20, '20 stickers');
const c1 = await one(`select min(cost) mn, max(cost) mx, sum(cost) s from public.laptop_costs c join public.laptops l on l.id = c.laptop_id where l.lot_id = $1`, [lot1.lot_id]);
ok(+c1.mn === 15000 && +c1.mx === 15000 && +c1.s === 300000, 'each laptop costs ₹15,000');
eq((await lap(lot1.codes[0])).shorthand, 'Dell i5 8th 8/256', 'shorthand "Dell i5 8th 8/256"');
const dup = await rpcErr(U.admin, 'create_lot', { p_supplier_id: sup.id, p_lot_no: 1, p_bought_on: today, p_lines: [{ qty: 1, is_mixed: true }] });
ok(dup && /already exists/.test(dup.message), 'same lot number refused');

// ---------- Test 2: tests rule ----------
console.log('\nTest 2: tests must pass');
const L2 = await lap(lot1.codes[1]);
await rpc(U.coadmin, 'set_test', { p_laptop_id: L2.id, p_test: 'Battery', p_result: 'fail' });
const sale2 = { p_laptop_id: L2.id, p_price: 25000, p_lead_source: 'OLX', p_name: 'Test', p_mobile: '9800000002', p_paid: 25000, p_method: 'Cash' };
const e2a = await rpcErr(U.coadmin, 'sell_laptop', sale2);
ok(e2a && /All tests must pass/.test(e2a.message), 'co-admin cannot sell with a failed test', e2a?.message);
const e2s = await rpcErr(U.staff, 'sell_laptop', { ...sale2, p_override_tests: true });
ok(e2s && /All tests must pass/.test(e2s.message), 'staff cannot override the tests rule');
const e2b = await rpcErr(U.admin, 'sell_laptop', sale2);
ok(e2b && /Sell anyway/.test(e2b.message), 'admin is asked to confirm first', e2b?.message);
const s2 = await rpc(U.admin, 'sell_laptop', { ...sale2, p_override_tests: true });
eq(s2.balance, 0, 'admin can sell after confirming');

// ---------- Test 3: sale with balance ----------
console.log('\nTest 3: ₹29,500 with ₹15,000 paid');
const L3 = await lap(lot1.codes[2]);
await passAll(U.coadmin, L3.id);
const before3 = await inStock();
const s3 = await rpc(U.coadmin, 'sell_laptop', { p_laptop_id: L3.id, p_price: 29500, p_paid: 15000, p_method: 'Cash',
  p_lead_source: 'Instagram', p_name: 'Mohammed Irfan', p_mobile: '+91 98000 00003', p_warranty_months: 6 });
eq(s3.balance, 14500, 'balance ₹14,500');
eq(await inStock(), before3 - 1, 'stock goes down by 1');
const p3 = await rpc(U.coadmin, 'add_sale_payment', { p_sale_id: s3.sale_id, p_amount: 5000, p_method: 'UPI', p_ref: 'UTR123' });
eq(p3.balance, 9500, 'after ₹5,000 UPI the balance is ₹9,500');
const pays3 = (await rpc(U.coadmin, 'get_laptop', { p_code: L3.code })).sale.payments;
ok(pays3.length === 2 && pays3[1].method === 'UPI' && pays3[1].ref === 'UTR123', 'both payments listed, with method and ref');
const e3 = await rpcErr(U.coadmin, 'add_sale_payment', { p_sale_id: s3.sale_id, p_amount: 9501, p_method: 'Cash' });
ok(e3 && /more than the balance/.test(e3.message), 'cannot pay more than the balance');
const e3s = await rpcErr(U.staff, 'add_sale_payment', { p_sale_id: s3.sale_id, p_amount: 100, p_method: 'Cash' });
ok(e3s, 'staff cannot record a later customer payment');
const e3d = await rpcErr(U.coadmin, 'sell_laptop', { p_laptop_id: L3.id, p_price: 1000, p_lead_source: 'OLX', p_paid: 1000, p_method: 'Cash' });
ok(e3d && /already sold/.test(e3d.message), 'a laptop can never be sold twice');

// ---------- Test 4: exchange ----------
console.log('\nTest 4: exchange');
const L4 = await lap(lot1.codes[3]);
await passAll(U.admin, L4.id);
const s4 = await rpc(U.coadmin, 'sell_laptop', { p_laptop_id: L4.id, p_price: 20000, p_paid: 10000, p_method: 'UPI',
  p_lead_source: 'Walk-in', p_name: 'Priya Nair', p_mobile: '9800000004', p_exchange_model: 'HP 15 i3 7th', p_exchange_value: 5000 });
eq(s4.balance, 5000, '₹20,000 − ₹5,000 exchange − ₹10,000 UPI leaves ₹5,000');
eq(s4.exchange_code, `00-01-${MM}-${YY}-001`, 'exchange laptop gets 00-01-MM-YY-001');
const X4 = await lap(s4.exchange_code);
eq(X4.status, 'in_stock', 'exchange laptop is in stock');
eq((await one(`select cost from public.laptop_costs where laptop_id = $1`, [X4.id])).cost, '5000.00', 'exchange laptop costs ₹5,000');

// ---------- Test 5: booking ----------
console.log('\nTest 5: booking');
const L5 = await lap(lot1.codes[4]);
await passAll(U.staff, L5.id);
const b5 = await rpc(U.staff, 'book_laptop', { p_laptop_id: L5.id, p_mobile: '9800000005', p_lead_source: 'OLX', p_name: 'Sana Khan', p_agreed_price: 18000, p_advance: 3000, p_method: 'UPI' });
eq((await lap(L5.code)).status, 'booked', 'laptop is booked');
const s5 = await rpc(U.staff, 'complete_booking', { p_booking_id: b5.booking_id, p_price: 18000, p_paid: 15000, p_method: 'Cash' });
eq(s5.balance, 0, 'advance + ₹15,000 clears ₹18,000');
const pays5 = (await rpc(U.admin, 'get_laptop', { p_code: L5.code })).sale.payments;
ok(pays5.length === 2 && +pays5[0].amount === 3000 && +pays5[1].amount === 15000, 'two payments on the sale (₹3,000 and ₹15,000)');
const m5 = await rpc(U.admin, 'money_day', { p_date: today });
eq(m5.ins.filter(x => /Sana Khan/.test(x.t)).reduce((s, x) => s + +x.amt, 0), 18000, 'advance counted once in Today\'s money');

// ---------- Test 6: return ----------
console.log('\nTest 6: return with ₹12,000 refund');
const L6 = await lap(lot1.codes[5]);
await passAll(U.admin, L6.id);
const s6 = await rpc(U.admin, 'sell_laptop', { p_laptop_id: L6.id, p_price: 15000, p_paid: 15000, p_method: 'Cash', p_lead_source: 'Octo', p_name: 'Ravi', p_mobile: '9800000006' });
const e6 = await rpcErr(U.coadmin, 'return_sale', { p_sale_id: s6.sale_id, p_refund: 12000, p_method: 'Cash' });
ok(e6 && /Only the admin/.test(e6.message), 'co-admin cannot process a return');
await rpc(U.admin, 'return_sale', { p_sale_id: s6.sale_id, p_refund: 12000, p_method: 'Cash', p_note: 'screen issue' });
const m6 = await rpc(U.admin, 'money_day', { p_date: today });
ok(m6.outs.some(x => +x.amt === 12000 && /Refund to Ravi/.test(x.t)), '₹12,000 refund is money out in Today\'s money');
eq((await lap(L6.code)).status, 'in_stock', 'laptop is back in stock');
const r6 = await rpc(U.admin, 'get_laptop', { p_code: L6.code });
ok(r6.sale === null && r6.returns.length === 1 && +r6.returns[0].refund === 12000, 'old sale kept in history as returned');

// ---------- Test 7: profit and cost privacy ----------
console.log('\nTest 7: profit ₹8,150 and cost privacy');
const lot7 = await rpc(U.coadmin, 'create_lot', { p_supplier_id: sup.id, p_lot_no: 2, p_bought_on: today,
  p_lines: [{ brand: 'Lenovo', model: 'T480', processor: 'i5', gen: 8, ram_gb: 16, storage_type: 'SSD', storage_gb: 512, qty: 1, cost: 20000 }] });
const L7 = await lap(lot7.codes[0]);
await rpc(U.staff, 'add_repair', { p_laptop_id: L7.id, p_work: 'SSD changed', p_amount: 1000 });
await rpc(U.staff, 'add_repair', { p_laptop_id: L7.id, p_work: 'Battery', p_amount: 350 });
eq(await rpc(U.coadmin, 'safe_price', { p_laptop_id: L7.id }), 21350, 'co-admin gets only the floor price (₹21,350)');
ok(await rpcErr(U.staff, 'safe_price', { p_laptop_id: L7.id }), 'staff cannot get the floor price');
await passAll(U.coadmin, L7.id);
const eStaffLow = await rpcErr(U.staff, 'sell_laptop', { p_laptop_id: L7.id, p_price: 21000, p_paid: 21000, p_method: 'Cash', p_lead_source: 'OLX' });
ok(eStaffLow && /too low/.test(eStaffLow.message), 'staff price below the floor is refused');
const s7 = await rpc(U.coadmin, 'sell_laptop', { p_laptop_id: L7.id, p_price: 29500, p_paid: 29500, p_method: 'UPI', p_lead_source: 'Lead Matrix' });
eq((await rpc(U.admin, 'get_laptop', { p_code: L7.code })).sale.profit, 8150, 'admin sees profit ₹8,150');
for (const t of ['laptop_costs', 'lot_line_costs', 'supplier_payments', 'debts', 'shop_expenses'])
  eq((await as(U.coadmin, `select count(*) n from public.${t}`)).rows[0].n, 0, `co-admin reads 0 rows from ${t}`);
const snapC = JSON.stringify(await rpc(U.coadmin, 'get_snapshot'));
const leaked = snapC.match(/"(cost|full_cost|lot_share|profit|line_cost|bought|paid_to_supplier|gross|net|cost_missing)":/g);
ok(!leaked && /"stock_value":null/.test(snapC) && /"debts":\[\]/.test(snapC), 'co-admin snapshot has no cost or profit fields', leaked);
ok(!/"profit"|"cost"/.test(JSON.stringify(await rpc(U.coadmin, 'get_laptop', { p_code: L7.code }))), 'co-admin get_laptop has no cost or profit');
ok(!/"gross"|"net"/.test(JSON.stringify(await rpc(U.coadmin, 'report_year', { p_year: +today.slice(0, 4) }))), 'co-admin report has no profit');
ok(await rpcErr(U.coadmin, 'lot_pnl'), 'co-admin cannot open Lot P&L');
const snapS = await rpc(U.staff, 'get_snapshot');
ok(snapS.suppliers.length === 0 && snapS.activity.length === 0 && snapS.lots.every(l => l.supplier_name === null), 'staff snapshot hides suppliers and activity');
eq((await as(U.staff, `select count(*) n from public.suppliers`)).rows[0].n, 0, 'staff reads 0 suppliers');
ok(await rpcErr(U.staff, 'report_year', { p_year: 2026 }), 'staff cannot open reports');
ok(await rpcErr(U.staff, 'create_lot', { p_supplier_id: sup.id, p_lot_no: 9, p_bought_on: today, p_lines: [{ qty: 1, is_mixed: true }] }), 'staff cannot add lots');

// ---------- Test 8: sync signal ----------
console.log('\nTest 8: live sync signal');
const lastLog = await one(`select message, actor_name from public.activity_log where action = 'sale' order by id desc limit 1`);
ok(/Sold .* to Lead Matrix customer for ₹29,500/.test(lastLog.message) && lastLog.actor_name === 'Raheem', 'a sale writes an activity line with the person\'s name', lastLog.message);
eq((await as(U.coadmin, `select count(*) n from public.activity_log where action = 'sale'`)).rows[0].n > 0, true, 'co-admin can receive the sale line (Realtime uses the same rule)');
eq((await as(U.staff, `select count(*) n from public.activity_log`)).rows[0].n, 0, 'staff sees no activity');
eq((await as(U.coadmin, `select count(*) n from public.activity_log where admin_only`)).rows[0].n, 0, 'co-admin never sees admin-only lines');
console.log('  NOTE  delivery from phone A to phone B needs real Supabase Realtime; checked by hand in Phase 8');

// ---------- Test 9: scanner lookups ----------
console.log('\nTest 9: sticker lookups');
eq((await rpc(U.staff, 'get_laptop', { p_code: lot1.codes[0] })).code, lot1.codes[0], 'scanned code opens the right laptop');
eq((await rpc(U.staff, 'get_laptop', { p_code: lot1.codes[0].replace(/-/g, '') })).code, lot1.codes[0], 'typed 11 digits open it');
eq((await rpc(U.staff, 'get_laptop', { p_code: ' ' + lot1.codes[0].toLowerCase() + '\n' })).code, lot1.codes[0], 'pasted text with spaces opens it');
eq(await rpc(U.staff, 'get_laptop', { p_code: '99-99-99-99-999' }), null, 'unknown code returns nothing (app shows a message)');
ok((await rpc(U.staff, 'search_laptops', { p_q: '0101' })).length >= 20, 'partial digits list matches');

// ---------- extra checks ----------
console.log('\nExtra checks');
// lot expenses, fitted parts, no double counting
const lotM = await rpc(U.admin, 'create_lot', { p_supplier_id: sup.id, p_lot_no: 3, p_bought_on: today, p_kind: 'purchase',
  p_lines: [{ is_mixed: true, qty: 4, cost: 40000 }] });
const ex = await rpc(U.coadmin, 'add_lot_expense', { p_lot_id: lotM.lot_id, p_type: 'Charger', p_count: 4, p_amount: 1200, p_method: 'Cash' });
const LM = await lap(lotM.codes[0]);
const fit = await rpc(U.staff, 'add_repair', { p_laptop_id: LM.id, p_work: '', p_lot_expense_id: ex.lot_expense_id });
eq(fit.amount, 300, 'a fitted charger costs one unit (₹300)');
const shares = await one(`select sum(private.lot_share(id) + private.repairs_of(id)) s from public.laptops where lot_id = $1`, [lotM.lot_id]);
eq(+(+shares.s).toFixed(2), 1200, 'the lot expense is counted exactly once across the lot');
const lj = (await rpc(U.coadmin, 'get_snapshot')).lots.find(l => l.id === lotM.lot_id);
eq(lj.expenses[0].units_left, 3, 'units left: 3 of 4');
ok(await rpcErr(U.admin, 'delete_lot_expense', { p_id: ex.lot_expense_id }), 'cannot delete an expense with fitted parts');
// cost missing
const lotO = await rpc(U.admin, 'create_lot', { p_supplier_id: sup.id, p_lot_no: 4, p_bought_on: today, p_kind: 'opening', p_note: 'Excel lot 786',
  p_lines: [{ is_mixed: true, qty: 2 }] });
const snapA = await rpc(U.admin, 'get_snapshot');
eq(snapA.lots.find(l => l.id === lotO.lot_id).cost_missing, 2, 'opening lot shows 2 laptops with cost missing');
ok(snapA.stock_value.cost_missing >= 2, 'stock value counts laptops with cost missing');
const LO = await lap(lotO.codes[0]); await passAll(U.admin, LO.id);
const sO = await rpc(U.admin, 'sell_laptop', { p_laptop_id: LO.id, p_price: 9000, p_paid: 9000, p_method: 'UPI', p_lead_source: 'OLX' });
eq((await rpc(U.admin, 'get_laptop', { p_code: LO.code })).sale.profit, null, 'profit shows as missing, not a wrong number');
const lineO = snapA.lots.find(l => l.id === lotO.lot_id).lines[0].id;
await rpc(U.admin, 'set_line_cost', { p_line_id: lineO, p_cost: 13000 });
eq((await rpc(U.admin, 'get_laptop', { p_code: LO.code })).sale.profit, 2500, 'after the admin fills the cost, profit appears (₹9,000 − ₹6,500)');
// optional name and mobile
const L10 = await lap(lot1.codes[10]); await passAll(U.admin, L10.id);
const eW = await rpcErr(U.coadmin, 'sell_laptop', { p_laptop_id: L10.id, p_price: 10000, p_paid: 10000, p_method: 'UPI', p_lead_source: 'OLX', p_warranty_months: 3 });
ok(eW && /mobile number to give a warranty/.test(eW.message), 'warranty needs a mobile');
const eD = await rpcErr(U.coadmin, 'sell_laptop', { p_laptop_id: L10.id, p_price: 10000, p_paid: 4000, p_method: 'UPI', p_lead_source: 'OLX' });
ok(eD && /money is still due/.test(eD.message), 'a balance needs a mobile');
const eL = await rpcErr(U.coadmin, 'sell_laptop', { p_laptop_id: L10.id, p_price: 10000, p_paid: 10000, p_method: 'UPI' });
ok(eL && /came from/.test(eL.message), 'lead source is required');
await rpc(U.coadmin, 'sell_laptop', { p_laptop_id: L10.id, p_price: 10000, p_paid: 10000, p_method: 'UPI', p_lead_source: 'OLX' });
ok(true, 'paid-in-full sale with no name or mobile is allowed');
// bulk sale for a dealer
const ids = [];
for (const c of lot1.codes.slice(11, 14)) { const l = await lap(c); await passAll(U.admin, l.id); ids.push(l.id); }
const bk = await rpc(U.coadmin, 'sell_laptops_bulk', { p_laptop_ids: ids, p_price_each: 11000, p_total_paid: 25000, p_method: 'UPI', p_name: 'Shahid', p_mobile: '9800000011' });
eq(bk.balance, 8000, 'bulk sale of 3 at ₹11,000 with ₹25,000 paid leaves ₹8,000');
const bpaid = (await db.query(`select private.sale_paid(s.id) p from public.sales s where s.bulk_group = $1 order by array_position($2::uuid[], s.laptop_id)`, [bk.bulk_group, `{${ids.join(',')}}`])).rows.map(r => +r.p);
eq(bpaid.join(','), '11000,11000,3000', 'bulk payment shared in the order ticked');
const rc = await rpc(U.coadmin, 'receive_customer_payment', { p_mobile: '98000 00011', p_amount: 8000, p_method: 'Cash' });
eq(rc.balance, 0, 'customer payment clears the oldest balance');
// undo sale
const L15 = await lap(lot1.codes[15]); await passAll(U.admin, L15.id);
const s15 = await rpc(U.admin, 'sell_laptop', { p_laptop_id: L15.id, p_price: 10000, p_paid: 6000, p_method: 'Cash', p_lead_source: 'OLX', p_mobile: '9800000015' });
await rpc(U.admin, 'undo_sale', { p_sale_id: s15.sale_id, p_reason: 'wrong laptop' });
const u15 = await one(`select count(*) n, sum(amount) s from public.sale_payments where sale_id = $1`, [s15.sale_id]);
ok(+u15.n === 2 && +u15.s === 0, 'undo keeps the payment and adds a reversal');
eq((await lap(L15.code)).status, 'in_stock', 'undone laptop is back in stock');
// payments can't be edited or deleted
let blocked = false;
try { await db.query(`delete from public.sale_payments where sale_id = $1`, [s3.sale_id]); } catch (e) { blocked = /cannot be changed/.test(e.message); }
ok(blocked, 'payments cannot be deleted, even by the database owner');
const eUp = await (async () => { try { await as(U.coadmin, `update public.laptops set status = 'in_stock' where id = $1`, [L3.id]); return null; } catch (e) { return e; } })();
ok(eUp && /permission denied/.test(eUp.message), 'nobody can change a laptop status directly');
await as(U.staff, `update public.laptops set ram_gb = 16, notes = 'small scratch' where id = $1`, [L10.id]);
eq((await lap(L10.code)).shorthand, 'Dell i5 8th 16/256', 'staff can edit specs; shorthand updates');
// idempotency
const ref = '20000000-0000-0000-0000-000000000001';
await rpc(U.coadmin, 'add_sale_payment', { p_sale_id: s4.sale_id, p_amount: 1000, p_method: 'Cash', p_client_ref: ref });
const again = await rpc(U.coadmin, 'add_sale_payment', { p_sale_id: s4.sale_id, p_amount: 1000, p_method: 'Cash', p_client_ref: ref });
ok(again.repeat === true, 'a double-tapped save is not recorded twice');
eq((await one(`select count(*) n from public.sale_payments where sale_id = $1 and method = 'Cash'`, [s4.sale_id])).n, 1, 'only one ₹1,000 payment exists');
// shop expenses and Liabilities
await rpc(U.admin, 'add_debt', { p_name: 'Shop rent November', p_type: 'Shop rent', p_amount: 18000 });
const eR = await rpcErr(U.admin, 'add_shop_expense', { p_type: 'Rent', p_amount: 18000, p_method: 'Cash' });
ok(eR && /Liabilities/.test(eR.message), 'rent cannot be entered twice while it is open in Liabilities');
const debtId = (await one(`select id from public.debts limit 1`)).id;
await rpc(U.admin, 'pay_debt', { p_debt_id: debtId, p_amount: 18000, p_method: 'Bank' });
await rpc(U.admin, 'add_shop_expense', { p_type: 'Salary', p_amount: 12000, p_method: 'Cash' });
const se = await rpc(U.admin, 'shop_expense_list', { p_from: today, p_to: today });
ok(se.length === 2 && se.some(x => x.from_liabilities && +x.amount === 18000), 'rent paid in Liabilities shows in Shop expenses, marked from Liabilities');
const rep = await rpc(U.admin, 'report_year', { p_year: +today.slice(0, 4) });
const mrow = rep.months[+MM - 1];
eq(mrow.shop, 30000, 'month shop expenses ₹30,000');
eq(+(mrow.gross - mrow.shop).toFixed(2), mrow.net, 'net profit = gross − shop expenses');
// co-admin's Today's money: business payments combined, no names, totals still match
await rpc(U.admin, 'pay_supplier', { p_supplier_id: sup.id, p_amount: 5000, p_method: 'Cash', p_ref: 'cheque 11' });
await rpc(U.admin, 'add_shop_expense', { p_type: 'Internet', p_amount: 700, p_method: 'UPI', p_note: 'Airtel' });
const mA = await rpc(U.admin, 'money_day', { p_date: today });
const mC = await rpc(U.coadmin, 'money_day', { p_date: today });
const bizC = mC.outs.filter(x => x.t === 'Business payments (by admin)');
ok(bizC.length > 0 && !JSON.stringify(mC.outs).match(/Supplier|Ali Traders|Shop rent|Shop:|Airtel|Salary/),
   'co-admin sees supplier, Liabilities and shop payments only as "Business payments (by admin)"', JSON.stringify(mC.outs));
eq(bizC.map(x => x.m).length, new Set(bizC.map(x => x.m)).size, 'one combined line per payment method');
const byM = (a, m) => a.outs.filter(x => x.m === m).reduce((s, x) => s + +x.amt, 0);
ok(['Cash', 'UPI', 'Bank'].every(m => byM(mA, m) === byM(mC, m)), 'cash drawer totals are the same for admin and co-admin',
   ['Cash', 'UPI', 'Bank'].map(m => `${m} ${byM(mA, m)}/${byM(mC, m)}`).join(' '));
ok(mA.outs.some(x => x.t === 'Supplier Ali Traders' && +x.amt === 5000), 'admin still sees each payment in full');
// staff cancels a booking: no refund, the advance is held for admin or co-admin
const bookAs = async (code, mob) => { const l = await lap(code);
  return [l, await rpc(U.staff, 'book_laptop', { p_laptop_id: l.id, p_mobile: mob, p_lead_source: 'OLX', p_name: 'Imran', p_advance: 2000, p_method: 'UPI' })]; };
const [L16, b16] = await bookAs(lot1.codes[16], '9800000016');
const eSR = await rpcErr(U.staff, 'cancel_booking', { p_booking_id: b16.booking_id, p_refund: true });
ok(eSR && /Only the admin or co-admin can refund/.test(eSR.message), 'staff cannot refund an advance');
const c16 = await rpc(U.staff, 'cancel_booking', { p_booking_id: b16.booking_id });
eq(c16.advance_status, 'held', 'staff cancel leaves the advance held');
eq((await lap(L16.code)).status, 'in_stock', 'the laptop goes back on sale straight away');
eq((await one(`select count(*) n from public.refunds where booking_id = $1`, [b16.booking_id])).n, 0, 'no refund is made by staff');
ok((await rpc(U.coadmin, 'get_snapshot')).held_advances.some(h => h.booking_id === b16.booking_id && +h.advance === 2000), 'co-admin sees the held ₹2,000 advance');
eq((await rpc(U.staff, 'get_snapshot')).held_advances.length, 0, 'staff does not get the held list');
ok(await rpcErr(U.staff, 'settle_held_advance', { p_booking_id: b16.booking_id, p_refund: true }), 'staff cannot decide on a held advance');
await rpc(U.coadmin, 'settle_held_advance', { p_booking_id: b16.booking_id, p_refund: true });
ok((await rpc(U.admin, 'money_day', { p_date: today })).outs.some(x => +x.amt === 2000 && /Advance back to Imran/.test(x.t)), 'co-admin refund shows as money out');
ok(await rpcErr(U.coadmin, 'settle_held_advance', { p_booking_id: b16.booking_id, p_refund: false }), 'an advance cannot be decided twice');
const [, b17] = await bookAs(lot1.codes[17], '9800000017');
await rpc(U.staff, 'cancel_booking', { p_booking_id: b17.booking_id });
await rpc(U.admin, 'settle_held_advance', { p_booking_id: b17.booking_id, p_refund: false });
const s17 = await one(`select advance_status, (select count(*) from public.refunds where booking_id = $1) n from public.bookings where id = $1`, [b17.booking_id]);
ok(s17.advance_status === 'kept' && +s17.n === 0, 'admin can keep a held advance (no refund)');
ok(!(await rpc(U.coadmin, 'get_snapshot')).held_advances.length, 'nothing is left waiting');
const [, b18] = await bookAs(lot1.codes[18], '9800000018');
eq((await rpc(U.coadmin, 'cancel_booking', { p_booking_id: b18.booking_id, p_refund: false })).advance_status, 'kept', 'co-admin cancel without refund keeps the advance');

// session expiry and turned-off users
await db.query(`update public.app_sessions set created_at = now() - interval '8 days' where user_id = $1`, [U.staff.id]);
const eS = await rpcErr(U.staff, 'get_snapshot');
ok(eS && /log in again/.test(eS.message), 'a login older than 7 days can read nothing');
await db.query(`update public.app_sessions set created_at = now() where user_id = $1`, [U.staff.id]);
await db.query(`update public.profiles set active = false where id = $1`, [U.staff.id]);
eq((await as(U.staff, `select count(*) n from public.laptops`)).rows[0].n, 0, 'a turned-off user reads nothing');
ok(await rpcErr(U.staff, 'get_snapshot'), 'a turned-off user cannot call RPCs');
// anon
const eAnon = await (async () => { try { await db.exec(`set role anon`); await db.query(`select public.get_snapshot()`); return null; } catch (e) { return e; } finally { await db.exec('reset role'); } })();
ok(eAnon && /permission denied/.test(eAnon.message), 'not logged in: no access');
// lead report and lot P&L
const lr = await rpc(U.admin, 'lead_report', { p_year: +today.slice(0, 4) });
ok(lr.some(x => x.lead_source === 'Dealer' && x.n === 3), 'lead report counts the 3 dealer sales');
const pnl = await rpc(U.admin, 'lot_pnl');
const p1 = pnl.find(x => x.prefix === `01-01-${MM}-${YY}`);
ok(p1 && p1.status === 'Part sold' && p1.qty === 20, 'Lot P&L shows lot 1 as Part sold', JSON.stringify(p1));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
