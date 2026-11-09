// Local stand-in for Supabase, for trying the app in a browser without a Supabase project.
// - serves the app's files, with a config.js pointing here
// - /rest/v1/rpc/*  runs the real database functions (all migrations) on PGlite, as the logged-in user
// - /rest/v1/laptops and /rest/v1/profiles: the two direct table uses
// - /auth/v1/* and /functions/v1/*: simple versions of Supabase Auth and the three Edge Functions
// Not for production. Usage: node tests/ui/devserver.mjs   then open http://localhost:8787
// Demo logins: Admin 9900000001, Co-admin 9900000002, Staff 9900000003; PIN 246810 for all.
import http from 'node:http';
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';

const here = dirname(fileURLToPath(import.meta.url)), root = join(here, '..', '..');
const req = createRequire(join(root, 'tests', 'local', 'package.json'));
const { PGlite } = req('@electric-sql/pglite');
const { pgcrypto } = req('@electric-sql/pglite/contrib/pgcrypto');
const ANON = 'dev-anon-key-not-a-secret-local-only';
export const PIN = '246810';
export const USERS = [
  { id: '00000000-0000-0000-0000-00000000000a', name: 'Ayan', mobile: '9900000001', role: 'admin' },
  { id: '00000000-0000-0000-0000-00000000000b', name: 'Raheem', mobile: '9900000002', role: 'coadmin' },
  { id: '00000000-0000-0000-0000-00000000000c', name: 'Imran', mobile: '9900000003', role: 'staff' }];

