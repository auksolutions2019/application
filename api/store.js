// The app's data: one role-filtered snapshot from get_snapshot(), cached on the phone for offline viewing,
// refreshed after every save and whenever the other phone saves (Realtime on sync_ticks).
import { client, read } from './client.js';

export const S = { d: null, byCode: new Map(), extra: new Map(), fromCache: false, live: false, loadedAt: 0, unread: 0 };
const CACHE = 'fcl_snapshot';
let listeners = [];
export const onChange = f => listeners.push(f);

function index() {
  S.byCode = new Map(S.d.laptops.map(l => [l.code, l]));
  S.lotById = new Map(S.d.lots.map(x => [x.id, x]));
  S.supById = new Map((S.d.suppliers || []).map(x => [x.id, x]));
  S.partnerById = new Map((S.d.partners || []).map(x => [x.id, x]));
}

export async function load() {
  try {
    // calendar notifications (overdue service, old balances, held advances) are made here; returns the unread count
    try { S.unread = await read('notifications_check'); } catch (e) { if (e.code === '28000') throw e; }
    S.d = await read('get_snapshot');
    S.fromCache = false; S.loadedAt = Date.now(); S.extra.clear();
    try { localStorage.setItem(CACHE, JSON.stringify(S.d)); } catch (e) { /* too big or private mode: skip the cache */ }
  } catch (e) {
    if (e.code === '28000') throw e;
    const cached = (() => { try { return JSON.parse(localStorage.getItem(CACHE)); } catch (x) { return null; } })();
    if (!cached) throw e;
    S.d = cached; S.fromCache = true;
  }
  index();
  listeners.forEach(f => f());
  if (!S.fromCache) phoneAlerts().catch(() => {});
}

// Low-stock alerts as phone notifications, when the app is installed and the phone allows it.
// Shown once each; the first time only remembers what is already there (no burst of old alerts).
const SHOWN = 'fcl_shown_notifs';
async function phoneAlerts() {
  if (!('Notification' in window) || Notification.permission !== 'granted' || !('serviceWorker' in navigator)) return;
  const list = (await read('my_notifications')).filter(n => n.kind === 'low_stock' && !n.read);
  let seen; try { seen = JSON.parse(localStorage.getItem(SHOWN)); } catch (e) { seen = null; }
  const first = !Array.isArray(seen); seen = new Set(seen || []);
  const reg = await navigator.serviceWorker.ready;
  for (const n of list) {
    if (seen.has(n.id)) continue;
    seen.add(n.id);
    if (!first) await reg.showNotification(n.title, { body: n.body, tag: n.id, icon: 'assets/icon-192.png', badge: 'assets/icon-192.png', data: { url: './' } });
  }
  try { localStorage.setItem(SHOWN, JSON.stringify([...seen].slice(-200))); } catch (e) { /* private mode */ }
}
// Ask once, from a tap (browsers want a user gesture). Does nothing where notifications are not supported.
export async function askPhoneAlerts() {
  try {
    if (!('Notification' in window) || Notification.permission !== 'default' || localStorage.getItem('fcl_asked_notifs')) return;
    localStorage.setItem('fcl_asked_notifs', '1');
    if (await Notification.requestPermission() === 'granted') phoneAlerts().catch(() => {});
  } catch (e) { /* not supported */ }
}

// Laptop by code: loaded ones first, otherwise ask the server (old sold laptops are not in the snapshot).
export async function laptopByCode(code) {
  if (S.byCode.has(code)) return S.byCode.get(code);
  if (S.extra.has(code)) return S.extra.get(code);
  const l = await read('get_laptop', { p_code: code });
  if (l) S.extra.set(l.code, l);
  return l;
}
export const cachedLaptop = code => S.byCode.get(code) || S.extra.get(code) || null;
export const role = () => S.d?.me?.role;
export const isAdmin = () => role() === 'admin';
export const isMgr = () => role() === 'admin' || role() === 'coadmin';

// Live sync
let timer = null, channel = null;
export function startSync(setDot) {
  if (channel) return;
  channel = client().channel('fcl-sync')
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'sync_ticks' }, () => {
      clearTimeout(timer); timer = setTimeout(() => load().catch(() => {}), 500);
    })
    .subscribe(status => { S.live = status === 'SUBSCRIBED'; setDot(S.live); });
}
export function stopSync() { if (channel) { client().removeChannel(channel); channel = null; } }
