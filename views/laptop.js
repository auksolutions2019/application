// Laptop pop-up: three main actions (Replace parts, Delivery / Handover, Give for service), Tests,
// specs, photos, sale, booking, exchange, payments, bill, return / undo, service.
import { $, esc, rs, fmtD, tag, MON, sum, chips, chipVal, multiChips, multiVals, val, num, todayIN, initials, waLink, daysSince } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, openSheet, closeModal, confirmBox, dialog, amountBox, guard, METHODS, sheetOpen } from '../ui/feedback.js';
import { S, load, laptopByCode, cachedLaptop, isAdmin, isMgr, role } from '../api/store.js';
import { read, write, updateLaptop } from '../api/client.js';
import { specEditor, wireSpecEditor, readSpecs, lapName, SKILLS } from '../ui/specs.js';
import { printStickers, printBill, billText, warrantyOf } from '../ui/print.js';
import { TESTS, LEADS, status, testBadge, testCount, testsPassed, ageDays, oldDays, atService, lotOf, noteLine } from './common.js';

let cur = null, mtab = 'hand', resvSell = false, editSpecs = false, dirty = false, floorCache = new Map();
const L = () => cachedLaptop(cur);
// The laptops on the same bill: this one, or every laptop of its bulk sale
function billLaptops(l) {
  const g = l.sale?.bulk_group; if (!g) return [l];
  const all = new Map([...S.d.laptops, ...S.extra.values()].filter(x => x.sale?.bulk_group === g).map(x => [x.code, x]));
  return [...all.values()].sort((a, b) => a.code.localeCompare(b.code));
}

function pickTab(l) {
  if (atService(l)) return 'svc';
  if (l.sale || l.booking || testsPassed(l)) return 'hand';
  return 'test';
}

function render() {
  const l = L(); if (!l) return closeModal();
  const lot = lotOf(l), w = warrantyOf(l), age = ageDays(l), svc = l.service;
  const hi = atService(l) ? 'svc' : l.sale ? 'hand' : '';
  $('sheet').innerHTML = `<div style="display:flex;justify-content:space-between;align-items:start;gap:10px">
    <div style="min-width:0"><div style="margin-bottom:8px">${tag(l.code, 1)}</div><div class="muted">${lot ? `${lot.supplier_name ? esc(lot.supplier_name) + ', ' : ''}${MON[lot.month - 1]} ${lot.year}` : ''}${l.notes ? ', ' + esc(l.notes) : ''}</div></div>
    <button class="ghost sm" onclick="A.closeModal()" aria-label="Close">${ICON.x}</button></div>
  <div class="badges">${status(l)}${testBadge(l)}${w ? w.badge : ''}${!l.sale && age >= oldDays() ? `<span class="pill due">${age} days in stock</span>` : ''}${isAdmin() && l.cost == null && l.full_cost == null ? '<span class="warnmark">Cost missing</span>' : ''}</div>
  ${svc ? `<div class="svcbox">${ICON.tool}<div><b>With ${esc(svc.partner)} since ${fmtD(svc.given_on)}</b><div class="${svc.overdue ? 'overdue' : 'muted'}">${svc.days_out} day${svc.days_out === 1 ? '' : 's'} out${svc.expected_on ? `, expected back ${fmtD(svc.expected_on)}${svc.overdue ? ' (overdue)' : ''}` : ''}${svc.kind === 'warranty' ? ', customer warranty' : ''}</div></div></div>` : ''}
  ${w ? `<div class="wbox ${w.ok ? '' : 'off'}">${ICON.shield}<div><b>${w.ok ? 'Under warranty' : 'Warranty ended'}</b><div class="muted">${w.end ? `Laptop ${w.months} months, till ${fmtD(w.end)}. ` : ''}${w.aend ? `Charger and battery till ${fmtD(w.aend)}. ` : ''}Service support till ${fmtD(w.svc)}.</div></div></div>` : ''}
  ${photoStrip(l)}
  ${specBlock(l)}
  <div class="acts3">
    <button class="${mtab === 'parts' ? 'on' : ''}" onclick="A.lapTab('parts')">${ICON.wrench}Replace parts</button>
    <button class="${mtab === 'hand' ? 'on' : ''} ${hi === 'hand' ? 'hi' : ''}" onclick="A.lapTab('hand')">${ICON.hand}Delivery / Handover</button>
    <button class="${mtab === 'svc' ? 'on' : ''} ${hi === 'svc' ? 'hi' : ''}" onclick="A.lapTab('svc')">${ICON.tool}Give for service</button></div>
  <div class="minitabs"><a class="${mtab === 'test' ? 'on' : ''}" onclick="A.lapTab('test')">Tests ${testCount(l)}/${TESTS.length}</a></div>
  ${mtab === 'test' ? testPane(l) : mtab === 'parts' ? partsPane(l) : mtab === 'svc' ? svcPane(l) : handPane(l)}
  <div class="row" style="margin-top:18px"><button class="ghost sm" onclick="A.printStickers(['${esc(l.code)}'])">Reprint sticker</button></div>
  ${l.returns?.length ? `<h3 class="sh">Earlier sales, returned</h3><div class="list flat">${l.returns.map(r => `<div class="lrow"><span class="cm">${esc(r.name)}, sold ${fmtD(r.sold_on)}, returned ${fmtD(r.returned_on)}</span><b>${rs(r.refund)} back</b></div>`).join('')}</div>` : ''}`;
  if (editSpecs) wireSpecEditor('ls_');
  const hp = $('hprice'); if (hp) actions.safeHint(hp);
  dirty = false;
}

