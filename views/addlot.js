// Add a new lot, shopping-cart style: pick a laptop type, say how many, add it, repeat.
// Each group the dealer adds becomes one lot_lines row in create_lot (the word "line" is never shown).
import { $, esc, rs, tag, pad, todayIN } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, openSheet, sheetHead, closeModal, confirmBox, guard } from '../ui/feedback.js';
import { S, load, isMgr } from '../api/store.js';
import { write } from '../api/client.js';
import { shorthand } from '../ui/specs.js';
import { printStickers } from '../ui/print.js';
import { showLot } from './stock.js';

const BRANDS = ['Dell', 'HP', 'Lenovo', 'Acer', 'Asus', 'Apple', 'Other'];
const MIX_BRANDS = ['Dell', 'HP', 'Lenovo', 'Acer', 'Asus', 'Apple'];
// [chips always shown, chips behind "+"]
const ROWS = {
  processor: [['i3', 'i5', 'i7', 'Pentium', 'Celeron', 'Ryzen 5', 'Other'], ['i9', 'Ryzen 3', 'Ryzen 7']],
  gen: [[4, 5, 6, 7, 8, 10, 11, 12], [2, 3, 9, 13]],
  ram_gb: [[4, 8, 16, 32], [6, 12]],
  storage_gb: [[128, 256, 512, 1000], [120, 240, 320, 500]]
};
const MAX_QTY = 500, MAX_GROUPS = 99;
const ord = n => (n % 100 >= 11 && n % 100 <= 13) ? n + 'th' : n + (['th', 'st', 'nd', 'rd'][n % 10] || 'th');
const sizeText = z => z >= 1000 && z % 1000 === 0 ? z / 1000 + ' TB' : String(z);
const chipText = (k, v) => k === 'gen' ? ord(v) : k === 'ram_gb' ? v + ' GB' : k === 'storage_gb' ? sizeText(v) : v;
const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;

let D = null;   // the lot being built
const blankForm = (brand = null) => ({ brand, brand_other: '', processor: null, processor_other: '', gen: null, ram_gb: null,
  storage_type: 'SSD', storage_gb: null, model: '', qty: 1, cost: '' });
const blankMixed = () => ({ qty: 1, cost: '', brands: [] });

// ---------- helpers ----------
const sheetY = fn => { const s = $('sheet'), y = s ? s.scrollTop : 0; fn(); if (s) s.scrollTop = y; };   // no jumping
const cleanQty = v => Math.min(MAX_QTY, Math.max(1, Math.floor(+v) || 1));
const costNum = c => c === '' || c == null || isNaN(+c) ? null : Math.round(+c * 100) / 100;
const specsOf = f => ({ brand: f.brand, brand_other: f.brand === 'Other' ? f.brand_other.trim() : '', model: f.model.trim(),
  processor: f.processor, processor_other: f.processor === 'Other' ? f.processor_other.trim() : '',
  gen: f.gen, ram_gb: f.ram_gb, storage_type: f.storage_type, storage_gb: f.storage_gb });
const formReady = f => !!(f.brand && f.processor && (f.brand !== 'Other' || f.brand_other.trim()) && (f.processor !== 'Other' || f.processor_other.trim()));
const groupTitle = it => it.is_mixed ? 'Mixed, check later' : shorthand(it.specs) || 'Laptops';
const prefix = () => {
  const s = S.supById.get(D.supplier), dt = D.date || todayIN();
  return s ? `${s.code}-${pad(+D.lot_no || 1, 2)}-${dt.slice(5, 7)}-${dt.slice(2, 4)}` : '';
};
const total = () => D.items.reduce((t, it) => t + it.qty, 0);
// Deleted lots count too (max_lot_no), so their sticker numbers are never used again
const nextLotNo = supId => Math.max(S.supById.get(supId)?.max_lot_no || 0, S.d.lots.filter(x => x.supplier_id === supId).reduce((m, x) => Math.max(m, x.lot_no), 0)) + 1;

