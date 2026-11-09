// admin-users: the admin adds users, changes roles, resets PINs and turns users off or on.
// Needs the service role (creating logins), so it runs here and checks that the caller is an active admin.
// Deploy with JWT verification OFF; the token is checked here.
import { createClient } from 'npm:@supabase/supabase-js@2.115.0';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ORIGIN = Deno.env.get('APP_ORIGIN') || '*';
const DOMAIN = Deno.env.get('LOGIN_EMAIL_DOMAIN') || 'fcl.local';
const ROLES: Record<string, string> = { admin: 'Admin', coadmin: 'Co-admin', staff: 'Staff' };

const cors = { 'Access-Control-Allow-Origin': ORIGIN, 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin' };
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const admin = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
const weak = (p: string) => !/^\d{6}$/.test(p) || /^(\d)\1{5}$/.test(p) || ['123456', '654321'].includes(p);
const rand8 = () => Array.from(crypto.getRandomValues(new Uint8Array(8)), b => 'abcdefghjkmnpqrstuvwxyz23456789'[b % 31]).join('');

function jwtPayload(token: string): Record<string, unknown> {
  const p = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
  return JSON.parse(atob(p + '='.repeat((4 - (p.length % 4)) % 4)));
}
async function caller(req: Request) {
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token || token.split('.').length !== 3) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) return null;
  const sid = String(jwtPayload(token).session_id || '');
  const { data: sess } = await admin.from('app_sessions').select('created_at').eq('session_id', sid).eq('user_id', data.user.id).maybeSingle();
  if (!sess || Date.now() - new Date(sess.created_at).getTime() > 7 * 864e5) return null;
  const { data: prof } = await admin.from('profiles').select('id, name, mobile, role, active').eq('id', data.user.id).maybeSingle();
  if (!prof?.active) return null;
  return prof;
}
async function activeAdmins() {
  const { count } = await admin.from('profiles').select('id', { count: 'exact', head: true }).eq('role', 'admin').eq('active', true);
  return count || 0;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'method', message: 'Use POST' });
  const me = await caller(req);
  if (!me) return json(401, { error: 'auth', message: 'Please log in again.' });
  if (me.role !== 'admin') return json(403, { error: 'forbidden', message: 'Only the admin can manage users.' });
  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return json(400, { error: 'bad', message: 'Bad request' }); }
  const log = (message: string) => admin.from('activity_log').insert({ actor_id: me.id, actor_name: me.name, actor_role: me.role, action: 'user', entity: 'user', message });

  const target = async () => {
    const { data } = await admin.from('profiles').select('id, name, mobile, role, active').eq('id', String(b.user_id || '')).maybeSingle();
    return data;
  };

  switch (b.action) {
    case 'list': {
      const { data } = await admin.from('profiles').select('id, name, mobile, role, active, last_login_at').order('name');
      return json(200, { users: data });
    }
    case 'create': {
      const name = String(b.name || '').trim(), mobile = String(b.mobile || '').replace(/\D/g, '').slice(-10), role = String(b.role || ''), pin = String(b.pin || '');
      if (!name || name.length > 80) return json(400, { error: 'bad', message: 'Enter the name' });
      if (!/^[6-9]\d{9}$/.test(mobile)) return json(400, { error: 'bad', message: 'Enter a 10-digit mobile number' });
      if (!ROLES[role]) return json(400, { error: 'bad', message: 'Choose a role' });
      if (weak(pin)) return json(400, { error: 'bad', message: 'Choose a 6-digit PIN that is not easy to guess' });
      const { data: dup } = await admin.from('profiles').select('id').eq('mobile', mobile).maybeSingle();
      if (dup) return json(409, { error: 'exists', message: 'A user with this mobile number already exists' });
      const email = `91${mobile}.${rand8()}@${DOMAIN}`;
      const { data: cu, error: ce } = await admin.auth.admin.createUser({ email, password: pin, email_confirm: true });
      if (ce || !cu?.user) return json(500, { error: 'server', message: 'Could not create the login: ' + (ce?.message || 'unknown') });
      const { error: pe } = await admin.from('profiles').insert({ id: cu.user.id, name, mobile, role, active: true });
      if (pe) { await admin.auth.admin.deleteUser(cu.user.id); return json(500, { error: 'server', message: 'Could not save the user: ' + pe.message }); }
      await log(`Added user ${name} (${ROLES[role]})`);
      return json(200, { ok: true, user_id: cu.user.id });
    }
    case 'set_role': {
      const t = await target(), role = String(b.role || '');
      if (!t) return json(404, { error: 'missing', message: 'User not found' });
      if (!ROLES[role]) return json(400, { error: 'bad', message: 'Choose a role' });
      if (t.role === 'admin' && role !== 'admin' && t.active && await activeAdmins() <= 1) return json(400, { error: 'last_admin', message: 'This is the only admin. Make someone else admin first.' });
      await admin.from('profiles').update({ role }).eq('id', t.id);
      await log(`Changed the role of ${t.name} to ${ROLES[role]}`);
      return json(200, { ok: true });
    }
    case 'reset_pin': {
      const t = await target(), pin = String(b.pin || '');
      if (!t) return json(404, { error: 'missing', message: 'User not found' });
      if (weak(pin)) return json(400, { error: 'bad', message: 'Choose a 6-digit PIN that is not easy to guess' });
      const { error } = await admin.auth.admin.updateUserById(t.id, { password: pin });
      if (error) return json(500, { error: 'server', message: 'Could not reset the PIN' });
      await admin.from('login_attempts').delete().eq('mobile', t.mobile);
      if (t.id !== me.id) await admin.from('app_sessions').delete().eq('user_id', t.id);   // logged out on their phone
      await log(`Reset the PIN of ${t.name}`);
      return json(200, { ok: true });
    }
    case 'set_active': {
      const t = await target(), on = b.active === true;
      if (!t) return json(404, { error: 'missing', message: 'User not found' });
      if (t.id === me.id && !on) return json(400, { error: 'self', message: 'You cannot turn yourself off' });
      if (!on && t.role === 'admin' && t.active && await activeAdmins() <= 1) return json(400, { error: 'last_admin', message: 'This is the only admin.' });
      await admin.from('profiles').update({ active: on }).eq('id', t.id);
      await admin.auth.admin.updateUserById(t.id, { ban_duration: on ? 'none' : '876000h' });
      if (!on) await admin.from('app_sessions').delete().eq('user_id', t.id);              // stops working at once
      await log(on ? `Turned on user ${t.name}` : `Turned off user ${t.name}`);
      return json(200, { ok: true });
    }
    default:
      return json(400, { error: 'bad', message: 'Unknown action' });
  }
});