function specBlock(l) {
  if (editSpecs) return `<div class="lineed">${specEditor('ls_', l)}<div class="row" style="margin-top:12px"><button class="ghost" onclick="A.editSpecs(false)">Cancel</button><button onclick="A.saveSpecs()">Save specs</button></div></div>`;
  return `<div class="row nw" style="align-items:center;margin-top:12px"><div style="min-width:0"><div class="shorthand">${esc(l.shorthand || 'Specs not entered')}</div><div class="muted">${esc(l.model || '')}</div></div><button class="ghost sm" style="flex:none" onclick="A.editSpecs(true)">Edit specs</button></div>
  <div class="row nw"><div><label>Serial no.</label><input value="${esc(l.serial)}" placeholder="from laptop bottom" onchange="A.setField('serial',this.value)"></div>
  <div style="max-width:100px"><label>Grade</label><select onchange="A.setField('grade',this.value)">${['', 'A', 'B', 'C'].map(g => `<option ${g === (l.grade || '') ? 'selected' : ''} value="${g}">${g || '–'}</option>`).join('')}</select></div></div>
  <label>Notes</label><input value="${esc(l.notes || '')}" maxlength="300" placeholder="e.g. small dent on lid, Windows key missing" onchange="A.setField('notes',this.value)">`;
}

// ----- Tests -----
function testPane(l) {
  return `<p class="muted" style="margin-bottom:10px">Check each part before selling. A laptop can only be sold when every test passes.</p>
  <div class="list flat">${TESTS.map(t => { const v = l.tests?.[t]; return `<div class="trow"><span class="cm"><b>${t}</b></span>
   <button class="tb ${v === 'ok' ? 'ok' : ''}" onclick="A.setTest('${t}','ok')">${ICON.check}Pass</button><button class="tb ${v === 'fail' ? 'bad' : ''}" onclick="A.setTest('${t}','fail')">${ICON.x}Fail</button></div>`; }).join('')}</div>
  <div class="row" style="margin-top:12px"><button class="ghost" onclick="A.setAllTests()">${ICON.check}Mark all passed</button></div>
  <label>Test notes</label><input value="${esc(l.test_note || '')}" placeholder="e.g. battery 78%, small scratch on lid" onchange="A.setField('test_note',this.value)">`;
}

// ----- Replace parts (repairs, including parts bought for the lot) -----
function partsPane(l) {
  const lot = lotOf(l);
  const stockParts = isMgr() ? (lot?.expenses || []).filter(e => e.units_left > 0 && (!e.line_id || e.line_id === l.line_id) && ['SSD', 'RAM', 'Battery', 'Charger', 'HDD', 'Keyboard', 'Screen', 'Other'].includes(e.type)) : [];
  const total = sum(l.repairs, r => r.amount);
  return `${l.repairs.length ? `<div class="list flat">${l.repairs.map(r => `<div class="lrow"><span class="cm"><b>${esc(r.work)}</b><span class="muted">${fmtD(r.done_on)}${r.from_lot_stock ? ', from lot stock' : ''}</span></span><b>${rs(r.amount)}</b>${isAdmin() ? `<button class="sm ghost" onclick="A.delRepair('${r.id}')" aria-label="Delete">${ICON.trash}</button>` : ''}</div>`).join('')}<div class="lrow"><span class="cm"><b>Total repairs</b></span><b>${rs(total)}</b></div></div>` : '<p class="muted">No parts or repairs added yet.</p>'}
  ${stockParts.length ? `<h3 class="sh">Use a part bought for this lot</h3><div class="list flat">${stockParts.map(e => `<div class="lrow"><span class="cm"><b>${esc(e.type)}</b><span class="muted">${e.units_left} of ${e.count} left${e.note ? ', ' + esc(e.note) : ''}</span></span><button class="sm" onclick="A.fitPart('${e.id}')">Fit 1</button></div>`).join('')}</div>` : ''}
  <h3 class="sh">Add other work or a part bought for this laptop</h3>
  <div class="row nw"><div><label>Work done</label><input id="edesc" list="worklist" placeholder="e.g. SSD changed"></div><div style="max-width:130px"><label>Cost (₹)</label><input id="eamt" type="number" inputmode="decimal"></div></div>
  <datalist id="worklist"><option>SSD changed</option><option>RAM upgrade</option><option>Battery replaced</option><option>Keyboard replaced</option><option>Camera repair</option><option>Screen replaced</option><option>USB port repair</option><option>Charger</option><option>Body / hinge repair</option><option>Windows installed</option></datalist>
  <button style="width:100%;margin-top:10px" onclick="A.addRepair()">${ICON.plus}Add repair</button>`;
}