// Most-bought specs of the last 90 days, from the lots' groups, weighted by how many laptops.
function quickList() {
  const since = new Date(Date.now() - 90 * 864e5).toISOString().slice(0, 10), m = new Map();
  for (const lot of S.d.lots) {
    if (lot.kind === 'exchange' || !lot.bought_on || lot.bought_on < since) continue;
    for (const ln of lot.lines || []) {
      if (ln.is_mixed || !ln.brand || !ln.processor) continue;
      const sp = { brand: ln.brand, brand_other: ln.brand_other || '', processor: ln.processor, processor_other: ln.processor_other || '',
        gen: ln.gen, ram_gb: ln.ram_gb, storage_type: ln.storage_type || 'SSD', storage_gb: ln.storage_gb };
      const key = JSON.stringify(sp), e = m.get(key) || { specs: sp, n: 0, models: new Map() };
      e.n += ln.qty || 1;
      if (ln.model) e.models.set(ln.model, (e.models.get(ln.model) || 0) + (ln.qty || 1));
      m.set(key, e);
    }
  }
  return [...m.values()].sort((a, b) => b.n - a.n).slice(0, 8)
    .map(e => ({ specs: e.specs, model: [...e.models].sort((a, b) => b[1] - a[1])[0]?.[0] || '', label: shorthand(e.specs) }));
}

