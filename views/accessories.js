// Accessories (Stock → Accessories): chargers, mice, keyboards, bags… The count is the sum of stock movements
// (in, out, adjust) kept in the database; it never goes below 0. Staff sell or give and see quantities; the admin
// and co-admin also add stock and adjust; only the admin sees costs and can delete.
// Also the "Accessories given with this sale" picker used by the laptop sale and the bulk sale.
import { $, esc, rs, fmtD, todayIN, chips, chipVal, val, num } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, empty, openSheet, sheetHead, closeModal, confirmBox, guard, METHODS, kebab } from '../ui/feedback.js';
import { S, load, isAdmin, isMgr } from '../api/store.js';
import { read, write } from '../api/client.js';

const QUICK = ['Charger', 'Mouse', 'Keyboard', 'Bag'];
const REASONS = ['Damaged', 'Lost', 'Found', 'Count correction', 'Returned by customer'];
export const accIcon = n => /charg|adapt/i.test(n) ? '🔌' : /mouse/i.test(n) ? '🖱️' : /key ?board/i.test(n) ? '⌨️' : /bag|sleeve/i.test(n) ? '🎒'
  : /ram|ssd|hdd/i.test(n) ? '💾' : /batter/i.test(n) ? '🔋' : '📦';
const accs = () => S.d.accessories || [];
const byId = id => accs().find(a => a.id === id);
const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;

// ---------- list (Stock → Accessories) ----------
export function accessoriesView() {
  const list = accs();
  return `${isMgr() ? `<button class="addbig" onclick="A.addAccessory()">${ICON.plus}Add accessory</button>` : ''}
  <div class="list">${list.length ? list.map(a => {
    const pct = Math.min(100, a.qty / Math.max(a.alert_at * 3, a.qty, 1) * 100);
    return `<div class="crow acc${a.low ? ' low' : ''}" onclick="A.openAccessory('${a.id}')" style="cursor:pointer">
      <div class="av sq accic">${accIcon(a.name)}</div>
      <div class="cm"><b>${esc(a.name)}</b><div>${a.low ? `<span class="lowtag">Low stock, alert at ${a.alert_at}</span>` : `<span class="muted">Alert at ${a.alert_at}</span>`}</div>
        <div class="accbar"><i style="width:${pct}%"></i></div></div>
      <div class="accq"><b>${a.qty}</b><span>left</span></div></div>`;
  }).join('') : empty('📦', 'No accessories yet', 'Add chargers, mice, keyboards or bags. You get an alert when one runs low.')}</div>
  ${list.length ? '<p class="muted" style="margin:10px 2px">Red = at or below the alert number. Tap an item to add stock, sell or change the alert.</p>' : ''}`;
}

// ---------- add ----------
function stepper(id, value, min = 0) {
  return `<div class="stepper"><button type="button" onclick="A.accStep('${id}',-1,${min})" aria-label="One less">−</button>
    <input id="${id}" type="number" inputmode="numeric" min="${min}" value="${value}">
    <button type="button" onclick="A.accStep('${id}',1,${min})" aria-label="One more">+</button></div>`;
}

let curAcc = null, accMode = 'out';