// ----- Delivery / Handover: sale, booking, payments -----
function dealerChips() {
  const ds = [...new Map(S.d.laptops.filter(x => x.sale?.customer_type === 'Dealer' && x.sale.mobile).map(x => [x.sale.mobile, x.sale])).values()];
  return ds.length ? `<div class="chips" id="hdealers">${ds.slice(0, 12).map(s => `<button type="button" onclick="A.pickDealer('${esc(s.name)}','${esc(s.mobile)}')">${esc(s.label)}</button>`).join('')}</div>` : '';
}
function handPane(l) {
  if (atService(l)) return `<div class="note bad">${ICON.alert}<span>This laptop is with ${esc(l.service.partner)} since ${fmtD(l.service.given_on)}. Receive it back before selling or handing it over.</span></div>`;
  if (l.sale) return soldPane(l);
  const b = l.booking;
  if (b && !resvSell) return `<div class="resv">${ICON.clock}<div class="cm"><b>Booked by ${esc(b.label)}</b><div class="muted">${esc(b.mobile || '')}, on ${fmtD(b.booked_on)}${b.agreed_price ? `, agreed price ${rs(b.agreed_price)}` : ''}</div><div style="margin-top:4px">Advance paid <b>${rs(b.advance)}</b></div>${(b.payments || []).map(p => noteLine(p.note, 'booking_payment', p.id)).join('')}</div></div>
    <div class="row" style="margin-top:12px"><button onclick="A.completeSale()">Complete the sale</button><button class="ghost" onclick="A.cancelReserve()">Cancel booking</button></div>`;
  const canSell = testsPassed(l), price = b?.agreed_price || S.d.prices?.[l.shorthand] || '';
  const def = S.d.settings.default_warranty_months, accDef = S.d.settings.accessory_warranty_months ?? 12;
  return `${!canSell ? `<div class="note bad">${ICON.alert}<span>${TESTS.length - testCount(l)} test${TESTS.length - testCount(l) > 1 ? 's are' : ' is'} not passed yet. ${isAdmin() ? 'You can still sell as admin.' : 'Finish the tests before selling.'}</span></div>` : ''}
  <label>Where the customer came from *</label>${chips('hlead', LEADS, b?.lead_source || '', 'wrap')}
  ${chips('htype', ['Retail', 'Dealer'], b?.customer_type || 'Retail')}${dealerChips()}
  <div class="row"><div><label>Customer name</label><input id="hname" value="${esc(b?.name || '')}"></div><div><label>Mobile</label><input id="hmob" type="tel" inputmode="tel" value="${esc(b?.mobile || '')}"></div></div>
  <label>Address (optional)</label><input id="hadd" value="${esc(b?.address || '')}">
  <label>Selling price (₹)</label><input id="hprice" type="number" inputmode="decimal" value="${price}" oninput="A.safeHint(this)">
  <div id="safe" class="safe"></div>
  <details class="exch" id="exon"><summary>${ICON.swap}Customer gives an old laptop in exchange</summary>
   <div class="row nw"><div><label>Old laptop model</label><input id="exmodel" placeholder="HP 15 i3 7th gen"></div><div style="max-width:130px"><label>Value (₹)</label><input id="exval" type="number" inputmode="decimal"></div></div>
   <p class="muted" style="margin-top:6px">The value is taken off the bill, and the old laptop is added to stock with its own sticker.</p></details>
  ${b ? `<div class="note">${ICON.check}<span>Advance of ${rs(b.advance)} is already counted.</span></div>` : ''}
  <div class="row nw"><div><label>${b ? 'Paid now (on top of advance)' : 'Paid now (₹)'}</label><input id="hpaid" type="number" inputmode="decimal"></div><div><label>Date</label><input id="hdate" type="date" value="${todayIN()}" max="${todayIN()}"></div></div>
  ${chips('hmeth', METHODS, 'Cash')}<div class="row nw"><input id="href" placeholder="Ref / UTR (optional)"><input id="hnote" maxlength="300" placeholder="Note (optional)"></div>
  <label>Laptop warranty</label>${chips('hwar', [['0', 'None'], ['3', '3 months'], ['6', '6 months'], ['12', '12 months']], String([0, 3, 6, 12].includes(def) ? def : 0))}
  <label>Charger and battery warranty</label>${chips('hacc', [['0', 'None'], ['6', '6 months'], ['12', '12 months']], String([0, 6, 12].includes(accDef) ? accDef : 0))}
  <p class="muted" style="margin-top:6px">Name and mobile are optional, but the mobile is needed for a warranty or if money is still due.</p>
  <button style="width:100%;margin-top:14px;padding:14px" onclick="A.sellOne()">Mark as sold</button>
  ${!b ? `<button class="ghost" style="width:100%;margin-top:8px" onclick="A.reserveOne()">${ICON.clock}Book for this customer with advance</button>` : ''}`;
}
function soldPane(l) {
  const sl = l.sale, due = sl.due, pd = sl.paid, pc = Math.min(100, pd / sl.price * 100), adm = isAdmin();
  const remind = `Assalamu Alaikum ${sl.name || ''}, this is ${S.d.settings.shop_name}, R.T Nagar. A balance of ${rs(due)} is pending for your laptop purchase. Kindly clear it at your convenience. Thank you.`;
  return `<div class="cust"><div class="av">${esc(initials(sl.label))}</div><div class="cm"><b>${esc(sl.label)}</b><div class="muted">${esc(sl.mobile || 'No mobile')}${sl.address ? ', ' + esc(sl.address) : ''} · ${esc(sl.lead_source)}${sl.customer_type === 'Dealer' ? ', dealer' : ''}</div></div>
   ${sl.mobile ? `<a class="ib" href="tel:${esc(sl.mobile)}" aria-label="Call">${ICON.phone}</a><a class="ib wa" target="_blank" href="${esc(waLink(sl.mobile, due > 0 ? remind : billText(billLaptops(l), S.d.settings)))}" aria-label="WhatsApp">${ICON.wa}</a>` : ''}</div>
  <div class="paybox"><div class="pb1"><div><span class="muted">Paid</span><b>${rs(pd)}</b></div><div class="right"><span class="muted">${due > 0 ? 'Balance' : 'Fully paid'}</span><b style="color:${due > 0 ? 'var(--red)' : 'var(--green)'}">${rs(due)}</b></div></div>
   <div class="prog"><i style="width:${pc}%;background:${due > 0 ? 'var(--blue)' : 'var(--green)'}"></i></div>
   <div class="muted" style="margin-top:6px">Sold for ${rs(sl.price)} on ${fmtD(sl.sold_on)}${sl.invoice_no ? `, bill INV-${sl.invoice_no}` : ''}</div></div>
  ${adm ? `<div class="kv"><span>Cost, repairs, parts${l.service_cost ? ' and service' : ''}</span><b>${l.full_cost != null ? rs(l.full_cost) : 'cost missing'}</b></div>
    <div class="kv"><span>Profit on this laptop</span><b style="color:${sl.profit >= 0 ? 'var(--green)' : 'var(--red)'}">${sl.profit != null ? rs(sl.profit) : 'cost missing'}</b></div>` : ''}
  ${sl.payments.length ? `<h3 class="sh">Payments</h3><div class="list flat">${sl.payments.map((p, i) => `<div class="lrow"><span class="pn">${i + 1}</span><span class="cm">${fmtD(p.paid_on)}<span class="mtag">${esc(p.method)}</span>${p.ref ? `<span class="muted"> ${esc(p.ref)}</span>` : ''}${p.method === 'Exchange' ? '' : noteLine(p.note, p.from_booking ? null : 'sale_payment', p.id)}</span><b>${rs(p.amount)}</b></div>`).join('')}</div>` : ''}
  ${due > 0 && isMgr() ? `<div class="row nw" style="margin-top:12px"><input id="ppay" type="number" inputmode="decimal" placeholder="Amount received (₹)"><button style="flex:none;white-space:nowrap" onclick="A.addPay()">${ICON.plus}Add payment</button></div>
   ${chips('pmeth', METHODS, 'Cash')}<div class="row nw"><input id="pref" placeholder="Ref / UTR (optional)"><input id="pnote" maxlength="300" placeholder="Note (optional)"></div><button class="chipfill" onclick="document.getElementById('ppay').value=${due}">Full balance ${rs(due)}</button>` : ''}
  <div class="row" style="margin-top:16px"><button class="ghost sm" onclick="A.printBillCur()">Bill and warranty card</button>${sl.mobile ? `<a class="btnlink" target="_blank" href="${esc(waLink(sl.mobile, billText(billLaptops(l), S.d.settings)))}">${ICON.wa}Send bill on WhatsApp</a>` : ''}</div>
  ${adm ? `<div class="row" style="margin-top:8px"><button class="ghost sm" onclick="A.returnSale()">Customer returned it</button><button class="ghost sm" style="color:var(--red)" onclick="A.undoSale()">Undo sale (entry mistake)</button></div>` : ''}`;
}

