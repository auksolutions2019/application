// Small shared helpers (same behaviour as the prototype).
export const $ = id => document.getElementById(id);
export const MON = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
export const pad = (n, l) => String(n).padStart(l, '0');
export const rs = n => '₹' + Math.round(Number(n) || 0).toLocaleString('en-IN');
export const fmtD = d => d ? String(d).slice(0, 10).split('-').reverse().join('/') : '';
export const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// for values placed inside onclick="...('...')" strings
export const enc = s => encodeURIComponent(String(s ?? '')).replace(/'/g, '%27');
export const dec = s => decodeURIComponent(s);
export const sum = (a, f) => (a || []).reduce((s, x) => s + (Number(f ? f(x) : x) || 0), 0);
export const stat = (t, v) => `<div class="stat"><span>${t}</span><b>${v}</b></div>`;
export const initials = n => String(n || '?').trim().split(/\s+/).slice(0, 2).map(w => w[0]).join('').toUpperCase();
export const uuid = () => (crypto.randomUUID ? crypto.randomUUID()
  : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }));
// Today in India, as YYYY-MM-DD
export const todayIN = () => new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10);
export const daysSince = d => d ? Math.max(0, Math.round((new Date(todayIN()) - new Date(String(d).slice(0, 10))) / 864e5)) : 0;
export const addMonths = (iso, m) => { const d = new Date(iso + 'T00:00:00'); d.setMonth(d.getMonth() + m); return d.getFullYear() + '-' + pad(d.getMonth() + 1, 2) + '-' + pad(d.getDate(), 2); };
// code shown as a silver asset tag: supplier | lot | month | year | piece
export const tag = (code, lg) => `<span class="tag${lg ? ' lg' : ''}">${String(code).split('-').map(p => `<i>${esc(p)}</i>`).join('')}</span>`;
export const codeDigits = s => String(s || '').replace(/\D/g, '');
export const codeFromDigits = d => d.length === 11 ? [d.slice(0, 2), d.slice(2, 4), d.slice(4, 6), d.slice(6, 8), d.slice(8)].join('-') : null;
export const waLink = (mob, txt) => `https://wa.me/91${String(mob || '').replace(/\D/g, '').slice(-10)}?text=${encodeURIComponent(txt)}`;

// single-choice chips (prototype style)
export const chips = (id, opts, def, extra = '') => `<div class="chips mchips ${extra}" id="${id}">${opts.map(o => {
  const [v, t] = Array.isArray(o) ? o : [o, o];
  return `<button type="button" data-v="${esc(v)}" class="${String(v) === String(def) ? 'on' : ''}" onclick="A.pickChip(this)">${esc(t)}</button>`;
}).join('')}</div>`;
export function pickChip(el) { [...el.parentNode.children].forEach(b => b.classList.remove('on')); el.classList.add('on'); el.parentNode.dispatchEvent(new Event('change')); }
export const chipVal = id => $(id)?.querySelector('.on')?.dataset.v ?? null;
// multi-choice chips
export const multiChips = (id, opts, sel = []) => `<div class="chips mchips wrap" id="${id}">${opts.map(o =>
  `<button type="button" data-v="${esc(o)}" class="${sel.includes(o) ? 'on' : ''}" onclick="this.classList.toggle('on')">${esc(o)}</button>`).join('')}</div>`;
export const multiVals = id => [...($(id)?.querySelectorAll('.on') || [])].map(b => b.dataset.v);
export const val = id => ($(id)?.value ?? '').trim();
export const num = id => { const v = val(id); return v === '' ? null : Number(v); };