// ---------- the add card ----------
function chipRow(k) {
  const f = D.f, cur = f[k], [main, more] = ROWS[k];
  const open = D.more[k] || more.includes(cur) || (k === 'storage_gb' && cur != null && !main.includes(cur));
  const list = open ? [...main, ...more] : main;
  const b = v => `<button type="button" class="${String(cur) === String(v) ? 'on' : ''}" onclick="A.lcPick('${k}','${v}')">${esc(chipText(k, v))}</button>`;
  return `${list.map(b).join('')}${open ? '' : `<button type="button" class="plus" onclick="A.lcMore('${k}')" aria-label="More choices">+</button>`}`;
}
function knownCard() {
  const f = D.f, sizeOther = f.storage_gb != null && ![...ROWS.storage_gb[0], ...ROWS.storage_gb[1]].includes(f.storage_gb);
  return `<div class="lcrow"><span>Brand</span><div class="chips wrap" id="lcr_brand">${BRANDS.map(v => `<button type="button" class="${f.brand === v ? 'on' : ''}" onclick="A.lcPick('brand','${v}')">${v}</button>`).join('')}</div>
    <input class="sm ${f.brand === 'Other' ? '' : 'hidden'}" id="lc_brand_other" placeholder="Brand name" value="${esc(f.brand_other)}" oninput="A.lcSet('brand_other',this.value)"></div>
  <div class="lcrow"><span>Processor</span><div class="chips wrap" id="lcr_processor">${chipRow('processor')}</div>
    <input class="sm ${f.processor === 'Other' ? '' : 'hidden'}" id="lc_processor_other" placeholder="Processor" value="${esc(f.processor_other)}" oninput="A.lcSet('processor_other',this.value)"></div>
  <div class="lcrow"><span>Generation</span><div class="chips wrap" id="lcr_gen">${chipRow('gen')}</div></div>
  <div class="lcrow"><span>RAM</span><div class="chips wrap" id="lcr_ram_gb">${chipRow('ram_gb')}</div></div>
  <div class="lcrow"><span>Storage</span><div class="chips wrap" id="lcr_storage">
    ${['SSD', 'HDD'].map(v => `<button type="button" class="${f.storage_type === v ? 'on' : ''}" onclick="A.lcPick('storage_type','${v}')">${v}</button>`).join('')}<i class="gap"></i><span id="lcr_storage_gb" class="chipset">${chipRow('storage_gb')}</span></div>
    <input class="sm ${D.more.storage_gb || sizeOther ? '' : 'hidden'}" id="lc_size_other" type="number" inputmode="numeric" placeholder="Other size in GB" value="${sizeOther ? f.storage_gb : ''}" oninput="A.lcSize(this.value)"></div>
  <label>Model (optional)</label><input id="lc_model" placeholder="e.g. Latitude 5490" value="${esc(f.model)}" oninput="A.lcSet('model',this.value)">
  ${qtyCost('f')}
  <button id="lc_add" class="addgrp" onclick="A.lcAdd()"></button>`;
}
function mixedCard() {
  const m = D.m;
  return `<div class="mixhelp"><b>Mixed laptops</b><p class="muted">For a big lot where you don't know each model yet. Brand, processor, RAM and storage are filled in for each laptop when you test it.</p></div>
  ${qtyCost('m')}
  <div class="lcrow"><span>Brands in this lot (optional)</span><div class="chips wrap" id="lcr_mbrands">${MIX_BRANDS.map(v => `<button type="button" class="${m.brands.includes(v) ? 'on' : ''}" onclick="A.lmBrand('${v}')">${v}</button>`).join('')}</div></div>
  <button id="lc_add" class="addgrp" onclick="A.lcAdd()"></button>`;
}
function qtyCost(w) {
  const o = D[w];
  return `<div class="row nw qc"><div><label>How many</label><div class="stepper"><button type="button" onclick="A.lcStep('${w}',-1)" aria-label="One less">−</button>
    <input id="lc_qty" type="number" inputmode="numeric" min="1" max="${MAX_QTY}" value="${o.qty}" oninput="A.lcQty('${w}',this.value)" onblur="this.value=A.lcQtyNow()">
    <button type="button" onclick="A.lcStep('${w}',1)" aria-label="One more">+</button></div></div>
  <div><label id="lc_costlbl">Cost (₹)</label>
    <input id="lc_cost" type="number" inputmode="decimal" min="0" placeholder="Blank if not known" value="${esc(o.cost)}" oninput="A.lcCost('${w}',this.value)"></div></div>
  <div class="okhint" id="lc_each"></div>`;
}
function renderCard() {
  const box = $('lotcard'); if (!box) return;
  if (!D.open) { box.innerHTML = ''; return; }
  const q = D.quick;
  box.innerHTML = `<div class="lotcard${D.edit != null ? ' editing' : ''}">
    <div class="lch"><span><i class="stepno">1</i>${D.edit != null ? 'Change these laptops' : 'Add laptops to this lot'}</span>
      ${D.items.length || D.edit != null ? `<button class="sm ghost" onclick="A.lcClose()">${D.edit != null ? 'Cancel' : 'Close'}</button>` : ''}</div>
    <p class="muted" style="margin:2px 0 10px">Choose the details, set how many, then tap Add.</p>
    <div class="seg lottabs"><button class="${D.mode === 'known' ? 'on' : ''}" onclick="A.lcMode('known')">I know the models</button><button class="${D.mode === 'mixed' ? 'on' : ''}" onclick="A.lcMode('mixed')">Mixed, check later</button></div>
    ${D.mode === 'known' ? knownCard() : mixedCard()}</div>
  ${q.length ? `<div class="lquick"><h3>Quick add, same as last time</h3><div class="chips wrap">${q.map((x, i) => `<button type="button" onclick="A.lcQuick(${i})">${esc(x.label)}</button>`).join('')}</div>
    <p class="muted">Tap one to fill in all its details, then set how many.</p></div>` : ''}`;
  updateCard();
}
// Button label, cost label and the "each" figure, without redrawing the card
function updateCard() {
  const btn = $('lc_add'); if (!btn) return;
  const w = D.mode === 'known' ? 'f' : 'm', o = D[w], c = costNum(o.cost);
  const lbl = $('lc_costlbl');
  if (lbl) lbl.textContent = w === 'm' ? 'Cost for all (₹)' : o.qty > 1 ? `Cost for these ${o.qty} (₹)` : 'Cost (₹)';
  const each = $('lc_each');
  if (each) each.textContent = c != null && c > 0 && o.qty > 1 ? `${rs(c / o.qty)} each${w === 'm' ? ' on average' : ''}` : '';
  if (w === 'f') {
    const ok = formReady(D.f), sh = shorthand(specsOf(D.f));
    btn.disabled = !ok;
    btn.textContent = !ok ? 'Pick at least the brand and processor'
      : `${D.edit != null ? 'Save' : '+ Add'} ${o.qty} × ${sh}${D.edit != null ? '' : ' to lot'}`;
  } else {
    btn.disabled = false;
    btn.textContent = D.edit != null ? `Save ${plural(o.qty, 'mixed laptop')}` : `+ Add ${plural(o.qty, 'mixed laptop')} to lot`;
  }
}