// ----- Give for service / receive back -----
function svcPane(l) {
  const j = l.service, mgr = isMgr(), adm = isAdmin();
  const hist = l.service_history?.length ? `<h3 class="sh">Service history</h3><div class="list flat">${l.service_history.map(h => `<div class="lrow" style="cursor:default"><span class="cm"><b>${esc(h.partner)}</b><span class="muted">${fmtD(h.given_on)} to ${fmtD(h.received_on)}, ${esc((h.issues || []).join(', ') || h.note)}, ${h.outcome === 'fixed' ? 'fixed' : h.outcome === 'not_fixed' ? 'not fixed' : 'no work'}${h.kind === 'warranty' ? ', warranty' : ''}${h.work_done ? ': ' + esc(h.work_done) : ''}</span></span>
    ${adm ? (h.charge != null ? `<b>${rs(h.charge)}</b>` : `<button class="sm" onclick="A.fillCharge('${h.id}')">Add charge</button>`) : mgr ? (h.charge_entered ? '<span class="mtag">charge entered</span>' : `<button class="sm" onclick="A.fillCharge('${h.id}')">Add charge</button>`) : ''}</div>`).join('')}</div>` : '';
  if (j) return `<div class="list flat"><div class="kv" style="padding:9px 12px"><span>Partner</span><b>${esc(j.partner)}</b></div><div class="kv" style="padding:9px 12px"><span>To fix</span><b>${esc((j.issues || []).join(', ') || '–')}</b></div>
    ${j.note ? `<div class="kv" style="padding:9px 12px"><span>Note</span><b>${esc(j.note)}</b></div>` : ''}<div class="kv" style="padding:9px 12px"><span>Given</span><b>${fmtD(j.given_on)} (${j.days_out} days)</b></div>
    ${j.expected_on ? `<div class="kv" style="padding:9px 12px"><span>Expected back</span><b class="${j.overdue ? 'overdue' : ''}">${fmtD(j.expected_on)}</b></div>` : ''}<div class="kv" style="padding:9px 12px;border:0"><span>Type</span><b>${j.kind === 'warranty' ? "Customer's laptop, warranty" : 'Stock laptop'}</b></div></div>
    <h3 class="sh">Receive back from service</h3>
    <div class="row nw"><div><label>Date received</label><input id="rdate" type="date" value="${todayIN()}" max="${todayIN()}"></div></div>
    <label>Work done</label><input id="rwork" placeholder="e.g. display cable changed">
    <label>Result</label>${chips('rout', [['fixed', 'Fixed'], ['not_fixed', 'Not fixed'], ['no_work', 'Returned without work']], 'fixed', 'wrap')}
    ${mgr ? `<label>Service charge (₹)</label><input id="rcharge" type="number" inputmode="decimal" placeholder="Blank if not known yet">
      <p class="muted" style="margin-top:4px">${j.kind === 'warranty' ? 'Counted as a warranty cost, not added to the laptop.' : 'Added to this laptop\'s cost, so profit stays right.'}</p>` : '<p class="muted" style="margin-top:8px">The admin or co-admin will add the service charge.</p>'}
    ${adm ? `<label>Paid to the partner</label>${chips('rpaid', [['later', 'Pay later'], ['now', 'Paid now']], 'later')}${chips('rmeth', METHODS, 'Cash')}<div class="row nw"><input id="rref" placeholder="Ref / UTR (optional)"><input id="rnote" maxlength="300" placeholder="Note (optional)"></div>` : ''}
    <button style="width:100%;margin-top:14px;padding:14px" onclick="A.receiveService('${j.id}')">Received back</button>${hist}`;
  if (l.booking) return `<div class="note bad">${ICON.alert}<span>This laptop is booked. Complete or cancel the booking before giving it for service.</span></div>${hist}`;
  const partners = (S.d.partners || []).filter(p => p.active);
  return `${partners.length ? `<label>Service partner</label><div class="chips mchips wrap" id="spart">${partners.map((p, i) => `<button type="button" data-v="${p.id}" class="${i === 0 ? 'on' : ''}" onclick="A.pickChip(this)">${esc(p.label)}${p.out_count ? ` <span>${p.out_count} out</span>` : ''}</button>`).join('')}</div>`
      : `<p class="muted">No service partners yet.</p>`}
    ${mgr ? `<a class="link" style="display:inline-block;margin-top:6px" onclick="A.formPartner()">${ICON.plus.replace('class="i"', 'class="i" style="width:14px;height:14px;vertical-align:-2px"')} Add a service partner</a>` : ''}
    ${partners.length ? `<label>What to fix</label>${multiChips('sissue', SKILLS)}
    <label>Note</label><input id="snote" placeholder="e.g. no display, board short">
    <div class="row nw"><div><label>Date given</label><input id="sdate" type="date" value="${todayIN()}" max="${todayIN()}"></div><div><label>Expected back (optional)</label><input id="sexp" type="date"></div></div>
    <label>Type</label>${chips('skind', [[l.sale ? 'warranty' : 'stock', l.sale ? "Customer's laptop, back under warranty" : 'Stock laptop']], l.sale ? 'warranty' : 'stock')}
    <button style="width:100%;margin-top:14px;padding:14px" onclick="A.giveService()">${ICON.tool}Give for service</button>` : ''}${hist}`;
}

