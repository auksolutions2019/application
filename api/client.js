// Supabase client, RPC calls with plain-English errors, and offline blocking for saves.
import { uuid } from '../ui/dom.js';

let sb = null;
export function configured() {
  const c = window.FCL_CONFIG || {};
  return /^https:\/\/|^http:\/\/localhost|^http:\/\/127\.0\.0\.1/.test(c.SUPABASE_URL || '') && (c.SUPABASE_ANON_KEY || '').length > 20;
}
export function client() {
  if (!sb) {
    const c = window.FCL_CONFIG;
    sb = window.supabase.createClient(c.SUPABASE_URL, c.SUPABASE_ANON_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: 'fcl-auth' }
    });
  }
  return sb;
}

export class AppError extends Error {
  constructor(message, { hint = null, code = null } = {}) { super(message); this.hint = hint; this.code = code; }
}

// RPCs that accept a client_ref, so a double tap or retry is never saved twice.
const WITH_REF = new Set(['create_lot', 'add_lot_expense', 'add_repair', 'sell_laptop', 'complete_booking', 'sell_laptops_bulk',
  'add_sale_payment', 'receive_customer_payment', 'book_laptop', 'cancel_booking', 'settle_held_advance', 'return_sale',
  'undo_sale', 'pay_supplier', 'pay_debt', 'add_shop_expense', 'give_for_service', 'receive_from_service', 'pay_service_partner']);

let onAuthLost = () => {};
export const setAuthLostHandler = f => { onAuthLost = f; };

function offlineError() { return new AppError('You are offline. Nothing was saved. Try again when the internet is back.', { code: 'offline' }); }

function mapError(error) {
  const msg = String(error?.message || error || 'Something went wrong');
  if (error?.code === '28000' || /JWT expired|invalid JWT|log in again/i.test(msg)) { onAuthLost(); return new AppError('Please log in again.', { code: '28000' }); }
  if (/Failed to fetch|NetworkError|Load failed|fetch failed/i.test(msg)) return new AppError('Could not reach the server. Check the internet and try again.', { code: 'network' });
  if (/duplicate key value.*laptops_serial_uniq/i.test(msg)) return new AppError('Another laptop already has this serial number.');
  if (/permission denied/i.test(msg)) return new AppError('You are not allowed to do this.');
  return new AppError(msg.replace(/^ERROR:\s*/, ''), { hint: error?.hint, code: error?.code });
}

// Read: works offline only through the cached snapshot (see store.js).
export async function read(fn, args = {}) {
  const { data, error } = await client().rpc(fn, args);
  if (error) throw mapError(error);
  return data;
}
// Save: blocked when offline, so nothing is half-saved or double-sold.
export async function write(fn, args = {}) {
  if (!navigator.onLine) throw offlineError();
  const body = WITH_REF.has(fn) ? { ...args, p_client_ref: uuid() } : args;
  const { data, error } = await client().rpc(fn, body);
  if (error) throw mapError(error);
  return data;
}
// Direct edit of the laptop fields every user may change (model, specs, serial, grade, notes, test notes).
export async function updateLaptop(id, fields) {
  if (!navigator.onLine) throw offlineError();
  const { error } = await client().from('laptops').update(fields).eq('id', id);
  if (error) throw mapError(error);
}
// Edge Functions (login, PIN change, users). Returns the JSON body; throws AppError with .data on failure.
export async function fn(name, body) {
  if (!navigator.onLine) throw offlineError();
  const c = window.FCL_CONFIG;
  const { data: { session } } = await client().auth.getSession();
  let res;
  try {
    res = await fetch(`${c.SUPABASE_URL}/functions/v1/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: c.SUPABASE_ANON_KEY,
                 Authorization: `Bearer ${session?.access_token || c.SUPABASE_ANON_KEY}` },
      body: JSON.stringify(body || {})
    });
  } catch (e) { throw new AppError('Could not reach the server. Check the internet and try again.', { code: 'network' }); }
  let data = null; try { data = await res.json(); } catch (e) { /* empty body */ }
  if (!res.ok) { const err = new AppError(data?.message || data?.error || 'Something went wrong'); err.data = data; err.status = res.status; throw err; }
  return data;
}