function renderAcc(hist) {
  const a = byId(curAcc); if (!a) return closeModal();
  const mgr = isMgr(), adm = isAdmin();
  const tabs = [['out', 'Sell or give'], ...(mgr ? [['in', 'Add stock'], ['adjust', 'Adjust']] : [])];
  if (!tabs.some(t => t[0] === accMode)) accMode = 'out';
  const form = accMode === 'in' ? `<div class="row nw qc"><div><label>How many</label>${stepper('ain_qty', 1, 1)}</div>
      <div><label>Cost each (₹, optional)</label><input id="ain_cost" type="number" inputmode="decimal" min="0" placeholder="Blank if not known"></div></div>
      <div class="row nw"><div><label>Supplier (optional)</label><select id="ain_sup"><option value="">–</option>${S.d.suppliers.filter(s => s.code !== '00').map(s => `<option value="${s.id}">${s.code}, ${esc(s.name)}</option>`).join('')}</select></div>
      <div><label>Date</label><input id="ain_date" type="date" value="${todayIN()}" max="${todayIN()}"></div></div>
      <label>Paid by</label>${chips('ain_meth', METHODS, 'Cash')}
      <input id="ain_note" maxlength="300" placeholder="Note (optional)" style="margin-top:8px">
      <button style="width:100%;margin-top:12px;padding:14px" onclick="A.accIn()">Add to stock</button>`
    : accMode === 'adjust' ? `<p class="muted">For damaged, lost or found items, or when the count on the shelf is different.</p>
      <div class="row nw qc"><div><label>Change by (− to take off)</label>${stepper('aadj_qty', -1, -9999)}</div></div>
      <label>Reason</label>${chips('aadj_reason', REASONS, 'Damaged', 'wrap')}
      <input id="aadj_note" maxlength="300" placeholder="Note (optional)" style="margin-top:8px">
      <button style="width:100%;margin-top:12px;padding:14px" onclick="A.accAdjust()">Save adjustment</button>`
    : `<div class="row nw qc"><div><label>How many</label>${stepper('aout_qty', 1, 1)}</div>
      <div><label>Price each (₹)</label><input id="aout_price" type="number" inputmode="decimal" min="0" value="${a.price != null ? +a.price : ''}" placeholder="0"></div></div>
      <label class="tog"><input type="checkbox" id="aout_free" onchange="document.getElementById('aout_price').disabled=this.checked">Free (given, no charge)</label>
      <label>Paid by</label>${chips('aout_meth', METHODS, 'Cash')}
      <div class="row nw"><input id="aout_name" placeholder="Customer (optional)"><input id="aout_mob" type="tel" inputmode="tel" placeholder="Mobile (optional)"></div>
      <input id="aout_note" maxlength="300" placeholder="Note (optional)" style="margin-top:8px">
      <button style="width:100%;margin-top:12px;padding:14px" onclick="A.accOut()">${a.qty ? 'Save' : 'Nothing in stock'}</button>`;
  const h = hist || [];
  openSheet(`<div class="shd"><div class="lhead"><div class="av sq accic">${accIcon(a.name)}</div><div><h2 style="font-size:20px">${esc(a.name)}</h2>
      <p class="muted">${a.price != null ? `Sells at ${rs(a.price)}. ` : ''}Alert at ${a.alert_at}${adm && a.cost != null ? `. Cost ${rs(a.cost)} each` : ''}</p></div></div>
    <div class="hbtns">${kebab([mgr ? ['Edit name, price, alert', 'A.accEdit()'] : null, adm ? ['Delete accessory', 'A.accDelete()', true] : null], 'Accessory actions')}<button class="ghost sm" onclick="A.closeModal()" aria-label="Close">${ICON.x}</button></div></div>
  <div class="accbig${a.low ? ' low' : ''}"><b>${a.qty}</b><span>left${a.low ? ', low stock' : ''}</span></div>
  <div class="seg lottabs">${tabs.map(([k, t]) => `<button class="${accMode === k ? 'on' : ''}" onclick="A.accTab('${k}')">${t}</button>`).join('')}</div>
  <div id="accform">${form}</div>
  <h3 class="sh">History</h3>
  <div class="list flat">${h.length ? h.map(m => `<div class="lrow" style="cursor:default"><span class="cm"><b>${m.kind === 'in' ? `+${m.delta} added` : m.kind === 'out' ? `${-m.delta} ${m.free ? 'given free' : 'sold'}` : `${m.delta > 0 ? '+' : ''}${m.delta} ${esc(m.reason || 'adjusted')}`}</b>
      <span class="muted">${fmtD(m.on)}, ${esc(m.by)}${m.customer ? ', ' + esc(m.customer) : ''}${m.supplier ? ', from ' + esc(m.supplier) : ''}${m.note ? ' – ' + esc(m.note) : ''}</span></span>
      ${m.amount > 0 ? `<b>${rs(m.amount)}</b>` : ''}${adm && m.unit_cost != null ? `<span class="mtag">${rs(m.unit_cost)} each</span>` : ''}</div>`).join('') : '<p class="muted" style="padding:12px">No movements yet.</p>'}</div>`);
}
async function reopen(msg) { await load(); if (msg) toast(msg, 'ok'); if (curAcc && byId(curAcc)) actions.openAccessory(curAcc); }