function photoStrip(l) {
  const ps = l.photos || [];
  const thumb = u => u.replace('/upload/', '/upload/c_fill,w_220,h_220,q_auto,f_auto/');
  return `<div class="photos">${ps.map((u, i) => `<a href="${esc(u)}" target="_blank" rel="noopener"><img src="${esc(thumb(u))}" alt="Photo ${i + 1} of ${esc(l.code)}" loading="lazy"></a>`).join('')}
  <label class="addph">${ICON.cam}<span>${ps.length ? 'Add' : 'Add photos'}</span><input type="file" accept="image/*" multiple style="display:none" onchange="A.addPhotos(this.files);this.value=''"></label></div>`;
}
function shrink(file, max = 1600, q = 0.8) {
  return new Promise((res, rej) => { const i = new Image(); i.onload = () => { const s = Math.min(1, max / Math.max(i.width, i.height)), c = document.createElement('canvas'); c.width = i.width * s; c.height = i.height * s; c.getContext('2d').drawImage(i, 0, 0, c.width, c.height); c.toBlob(b => b ? res(b) : rej(new Error('Could not read the photo')), 'image/jpeg', q); URL.revokeObjectURL(i.src); }; i.onerror = () => rej(new Error('Could not read the photo')); i.src = URL.createObjectURL(file); });
}

