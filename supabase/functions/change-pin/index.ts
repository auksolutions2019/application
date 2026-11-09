// change-pin: a logged-in user changes their own PIN after giving the current one.
// Wrong current PINs count towards the same 5-try, 15-minute lock as the login.
// Deploy with JWT verification OFF; the token is checked here.
import { createClient } from 'npm:@supabase/supabase-js@2.115.0';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ORIGIN = Deno.env.get('APP_ORIGIN') || '*';
const MAX_TRIES = 5, LOCK_MIN = 15;

const cors = { 'Access-Control-Allow-Origin': ORIGIN, 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin' };
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const admin = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
const weak = (p: string) => !/^\d{6}$/.test(p) || /^(\d)\1{5}$/.test(p) || ['123456', '654321'].includes(p);

function jwtPayload(token: string): Record<string, unknown> {
  const p = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
  return JSON.parse(atob(p + '='.repeat((4 - (p.length % 4)) % 4)));
}
// The caller: a real, active user with a PIN login younger than 7 days
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
  return { user: data.user, prof };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'method', message: 'Use POST' });
  const me = await caller(req);
  if (!me) return json(401, { error: 'auth', message: 'Please log in again.' });
  let body: { old_pin?: string; new_pin?: string };
  try { body = await req.json(); } catch { return json(400, { error: 'bad', message: 'Send the current and new PIN' }); }
  const oldPin = String(body.old_pin || ''), newPin = String(body.new_pin || '');
  if (!/^\d{6}$/.test(oldPin)) return json(400, { error: 'bad', message: 'Enter your current 6-digit PIN' });
  if (weak(newPin)) return json(400, { error: 'bad', message: 'Choose a new 6-digit PIN that is not easy to guess' });
  if (oldPin === newPin) return json(400, { error: 'bad', message: 'The new PIN is the same as the old one' });

  const mobile = me.prof.mobile, now = new Date();
  const { data: att } = await admin.from('login_attempts').select('failed_count, locked_until').eq('mobile', mobile).maybeSingle();
  if (att?.locked_until && new Date(att.locked_until) > now) return json(423, { error: 'locked', locked_until: att.locked_until, message: 'Too many wrong PINs.' });

  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '';
  const pub = createClient(URL_, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: s, error } = await pub.auth.signInWithPassword({ email: me.user.email!, password: oldPin });
  if (error || !s?.session) {
    const n = (att?.failed_count || 0) + 1;
    const locked = n >= MAX_TRIES ? new Date(Date.now() + LOCK_MIN * 60e3).toISOString() : null;
    await admin.from('login_attempts').upsert({ mobile, failed_count: locked ? 0 : n, locked_until: locked, updated_at: now.toISOString() });
    if (locked) return json(423, { error: 'locked', locked_until: locked, message: 'Too many wrong PINs.' });
    return json(401, { error: 'wrong', tries_left: MAX_TRIES - n, message: 'The current PIN is wrong' });
  }
  await admin.auth.admin.signOut(s.session.access_token, 'local').catch(() => {});   // the check made a session; end it
  const { error: ue } = await admin.auth.admin.updateUserById(me.prof.id, { password: newPin });
  if (ue) return json(500, { error: 'server', message: 'Could not change the PIN. Try again.' });
  await admin.from('login_attempts').delete().eq('mobile', mobile);
  await admin.from('activity_log').insert({ actor_id: me.prof.id, actor_name: me.prof.name, actor_role: me.prof.role, action: 'pin', entity: 'user', entity_id: me.prof.id, message: 'Changed their PIN' });
  return json(200, { ok: true });
});