// ---------- the list, summary and create button ----------
function renderList() {
  const box = $('lotlist'); if (!box) return;
  const n = total(), withCost = D.items.filter(it => it.cost != null), sumCost = withCost.reduce((t, it) => t + it.cost, 0);
  const noCost = D.items.filter(it => it.cost == null), noCostN = noCost.reduce((t, it) => t + it.qty, 0);
  const p = prefix();
  box.innerHTML = `<div class="lothead"><span><i class="stepno">2</i>In this lot</span><span class="muted">${plural(n, 'laptop')}</span></div>
  ${D.items.length ? D.items.map((it, i) => {
    const sub = it.is_mixed ? ['Models filled in after testing', it.brands?.length ? it.brands.join(', ') : ''] : [it.specs.model];
    const cost = it.cost == null ? '<span class="nocost">cost not entered</span>'
      : esc(rs(it.cost) + (it.qty > 1 ? ` (${rs(it.cost / it.qty)} each)` : ''));
    return `<div class="grp${D.edit === i ? ' ed' : ''}"><div class="qx">${it.qty}×</div>
      <div class="gt"><b>${esc(groupTitle(it))}</b><span>${[...sub.filter(Boolean).map(esc), cost].join(' · ')}</span></div>
      <button class="ib2" onclick="A.lcEdit(${i})" aria-label="Change">✎</button><button class="ib2" onclick="A.lcDel(${i})" aria-label="Remove">${ICON.trash}</button></div>`;
  }).join('') : '<p class="muted" style="padding:10px 2px">Nothing added yet. Pick the laptops above and tap Add.</p>'}
  ${!D.open ? `<button class="ghost addmore" onclick="A.lcOpen()">${ICON.plus}Add more laptops</button>` : ''}
  ${n ? `<div class="prev lotsum"><span class="muted">Stickers will read</span><div style="margin:6px 0">${tag(p + '-001')}${n > 1 ? ` <span class="muted">to</span> ${tag(p + '-' + pad(n, 3))}` : ''}</div>
    <div class="sumrow"><b>${plural(n, 'laptop')}</b><b>${withCost.length ? rs(sumCost) : ''}</b></div>
    ${noCostN ? `<span class="muted">${noCostN} ${noCost.every(it => it.is_mixed) ? 'mixed ' : ''}${noCostN === 1 ? 'laptop has' : 'laptops have'} no cost yet. You can add it later.</span>` : ''}</div>` : ''}`;
  const cb = $('lotcreate');
  if (cb) { cb.disabled = !n; cb.textContent = n ? `Create lot and print ${plural(n, 'sticker')}` : 'Add laptops to create the lot'; }
}
function renderAll() { sheetY(() => { renderCard(); renderList(); }); }

function openForm() {
  const sups = S.d.suppliers.filter(s => s.code !== '00');
  openSheet(`${sheetHead('Add a new lot', 'Pick the laptops you bought. Each gets its own QR sticker.')}
  <label>Supplier</label><select id="bsup" onchange="A.lotSup(this.value)">${sups.map(s => `<option value="${s.id}" ${s.id === D.supplier ? 'selected' : ''}>${s.code}, ${esc(s.name)}</option>`).join('')}</select>
  <div class="row nw"><div><label>Lot no.</label><input id="bno" type="number" min="1" max="99" value="${esc(D.lot_no)}" oninput="A.lotHead('lot_no',this.value)"></div>
  <div style="flex:2"><label>Purchase date</label><input id="bdate" type="date" value="${esc(D.date)}" max="${todayIN()}" onchange="A.lotHead('date',this.value)"></div></div>
  <div id="lotcard"></div>
  <div id="lotlist"></div>
  <label class="tog"><input type="checkbox" id="bopen" ${D.kind === 'opening' ? 'checked' : ''} onchange="A.lotHead('kind',this.checked?'opening':'purchase')">Opening stock (laptops the shop had before this app)</label>
  <label>Note (optional)</label><input id="bnote" maxlength="300" value="${esc(D.note)}" placeholder="e.g. bought at Hyderabad expo" oninput="A.lotHead('note',this.value)">
  <button id="lotcreate" class="createlot" onclick="A.createLot()"></button>`);
  renderCard(); renderList();
}

