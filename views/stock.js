// Stock: lots (with lines, expenses, bulk sale) and all laptops (search and filters).
import { $, esc, rs, tag, MON, pad, sum, chips, chipVal, val, num, todayIN, fmtD, multiChips } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, empty, openSheet, sheetHead, closeModal, confirmBox, dialog, guard, METHODS } from '../ui/feedback.js';
import { S, load, isAdmin, isMgr, role } from '../api/store.js';
import { read, write } from '../api/client.js';
import { specEditor, wireSpecEditor, readSpecs, shorthand, lapName, PROCS, RAMS } from '../ui/specs.js';
import { printStickers } from '../ui/print.js';
import { status, lapRow, owned, atService, ageDays, oldDays, testsPassed, matches, LEADS } from './common.js';

let stockTab = 'lots', stockQ = '', stockF = 'all', openLot = null, spec = { processor: '', ram: '', storage: '' };
const lotExtra = new Map();          // laptops of a lot that are not in the snapshot (old sold ones)
let olderSold = null;                // "Show older" sold laptops

const lotLaptops = lot => {
  const mine = S.d.laptops.filter(l => l.lot_id === lot.id);
  const extra = lotExtra.get(lot.id);
  return extra && extra.length >= mine.length ? extra : mine;
};
const lotTitle = lot => lot.lines.length === 1 ? lot.lines[0].label : `${lot.lines.length} models`;
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
  return `<div class="ld" id="bdetail">
  ${adm ? `<div class="ldm"><span>Lot cost ${b.cost != null ? rs(b.cost) : '–'}</span><span>${b.cost_missing ? `<b style="color:#9A6200">${b.cost_missing} without cost</b>` : 'All costs entered'}</span></div>` : ''}
  <div class="list flat" style="margin-top:8px">${b.lines.map(ln => `<div class="lrow" style="cursor:default"><span class="cm"><b>${esc(ln.label)}</b><span class="muted">${ln.qty} laptop${ln.qty > 1 ? 's' : ''}</span></span>
    ${adm ? (ln.line_cost != null ? `<b>${rs(ln.line_cost)}</b><span class="muted">${rs(ln.line_cost / ln.qty)} each</span>` : `<button class="sm" onclick="A.fillLineCost('${ln.id}',${ln.qty})">Fill in cost</button>`) : ''}
    ${adm && ln.line_cost != null && b.kind !== 'exchange' ? `<button class="sm ghost" onclick="A.fillLineCost('${ln.id}',${ln.qty})" aria-label="Change cost">✎</button>` : ''}</div>`).join('')}</div>
  <div class="row" style="margin:10px 0"><button class="ghost sm" onclick="A.printLot('${b.id}')">Print all stickers</button>
    ${mgr && b.kind !== 'exchange' ? `<button class="ghost sm" onclick="A.addLotExpense('${b.id}')">Add parts / expense</button>` : ''}
    ${avail.length ? `<button class="ghost sm" onclick="document.querySelectorAll('.pick').forEach(c=>c.checked=!c.checked)">Tick all in stock</button>` : ''}</div>
  ${mgr && b.expenses?.length ? `<h3 class="sh" style="margin-top:6px">Parts and expenses for this lot</h3><div class="list flat">${b.expenses.map(e => `<div class="lrow" style="cursor:default"><span class="cm"><b>${e.count} × ${esc(e.type)}</b><span class="muted">${fmtD(e.spent_on)}${e.line_id ? ', ' + esc(b.lines.find(x => x.id === e.line_id)?.label || '') : ', all laptops'}${e.note ? ', ' + esc(e.note) : ''}</span></span>
     ${e.count > 1 ? `<span class="mtag">${e.units_left} of ${e.count} left</span>` : ''}<b>${rs(e.amount)}</b>${adm ? `<button class="sm ghost" onclick="A.delLotExpense('${e.id}')" aria-label="Delete">${ICON.trash}</button>` : ''}</div>`).join('')}</div>` : ''}
  <div class="list flat" style="margin-top:10px">${ls.map(l => `<div class="lrow">${canPick(l) ? `<input type="checkbox" class="pick" value="${l.id}" aria-label="Select ${esc(l.code)}">` : '<span style="width:20px"></span>'}<span onclick="A.openLaptop('${esc(l.code)}')" style="flex:1;min-width:0">${tag(l.code)}<div class="muted" style="margin-top:4px">${esc(lapName(l))}</div></span>${status(l)}</div>`).join('')}</div>
  ${avail.length ? `<h3 style="margin-top:18px">Sell ticked laptops together</h3><p class="muted">For a dealer or customer taking many laptops. The payment is shared across them, in the order ticked.</p>
  <label>Where the customer came from</label>${chips('llead', LEADS, 'Dealer')}
  ${chips('ltype', ['Retail', 'Dealer'], 'Dealer')}
  ${dealers.length ? `<div class="chips" style="margin-top:2px">${dealers.slice(0, 12).map(s => `<button type="button" onclick="A.fillDealer('${esc(s.name)}','${esc(s.mobile)}')">${esc(s.label)}</button>`).join('')}</div>` : ''}
  <div class="row"><div><label>Name</label><input id="lname"></div><div><label>Mobile</label><input id="lmob" type="tel" inputmode="tel"></div></div>
  <label>Address (optional)</label><input id="ladd">
  <div class="row"><div><label>Price per laptop (₹) *</label><input id="lprice" type="number" inputmode="decimal"></div><div><label>Total paid now (₹)</label><input id="lpaid" type="number" inputmode="decimal"></div></div>
  ${chips('lmeth', METHODS, 'Cash')}<input id="lref" placeholder="Ref / UTR (optional)">
  <p class="muted" style="margin-top:6px">Mobile is needed if money is still due. Warranty: the shop's default (${S.d.settings.default_warranty_months} months) when a mobile is given.</p>
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
    const seg = `<div class="seg"><button class="${stockTab === 'lots' ? 'on' : ''}" onclick="A.stockTab('lots')">Lots</button><button class="${stockTab === 'laps' ? 'on' : ''}" onclick="A.stockTab('laps')">All laptops</button></div>`;
    return seg + (stockTab === 'laps' ? laptopsView() : lotsView());
  }
};

