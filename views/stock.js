// Stock: lots (with their laptops, expenses, bulk sale) and all laptops (search and filters).
import { $, esc, rs, tag, MON, chips, chipVal, val, num, todayIN, fmtD } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, empty, openSheet, sheetHead, closeModal, confirmBox, dialog, guard, METHODS, kebab } from '../ui/feedback.js';
import { S, load, isAdmin, isMgr, role } from '../api/store.js';
import { read, write } from '../api/client.js';
import { lapName, PROCS, RAMS } from '../ui/specs.js';
import { printStickers } from '../ui/print.js';
import { accessoriesView, accPicker, giveWithSale } from './accessories.js';
import { status, lapRow, owned, atService, ageDays, oldDays, testsPassed, matches, LEADS, noteLine, thumb } from './common.js';

let stockTab = 'lots', stockQ = '', stockF = 'all', openLot = null, spec = { processor: '', ram: '', storage: '' };
const lotExtra = new Map();          // laptops of a lot that are not in the snapshot (old sold ones)
let olderSold = null;                // "Show older" sold laptops

const lotLaptops = lot => {
  const mine = S.d.laptops.filter(l => l.lot_id === lot.id);
  const extra = lotExtra.get(lot.id);
  return extra && extra.length >= mine.length ? extra : mine;
};
const grpLabel = ln => /^Line d+$/.test(ln.label || '') ? 'Laptops' : ln.label === 'Mixed' ? 'Mixed, check later' : ln.label;
const lotTitle = lot => lot.lines.length === 1 ? grpLabel(lot.lines[0]) : `${lot.lines.length} kinds of laptops`;
const kindPill = lot => lot.kind === 'opening' ? '<span class="pill grey">Opening stock</span>' : lot.kind === 'exchange' ? '<span class="pill grey">Exchanged</span>' : '';

function lotsView() {
  const lots = [...S.d.lots].filter(x => x.qty > 0 || x.kind !== 'exchange').reverse();
  return `${isMgr() ? `<button class="addbig" onclick="A.addLot()">${ICON.plus}Add a new lot</button>` : ''}
  ${lots.length ? lots.map(b => {
    const sold = b.sold, pc = b.qty ? sold / b.qty * 100 : 0;
    return `<div class="lot${openLot === b.id ? ' open' : ''}"><div class="lt" onclick="A.toggleLot('${b.id}')">
      <div style="flex:1;min-width:0">${tag(b.prefix)} ${kindPill(b)}${isAdmin() && b.cost_missing ? ' <span class="warnmark">Cost missing</span>' : ''}
      <div class="lm">${esc(lotTitle(b))}</div><div class="muted">${b.supplier_name ? esc(b.supplier_name) + ', ' : ''}${MON[b.month - 1]} ${b.year}${b.note ? ', ' + esc(b.note) : ''}</div></div>
      <div class="right"><b class="wide" style="font-size:20px">${b.qty - sold}</b><div class="muted">left of ${b.qty}</div></div></div>
      <div class="prog"><i style="width:${pc}%"></i></div>
      ${openLot === b.id ? lotDetail(b) : ''}</div>`;
  }).join('') : empty(ICON.stock, 'No lots yet', 'When laptops arrive from a supplier, add them as a lot. Each laptop gets its own QR sticker.')}`;
}

