// Login with mobile + 6-digit PIN (through the auth-login Edge Function), 7-day PIN check, logout.
import { client, fn } from './client.js';

const LAST_MOBILE = 'fcl_mobile', LOGIN_AT = 'fcl_login_at', WEEK = 7 * 864e5;
const ls = { get: k => { try { return localStorage.getItem(k); } catch (e) { return null; } },
             set: (k, v) => { try { localStorage.setItem(k, v); } catch (e) { /* private mode */ } },
             del: k => { try { localStorage.removeItem(k); } catch (e) { /* private mode */ } } };

export const lastMobile = () => ls.get(LAST_MOBILE) || '';
export const forgetMobile = () => ls.del(LAST_MOBILE);

// Returns the profile on success. Throws AppError; err.data has {error:'locked', locked_until} or {error:'wrong'}.
export async function login(mobile, pin) {
  const res = await fn('auth-login', { mobile, pin });
  const { error } = await client().auth.setSession({ access_token: res.session.access_token, refresh_token: res.session.refresh_token });
  if (error) throw new Error('Could not start the session. Try again.');
  ls.set(LAST_MOBILE, mobile);
  ls.set(LOGIN_AT, String(Date.now()));
  return res.profile;
}

// A session is usable only within 7 days of the PIN login (the database checks the same).
export async function hasSession() {
  const at = +ls.get(LOGIN_AT) || 0;
  if (!at || Date.now() - at > WEEK) return false;
  const { data: { session } } = await client().auth.getSession();
  return !!session;
}

export async function logout() {
  try { await client().auth.signOut({ scope: 'local' }); } catch (e) { /* offline: still clear locally */ }
  ls.del(LOGIN_AT);
  try { localStorage.removeItem('fcl_snapshot'); } catch (e) { /* ignore */ }
}
