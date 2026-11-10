// Home: stock count and pips, money boxes, this month, alerts, search.
import { $, esc, rs, stat, tag, sum, todayIN, fmtD } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { empty, confirmBox, dialog, guard, toast } from '../ui/feedback.js';
import { S, load, isAdmin, isMgr, role } from '../api/store.js';
import { read, write } from '../api/client.js';
import { owned, atService, ageDays, oldDays, lapList, matches, testsPassed, thumb } from './common.js';
import { lapName } from '../ui/specs.js';

export const views = {
  home() {
    const d = S.d, L = d.laptops, adm = isAdmin(), mgr = isMgr();
    const ym = (d.today || todayIN()).slice(0, 7);
    const mSold = L.filter(l => l.sale && l.sale.sold_on.startsWith(ym));
    const inS = L.filter(owned).length, svcN = L.filter(atService).length;
    const custOwe = sum(L, l => l.sale ? Math.max(0, l.sale.due) : 0);
    const iOwe = adm ? sum(d.suppliers, s => Math.max(0, +s.due || 0)) + sum(d.debts, x => Math.max(0, +x.balance)) + (+d.service_owed || 0) : 0;
    const recent = L.slice(-120);
    const missingLots = adm ? d.lots.filter(x => x.cost_missing > 0) : [];
    const chargeMissing = adm ? sum(d.partners, p => p.charge_missing || 0) : 0;
    const old = L.filter(l => owned(l) && ageDays(l) >= oldDays()).sort((a, b) => ageDays(b) - ageDays(a));
    const boxes = mgr
      ? `<div><span>Customers owe you</span><b class="${custOwe ? 'g' : ''}">${rs(custOwe)}</b></div>
         ${adm ? `<div><span>You owe</span><b class="${iOwe ? 'r' : ''}">${rs(iOwe)}</b></div>` : `<div><span>At service</span><b>${svcN}</b></div>`}`
      : `<div><span>At service</span><b>${svcN}</b></div><div><span>Booked</span><b>${L.filter(l => !l.sale && l.booking).length}</b></div>`;
    return `<section class="hero"><div class="n">${inS}</div><div class="l">laptops on the shelf right now${svcN ? `, ${svcN} at service` : ''}</div>
    ${recent.length ? `<div class="pips" aria-hidden="true">${recent.map(l => `<i class="${l.sale ? 's' : ''}"></i>`).join('')}</div>` : '<div style="height:16px"></div>'}
    <div class="money">${boxes}</div></section>
    <div class="grid">${stat('Sold this month', mSold.length)}${mgr ? stat('Sales this month', rs(sum(mSold, l => l.sale.price))) : ''}
      ${stat('At service', svcN)}${adm ? stat('Stock value', rs(d.stock_value?.value) + (d.stock_value?.cost_missing ? `<small class="warnmark" style="margin-left:6px">+${d.stock_value.cost_missing} cost missing</small>` : '')) : ''}
      ${adm ? stat('Owed to service partners', rs(d.service_owed)) : ''}</div>
    ${missingLots.length ? `<div class="card alertc"><div class="chead"><h3 style="margin:0">Cost missing</h3><span class="warnmark">${sum(missingLots, x => x.cost_missing)} laptops</span></div>
      <p class="muted">Profit for these laptops shows "cost missing" until you fill in what you paid.</p>
      <div class="list flat" style="margin-top:10px">${missingLots.slice(0, 5).map(x => `<div class="lrow" onclick="A.openLot('${x.id}')"><div class="cm">${tag(x.prefix)}<div class="muted" style="margin-top:4px">${esc(x.supplier_name || '')}${x.note ? ', ' + esc(x.note) : ''}</div></div><span class="warnmark">${x.cost_missing} missing</span></div>`).join('')}</div></div>` : ''}
    ${mgr && d.held_advances?.length ? `<div class="card alertc"><h3>Advance held from cancelled bookings</h3><p class="muted">Staff cancelled these bookings. Refund the advance or keep it.</p>
      <div class="list flat" style="margin-top:10px">${d.held_advances.map(h => `<div class="crow"><div class="cm"><b>${esc(h.name)}</b><div class="muted">${esc(h.code)}, cancelled ${fmtD(h.cancelled_on)}</div></div>
        <div class="cr"><span class="pill res">${rs(h.advance)}</span><div class="acts"><button class="sm" onclick="A.settleAdvance('${h.booking_id}',true)">Refund</button><button class="sm ghost" onclick="A.settleAdvance('${h.booking_id}',false)">Keep</button></div></div></div>`).join('')}</div></div>` : ''}
    ${chargeMissing ? `<div class="card alertc"><div class="chead"><h3 style="margin:0">Service charges to fill in</h3><span class="warnmark">${chargeMissing}</span></div><p class="muted">Laptops came back from service without a charge entered.</p><button class="ghost" style="width:100%;margin-top:10px" onclick="A.go('partners')">Open service partners</button></div>` : ''}
    ${old.length ? `<div class="card alertc"><div class="chead"><h3 style="margin:0">Sitting too long</h3><span class="pill due">${old.length} laptops</span></div>
      <p class="muted">Unsold for over ${oldDays()} days. ${adm ? `About ${rs(sum(old, l => +l.full_cost || 0))} of your money is stuck in them. ` : ''}A small price cut can free it up.</p>
      <div class="list flat" style="margin-top:10px">${old.slice(0, 3).map(l => `<div class="lrow" onclick="A.openLaptop('${esc(l.code)}')">${thumb(l)}<div class="cm">${tag(l.code)}<b style="margin-top:6px">${esc(lapName(l))}</b></div><span class="pill due">${ageDays(l)} days</span></div>`).join('')}</div>
      <button class="ghost" style="width:100%;margin-top:10px" onclick="A.stockFilter('old')">See all ${old.length}</button></div>` : ''}
    ${!d.lots.some(x => x.kind !== 'exchange') && adm ? `<div class="card" style="border-color:var(--blue)"><h3>Start here</h3><p class="muted">Add your suppliers and your first lot, or bring in the Excel sheet or the old app's backup from More, Backup and import.</p><button style="margin-top:10px" onclick="A.go('backup')">Backup and import</button></div>` : ''}
    <div class="quick">${role() === 'staff'
      ? `<button onclick="A.go('scan')">${ICON.scan}Scan a sticker</button><button class="ghost" onclick="A.go('partners')">${ICON.tool}Service partners</button>`
      : `<button onclick="A.addLot()">${ICON.plus}Add a new lot</button><button class="ghost" onclick="A.go('reports')">${ICON.chart}See reports</button>`}</div>
    <div class="card"><h3>Find a laptop</h3><div class="row"><input id="q" placeholder="Code, serial, model, i5 8th, customer or mobile" onkeydown="if(event.key==='Enter')A.doSearch()"><button style="flex:0" onclick="A.doSearch()" aria-label="Search">${ICON.search}</button></div><div id="sres"></div></div>`;
  }
};

export const actions = {
  async settleAdvance(id, refund) {
    const h = S.d.held_advances.find(x => x.booking_id === id);
    let note = '';
    if (refund) { note = await dialog({ title: `Refund ${rs(h.advance)} to ${esc(h.name)}?`, body: 'It shows as money out today.', ok: 'Refund', text: true, placeholder: 'Note (optional)' }); if (note === null) return; }
    else if (!await confirmBox(`Keep the advance of ${rs(h.advance)}?`, 'The money stays with the shop.', 'Keep')) return;
    await guard(async () => { await write('settle_held_advance', { p_booking_id: id, p_refund: refund, p_note: note }); await load(); toast(refund ? 'Advance refunded' : 'Advance kept', 'ok'); });
  },
  async doSearch() {
    const q = ($('q').value || '').trim().toLowerCase(); if (!q) return;
    const local = S.d.laptops.filter(l => matches(l, q));
    $('sres').innerHTML = lapList(local);
    if (S.d.hidden_sold > 0 && navigator.onLine) {        // older sold laptops are on the server only
      try {
        const more = (await read('search_laptops', { p_q: q })).filter(l => !S.byCode.has(l.code));
        more.forEach(l => S.extra.set(l.code, l));
        if (more.length && $('sres')) $('sres').innerHTML = lapList([...local, ...more]);
      } catch (e) { /* offline or slow: local results stay */ }
    }
  }
};
