// Toasts, dialogs and empty states (same look and wording as the prototype).
import { $, esc, rs, chips, chipVal } from './dom.js';
import { ICON } from './icons.js';

export const METHODS = ['Cash', 'UPI', 'Bank'];

export function toast(msg, kind = 'err') {
  const t = document.createElement('div');
  t.className = 'toast ' + kind;
  t.innerHTML = (kind === 'ok' ? ICON.check : ICON.alert) + '<span>' + esc(msg).replace(/\n/g, '<br>') + '</span>';
  const box = $('toasts');
  while (box.children.length >= 2) box.firstChild.remove();
  box.appendChild(t);
  if (navigator.vibrate && kind === 'err') navigator.vibrate(40);
  setTimeout(() => { t.classList.add('out'); setTimeout(() => t.remove(), 300); }, kind === 'ok' ? 2600 : 4200);
}

let lastMethod = 'Cash';
// Small centred dialog. Resolves true/false; for amount dialogs {amount, method, ref} or null; for text dialogs the text or null.
export function dialog({ title, body = '', ok = 'OK', danger = false, amount = false, max = null, text = false,
                         allowZero = false, method = true, ref = true, note = true, placeholder = '', value = '', html = '' }) {
  return new Promise(res => {
    const d = $('dlg');
    d.innerHTML = `<div class="dbox"><h3>${title}</h3>${body ? `<p class="muted" style="margin-bottom:6px">${body}</p>` : ''}
    ${amount ? `<div class="amt"><span>₹</span><input id="dlgv" type="number" inputmode="decimal" placeholder="0"></div>
      ${max ? `<button class="chipfill" onclick="document.getElementById('dlgv').value=${Number(max)}">Full amount ${rs(max)}</button>` : ''}
      ${method ? chips('dlgm', METHODS, lastMethod) : ''}
      ${method && ref ? `<input id="dlgref" placeholder="Ref / UTR (optional)" autocomplete="off" style="margin-top:4px">` : ''}
      ${note ? `<input id="dlgnote" placeholder="Note (optional)" maxlength="300" autocomplete="off" style="margin-top:6px">` : ''}` : ''}
    ${html}
    ${text ? `<input id="dlgv" style="margin-top:8px" autocomplete="off" maxlength="300" placeholder="${esc(placeholder)}" value="${esc(value)}">` : ''}
    <div class="row" style="margin-top:16px"><button class="ghost" id="dlgno">Cancel</button><button id="dlgok" class="${danger ? 'red' : ''}">${ok}</button></div></div>`;
    d.classList.remove('hidden');
    const v = $('dlgv');
    if (v) setTimeout(() => v.focus(), 60);
    const done = r => { d.classList.add('hidden'); d.innerHTML = ''; res(r); };
    $('dlgno').onclick = () => done(amount || text ? null : false);
    $('dlgok').onclick = () => {
      if (amount) {
        const n = +v.value;
        if (!(allowZero && v.value !== '' && n === 0) && (!n || n <= 0)) return toast('Enter an amount');
        if (max != null && n > max + 0.001) return toast('That is more than the balance of ' + rs(max));
        if (method) lastMethod = chipVal('dlgm') || 'Cash';
        done({ amount: n, method: method ? lastMethod : null, ref: ($('dlgref')?.value || '').trim(), note: ($('dlgnote')?.value || '').trim() });
      } else done(text ? v.value : true);
    };
    if (v) v.onkeydown = e => { if (e.key === 'Enter') $('dlgok').click(); };
  });
}
export const confirmBox = (title, body, ok = 'Yes', danger) => dialog({ title, body, ok, danger });
export const amountBox = (title, body, max, opts = {}) => dialog({ title, body, ok: 'Save payment', amount: true, max, ...opts });

export function empty(ic, title, body, btn, act) {
  return `<div class="empty"><div class="ei">${ic}</div><h3>${title}</h3><p class="muted">${body}</p>${btn ? `<button style="margin-top:14px" onclick="${act}">${btn}</button>` : ''}</div>`;
}

// Pop-up sheet
let onClose = null;
export function openSheet(html, closeCb = null) { onClose = closeCb; $('sheet').innerHTML = html; $('modal').classList.remove('hidden'); $('sheet').scrollTop = 0; }
export function closeModal() { $('modal').classList.add('hidden'); $('sheet').innerHTML = ''; const cb = onClose; onClose = null; if (cb) cb(); }
export const sheetOpen = () => !$('modal').classList.contains('hidden');
export function sheetHead(t, sub) {
  return `<div class="shd"><div><h2 style="font-size:20px">${t}</h2>${sub ? `<p class="muted">${sub}</p>` : ''}</div><button class="ghost sm" onclick="A.closeModal()" aria-label="Close">${ICON.x}</button></div>`;
}

// Run an action with a busy guard, show errors as toasts. Returns the result or undefined on error.
let busy = false;
export async function guard(fn) {
  if (busy) return;
  busy = true;
  try { return await fn(); }
  catch (e) { toast(e.message || 'Something went wrong'); }
  finally { busy = false; }
}

// ⋮ menu: delete and other rare actions live here, never as a big main button.
// items: [label, onclick code, red?]; empty or falsy items are skipped.
let kebabSeq = 0;
export function kebab(items, label = 'More actions') {
  const list = items.filter(Boolean);
  if (!list.length) return '';
  const id = 'km' + (++kebabSeq);
  return `<div class="kebab"><button type="button" class="ghost sm kbtn" aria-label="${label}" aria-haspopup="true" onclick="event.stopPropagation();A.kebabToggle('${id}')">⋮</button>
  <div class="kmenu hidden" id="${id}" role="menu">${list.map(([t, act, red]) => `<button type="button" role="menuitem" class="${red ? 'kred' : ''}" onclick="event.stopPropagation();A.kebabClose();${act}">${t}</button>`).join('')}</div></div>`;
}
export function kebabClose() { document.querySelectorAll('.kmenu:not(.hidden)').forEach(m => m.classList.add('hidden')); }
export function kebabToggle(id) { const m = $(id), open = m && m.classList.contains('hidden'); kebabClose(); if (open) m.classList.remove('hidden'); }
document.addEventListener('click', e => { if (!e.target.closest?.('.kebab')) kebabClose(); });
