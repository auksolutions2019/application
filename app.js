// First Choice Laptops, Stock Manager: app start, login, navigation.
import * as dom from './ui/dom.js';
import * as fb from './ui/feedback.js';
import { ICON } from './ui/icons.js';
import { initTips } from './ui/charts.js';
import { configured, setAuthLostHandler } from './api/client.js';
import { login, logout as doLogout, hasSession, lastMobile, forgetMobile } from './api/auth.js';
import { S, load, onChange, startSync, stopSync, role } from './api/store.js';
import * as home from './views/home.js';
import * as stock from './views/stock.js';
import * as addlot from './views/addlot.js';
import * as scan from './views/scan.js';
import * as laptop from './views/laptop.js';
import * as people from './views/people.js';
import * as service from './views/service.js';
import * as more from './views/more.js';
import * as reports from './views/reports.js';
import * as backup from './views/backup.js';

const { $, esc } = dom;
const mods = [home, stock, addlot, scan, laptop, people, service, more, reports, backup];
const VIEWS = Object.assign({}, ...mods.map(m => m.views || {}));

const TITLES = { home: 'Home', scan: 'Scan sticker', stock: 'Stock', sales: 'Customers', more: 'More', suppliers: 'Suppliers',
  debts: 'Liabilities', reports: 'Reports', backup: 'Backup and import', share: 'Share stock', prices: 'Model prices',
  money: "Today's money", activity: 'Activity', settings: 'Settings', partners: 'Service partners', shopexp: 'Shop expenses',
  lotpnl: 'Lot P&L', users: 'Users', pin: 'Change my PIN', deleted: 'Recently deleted' };
// Who may open which screen (the database enforces the same rules)
const ACCESS = { sales: 'mgr', suppliers: 'mgr', money: 'mgr', reports: 'mgr', activity: 'mgr',
  debts: 'admin', settings: 'admin', backup: 'admin', shopexp: 'admin', lotpnl: 'admin', users: 'admin', deleted: 'admin' };
const allowed = v => !ACCESS[v] || (ACCESS[v] === 'mgr' ? role() !== 'staff' : role() === 'admin');
const MORE = ['suppliers', 'debts', 'reports', 'backup', 'share', 'prices', 'money', 'activity', 'settings', 'partners', 'shopexp', 'lotpnl', 'users', 'pin', 'deleted'];

let view = 'home', renderSeq = 0;

function dockItems() {
  return role() === 'staff'
    ? [['home', 'Home', 'home'], ['stock', 'Stock', 'stock'], ['scan', 'Scan', 'scan'], ['partners', 'Service', 'tool'], ['more', 'More', 'more']]
    : [['home', 'Home', 'home'], ['stock', 'Stock', 'stock'], ['scan', 'Scan', 'scan'], ['sales', 'Customers', 'cust'], ['more', 'More', 'more']];
}

async function render(keepScroll) {
  const seq = ++renderSeq, y = scrollY;
  let out;
  try { out = VIEWS[view](); } catch (e) { console.error(e); out = `<p class="muted">Could not show this screen: ${esc(e.message)}</p>`; }
  if (out && typeof out.then === 'function') {
    if (!keepScroll) $('main').innerHTML = '<p class="muted" style="padding:20px;text-align:center">Loading…</p>';
    try { out = await out; } catch (e) { out = `<div class="card"><p class="muted">${esc(e.message)}</p><button class="ghost" style="margin-top:10px" onclick="A.go('${view}')">Try again</button></div>`; }
  }
  if (seq !== renderSeq) return;
  $('main').innerHTML = out;
  for (const m of mods) m.after?.(view);
  if (keepScroll) scrollTo(0, y);
}

function go(v) {
  if (!VIEWS[v] || !allowed(v)) v = 'home';
  scan.actions.stopScan();
  view = v;
  $('ptitle').textContent = TITLES[v] || '';
  const inMore = MORE.includes(v) && !(role() === 'staff' && v === 'partners');
  $('dock').innerHTML = dockItems().map(([k, t, ic]) => `<a class="${k === 'scan' ? 'scan ' : ''}${k === v || (k === 'more' && inMore) ? 'on' : ''}" onclick="A.go('${k}')" tabindex="0">${k === 'scan' ? `<span class="b">${ICON[ic]}</span>` : ICON[ic]}${t}</a>`).join('');
  scrollTo(0, 0);
  render(false);
}
// Re-draw after data changes, without jumping to the top
function refresh() {
  if (view !== 'scan') render(true);
  laptop.actions.rerender?.();
}