// ---------- add lot (header + lines) ----------
let draft = null;
const newLine = () => ({ is_mixed: false, specs: {}, qty: '', cost: '' });
function captureLines() {
  if (!draft) return;
  draft.supplier = val('bsup'); draft.lot_no = val('bno'); draft.date = val('bdate'); draft.note = val('bnote');
  draft.kind = $('bopen')?.checked ? 'opening' : 'purchase';
  draft.lines.forEach((ln, i) => {
    if (!$(`ln${i}_qty`)) return;
    ln.is_mixed = $(`ln${i}_mixed`).checked;
    if (!ln.is_mixed) ln.specs = readSpecs(`ln${i}_`);
    ln.qty = val(`ln${i}_qty`); ln.cost = val(`ln${i}_cost`);
  });
}
function nextLotNo(supId) { return S.d.lots.filter(x => x.supplier_id === supId).reduce((m, x) => Math.max(m, x.lot_no), 0) + 1; }
function renderLotForm() {
  const sups = S.d.suppliers.filter(s => s.code !== '00');
  const d = draft;
  openSheet(`${sheetHead('Add a new lot', 'Each laptop gets its own QR sticker')}
  <label>Supplier</label><select id="bsup" onchange="A.lotSupChanged()">${sups.map(s => `<option value="${s.id}" ${s.id === d.supplier ? 'selected' : ''}>${s.code}, ${esc(s.name)}</option>`).join('')}</select>
  <div class="row nw"><div><label>Lot no.</label><input id="bno" type="number" min="1" max="99" value="${esc(d.lot_no)}" oninput="A.lotPrev()"></div>
  <div style="flex:2"><label>Purchase date</label><input id="bdate" type="date" value="${esc(d.date)}" max="${todayIN()}" onchange="A.lotPrev()"></div></div>
  <label class="tog"><input type="checkbox" id="bopen" ${d.kind === 'opening' ? 'checked' : ''}>Opening stock (laptops the shop had before this app)</label>
  <label>Note (optional)</label><input id="bnote" value="${esc(d.note || '')}" placeholder="e.g. bought at Hyderabad expo">
  ${d.lines.map((ln, i) => `<div class="lineed"><div class="lh"><span>Line ${i + 1}</span>${d.lines.length > 1 ? `<button class="sm ghost" onclick="A.lotRemoveLine(${i})" aria-label="Remove line">${ICON.x}</button>` : ''}</div>
    <label class="tog"><input type="checkbox" id="ln${i}_mixed" ${ln.is_mixed ? 'checked' : ''} onchange="A.lotToggleMixed(${i})">Mixed lot (models known only after checking)</label>
    ${ln.is_mixed ? '' : specEditor(`ln${i}_`, ln.specs)}
    <div class="row nw"><div><label>No. of laptops</label><input id="ln${i}_qty" type="number" min="1" value="${esc(ln.qty)}" oninput="A.lotPrev()"></div>
    <div><label>Cost of this line (₹)</label><input id="ln${i}_cost" type="number" min="0" inputmode="decimal" placeholder="Blank if not known" value="${esc(ln.cost)}" oninput="A.lotPrev()"></div></div></div>`).join('')}
  <button class="ghost" style="width:100%;margin-top:10px" onclick="A.lotAddLine()">${ICON.plus}Add line</button>
  <div class="prev" id="lotprev"></div>
  <button style="width:100%;margin-top:14px;padding:14px" onclick="A.createLot()">Create lot and stickers</button>`);
  d.lines.forEach((ln, i) => { if (!ln.is_mixed) wireSpecEditor(`ln${i}_`); });
  actions.lotPrev();
}