function lotDetail(b) {
  const ls = lotLaptops(b), adm = isAdmin(), mgr = isMgr();
  const canPick = l => owned(l) && !l.booking && !atService(l);
  const avail = ls.filter(canPick);
  const dealers = [...new Map(S.d.laptops.filter(l => l.sale?.customer_type === 'Dealer' && l.sale.mobile).map(l => [l.sale.mobile, l.sale])).values()];
  const menu = kebab([['Print all stickers', `A.printLot('${b.id}')`], mgr && b.kind !== 'exchange' ? ['Add parts / expense', `A.addLotExpense('${b.id}')`] : null,
    adm && b.kind !== 'exchange' ? ['Delete lot', `A.delLot('${b.id}')`, true] : null], 'Lot actions');
  return `<div class="ld" id="bdetail"><div class="ldtop">${menu}</div>
  ${adm ? `<div class="ldm"><span>Lot cost ${b.cost != null ? rs(b.cost) : '–'}</span><span>${b.cost_missing ? `<b style="color:#9A6200">${b.cost_missing} without cost</b>` : 'All costs entered'}</span></div>` : ''}
  <h3 class="sh" style="margin-top:10px">Laptops in this lot</h3><div class="list flat" style="margin-top:8px">${b.lines.map(ln => `<div class="lrow" style="cursor:default"><span class="cm"><b>${esc(grpLabel(ln))}</b><span class="muted">${ln.qty} laptop${ln.qty > 1 ? 's' : ''}</span></span>
    ${adm ? (ln.line_cost != null ? `<b>${rs(ln.line_cost)}</b><span class="muted">${rs(ln.line_cost / ln.qty)} each</span>` : `<button class="sm" onclick="A.fillLineCost('${ln.id}',${ln.qty})">Fill in cost</button>`) : ''}
    ${adm && ln.line_cost != null && b.kind !== 'exchange' ? `<button class="sm ghost" onclick="A.fillLineCost('${ln.id}',${ln.qty})" aria-label="Change cost">✎</button>` : ''}</div>`).join('')}</div>
  <div class="row" style="margin:10px 0"><button class="ghost sm" onclick="A.printLot('${b.id}')">Print all stickers</button>
    ${mgr && b.kind !== 'exchange' ? `<button class="ghost sm" onclick="A.addLotExpense('${b.id}')">Add parts / expense</button>` : ''}
    ${avail.length ? `<button class="ghost sm" onclick="document.querySelectorAll('.pick').forEach(c=>c.checked=!c.checked)">Tick all in stock</button>` : ''}</div>
  ${mgr && b.expenses?.length ? `<h3 class="sh" style="margin-top:6px">Parts and expenses for this lot</h3><div class="list flat">${b.expenses.map(e => `<div class="lrow" style="cursor:default"><span class="cm"><b>${e.count} × ${esc(e.type)}</b><span class="muted">${fmtD(e.spent_on)}${e.line_id ? ', ' + esc(grpLabel(b.lines.find(x => x.id === e.line_id) || {})) : ', all laptops'}</span>${noteLine(e.note, 'lot_expense', e.id)}</span>
     ${e.count > 1 ? `<span class="mtag">${e.units_left} of ${e.count} left</span>` : ''}<b>${rs(e.amount)}</b>${adm ? `<button class="sm ghost" onclick="A.delLotExpense('${e.id}')" aria-label="Delete">${ICON.trash}</button>` : ''}</div>`).join('')}</div>` : ''}
  <div class="list flat" style="margin-top:10px">${ls.map(l => `<div class="lrow">${canPick(l) ? `<input type="checkbox" class="pick" value="${l.id}" aria-label="Select ${esc(l.code)}">` : '<span style="width:20px"></span>'}${thumb(l, '', true)}<span onclick="A.openLaptop('${esc(l.code)}')" style="flex:1;min-width:0">${tag(l.code)}<div class="muted" style="margin-top:4px">${esc(lapName(l))}</div></span>${status(l)}</div>`).join('')}</div>
  ${avail.length ? `<h3 style="margin-top:18px">Sell ticked laptops together</h3><p class="muted">For a dealer or customer taking many laptops. The payment is shared across them, in the order ticked.</p>
  <label>Where the customer came from</label>${chips('llead', LEADS, 'Dealer')}
  ${chips('ltype', ['Retail', 'Dealer'], 'Dealer')}
  ${dealers.length ? `<div class="chips" style="margin-top:2px">${dealers.slice(0, 12).map(s => `<button type="button" onclick="A.fillDealer('${esc(s.name)}','${esc(s.mobile)}')">${esc(s.label)}</button>`).join('')}</div>` : ''}
  <div class="row"><div><label>Name</label><input id="lname"></div><div><label>Mobile</label><input id="lmob" type="tel" inputmode="tel"></div></div>
  <label>Address (optional)</label><input id="ladd">
  <div class="row"><div><label>Price per laptop (₹) *</label><input id="lprice" type="number" inputmode="decimal"></div><div><label>Total paid now (₹)</label><input id="lpaid" type="number" inputmode="decimal"></div></div>
  ${chips('lmeth', METHODS, 'Cash')}<div class="row nw"><input id="lref" placeholder="Ref / UTR (optional)"><input id="lnote" maxlength="300" placeholder="Note (optional)"></div>
  <label>Laptop warranty</label>${chips('lwar', [['0', 'None'], ['3', '3 months'], ['6', '6 months'], ['12', '12 months']], String([0, 3, 6, 12].includes(S.d.settings.default_warranty_months) ? S.d.settings.default_warranty_months : 0))}
  <label>Charger and battery warranty</label>${chips('lacc', [['0', 'None'], ['6', '6 months'], ['12', '12 months']], String([0, 6, 12].includes(S.d.settings.accessory_warranty_months) ? S.d.settings.accessory_warranty_months : 0))}
  <p class="muted" style="margin-top:6px">Mobile is needed for a warranty or if money is still due. One bill for all ticked laptops.</p>
  ${accPicker('l')}
  <button style="width:100%;margin-top:14px" onclick="A.sellLot()">Sell ticked laptops</button>` : ''}</div>`;
}