// Put the card's laptops into the list. Returns false (with a message) when something is missing.
function addFromCard() {
  let it;
  if (D.mode === 'known') {
    if (!formReady(D.f)) { toast(D.f.brand && D.f.processor ? 'Type the brand or processor name' : 'Pick at least the brand and processor'); return false; }
    it = { is_mixed: false, specs: specsOf(D.f), qty: cleanQty(D.f.qty), cost: costNum(D.f.cost) };
  } else it = { is_mixed: true, brands: [...D.m.brands], qty: cleanQty(D.m.qty), cost: costNum(D.m.cost) };
  if (it.cost != null && it.cost < 0) { toast('Check the cost'); return false; }
  const others = total() - (D.edit != null ? D.items[D.edit].qty : 0);
  if (others + it.qty > MAX_QTY) { toast(`A lot can have up to ${MAX_QTY} laptops`); return false; }
  if (D.edit == null && D.items.length >= MAX_GROUPS) { toast(`A lot can have up to ${MAX_GROUPS} different kinds of laptops`); return false; }
  if (D.edit != null) D.items[D.edit] = it; else D.items.push(it);
  // Reset, keeping the brand: the next laptops are often the same brand
  D.f = blankForm(D.f.brand); D.m = blankMixed(); D.edit = null; D.more = {};
  return true;
}