const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const unb64 = s => JSON.parse(Buffer.from(s, 'base64url').toString());
const jwt = (sub, sid) => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub, session_id: sid, role: 'authenticated', aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600, iat: Math.floor(Date.now() / 1000), email: `${sub}@fcl.local` })}.dev`;
const claimsOf = req => { const t = (req.headers.authorization || '').replace(/^Bearer\s+/i, ''); try { return t.split('.').length === 3 ? unb64(t.split('.')[1]) : null; } catch { return null; } };
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2', '.svg': 'image/svg+xml' };

export async function startDevServer({ port = 8787, quiet = false } = {}) {
  const db = new PGlite({ extensions: { pgcrypto } });
  await db.exec(readFileSync(join(root, 'tests', 'local', 'supabase_stub.sql'), 'utf8'));
  for (const f of readdirSync(join(root, 'supabase', 'migrations')).filter(f => f.endsWith('.sql')).sort()) await db.exec(readFileSync(join(root, 'supabase', 'migrations', f), 'utf8'));
  for (const u of USERS) await db.query(`insert into auth.users (id, email) values ($1, $2)`, [u.id, `91${u.mobile}.dev@fcl.local`]);
  await db.query(`select public.bootstrap_first_admin($1, 'Ayan', '9900000001')`, [USERS[0].id]);
  for (const u of USERS.slice(1)) await db.query(`insert into public.profiles (id, name, mobile, role) values ($1, $2, $3, $4)`, [u.id, u.name, u.mobile, u.role]);
  const pins = new Map(USERS.map(u => [u.id, PIN]));

  // one request at a time (PGlite has one connection; each request sets its own role)
  let chain = Promise.resolve();
  const serial = fn => (chain = chain.then(fn, fn));
  const argTypes = new Map();
  async function typesOf(fn) {
    if (!argTypes.has(fn)) {
      const r = await db.query(`select proargnames n, proargtypes::regtype[]::text[] t from pg_proc where proname = $1 and pronamespace = 'public'::regnamespace`, [fn]);
      if (!r.rows.length) throw Object.assign(new Error(`Could not find the function public.${fn}`), { code: 'PGRST202' });
      const row = r.rows[0], m = {}; (row.n || []).forEach((n, i) => { m[n] = row.t[i]; }); argTypes.set(fn, m);
    }
    return argTypes.get(fn);
  }
  const pgVal = (v, type) => v === null || v === undefined ? null
    : type === 'boolean' ? !!v
    : type === 'jsonb' || type === 'json' ? JSON.stringify(v)
    : type.endsWith('[]') ? `{${v.map(x => '"' + String(x).replace(/["\\]/g, '\\$&') + '"').join(',')}}` : String(v);
  async function asUser(claims, fn) {
    await db.exec(claims ? `set role authenticated; select set_config('request.jwt.claims', '${JSON.stringify(claims).replace(/'/g, "''")}', false);` : `set role anon; select set_config('request.jwt.claims', '', false);`);
    try { return await fn(); } finally { await db.exec(`reset role; select set_config('request.jwt.claims', '', false);`); }
  }
  async function rpc(fn, args, claims) {
    const types = await typesOf(fn), keys = Object.keys(args || {});
    for (const k of keys) if (!(k in types)) throw Object.assign(new Error(`Could not find the function public.${fn}(${keys.join(', ')})`), { code: 'PGRST202' });
    const sql = `select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}::${types[k]}`).join(', ')}) as r`;
    return asUser(claims, async () => (await db.query(sql, keys.map(k => pgVal(args[k], types[k])))).rows[0].r);
  }

  // Edge Function stand-ins (same rules as supabase/functions/*)
  async function authLogin(body) {
    const mobile = String(body.mobile || '').replace(/\D/g, '').slice(-10), pin = String(body.pin || '');
    const att = (await db.query(`select * from public.login_attempts where mobile = $1`, [mobile])).rows[0];
    if (att?.locked_until && new Date(att.locked_until) > new Date()) return [423, { error: 'locked', locked_until: att.locked_until, message: 'Too many wrong PINs.' }];
    const prof = (await db.query(`select * from public.profiles where mobile = $1`, [mobile])).rows[0];
    if (!prof || !prof.active || pins.get(prof.id) !== pin) {
      const n = (att?.failed_count || 0) + 1, locked = n >= 5 ? new Date(Date.now() + 15 * 60e3).toISOString() : null;
      await db.query(`insert into public.login_attempts (mobile, failed_count, locked_until) values ($1, $2, $3) on conflict (mobile) do update set failed_count = $2, locked_until = $3`, [mobile, locked ? 0 : n, locked]);
      return locked ? [423, { error: 'locked', locked_until: locked, message: 'Too many wrong PINs.' }] : [401, { error: 'wrong', tries_left: 5 - n, message: 'Wrong mobile number or PIN' }];
    }
    const sid = randomUUID();
    await db.query(`insert into public.app_sessions (session_id, user_id) values ($1, $2)`, [sid, prof.id]);
    await db.query(`delete from public.login_attempts where mobile = $1`, [mobile]);
    return [200, { session: { access_token: jwt(prof.id, sid), refresh_token: b64({ sub: prof.id, sid }), expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600 }, profile: { id: prof.id, name: prof.name, role: prof.role } }];
  }
  async function me(claims) {
    if (!claims) return null;
    const ok = (await db.query(`select p.* from public.profiles p join public.app_sessions s on s.user_id = p.id where p.id = $1 and s.session_id = $2 and p.active`, [claims.sub, claims.session_id])).rows[0];
    return ok || null;
  }
  async function adminUsers(b, claims) {
    const m = await me(claims); if (!m) return [401, { message: 'Please log in again.' }];
    if (m.role !== 'admin') return [403, { message: 'Only the admin can manage users.' }];
    const t = b.user_id ? (await db.query(`select * from public.profiles where id = $1`, [b.user_id])).rows[0] : null;
    const admins = async () => +(await db.query(`select count(*) n from public.profiles where role = 'admin' and active`)).rows[0].n;
    const log = msg => db.query(`insert into public.activity_log (actor_id, actor_name, actor_role, action, message) values ($1, $2, $3, 'user', $4)`, [m.id, m.name, m.role, msg]);
    if (b.action === 'create') {
      if ((await db.query(`select 1 from public.profiles where mobile = $1`, [b.mobile])).rows.length) return [409, { message: 'A user with this mobile number already exists' }];
      const id = randomUUID();
      await db.query(`insert into auth.users (id, email) values ($1, $2)`, [id, `91${b.mobile}.dev@fcl.local`]);
      await db.query(`insert into public.profiles (id, name, mobile, role) values ($1, $2, $3, $4)`, [id, b.name, b.mobile, b.role]);
      pins.set(id, b.pin); await log(`Added user ${b.name}`); return [200, { ok: true, user_id: id }];
    }
    if (!t) return [404, { message: 'User not found' }];
    if (b.action === 'set_role') { if (t.role === 'admin' && b.role !== 'admin' && await admins() <= 1) return [400, { message: 'This is the only admin. Make someone else admin first.' }]; await db.query(`update public.profiles set role = $2 where id = $1`, [t.id, b.role]); await log(`Changed the role of ${t.name}`); return [200, { ok: true }]; }
    if (b.action === 'reset_pin') { pins.set(t.id, b.pin); if (t.id !== m.id) await db.query(`delete from public.app_sessions where user_id = $1`, [t.id]); await log(`Reset the PIN of ${t.name}`); return [200, { ok: true }]; }
    if (b.action === 'set_active') { if (t.id === m.id && !b.active) return [400, { message: 'You cannot turn yourself off' }]; await db.query(`update public.profiles set active = $2 where id = $1`, [t.id, !!b.active]); if (!b.active) await db.query(`delete from public.app_sessions where user_id = $1`, [t.id]); await log(`${b.active ? 'Turned on' : 'Turned off'} user ${t.name}`); return [200, { ok: true }]; }
    return [400, { message: 'Unknown action' }];
  }
  async function changePin(b, claims) {
    const m = await me(claims); if (!m) return [401, { message: 'Please log in again.' }];
    if (pins.get(m.id) !== b.old_pin) return [401, { error: 'wrong', message: 'The current PIN is wrong' }];
    pins.set(m.id, b.new_pin); return [200, { ok: true }];
  }

  const send = (res, status, body, type = 'application/json') => { res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' }); res.end(type === 'application/json' ? JSON.stringify(body) : body); };
  const pgErr = (res, e) => send(res, e.code === 'PGRST202' ? 404 : 400, { code: e.code || 'P0001', message: e.message, details: e.detail || null, hint: e.hint || null });
  const readBody = req => new Promise(r => { let s = ''; req.on('data', c => s += c); req.on('end', () => { try { r(s ? JSON.parse(s) : {}); } catch { r({}); } }); });

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://localhost:${port}`), p = url.pathname;
    try {
      if (p === '/config.js') return send(res, 200, `window.FCL_CONFIG={SUPABASE_URL:'http://localhost:${port}',SUPABASE_ANON_KEY:'${ANON}'};`, 'text/javascript');
      if (p.startsWith('/rest/v1/rpc/')) { const body = await readBody(req); return serial(async () => { try { send(res, 200, await rpc(p.slice(13), body, claimsOf(req))); } catch (e) { pgErr(res, e); } }); }
      if (p === '/rest/v1/laptops' && req.method === 'PATCH') {
        const body = await readBody(req), id = (url.searchParams.get('id') || '').replace(/^eq\./, ''), keys = Object.keys(body);
        return serial(async () => { try { await asUser(claimsOf(req), () => db.query(`update public.laptops set ${keys.map((k, i) => `${k} = $${i + 1}`).join(', ')} where id = $${keys.length + 1}`, [...keys.map(k => body[k]), id])); send(res, 204, ''); } catch (e) { pgErr(res, e); } });
      }
      if (p === '/rest/v1/profiles' && req.method === 'GET') {
        return serial(async () => { try { const r = await asUser(claimsOf(req), () => db.query(`select id, name, mobile, role, active, last_login_at from public.profiles order by name`)); send(res, 200, r.rows); } catch (e) { pgErr(res, e); } });
      }
      if (p === '/auth/v1/user') { const c = claimsOf(req); return c ? send(res, 200, { id: c.sub, aud: 'authenticated', role: 'authenticated', email: c.email, app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }) : send(res, 401, { message: 'invalid JWT' }); }
      if (p === '/auth/v1/token') { const b = await readBody(req); const r = unb64(b.refresh_token); return send(res, 200, { access_token: jwt(r.sub, r.sid), refresh_token: b.refresh_token, token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, user: { id: r.sub, aud: 'authenticated', role: 'authenticated' } }); }
      if (p === '/auth/v1/logout') return send(res, 204, '');
      if (p === '/functions/v1/warranty-check') {   // public: runs the same lookup the real function runs (as the service role)
        const t = url.searchParams.get('t') || '';
        return serial(async () => { await db.exec('set role service_role'); try { const r = (await db.query(`select public.warranty_lookup($1, $2) r`, [t, req.socket.remoteAddress || 'local'])).rows[0].r; send(res, r.error === 'rate_limited' ? 429 : r.error ? 404 : 200, r.error ? { error: r.error, message: r.error === 'rate_limited' ? 'Too many checks.' : 'Warranty not found. Check the QR on your bill.' } : r); } catch (e) { send(res, 500, { message: e.message }); } finally { await db.exec('reset role'); } });
      }
      if (p.startsWith('/functions/v1/')) {
        const body = await readBody(req), name = p.slice(14), c = claimsOf(req);
        return serial(async () => { try { const [st, out] = name === 'auth-login' ? await authLogin(body) : name === 'admin-users' ? await adminUsers(body, c) : name === 'change-pin' ? await changePin(body, c) : [404, { message: 'no function' }]; send(res, st, out); } catch (e) { send(res, 500, { message: e.message }); } });
      }
      if (p.startsWith('/realtime/')) return send(res, 404, { message: 'Realtime is not part of the local stand-in' });
      // static files
      let f = normalize(join(root, decodeURIComponent(p.endsWith('/') ? p + 'index.html' : p)));
      if (!f.startsWith(root) || !existsSync(f) || statSync(f).isDirectory()) return send(res, 404, 'Not found', 'text/plain');
      res.writeHead(200, { 'Content-Type': MIME[extname(f)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
      res.end(readFileSync(f));
    } catch (e) { send(res, 500, { message: e.message }); }
  });
  await new Promise(r => server.listen(port, r));
  if (!quiet) console.log(`Local stand-in running at http://localhost:${port}  (logins: ${USERS.map(u => `${u.role} ${u.mobile}`).join(', ')}; PIN ${PIN})`);
  return { server, db, rpc, close: () => new Promise(r => server.close(r)) };
}

// A little sample data so every screen has something to show
export async function seed(srv) {
  const admin = USERS[0], sid = randomUUID();
  await srv.db.query(`insert into public.app_sessions (session_id, user_id) values ($1, $2)`, [sid, admin.id]);
  const c = { sub: admin.id, session_id: sid }, R = (fn, a) => srv.rpc(fn, a, c);
  const today = (await srv.db.query(`select private.today()::text d`)).rows[0].d;
  const back = n => new Date(new Date(today).getTime() - n * 864e5).toISOString().slice(0, 10);
  const s1 = await R('add_supplier', { p_name: 'Sultan Traders', p_phone: '9845011223' });
  const s2 = await R('add_supplier', { p_name: 'Mubrak', p_phone: '' });
  const l1 = await R('create_lot', { p_supplier_id: s1.id, p_lot_no: 1, p_bought_on: back(70), p_lines: [
    { brand: 'Dell', model: 'Latitude 5490', processor: 'i5', gen: 8, ram_gb: 8, storage_type: 'SSD', storage_gb: 256, qty: 5, cost: 75000 },
    { brand: 'Lenovo', model: 'T480', processor: 'i5', gen: 8, ram_gb: 16, storage_type: 'SSD', storage_gb: 512, qty: 3, cost: 54000 }] });
  const l2 = await R('create_lot', { p_supplier_id: s2.id, p_lot_no: 1, p_bought_on: back(10), p_lines: [{ is_mixed: true, qty: 6 }] });
  const id = async code => (await srv.db.query(`select id from public.laptops where code = $1`, [code])).rows[0].id;
  for (const code of l1.codes.slice(0, 7)) await R('set_all_tests', { p_laptop_id: await id(code) });
  await R('add_lot_expense', { p_lot_id: l1.lot_id, p_type: 'Charger', p_count: 4, p_amount: 1200, p_method: 'Cash' });
  await R('add_repair', { p_laptop_id: await id(l1.codes[0]), p_work: 'SSD changed', p_amount: 1800 });
  await R('sell_laptop', { p_laptop_id: await id(l1.codes[0]), p_price: 29500, p_paid: 15000, p_method: 'Cash', p_lead_source: 'OLX', p_name: 'Mohammed Irfan', p_mobile: '9800000001', p_warranty_months: 6, p_sold_on: back(20) });
  await R('sell_laptop', { p_laptop_id: await id(l1.codes[1]), p_price: 21000, p_paid: 21000, p_method: 'UPI', p_lead_source: 'Instagram', p_sold_on: back(3) });
  await R('book_laptop', { p_laptop_id: await id(l1.codes[2]), p_mobile: '9800000002', p_lead_source: 'Walk-in', p_name: 'Sana Khan', p_agreed_price: 19000, p_advance: 2000, p_method: 'UPI' });
  const pt = await R('save_service_partner', { p_name: 'Ravi', p_mobile: '9845011111', p_shop_name: 'Ravi Chip Repair', p_skills: ['Chip-level', 'Screen'] });
  await R('give_for_service', { p_laptop_id: await id(l1.codes[3]), p_partner_id: pt.partner_id, p_issues: ['Screen'], p_given_on: back(6), p_expected_on: back(2) });
  await R('add_debt', { p_name: 'Shop rent, November', p_type: 'Shop rent', p_amount: 18000 });
  await R('add_shop_expense', { p_type: 'Salary', p_amount: 12000, p_method: 'Cash', p_note: 'Imran' });
  await R('set_model_price', { p_shorthand: 'Dell i5 8th 8/256', p_price: 19500 });
  return { l1, l2, partner: pt.partner_id };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === normalize(process.argv[1])) {
  const srv = await startDevServer();
  await seed(srv);
  console.log('Sample data added.');
}