function laptopsView() {
  const q = (stockQ || '').toLowerCase(), od = oldDays();
  const base = [...S.d.laptops, ...(stockF === 'sold' && olderSold ? olderSold : [])];
  const F = (l, k) => k === 'all' || (k === 'in' && owned(l) && !atService(l)) || (k === 'sold' && l.sale && !(l.sale.due > 0))
    || (k === 'due' && l.sale?.due > 0) || (k === 'res' && !l.sale && l.booking) || (k === 'svc' && atService(l))
    || (k === 'old' && owned(l) && ageDays(l) >= od) || (k === 'untested' && owned(l) && !testsPassed(l));
  const S2 = l => (!spec.processor || l.processor === spec.processor) && (!spec.ram || String(l.ram_gb) === spec.ram)
    && (!spec.storage || String(l.storage_gb) === spec.storage) && (!spec.gen || String(l.gen) === spec.gen);
  let ls = base.filter(l => F(l, stockF) && S2(l));
  if (stockF === 'old') ls.sort((a, b) => ageDays(a) - ageDays(b));
  if (q) ls = ls.filter(l => matches(l, q));
  const n = k => S.d.laptops.filter(l => F(l, k)).length;
  const gens = [...new Set(S.d.laptops.map(l => l.gen).filter(Boolean))].sort((a, b) => a - b);
  const sizes = [...new Set(S.d.laptops.map(l => l.storage_gb).filter(Boolean))].sort((a, b) => a - b);
  const sel = (id, label, opts, cur) => `<select style="flex:1;min-width:0;padding:8px" onchange="A.setSpecF('${id}',this.value)"><option value="">${label}</option>${opts.map(o => `<option ${String(o) === cur ? 'selected' : ''} value="${o}">${o}</option>`).join('')}</select>`;
  return `<input id="sq" class="search" placeholder="Search code, serial, model, i5 8th or customer" value="${esc(stockQ)}" oninput="A.stockSearch(this.value)">
  <div class="chips">${[['all', 'All'], ['in', 'In stock'], ['untested', 'Not tested'], ['old', 'Over ' + od + ' days'], ['res', 'Booked'], ['svc', 'At service'], ['due', 'Money due'], ['sold', 'Sold']].map(([k, t]) => `<button class="${stockF === k ? 'on' : ''}" onclick="A.stockFilter('${k}')">${t} <span>${n(k)}</span></button>`).join('')}</div>
  <div class="row nw" style="gap:6px;margin-bottom:12px">${sel('processor', 'Processor', PROCS.filter(p => p !== 'Other'), spec.processor)}${sel('gen', 'Gen', gens, spec.gen)}${sel('ram', 'RAM', RAMS, spec.ram)}${sel('storage', 'Storage', sizes, spec.storage)}</div>
  <div class="list">${ls.length ? [...ls].reverse().slice(0, 200).map(lapRow).join('') : '<p class="muted" style="padding:18px">No laptops match.</p>'}</div>
  ${stockF === 'sold' && S.d.hidden_sold > 0 && !olderSold ? `<button class="ghost" style="width:100%" onclick="A.showOlderSold()">Show ${S.d.hidden_sold} older sold laptops</button>` : ''}`;
}

