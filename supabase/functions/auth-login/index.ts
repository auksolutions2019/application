// auth-login: mobile + 6-digit PIN → session. 5 wrong PINs lock that mobile for 15 minutes.
// The hidden login email (91XXXXXXXXXX.<random>@fcl.local) is looked up here and never sent to the phone,
// so nobody can skip the lock by calling Supabase Auth directly.
// Deploy with JWT verification OFF (the caller is not logged in yet).
import { createClient } from 'npm:@supabase/supabase-js@2.115.0';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ORIGIN = Deno.env.get('APP_ORIGIN') || '*';
const MAX_TRIES = 5, LOCK_MIN = 15;

const cors = { 'Access-Control-Allow-Origin': ORIGIN, 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin' };
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const admin = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });

function jwtPayload(token: string): Record<string, unknown> {
  const p = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
  return JSON.parse(atob(p + '='.repeat((4 - (p.length % 4)) % 4)));
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'method', message: 'Use POST' });
  let body: { mobile?: string; pin?: string };
  try { body = await req.json(); } catch { return json(400, { error: 'bad', message: 'Send the mobile number and PIN' }); }
  const mobile = String(body.mobile || '').replace(/\D/g, '').slice(-10), pin = String(body.pin || '');
  if (!/^[6-9]\d{9}$/.test(mobile) || !/^\d{6}$/.test(pin)) return json(400, { error: 'bad', message: 'Enter your 10-digit mobile number and 6-digit PIN' });

  const now = new Date();
  const { data: att } = await admin.from('login_attempts').select('failed_count, locked_until').eq('mobile', mobile).maybeSingle();
  if (att?.locked_until && new Date(att.locked_until) > now) {
    return json(423, { error: 'locked', locked_until: att.locked_until, message: 'Too many wrong PINs.' });
  }
  const fail = async () => {
    const n = (att?.failed_count || 0) + 1;
    const locked = n >= MAX_TRIES ? new Date(Date.now() + LOCK_MIN * 60e3).toISOString() : null;
    await admin.from('login_attempts').upsert({ mobile, failed_count: locked ? 0 : n, locked_until: locked, updated_at: now.toISOString() });
    if (locked) return json(423, { error: 'locked', locked_until: locked, message: 'Too many wrong PINs.' });
    return json(401, { error: 'wrong', tries_left: MAX_TRIES - n, message: 'Wrong mobile number or PIN' });
  };

  // Same answer for an unknown mobile, a turned-off user and a wrong PIN
  const { data: prof } = await admin.from('profiles').select('id, name, role, active').eq('mobile', mobile).maybeSingle();
  if (!prof || !prof.active) return await fail();
  const { data: u, error: ue } = await admin.auth.admin.getUserById(prof.id);
  if (ue || !u?.user?.email) return await fail();

  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '';
  const pub = createClient(URL_, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: s, error } = await pub.auth.signInWithPassword({ email: u.user.email, password: pin });
  if (error || !s?.session) return await fail();

  const sid = String(jwtPayload(s.session.access_token).session_id || '');
  if (!sid) return json(500, { error: 'server', message: 'Could not start the session. Try again.' });
  // The database only accepts sessions listed here, for 7 days
  const { error: se } = await admin.from('app_sessions').insert({ session_id: sid, user_id: prof.id });
  if (se) return json(500, { error: 'server', message: 'Could not start the session. Try again.' });
  await admin.from('login_attempts').delete().eq('mobile', mobile);
  await admin.from('profiles').update({ last_login_at: now.toISOString() }).eq('id', prof.id);
  await admin.from('app_sessions').delete().eq('user_id', prof.id).lt('created_at', new Date(Date.now() - 8 * 864e5).toISOString());

  return json(200, {
    session: { access_token: s.session.access_token, refresh_token: s.session.refresh_token, expires_at: s.session.expires_at, expires_in: s.session.expires_in },
    profile: { id: prof.id, name: prof.name, role: prof.role }
  });
});