async function after(msg) { dirty = false; await load(); if (msg) toast(msg, 'ok'); }
async function sellCall(fn, args) {
  try { return await write(fn, args); }
  catch (e) {
    if (e.hint !== 'confirm_tests') throw e;
    if (!await confirmBox('Not every test has passed', 'Sell this laptop anyway?', 'Sell anyway', 1)) return null;
    return await write(fn, { ...args, p_override_tests: true });
  }
}

export const actions = {
  async openLaptop(code) {
    code = (code || '').trim().toUpperCase();
    let l;
    try { l = await laptopByCode(code); } catch (e) { return toast(navigator.onLine ? e.message : 'You are offline and this laptop is not saved on this phone.'); }
    if (!l) return toast('No laptop has the code ' + code);
    A.stopScan(); cur = l.code; resvSell = false; editSpecs = false; mtab = pickTab(l);
    openModalWith();
  },
  rerender(force) { if (cur && sheetOpen() && (force || !dirty)) { if (!L()) return; render(); } },
  lapTab(t) { mtab = t; resvSell = false; render(); },
  editSpecs(on) { editSpecs = on; render(); },
  async saveSpecs() {
    const s = readSpecs('ls_'), l = L();
    await guard(async () => { await updateLaptop(l.id, s); editSpecs = false; await after('Specs saved'); });
  },
  async setField(k, v) {
    const l = L(); v = String(v).trim(); if ((l[k] || '') === v) return;
    await guard(async () => { await updateLaptop(l.id, { [k]: v }); await after(); });
  },
  async setTest(t, v) {
    const l = L();
    await guard(async () => { const r = await write('set_test', { p_laptop_id: l.id, p_test: t, p_result: v }); await after(r.all_passed && !testsPassed(l) ? 'All tests passed. Ready to sell.' : null); });
  },
  async setAllTests() { const l = L(); await guard(async () => { await write('set_all_tests', { p_laptop_id: l.id }); await after('All tests passed. Ready to sell.'); }); },
  async addRepair() {
    const d = val('edesc'), a = num('eamt'); if (!d || !a) return toast('Enter the work done and its cost');
    await guard(async () => { await write('add_repair', { p_laptop_id: L().id, p_work: d, p_amount: a }); await after('Repair added'); });
  },
  async fitPart(expId) { await guard(async () => { const r = await write('add_repair', { p_laptop_id: L().id, p_work: '', p_lot_expense_id: expId }); await after(`Part fitted (${rs(r.amount)})`); }); },
  async delRepair(id) {
    if (!await confirmBox('Delete this repair?', 'It is removed from the laptop\'s cost.', 'Delete', 1)) return;
    await guard(async () => { await write('delete_repair', { p_repair_id: id }); await after(); });
  },
  async safeHint(el) {
    const h = $('safe'); if (!h) return;
    const l = L(), p = +el.value;
    let floor = null;
    if (isAdmin()) floor = l.full_cost != null ? Math.round(l.full_cost) : null;
    else if (isMgr()) {
      if (!floorCache.has(l.id)) { try { floorCache.set(l.id, await read('safe_price', { p_laptop_id: l.id })); } catch (e) { floorCache.set(l.id, null); } }
      floor = floorCache.get(l.id);
    } else { h.innerHTML = ''; return; }
    if (floor == null) { h.className = 'safe'; h.innerHTML = 'Lowest safe price not set yet (cost missing)'; return; }
    if (!p) { h.className = 'safe'; h.innerHTML = `Lowest safe price <b>${rs(floor)}</b>`; return; }
    const m = p - floor; h.className = 'safe ' + (m < 0 ? 'bad' : m < 1500 ? 'warn' : 'good');
    h.innerHTML = isAdmin() ? (m < 0 ? `Loss of <b>${rs(-m)}</b>. Cost, parts and repairs are ${rs(floor)}.` : `Profit <b>${rs(m)}</b> over cost, parts and repairs of ${rs(floor)}`)
      : (m < 0 ? `Below the lowest safe price of <b>${rs(floor)}</b>` : `Above the lowest safe price of ${rs(floor)}`);
  },
  pickDealer(name, mob) { $('hname').value = name; $('hmob').value = mob; const t = $('htype'); t?.querySelector('[data-v="Dealer"]')?.click(); const ld = $('hlead'); ld?.querySelector('[data-v="Dealer"]')?.click(); },
  async sellOne() {
    const l = L(), b = l.booking;
    const lead = chipVal('hlead'); if (!lead) return toast('Choose where the customer came from');
    const price = num('hprice'); if (!price) return toast('Enter the selling price');
    const exOn = $('exon').open, exVal = num('exval') || 0, exModel = val('exmodel');
    if (exOn && (!exVal || !exModel)) return toast('Enter the old laptop model and its value, or close the exchange section');
    const floor = isAdmin() ? l.full_cost : isMgr() ? floorCache.get(l.id) : null;
    if (floor != null && price < floor && !await confirmBox('This price is a loss', isAdmin() ? `Cost, parts and repairs are ${rs(floor)}. Selling at ${rs(price)} loses ${rs(floor - price)}.` : `This is below the lowest safe price of ${rs(floor)}.`, 'Sell anyway', 1)) return;
    const args = { p_price: price, p_lead_source: lead, p_customer_type: chipVal('htype'), p_name: val('hname'), p_mobile: val('hmob'), p_address: val('hadd'),
      p_paid: num('hpaid') || 0, p_method: chipVal('hmeth'), p_ref: val('href'), p_note: val('hnote'), p_sold_on: val('hdate') || null,
      p_warranty_months: +chipVal('hwar'), p_accessory_warranty_months: +chipVal('hacc'),
      p_exchange_model: exOn ? exModel : null, p_exchange_value: exOn ? exVal : null };
    await guard(async () => {
      const r = b ? await sellCall('complete_booking', { p_booking_id: b.id, ...args }) : await sellCall('sell_laptop', { p_laptop_id: l.id, ...args });
      if (!r) return;
      resvSell = false; mtab = 'hand';
      await after(`Sold${r.invoice_no ? `, bill INV-${r.invoice_no}` : ''}${r.balance > 0 ? `, balance ${rs(r.balance)}` : ''}${r.exchange_code ? `. Exchange laptop is ${r.exchange_code}` : ''}`);
    });
  },
  completeSale() { resvSell = true; render(); },
  async reserveOne() {
    const l = L(), lead = chipVal('hlead');
    if (!lead) return toast('Choose where the customer came from');
    if (!val('hmob')) return toast('Enter the customer mobile to book');
    await guard(async () => {
      await write('book_laptop', { p_laptop_id: l.id, p_mobile: val('hmob'), p_lead_source: lead, p_customer_type: chipVal('htype'), p_name: val('hname'),
        p_address: val('hadd'), p_agreed_price: num('hprice'), p_advance: num('hpaid') || 0, p_method: chipVal('hmeth'), p_ref: val('href'), p_note: val('hnote'), p_booked_on: val('hdate') || null });
      await after('Booked');
    });
  },
  async cancelReserve() {
    const l = L(), b = l.booking;
    if (role() === 'staff') {
      if (!await confirmBox('Cancel this booking?', `${esc(b.label)} booked it on ${fmtD(b.booked_on)}.${b.advance ? ` The advance of ${rs(b.advance)} is held until the admin or co-admin decides to refund or keep it.` : ''} The laptop goes back on sale.`, 'Cancel booking', 1)) return;
      return guard(async () => { await write('cancel_booking', { p_booking_id: b.id, p_refund: false }); await after('Booking cancelled'); });
    }
    if (!await confirmBox('Cancel this booking?', `${esc(b.label)} booked it on ${fmtD(b.booked_on)}. The laptop goes back on sale.`, 'Cancel booking', 1)) return;
    // a note can go with the refund; Cancel here means the advance is kept
    const refundNote = b.advance > 0 ? await dialog({ title: `Return the advance of ${rs(b.advance)}?`, body: 'Choose Cancel if the advance is kept.', ok: 'Yes, refund it', text: true, placeholder: 'Note (optional)' }) : null;
    await guard(async () => { await write('cancel_booking', { p_booking_id: b.id, p_refund: refundNote !== null, p_note: refundNote || '' }); await after('Booking cancelled'); });
  },
  async addPay() {
    const a = num('ppay'), l = L(); if (!a || a < 0) return toast('Enter the amount received');
    if (a > l.sale.due) return toast('That is more than the balance of ' + rs(l.sale.due));
    await guard(async () => { await write('add_sale_payment', { p_sale_id: l.sale.id, p_amount: a, p_method: chipVal('pmeth'), p_ref: val('pref'), p_note: val('pnote') }); await after(`${rs(a)} received`); });
  },
  async printBillCur() {
    let l = L();
    // sales from before bills get their invoice number and warranty QR the first time the bill is printed
    if (!l.sale.invoice_no || !l.sale.warranty_token) {
      const ok = await guard(async () => { await write('issue_invoice', { p_sale_id: l.sale.id }); await load(); return true; });
      if (!ok) return;
      l = L() || await laptopByCode(cur);
    }
    printBill(billLaptops(l), S.d.settings);
  },
  async returnSale() {
    const l = L(), sl = l.sale, cash = sum(sl.payments.filter(p => p.method !== 'Exchange'), p => p.amount);
    if (!await confirmBox('Customer returned this laptop?', `${esc(sl.label)} paid ${rs(cash)} in money. Next you enter how much you give back.`, 'Continue')) return;
    const r = cash ? await dialog({ title: 'Refund to customer', body: `Up to ${rs(cash)}. Enter 0 if nothing is refunded.`, ok: 'Save return', amount: true, max: cash, allowZero: true }) : { amount: 0, method: 'Cash', ref: '' };
    if (!r) return;
    await guard(async () => { await write('return_sale', { p_sale_id: sl.id, p_refund: r.amount, p_method: r.method || 'Cash', p_ref: r.ref || '', p_note: r.note || '' }); mtab = 'test'; await after('Return saved. The laptop is back in stock.'); });
  },
  async undoSale() {
    if (!await confirmBox('Undo this sale?', 'Use this only if the sale was entered by mistake. The payments are reversed and kept in the history.', 'Undo sale', 1)) return;
    await guard(async () => { await write('undo_sale', { p_sale_id: L().sale.id, p_reason: 'entry mistake' }); await after('Sale undone, laptop is back in stock'); });
  },
  async giveService() {
    const l = L(), partner = chipVal('spart'); if (!partner) return toast('Choose a service partner');
    const issues = multiVals('sissue'); if (!issues.length && !val('snote')) return toast('Choose what to fix, or write a note');
    await guard(async () => {
      await write('give_for_service', { p_laptop_id: l.id, p_partner_id: partner, p_issues: issues, p_note: val('snote'), p_given_on: val('sdate') || null, p_expected_on: val('sexp') || null, p_kind: chipVal('skind') });
      mtab = 'svc'; await after('Given for service');
    });
  },
  async receiveService(jobId) {
    const charge = isMgr() && val('rcharge') !== '' ? num('rcharge') : null;
    const paidNow = isAdmin() && chipVal('rpaid') === 'now';
    if (paidNow && !(charge > 0)) return toast('Enter the service charge to mark it paid');
    await guard(async () => {
      await write('receive_from_service', { p_job_id: jobId, p_outcome: chipVal('rout'), p_work_done: val('rwork'), p_received_on: val('rdate') || null,
        p_charge: charge, p_paid_now: paidNow, p_method: chipVal('rmeth') || 'Cash', p_ref: val('rref'), p_note: val('rnote') });
      mtab = L()?.sale ? 'hand' : 'test'; await after('Received back from service');
    });
  },
  async fillCharge(jobId) {
    const r = await dialog({ title: 'Service charge', body: 'What the partner charged for this job.', ok: 'Save charge', amount: true, method: false, note: false, allowZero: true });
    if (!r) return;
    await guard(async () => { await write('set_service_charge', { p_job_id: jobId, p_charge: r.amount }); await after('Charge saved'); });
  },
  async addPhotos(files) {
    const st = S.d.settings; if (!st.cloud_name || !st.upload_preset) return toast('Ask the admin to add the Cloudinary cloud name and upload preset in More, Settings');
    if (!navigator.onLine) return toast('You are offline. Photos can be added when the internet is back.');
    const l = L(); let n = 0;
    for (const f of files) {
      try {
        toast(`Uploading photo ${n + 1} of ${files.length}…`, 'ok');
        const fd = new FormData(); fd.append('file', await shrink(f)); fd.append('upload_preset', st.upload_preset); fd.append('folder', 'first-choice/' + l.code);
        const r = await fetch(`https://api.cloudinary.com/v1_1/${encodeURIComponent(st.cloud_name)}/image/upload`, { method: 'POST', body: fd }), j = await r.json();
        if (!r.ok) throw new Error(j.error?.message || r.status);
        await write('add_photo', { p_laptop_id: l.id, p_url: j.secure_url }); n++;
      } catch (e) { toast('Upload failed: ' + (e.message || 'check internet and Cloudinary settings')); break; }
    }
    if (n) await after(`${n} photo${n > 1 ? 's' : ''} saved`);
  },
  printStickers
};

function openModalWith() {
  openSheetFrame();
  render();
}
function openSheetFrame() {
  openSheet('', () => { cur = null; if (A.view() === 'scan') { const q = $('qcode'); if (q) { q.value = ''; $('qres').innerHTML = ''; } A.startScan(); } else A.refresh(); });
  $('sheet').oninput = () => { dirty = true; };
}