// ---------- login ----------
let lockTimer = null;
function showLogin(msg) {
  stopSync();
  $('app').classList.add('hidden'); $('login').classList.remove('hidden');
  fb.closeModal();
  if (!configured()) {
    $('lsub').textContent = 'Setup needed';
    $('lbody').innerHTML = '<p class="lockmsg">This copy of the app is not connected to the database yet. Put the Supabase Project URL and key in config.js (see README, step 7).</p>';
    return;
  }
  const mob = lastMobile();
  $('lsub').textContent = mob ? 'Enter your 6-digit PIN' : 'Enter your mobile number and PIN';
  $('lbody').innerHTML = `${mob
    ? `<label>Mobile number</label><div class="remembered"><span>+91 ${esc(mob.slice(0, 5))} ${esc(mob.slice(5))}</span><a class="link" onclick="A.notYou()">Not you?</a></div>`
    : `<label for="lmob">Mobile number</label><div class="mob"><span>+91</span><input id="lmob" type="tel" inputmode="numeric" maxlength="10" autocomplete="tel-national" placeholder="10-digit mobile"></div>`}
   <label for="lpin">6-digit PIN</label>
   <input id="lpin" class="pinf" type="password" inputmode="numeric" maxlength="6" autocomplete="current-password" onkeydown="if(event.key==='Enter')A.doLogin()">
   <div id="lmsg">${msg ? `<p class="lockmsg">${esc(msg)}</p>` : ''}</div>
   <button id="lbtn" style="width:100%;margin-top:14px" onclick="A.doLogin()">Login</button>`;
  setTimeout(() => ($(mob ? 'lpin' : 'lmob'))?.focus(), 100);
}
function showLock(until) {
  clearInterval(lockTimer);
  const tick = () => {
    const left = Math.max(0, Math.round((new Date(until) - Date.now()) / 1000));
    if (!$('lmsg')) return clearInterval(lockTimer);
    if (!left) { clearInterval(lockTimer); $('lmsg').innerHTML = ''; $('lbtn').disabled = false; return; }
    $('lmsg').innerHTML = `<p class="lockmsg">Too many wrong PINs. Try again in ${Math.floor(left / 60)}:${dom.pad(left % 60, 2)}</p>`;
    $('lbtn').disabled = true;
  };
  tick(); lockTimer = setInterval(tick, 1000);
}
async function doLogin() {
  const mob = lastMobile() || dom.codeDigits($('lmob')?.value).slice(-10), pin = ($('lpin').value || '').trim();
  if (!/^[6-9]\d{9}$/.test(mob)) return fb.toast('Enter your 10-digit mobile number');
  if (!/^\d{6}$/.test(pin)) return fb.toast('Enter your 6-digit PIN');
  $('lbtn').disabled = true; $('lbtn').textContent = 'Checking…';
  try {
    await login(mob, pin);
    await start();
  } catch (e) {
    $('lbtn').disabled = false; $('lbtn').textContent = 'Login';
    $('lpin').value = ''; $('lpin').classList.add('shake'); setTimeout(() => $('lpin')?.classList.remove('shake'), 400);
    if (e.data?.error === 'locked') showLock(e.data.locked_until);
    else $('lmsg').innerHTML = `<p class="lockmsg">${esc(e.data?.tries_left != null && e.data.tries_left <= 2
      ? `Wrong mobile number or PIN. ${e.data.tries_left} ${e.data.tries_left === 1 ? 'try' : 'tries'} left before a 15-minute block.` : e.message)}</p>`;
  }
}
function notYou() { forgetMobile(); showLogin(); }

async function start() {
  $('login').classList.add('hidden'); $('app').classList.remove('hidden');
  $('outbtn').innerHTML = ICON.out;
  $('main').innerHTML = '<p class="muted" style="padding:30px;text-align:center">Loading…</p>';
  try { await load(); }
  catch (e) { if (e.code === '28000') return showLogin('Please log in again.'); $('main').innerHTML = `<div class="card"><p class="muted">${esc(e.message)}</p><button style="margin-top:10px" onclick="location.reload()">Try again</button></div>`; return; }
  $('who').textContent = S.d.me?.name || '';
  setOffline();
  startSync(on => $('syncdot').classList.toggle('off', !on));
  // Opened by sharing a photo into the app: read its QR on the Scan screen
  if (new URLSearchParams(location.search).has('shared')) {
    history.replaceState(null, '', location.pathname);
    go('scan'); setTimeout(() => scan.actions.takeShared(), 300);
  } else go('home');
}
async function logout() {
  if (!await fb.confirmBox('Log out?', 'You will need your PIN to log in again.', 'Log out')) return;
  scan.actions.stopScan(); stopSync();
  await doLogout();
  location.reload();
}

function setOffline() {
  const off = !navigator.onLine || S.fromCache;
  $('offline').classList.toggle('hidden', !off);
  $('offline').textContent = !navigator.onLine ? 'You are offline. You can look, but nothing can be saved.'
    : 'Showing saved data from this phone. Pull down or reopen to refresh.';
}
addEventListener('online', () => { setOffline(); if (!$('app').classList.contains('hidden')) load().then(setOffline).catch(() => {}); });
addEventListener('offline', setOffline);

// ---------- wire up ----------
window.A = Object.assign({}, dom, fb, ...mods.map(m => m.actions || {}),
  { go, refresh, logout, doLogin, notYou, view: () => view });
onChange(() => { setOffline(); refresh(); });
setAuthLostHandler(() => showLogin('Please log in again.'));
initTips();
if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost')) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}
(async () => {
  if (configured() && await hasSession().catch(() => false)) start(); else showLogin();
})();