export const actions = {
  stockTab(t) { stockTab = t; A.refresh(); },
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

  addLot() {
    if (!isMgr()) return toast('Ask the admin or co-admin to add lots.');
    const sups = S.d.suppliers.filter(s => s.code !== '00');
    if (!sups.length) { toast('Add a supplier first'); return A.go('suppliers'); }
    draft = { supplier: sups[0].id, lot_no: nextLotNo(sups[0].id), date: todayIN(), kind: 'purchase', note: '', lines: [newLine()] };
    renderLotForm();
  },
  lotSupChanged() { captureLines(); draft.lot_no = nextLotNo(draft.supplier); renderLotForm(); },
  lotAddLine() { captureLines(); draft.lines.push(newLine()); renderLotForm(); setTimeout(() => $(`ln${draft.lines.length - 1}_mixed`)?.scrollIntoView({ block: 'center' }), 50); },
  lotRemoveLine(i) { captureLines(); draft.lines.splice(i, 1); renderLotForm(); },
  lotToggleMixed() { captureLines(); renderLotForm(); },
  lotPrev() {
    const s = S.supById.get(val('bsup')), no = +val('bno') || 1, dt = val('bdate') || todayIN();
    if (!s || !$('lotprev')) return;
    const qty = draft.lines.reduce((t, _, i) => t + (+val(`ln${i}_qty`) || 0), 0);
    const costs = draft.lines.map((_, i) => val(`ln${i}_cost`));
    const p = `${s.code}-${pad(no, 2)}-${dt.slice(5, 7)}-${dt.slice(2, 4)}`;
    $('lotprev').innerHTML = `<span class="muted">Stickers will read</span><div style="margin:6px 0">${tag(p + '-001')}${qty > 1 ? ` <span class="muted">to</span> ${tag(p + '-' + pad(qty, 3))}` : ''}</div>
      <span class="muted">${qty} laptops${costs.every(c => c !== '') && qty ? `, total cost ${rs(sum(costs))}` : costs.some(c => c !== '') ? `, cost entered for some lines` : ', cost to be filled in later'}</span>`;
  },
  async createLot() {
    captureLines();
    const lines = [];
    for (const [i, ln] of draft.lines.entries()) {
      const qty = +ln.qty;
      if (!qty || qty < 1) return toast(`Line ${i + 1}: enter the number of laptops`);
      if (!ln.is_mixed && !shorthand(ln.specs) && !ln.specs.model) return toast(`Line ${i + 1}: pick the brand and specs, or tick Mixed lot`);
      lines.push({ is_mixed: ln.is_mixed, ...(ln.is_mixed ? {} : ln.specs), qty, cost: ln.cost === '' ? null : +ln.cost });
    }
    await guard(async () => {
      const r = await write('create_lot', { p_supplier_id: draft.supplier, p_lot_no: +draft.lot_no, p_bought_on: draft.date, p_lines: lines, p_kind: draft.kind, p_note: draft.note });
      openLot = r.lot_id; stockTab = 'lots'; closeModal(); await load();
      toast(`Lot ${r.prefix} created with ${r.qty} stickers`, 'ok');
      if (A.view() !== 'stock') A.go('stock');
      if (await confirmBox('Print the stickers now?', `${r.qty} QR stickers for lot ${r.prefix}, 4 per row on A4 gum paper.`, 'Print')) printStickers(r.codes);
    });
  },
  async fillLineCost(lineId, qty) {
    const r = await dialog({ title: 'What did this line cost?', body: `Total paid for these ${qty} laptop${qty > 1 ? 's' : ''}. It is shared equally.`, ok: 'Save cost', amount: true, method: false, allowZero: true });
    if (!r) return;
    await guard(async () => { await write('set_line_cost', { p_line_id: lineId, p_cost: r.amount }); await load(); toast('Cost saved', 'ok'); });
  },
  addLotExpense(lotId) {
    const lot = S.lotById.get(lotId);
    openSheet(`${sheetHead('Add parts / expense', `For lot ${esc(lot.prefix)}. Shared equally across the laptops it applies to.`)}
    <label>What</label>${chips('xtype', ['SSD', 'RAM', 'Battery', 'Charger', 'HDD', 'Keyboard', 'Screen', 'Transport', 'Repair labour', 'Other'], 'SSD', 'wrap')}
    <label>Applies to</label>${chips('xline', [['', 'All laptops in the lot'], ...lot.lines.map(l => [l.id, l.label])], '', 'wrap')}
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
  async delLotExpense(id) {
    if (!await confirmBox('Delete this expense?', 'It is removed from the lot\'s cost.', 'Delete', 1)) return;
    await guard(async () => { await write('delete_lot_expense', { p_id: id }); await load(); });
  },
  async sellLot() {
    const ids = [...document.querySelectorAll('.pick:checked')].map(c => c.value);
    const price = num('lprice'), paid = num('lpaid') || 0;
    if (!ids.length) return toast('Tick at least one laptop');
    if (!price) return toast('Enter the price per laptop');
    const args = { p_laptop_ids: ids, p_price_each: price, p_total_paid: paid, p_method: chipVal('lmeth'), p_ref: val('lref'),
      p_lead_source: chipVal('llead'), p_customer_type: chipVal('ltype'), p_name: val('lname'), p_mobile: val('lmob'), p_address: val('ladd') };
    await guard(async () => {
      let r;
      try { r = await write('sell_laptops_bulk', args); }
      catch (e) {
        if (e.hint !== 'confirm_tests') throw e;
        if (!await confirmBox('Not every test has passed', esc(e.message), 'Sell anyway', 1)) return;
        r = await write('sell_laptops_bulk', { ...args, p_override_tests: true });
      }
      await load();
      toast(`${r.count} laptops sold. Total ${rs(r.total)}, balance ${rs(r.balance)}`, 'ok');
    });
  }
};