export const views = {
  stock() {
    if (!S.d.suppliers.filter(s => s.code !== '00').length && isAdmin() && !S.d.lots.some(x => x.kind !== 'exchange'))
      return empty(ICON.truck, 'Add a supplier first', 'Every lot is linked to a supplier number like 01 or 02.', 'Add supplier', "A.go('suppliers');setTimeout(A.formSupplier,50)");
    const seg = `<div class="seg"><button class="${stockTab === 'lots' ? 'on' : ''}" onclick="A.stockTab('lots')">Lots</button><button class="${stockTab === 'laps' ? 'on' : ''}" onclick="A.stockTab('laps')">All laptops</button><button class="${stockTab === 'acc' ? 'on' : ''}" onclick="A.stockTab('acc')">Accessories</button></div>`;
    return seg + (stockTab === 'laps' ? laptopsView() : stockTab === 'acc' ? accessoriesView() : lotsView());
  }
};

// The "Add a new lot" screen is in addlot.js. After it creates a lot, that lot opens here.
export function showLot(id) { openLot = id; stockTab = 'lots'; }

export const actions = {
  stockTab(t) { stockTab = t; A.refresh(); },
  showAccessories() { stockTab = 'acc'; if (A.view() !== 'stock') A.go('stock'); else A.refresh(); },
  stockFilter(k) { stockTab = 'laps'; stockF = k; if (A.view() !== 'stock') A.go('stock'); else A.refresh(); },
  setSpecF(k, v) { spec[k] = v; A.refresh(); },
  stockSearch(v) { stockQ = v; clearTimeout(window._sq); window._sq = setTimeout(() => { A.refresh(); setTimeout(() => { const e = $('sq'); if (e) { e.focus(); e.setSelectionRange(e.value.length, e.value.length); } }, 30); }, 250); },
  async showOlderSold() { await guard(async () => { olderSold = await read('old_sold_laptops', { p_offset: 0, p_limit: 300 }); olderSold.forEach(l => S.extra.set(l.code, l)); A.refresh(); }); },
  async toggleLot(id) {
    openLot = openLot === id ? null : id; A.refresh();
    const lot = S.lotById.get(id);
    if (openLot && lot && S.d.laptops.filter(l => l.lot_id === id).length < lot.qty && navigator.onLine) {
      try { const all = await read('lot_laptops', { p_lot_id: id }); lotExtra.set(id, all); all.forEach(l => { if (!S.byCode.has(l.code)) S.extra.set(l.code, l); }); A.refresh(); } catch (e) { /* keep what we have */ }
    }
  },
  openLot(id) { stockTab = 'lots'; openLot = null; A.go('stock'); actions.toggleLot(id); setTimeout(() => $('bdetail')?.scrollIntoView({ behavior: 'smooth' }), 300); },
  printLot(id) { const lot = S.lotById.get(id); printStickers(lotLaptops(lot).map(l => l.code)); },
  fillDealer(name, mob) { $('lname').value = name; $('lmob').value = mob; },

  async fillLineCost(lineId, qty) {
    const r = await dialog({ title: 'What did these laptops cost?', body: `Total paid for these ${qty} laptop${qty > 1 ? 's' : ''}. It is shared equally.`, ok: 'Save cost', amount: true, method: false, note: false, allowZero: true });
    if (!r) return;
    await guard(async () => { await write('set_line_cost', { p_line_id: lineId, p_cost: r.amount }); await load(); toast('Cost saved', 'ok'); });
  },
  addLotExpense(lotId) {
    const lot = S.lotById.get(lotId);
    openSheet(`${sheetHead('Add parts / expense', `For lot ${esc(lot.prefix)}. Shared equally across the laptops it applies to.`)}
    <label>What</label>${chips('xtype', ['SSD', 'RAM', 'Battery', 'Charger', 'HDD', 'Keyboard', 'Screen', 'Transport', 'Repair labour', 'Other'], 'SSD', 'wrap')}
    <label>Applies to</label>${chips('xline', [['', 'All laptops in the lot'], ...lot.lines.map(l => [l.id, grpLabel(l)])], '', 'wrap')}
    <div class="row nw"><div><label>How many</label><input id="xcount" type="number" min="1" value="1"></div><div><label>Total amount (₹)</label><input id="xamt" type="number" inputmode="decimal"></div></div>
    ${chips('xmeth', METHODS, 'Cash')}<input id="xref" placeholder="Ref / UTR (optional)">
    <div class="row nw"><div><label>Date</label><input id="xdate" type="date" value="${todayIN()}" max="${todayIN()}"></div><div><label>Note</label><input id="xnote" placeholder="e.g. 240 GB, from SP Road"></div></div>
    <p class="muted" style="margin-top:8px">When one of these parts goes into a laptop, add it there with "Use a part bought for this lot", so it is not counted twice.</p>
    <button style="width:100%;margin-top:14px;padding:14px" onclick="A.saveLotExpense('${lotId}')">Save</button>`);
  },
  async saveLotExpense(lotId) {
    const amt = num('xamt'), cnt = num('xcount');
    if (!amt || amt <= 0) return toast('Enter the amount');
    await guard(async () => {
      await write('add_lot_expense', { p_lot_id: lotId, p_type: chipVal('xtype'), p_count: cnt || 1, p_amount: amt, p_method: chipVal('xmeth'),
        p_line_id: chipVal('xline') || null, p_ref: val('xref'), p_note: val('xnote'), p_spent_on: val('xdate') || null });
      closeModal(); await load(); toast('Expense saved', 'ok');
    });
  },
  // Delete a lot (admin): only when none of its laptops has a customer or service history. Type the lot code to confirm.
  async delLot(id) {
    let chk; try { chk = await read('delete_lot_check', { p_lot_id: id }); } catch (e) { return toast(e.message); }
    if (chk.blockers.length) {
      return dialog({ title: `Lot ${esc(chk.prefix)} cannot be deleted`, ok: 'OK',
        body: `These laptops have a customer or service history, so they stay:`,
        html: `<div class="list flat blk">${chk.blockers.slice(0, 12).map(x => `<div class="lrow" style="cursor:default"><span class="cm">${tag(x.code)}<span class="muted" style="display:block;margin-top:4px">${esc(x.reason)}</span></span></div>`).join('')}${chk.blockers.length > 12 ? `<p class="muted" style="padding:8px">and ${chk.blockers.length - 12} more</p>` : ''}</div>` });
    }
    const typed = await dialog({ title: `Delete lot ${esc(chk.prefix)}?`, ok: 'Delete lot', danger: true, text: true, placeholder: chk.prefix,
      body: `Its ${chk.laptops} laptop${chk.laptops === 1 ? '' : 's'}${chk.expenses ? ` and ${chk.expenses} expense${chk.expenses === 1 ? '' : 's'}` : ''} go with it, to More → Recently deleted for 30 days. Its sticker numbers are never used again.<br><br>Type <b>${esc(chk.prefix)}</b> to confirm.` });
    if (typed == null) return;
    if (typed.trim() !== chk.prefix) return toast(`Type ${chk.prefix} exactly to delete the lot`);
    await guard(async () => {
      const r = await write('delete_lot', { p_lot_id: id, p_confirm: typed.trim() });
      openLot = null; await load();
      toast(`Lot ${r.prefix} deleted with ${r.laptops} laptop${r.laptops === 1 ? '' : 's'}. You can restore it from More → Recently deleted.`, 'ok');
    });
  },
  async delLotExpense(id) {
    if (!await confirmBox('Delete this expense?', 'It is removed from the lot\'s cost.', 'Delete', 1)) return;
    await guard(async () => { await write('delete_lot_expense', { p_id: id }); await load(); });
  },
  async sellLot() {
    const ids = [...document.querySelectorAll('.pick:checked')].map(c => c.value);
    const price = num('lprice'), paid = num('lpaid') || 0;
    if (!ids.length) return toast('Tick at least one laptop');
    if (!price) return toast('Enter the price per laptop');
    const args = { p_laptop_ids: ids, p_price_each: price, p_total_paid: paid, p_method: chipVal('lmeth'), p_ref: val('lref'), p_note: val('lnote'),
      p_warranty_months: +chipVal('lwar'), p_accessory_warranty_months: +chipVal('lacc'),
      p_lead_source: chipVal('llead'), p_customer_type: chipVal('ltype'), p_name: val('lname'), p_mobile: val('lmob'), p_address: val('ladd') };
    await guard(async () => {
      let r;
      try { r = await write('sell_laptops_bulk', args); }
      catch (e) {
        if (e.hint !== 'confirm_tests') throw e;
        if (!await confirmBox('Not every test has passed', esc(e.message), 'Sell anyway', 1)) return;
        r = await write('sell_laptops_bulk', { ...args, p_override_tests: true });
      }
      const accMsg = await giveWithSale('l', { p_bulk_group: r.bulk_group }, args.p_method);
      await load();
      toast(`${r.count} laptops sold on bill INV-${r.invoice_no}. Total ${rs(r.total)}, balance ${rs(r.balance)}${accMsg}`, 'ok');
    });
  }
};
