// warranty-check: public, no login. Answers the warranty QR printed on a bill.
// GET /functions/v1/warranty-check?t=<64-character token>
// Returns only: business name, invoice number, laptop and sticker code, bill date, warranty end dates and status.
// Never the customer's name, mobile, price or payments (public.warranty_lookup only selects the safe fields).
// Rate limited in the database: 20 checks per 10 minutes per phone, 1000 in total.
// Deploy with JWT verification OFF.
import { createClient } from 'npm:@supabase/supabase-js@2.115.0';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' };
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

// The caller's IP is only used as a hashed key for the rate limit
async function callerKey(req: Request) {
  const ip = (req.headers.get('cf-connecting-ip') || req.headers.get('x-forwarded-for') || 'unknown').split(',')[0].trim();
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('fcl-warranty:' + ip));
  return Array.from(new Uint8Array(h).slice(0, 16), b => b.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'GET' && req.method !== 'POST') return json(405, { error: 'method', message: 'Use GET' });
  let token = new URL(req.url).searchParams.get('t') || '';
  if (!token && req.method === 'POST') { try { token = String((await req.json()).t || ''); } catch { /* no body */ } }
  token = token.trim().toLowerCase();
  const { data, error } = await admin.rpc('warranty_lookup', { p_token: token, p_client: await callerKey(req) });
  if (error) return json(500, { error: 'server', message: 'Could not check the warranty. Try again.' });
  if (data?.error === 'rate_limited') return json(429, { error: 'rate_limited', message: 'Too many checks. Try again in a few minutes.' });
  if (data?.error) return json(404, { error: 'not_found', message: 'Warranty not found. Check the QR on your bill.' });
  return json(200, data);
});
