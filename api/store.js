// The app's data: one role-filtered snapshot from get_snapshot(), cached on the phone for offline viewing,
// refreshed after every save and whenever the other phone saves (Realtime on sync_ticks).
import { client, read } from './client.js';

export const S = { d: null, byCode: new Map(), extra: new Map(), fromCache: false, live: false, loadedAt: 0 };
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
