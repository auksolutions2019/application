// photo-delete: the admin or co-admin deletes a laptop photo. It goes out of the app at once (public.delete_photo,
// run as the caller, so the database checks the role and logs the name), then the Cloudinary copy is deleted.
// If Cloudinary fails, the photo stays out of the app and the failure is logged, so nobody is ever stuck.
// Secrets (Edge Functions → Secrets), never in the app or the repo:
//   CLOUDINARY_CLOUD_NAME, CLOUDINARY_API_KEY, CLOUDINARY_API_SECRET
// Deploy with JWT verification OFF; the token is checked here.
import { createClient } from 'npm:@supabase/supabase-js@2.115.0';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ORIGIN = Deno.env.get('APP_ORIGIN') || '*';
const CLOUD = Deno.env.get('CLOUDINARY_CLOUD_NAME') || '';
const API_KEY = Deno.env.get('CLOUDINARY_API_KEY') || '';
const API_SECRET = Deno.env.get('CLOUDINARY_API_SECRET') || '';

const cors = { 'Access-Control-Allow-Origin': ORIGIN, 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin' };
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const admin = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });

// --- helpers (tested in tests/local/unit.mjs) ---
// The Cloudinary public_id of a delivery URL from our account, or null when the URL is not ours.
// https://res.cloudinary.com/<cloud>/image/upload/[transformations/][v123/]folder/name.jpg → folder/name
function publicIdOf(url: string, cloud: string): string | null {
  const base = `https://res.cloudinary.com/${cloud}/image/upload/`;
  if (!cloud || !url.startsWith(base)) return null;
  const parts = url.slice(base.length).split('?')[0].split('/').filter(Boolean);
  while (parts.length > 1 && (parts[0].includes(',') || /^[a-z]{1,3}_[^/]*$/.test(parts[0]))) parts.shift();   // transformations
  if (parts.length > 1 && /^v\d+$/.test(parts[0])) parts.shift();                                                // version
  const id = decodeURIComponent(parts.join('/')).replace(/\.[a-z0-9]{2,5}$/i, '');
  return id || null;
}
// Cloudinary signature: the parameters sorted by name, joined with &, then the API secret, SHA-1 in hex.
async function signParams(params: Record<string, string>, secret: string): Promise<string> {
  const s = Object.keys(params).sort().map(k => `${k}=${params[k]}`).join('&') + secret;
  const h = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(h), b => b.toString(16).padStart(2, '0')).join('');
}
// --- end helpers ---

function jwtPayload(token: string): Record<string, unknown> {
  const p = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
  return JSON.parse(atob(p + '='.repeat((4 - (p.length % 4)) % 4)));
}
// The caller: an active admin or co-admin with a PIN login younger than 7 days
async function caller(req: Request) {
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token || token.split('.').length !== 3) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) return null;
  const sid = String(jwtPayload(token).session_id || '');
  const { data: sess } = await admin.from('app_sessions').select('created_at').eq('session_id', sid).eq('user_id', data.user.id).maybeSingle();
  if (!sess || Date.now() - new Date(sess.created_at).getTime() > 7 * 864e5) return null;
  const { data: prof } = await admin.from('profiles').select('id, role, active').eq('id', data.user.id).maybeSingle();
  if (!prof?.active) return null;
  return { token, prof };
}

async function deleteFromCloudinary(url: string): Promise<{ status: 'deleted' | 'failed' | 'skipped'; detail: string }> {
  if (!CLOUD || !API_KEY || !API_SECRET) return { status: 'skipped', detail: 'Cloudinary keys are not set in Supabase' };
  const publicId = publicIdOf(url, CLOUD);
  if (!publicId) return { status: 'skipped', detail: 'The photo is not in this Cloudinary account' };
  const params = { invalidate: 'true', public_id: publicId, timestamp: String(Math.floor(Date.now() / 1000)) };
  const form = new FormData();
  for (const [k, v] of Object.entries(params)) form.append(k, v);
  form.append('api_key', API_KEY);
  form.append('signature', await signParams(params, API_SECRET));
  try {
    const r = await fetch(`https://api.cloudinary.com/v1_1/${encodeURIComponent(CLOUD)}/image/destroy`, { method: 'POST', body: form });
    const j = await r.json().catch(() => ({}));
    if (r.ok && (j.result === 'ok' || j.result === 'not found')) return { status: 'deleted', detail: j.result === 'ok' ? '' : 'was already gone' };
    return { status: 'failed', detail: String(j.error?.message || j.result || `HTTP ${r.status}`).slice(0, 200) };
  } catch (e) {
    return { status: 'failed', detail: String((e as Error)?.message || e).slice(0, 200) };
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'method', message: 'Use POST' });
  const me = await caller(req);
  if (!me) return json(401, { error: 'auth', message: 'Please log in again.' });
  if (me.prof.role !== 'admin' && me.prof.role !== 'coadmin') return json(403, { error: 'role', message: 'Ask the admin or co-admin to delete photos.' });
  let body: { photo_id?: string };
  try { body = await req.json(); } catch { return json(400, { error: 'bad', message: 'Send the photo' }); }
  const photoId = String(body.photo_id || '');
  if (!/^[0-9a-f-]{36}$/i.test(photoId)) return json(400, { error: 'bad', message: 'Send the photo' });

  // 1. Out of the app, as the caller: the database checks the role, that the photo is ours, and logs the name
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '';
  const asUser = createClient(URL_, anonKey, { auth: { persistSession: false, autoRefreshToken: false },
                                               global: { headers: { Authorization: `Bearer ${me.token}` } } });
  const { data: del, error } = await asUser.rpc('delete_photo', { p_photo_id: photoId });
  if (error || !del) return json(400, { error: 'db', message: error?.message || 'Could not delete the photo' });

  // 2. The Cloudinary copy. Whatever happens, the result is recorded (and logged when it failed).
  const cloud = await deleteFromCloudinary(del.url);
  await admin.rpc('photo_cloud_result', { p_deletion_id: del.deletion_id, p_status: cloud.status, p_detail: cloud.detail });
  return json(200, { ok: true, code: del.code, cloud: cloud.status, detail: cloud.detail });
});