export const actions = {
  addLot() {
    if (!isMgr()) return toast('Ask the admin or co-admin to add lots.');
    const sups = S.d.suppliers.filter(s => s.code !== '00');
    if (!sups.length) { toast('Add a supplier first'); return A.go('suppliers'); }
    D = { supplier: sups[0].id, lot_no: nextLotNo(sups[0].id), date: todayIN(), kind: 'purchase', note: '',
      items: [], mode: 'known', f: blankForm(), m: blankMixed(), edit: null, open: true, more: {}, quick: quickList() };
    openForm();
  },
  lotSup(id) { D.supplier = id; D.lot_no = nextLotNo(id); $('bno').value = D.lot_no; sheetY(renderList); },
  lotHead(k, v) { D[k] = v; if (k === 'lot_no' || k === 'date') sheetY(renderList); },

  // card inputs
  lcPick(k, v) {
    const f = D.f, cur = f[k];
    const nv = ['gen', 'ram_gb', 'storage_gb'].includes(k) ? +v : v;
    f[k] = String(cur) === String(nv) && k !== 'storage_type' ? null : nv;   // tap again to clear (SSD/HDD always one)
    if (k === 'storage_gb' && $('lc_size_other')) $('lc_size_other').value = '';
    sheetY(() => {
      if (k === 'brand') { $('lcr_brand').querySelectorAll('button').forEach(b => b.classList.toggle('on', b.textContent === f.brand)); $('lc_brand_other').classList.toggle('hidden', f.brand !== 'Other'); }
      else if (k === 'storage_type') $('lcr_storage').querySelectorAll(':scope > button').forEach(b => b.classList.toggle('on', b.textContent === f.storage_type));
      else $('lcr_' + k).innerHTML = chipRow(k);
      if (k === 'processor') $('lc_processor_other').classList.toggle('hidden', f.processor !== 'Other');
    });
    updateCard();
  },
  lcMore(k) {
    D.more[k] = true;
    sheetY(() => { $('lcr_' + k).innerHTML = chipRow(k); if (k === 'storage_gb') $('lc_size_other').classList.remove('hidden'); });
  },
  lcSize(v) { const n = Math.floor(+v); D.f.storage_gb = v.trim() && n > 0 ? n : null; sheetY(() => { $('lcr_storage_gb').innerHTML = chipRow('storage_gb'); }); updateCard(); },
  lcSet(k, v) { D.f[k] = v; updateCard(); },
  lmBrand(v) {
    const b = D.m.brands, i = b.indexOf(v); if (i >= 0) b.splice(i, 1); else b.push(v);
    $('lcr_mbrands').querySelectorAll('button').forEach(x => x.classList.toggle('on', b.includes(x.textContent)));
  },
  lcStep(w, d) { D[w].qty = cleanQty((+D[w].qty || 1) + d); $('lc_qty').value = D[w].qty; updateCard(); },
  lcQty(w, v) { if (v !== '') D[w].qty = cleanQty(v); updateCard(); },
  lcQtyNow() { return D[D.mode === 'known' ? 'f' : 'm'].qty; },
  lcCost(w, v) { D[w].cost = v; updateCard(); },
  lcMode(m) { if (D.mode === m) return; D.mode = m; sheetY(renderCard); },

  // add, change, remove
  lcAdd() {
    if (!addFromCard()) return;
    D.open = false; renderAll();
    $('lotlist')?.scrollIntoView({ block: 'start', behavior: 'smooth' });
  },
  lcOpen() { D.open = true; D.edit = null; renderAll(); $('lotcard')?.scrollIntoView({ block: 'start', behavior: 'smooth' }); },
  lcClose() { D.open = !D.items.length; D.edit = null; D.f = blankForm(D.f.brand); D.m = blankMixed(); D.more = {}; renderAll(); },
  lcEdit(i) {
    const it = D.items[i];
    D.edit = i; D.open = true; D.more = {};
    if (it.is_mixed) { D.mode = 'mixed'; D.m = { qty: it.qty, cost: it.cost ?? '', brands: [...(it.brands || [])] }; }
    else { D.mode = 'known'; D.f = { ...blankForm(), ...it.specs, storage_type: it.specs.storage_type || 'SSD', qty: it.qty, cost: it.cost ?? '' }; }
    renderAll(); $('lotcard')?.scrollIntoView({ block: 'start', behavior: 'smooth' });
  },
  lcDel(i) {
    D.items.splice(i, 1);
    if (D.edit === i) { D.edit = null; D.f = blankForm(D.f.brand); D.m = blankMixed(); }
    else if (D.edit != null && D.edit > i) D.edit--;
    if (!D.items.length) D.open = true;
    renderAll();
  },
  lcQuick(i) {
    const q = D.quick[i];
    D.mode = 'known'; D.f = { ...blankForm(), ...q.specs, model: q.model }; D.more = {};
    sheetY(renderCard);
    $('lc_qty')?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  },

  async createLot() {
    // Picked laptops in the card but did not tap Add
    if (D.open && D.mode === 'known' && formReady(D.f)) {
      const sh = `${cleanQty(D.f.qty)} × ${shorthand(specsOf(D.f))}`;
      if (await confirmBox('Add these laptops too?', `You picked ${esc(sh)} but did not tap Add.`, 'Add them')) { if (!addFromCard()) return; D.open = false; renderAll(); }
      else if (!D.items.length) return;
    }
    if (!D.items.length) return toast('Add at least one laptop');
    const lines = D.items.map(it => it.is_mixed ? { is_mixed: true, qty: it.qty, cost: it.cost } : { is_mixed: false, ...it.specs, qty: it.qty, cost: it.cost });
    const brands = [...new Set(D.items.filter(it => it.is_mixed).flatMap(it => it.brands || []))];
    const note = [D.note.trim(), brands.length ? `Mixed: ${brands.join(', ')}` : ''].filter(Boolean).join('. ').slice(0, 300);
    await guard(async () => {
      const r = await write('create_lot', { p_supplier_id: D.supplier, p_lot_no: +D.lot_no, p_bought_on: D.date, p_lines: lines, p_kind: D.kind, p_note: note });
      showLot(r.lot_id); closeModal(); D = null; await load();
      toast(`Lot ${r.prefix} created with ${plural(r.qty, 'sticker')}`, 'ok');
      if (A.view() !== 'stock') A.go('stock');
      if (await confirmBox('Print the stickers now?', `${plural(r.qty, 'QR sticker')} for lot ${r.prefix}, 4 per row on A4 gum paper.`, 'Print')) printStickers(r.codes);
    });
  }
};