// ---------- picker: accessories given with a laptop sale ----------
const pick = {};   // prefix → { items: Map(id → {qty, price}), free }
const P = p => pick[p] || (pick[p] = { items: new Map(), free: true });
export function resetPicker(p) { delete pick[p]; }
export function accPicker(p) {
  if (!accs().some(a => a.qty > 0)) return '';
  return `<div class="accgive" id="${p}_acc">${pickerInner(p)}</div>`;
}
function pickerInner(p) {
  const st = P(p), rows = [...st.items.entries()].map(([id, x]) => ({ a: byId(id), ...x })).filter(r => r.a);
  const left = accs().filter(a => a.qty > 0 && !st.items.has(a.id));
  const low = rows.filter(r => r.a.qty - r.qty <= r.a.alert_at).map(r => `${r.a.name} ${r.a.qty - r.qty} left`);
  const extra = st.free ? 0 : rows.reduce((t, r) => t + r.qty * (+r.price || 0), 0);
  return `<h3 class="sh" style="margin-top:14px">Accessories given with this sale</h3>
  ${rows.map(r => `<div class="accrow"><span class="accic">${accIcon(r.a.name)}</span><div class="cm"><b>${esc(r.a.name)}</b><span class="muted">${r.a.qty} in stock</span></div>
    ${st.free ? '' : `<input class="accprice" type="number" inputmode="decimal" min="0" value="${esc(r.price)}" aria-label="Price each" onchange="A.accPickPrice('${p}','${r.a.id}',this.value)">`}
    <div class="stepper sm"><button type="button" onclick="A.accPickStep('${p}','${r.a.id}',-1)" aria-label="One less">−</button><span>${r.qty}</span><button type="button" onclick="A.accPickStep('${p}','${r.a.id}',1)" aria-label="One more">+</button></div></div>`).join('')}
  ${left.length ? `<select class="accadd" onchange="A.accPickAdd('${p}',this.value)"><option value="">+ ${rows.length ? 'Add another accessory' : 'Add an accessory'}</option>${left.map(a => `<option value="${a.id}">${esc(a.name)} (${a.qty} in stock)</option>`).join('')}</select>` : ''}
  ${low.length ? `<div class="accwarn">After this sale: ${esc(low.join(', '))}. You'll get an alert.</div>` : ''}
  ${rows.length ? `<label class="tog"><input type="checkbox" ${st.free ? 'checked' : ''} onchange="A.accPickFree('${p}',this.checked)">Free with the laptops (no extra charge)</label>
    ${!st.free ? `<p class="muted" style="margin-top:4px">${rs(extra)} is added to the bill as extra lines, paid now the same way as the laptop.</p>` : ''}` : ''}`;
}
const redraw = p => { const box = $(p + '_acc'); if (box) box.innerHTML = pickerInner(p); };
export function pickedAccessories(p) {
  const st = pick[p]; if (!st || !st.items.size) return null;
  return { items: [...st.items.entries()].map(([id, x]) => ({ id, qty: x.qty, price_each: st.free ? 0 : +x.price || 0 })), free: st.free };
}
// After the laptop sale is saved: record the accessories on it. A failure here never undoes the sale.
export async function giveWithSale(p, sale, method) {
  const g = pickedAccessories(p); if (!g) return '';
  try {
    await write('give_accessories', { ...sale, p_items: g.items, p_free: g.free, p_method: method || 'Cash' });
    resetPicker(p);
    return `, ${plural(g.items.reduce((t, x) => t + x.qty, 0), 'accessory').replace('accessorys', 'accessories')} given`;
  } catch (e) { toast('The laptop is sold, but the accessories were not saved: ' + e.message); return ''; }
}

export const actions = {
  addAccessory() {
    if (!isMgr()) return toast('Ask the admin or co-admin to add accessories.');
    openSheet(`${sheetHead('Add accessory', 'Chargers, mice, keyboards, bags, anything')}
    <label>Name</label><input id="acc_name" maxlength="80" placeholder="e.g. Charger 65W (Dell)">
    <p class="muted" style="margin-top:6px">Type anything, or tap one:</p>
    <div class="chips wrap">${QUICK.map(q => `<button type="button" onclick="document.getElementById('acc_name').value='${q}';document.getElementById('acc_name').focus()">${q}</button>`).join('')}</div>
    <div class="row nw qc"><div><label>Opening stock</label>${stepper('acc_open', 0)}</div><div><label>Alert me at</label>${stepper('acc_alert', 2)}</div></div>
    <div class="row nw"><div><label>Cost each (₹, optional)</label><input id="acc_cost" type="number" inputmode="decimal" min="0"></div>
      <div><label>Selling price (₹, optional)</label><input id="acc_price" type="number" inputmode="decimal" min="0"></div></div>
    <p class="okhint" style="color:#9A6200" id="acc_hint">You'll get a 🔔 alert when only 2 are left</p>
    <button style="width:100%;margin-top:12px;padding:14px" onclick="A.saveNewAccessory()">Save accessory</button>`);
    $('acc_alert').addEventListener('input', () => { $('acc_hint').textContent = `You'll get a 🔔 alert when only ${+$('acc_alert').value || 0} are left`; });
  },
  accStep(id, d, min) {
    const e = $(id); if (!e) return;
    e.value = Math.max(min, (+e.value || 0) + d); e.dispatchEvent(new Event('input'));
  },
  async saveNewAccessory() {
    const name = val('acc_name'); if (!name) return toast('Enter the name');
    await guard(async () => {
      await write('add_accessory', { p_name: name, p_opening: num('acc_open') || 0, p_alert: num('acc_alert') ?? 2, p_cost: num('acc_cost'), p_price: num('acc_price') });
      closeModal(); await load(); toast(`${name} added`, 'ok');
    });
  },
  async openAccessory(id) {
    curAcc = id; accMode = accMode || 'out';
    renderAcc([]);
    try { const h = await read('accessory_moves_list', { p_id: id }); if (curAcc === id && $('accform')) { const y = $('sheet').scrollTop; renderAcc(h); $('sheet').scrollTop = y; } } catch (e) { /* history is optional */ }
  },
  accTab(m) { accMode = m; actions.openAccessory(curAcc); },
  async accIn() {
    const qty = num('ain_qty'); if (!qty || qty < 1) return toast('Enter how many');
    await guard(async () => {
      await write('accessory_in', { p_id: curAcc, p_qty: qty, p_cost_each: num('ain_cost'), p_supplier_id: val('ain_sup') || null,
        p_on: val('ain_date') || null, p_method: chipVal('ain_meth'), p_note: val('ain_note') });
      await reopen(`${qty} added`);
    });
  },
  async accOut() {
    const a = byId(curAcc), qty = num('aout_qty'); if (!qty || qty < 1) return toast('Enter how many');
    if (qty > a.qty) return toast(`Only ${a.qty} ${a.name} left`);
    const free = $('aout_free').checked;
    await guard(async () => {
      await write('accessory_out', { p_id: curAcc, p_qty: qty, p_price_each: free ? 0 : num('aout_price') || 0, p_free: free,
        p_method: chipVal('aout_meth'), p_customer: val('aout_name'), p_mobile: val('aout_mob'), p_note: val('aout_note') });
      await reopen(`${qty} ${free ? 'given' : 'sold'}. ${a.qty - qty} left`);
    });
  },
  async accAdjust() {
    const d = num('aadj_qty'); if (!d) return toast('Enter how many to add or take off');
    await guard(async () => {
      await write('accessory_adjust', { p_id: curAcc, p_delta: d, p_reason: chipVal('aadj_reason'), p_note: val('aadj_note') });
      await reopen('Adjustment saved');
    });
  },
  accEdit() {
    const a = byId(curAcc); if (!a) return;
    openSheet(`${sheetHead('Edit ' + esc(a.name))}
    <label>Name</label><input id="ae_name" maxlength="80" value="${esc(a.name)}">
    <div class="row nw qc"><div><label>Alert me at</label>${stepper('ae_alert', a.alert_at)}</div>
      <div><label>Selling price (₹)</label><input id="ae_price" type="number" inputmode="decimal" min="0" value="${a.price != null ? +a.price : ''}"></div></div>
    <button style="width:100%;margin-top:14px;padding:14px" onclick="A.accSaveEdit()">Save</button>`);
  },
  async accSaveEdit() {
    await guard(async () => {
      await write('save_accessory', { p_id: curAcc, p_name: val('ae_name'), p_alert: num('ae_alert') ?? 2, p_price: num('ae_price') });
      await reopen('Saved');
    });
  },
  async accDelete() {
    const a = byId(curAcc); if (!a) return;
    if (!await confirmBox(`Delete ${esc(a.name)}?`, 'It leaves the list. Its history stays, and you can restore it from More → Recently deleted for 30 days.', 'Delete', 1)) return;
    await guard(async () => { await write('delete_accessory', { p_id: curAcc }); curAcc = null; closeModal(); await load(); toast(`${a.name} deleted`, 'ok'); });
  },

  // picker
  accPickAdd(p, id) { if (!id) return; const a = byId(id); P(p).items.set(id, { qty: 1, price: a?.price != null ? +a.price : '' }); redraw(p); },
  accPickStep(p, id, d) {
    const st = P(p), x = st.items.get(id), a = byId(id); if (!x || !a) return;
    const q = x.qty + d;
    if (q < 1) st.items.delete(id); else if (q > a.qty) return toast(`Only ${a.qty} ${a.name} in stock`); else x.qty = q;
    redraw(p);
  },
  accPickPrice(p, id, v) { const x = P(p).items.get(id); if (x) x.price = v; redraw(p); },
  accPickFree(p, on) { P(p).free = on; redraw(p); }
};
