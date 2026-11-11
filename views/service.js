// Service partners: list, add / edit, partner page (with them now, history, money for admin), charges to fill in.
import { $, esc, rs, fmtD, tag, val, multiChips, multiVals, waLink, initials } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, empty, openSheet, sheetHead, closeModal, confirmBox, dialog, amountBox, guard, kebab } from '../ui/feedback.js';
import { S, load, isAdmin, isMgr } from '../api/store.js';
import { read, write } from '../api/client.js';
import { SKILLS } from '../ui/specs.js';
import { noteLine, thumb } from './common.js';

let openPartnerId = null;

export const views = {
  async partners() {
    const ps = S.d.partners || [], mgr = isMgr(), adm = isAdmin();
    const missing = mgr ? await read('service_jobs_missing_charge').catch(() => []) : [];
    const out = S.d.laptops.filter(l => l.service);
    return `<section class="hero mini"><div class="l">Laptops at service</div><div class="n" style="font-size:36px">${out.length}</div><div class="l">${out.filter(l => l.service.overdue).length ? `${out.filter(l => l.service.overdue).length} past the expected date` : 'with outside technicians and repair shops'}${adm && S.d.service_owed ? `, ${rs(S.d.service_owed)} owed` : ''}</div></section>
    ${mgr ? `<button class="addbig" onclick="A.formPartner()">${ICON.plus}Add a service partner</button>` : ''}
    ${missing.length ? `<h3 class="sh">Charges to fill in</h3><div class="list">${missing.map(j => `<div class="lrow" style="cursor:default">${thumb(j.code, '', true)}<div class="cm">${tag(j.code)}<div class="muted" style="margin-top:4px">${esc(j.partner)}, back ${fmtD(j.received_on)}${j.kind === 'warranty' ? ', warranty' : ''}</div></div><button class="sm" onclick="A.fillCharge('${j.id}')">Add charge</button></div>`).join('')}</div>` : ''}
    <div class="list">${ps.length ? ps.map(p => `<div class="crow" onclick="A.openPartner('${p.id}')" style="cursor:pointer">
      <div class="av">${esc(initials(p.label))}</div>
      <div class="cm"><b>${esc(p.label)}${p.active ? '' : ' <span class="mtag">off</span>'}</b><div class="muted">${p.shop_name && p.name !== p.label ? esc(p.name) + ', ' : ''}${esc((p.skills || []).join(', ') || 'General repairs')}</div></div>
      <div class="cr">${p.out_count ? `<span class="pill svc">${p.out_count} with them</span>` : '<span class="pill grey">None out</span>'}${adm && p.owed > 0 ? `<span class="pill due">${rs(p.owed)} owed</span>` : ''}</div></div>`).join('')
      : empty(ICON.tool, 'No service partners yet', 'Add the technicians and repair shops you send laptops to.')}</div>`;
  }
};

async function renderPartner() {
  if (!openPartnerId) return;
  const d = await read('partner_detail', { p_partner_id: openPartnerId }), adm = isAdmin();
  const list = d.with_them.map(j => `${j.code} ${j.shorthand || j.model || ''} (since ${fmtD(j.given_on)})`).join('\n');
  const msg = `Assalamu Alaikum ${d.name}, this is ${S.d.settings.shop_name}. These laptops are with you:\n${list}\nPlease update us on them. Thank you.`;
  const h = d.history;
  openSheet(`${sheetHead(esc(d.label), `${d.shop_name && d.name !== d.label ? esc(d.name) + ', ' : ''}${esc(d.mobile || 'no mobile')}${d.address ? ', ' + esc(d.address) : ''}`)}
  <div class="badges" data-partner="${d.id}">${(d.skills || []).map(s => `<span class="pill grey">${esc(s)}</span>`).join('')}</div>
  <div class="row" style="margin-top:12px">${d.mobile ? `<a class="btnlink" style="background:var(--ice);color:var(--ink)" href="tel:${esc(d.mobile)}">${ICON.phone}Call</a><a class="btnlink" target="_blank" href="${esc(waLink(d.mobile, msg))}">${ICON.wa}WhatsApp</a>` : ''}
   ${adm && d.money?.owed > 0 ? `<button class="sm" onclick="A.payPartner('${d.id}')">Pay</button>` : ''}${isMgr() ? `<button class="sm ghost" onclick="A.formPartner('${d.id}')">Edit</button>` : ''}${adm ? kebab([['Delete partner', `A.delPartner('${d.id}')`, true]], 'Partner actions') : ''}</div>
  <h3 class="sh">With them now (${d.with_them.length})</h3>
  <div class="list flat">${d.with_them.length ? d.with_them.map(j => `<div class="lrow" onclick="A.closeModal();A.openLaptop('${esc(j.code)}')">${thumb(j.code)}<div class="cm">${tag(j.code)}<b style="margin-top:6px">${esc(j.shorthand || j.model || 'Laptop')}</b><div class="muted">${esc((j.issues || []).join(', ') || j.note)}${j.kind === 'warranty' ? ', warranty' : ''}</div></div>
     <span class="pill ${j.overdue ? 'bad' : 'svc'}">${j.days_out} day${j.days_out === 1 ? '' : 's'}${j.overdue ? ', overdue' : ''}</span></div>`).join('') : '<p class="muted" style="padding:12px">Nothing with them right now.</p>'}</div>
  <h3 class="sh">History</h3>
  <div class="grid">${[['Sent', h.sent], ['Returned', h.returned], ['Fixed', h.fixed], ['Not fixed', h.not_fixed + h.no_work]].map(([t, v]) => `<div class="stat"><span>${t}</span><b>${v}</b></div>`).join('')}</div>
  ${adm && d.money ? `<h3 class="sh">Money</h3><div class="list flat"><div class="kv" style="padding:9px 12px"><span>Service charges</span><b>${rs(d.money.charges)}</b></div><div class="kv" style="padding:9px 12px"><span>Paid</span><b>${rs(d.money.paid)}</b></div><div class="kv" style="padding:9px 12px;border:0"><span>Still owed</span><b style="color:${d.money.owed > 0 ? 'var(--red)' : 'var(--green)'}">${rs(d.money.owed)}</b></div></div>${d.charge_missing ? `<p class="muted" style="margin-top:6px">${d.charge_missing} job${d.charge_missing > 1 ? 's' : ''} still without a charge.</p>` : ''}
  ${d.money.payments?.length ? `<h3 class="sh">Payments</h3><div class="list flat">${d.money.payments.map(p => `<div class="lrow" style="cursor:default"><span class="cm">${fmtD(p.paid_on)}<span class="mtag">${esc(p.method)}</span>${p.ref ? `<span class="muted"> ${esc(p.ref)}</span>` : ''}${noteLine(p.note, 'service_payment', p.id)}</span><b>${rs(p.amount)}</b></div>`).join('')}</div>` : ''}` : ''}
  ${d.recent.length ? `<h3 class="sh">Recently returned</h3><div class="list flat">${d.recent.map(j => `<div class="lrow" style="cursor:default">${thumb(j.code, '', true)}<span class="cm">${tag(j.code)}<span class="muted" style="display:block;margin-top:4px">back ${fmtD(j.received_on)}, ${j.outcome === 'fixed' ? 'fixed' : j.outcome === 'not_fixed' ? 'not fixed' : 'no work'}${j.work_done ? ': ' + esc(j.work_done) : ''}</span></span>${adm ? (j.charge != null ? `<b>${rs(j.charge)}</b>` : '<span class="warnmark">charge missing</span>') : ''}</div>`).join('')}</div>` : ''}`,
  () => { openPartnerId = null; A.refresh(); });
}

export const actions = {
  async openPartner(id) { openPartnerId = id; await guard(renderPartner); },
  async delPartner(id) {
    const p = S.partnerById.get(id), name = p?.label || p?.name || 'this partner';
    if (!await confirmBox(`Delete ${esc(name)}?`, 'Only a partner who never had a laptop or a payment can be deleted. Otherwise turn them off. It goes to More → Recently deleted for 30 days.', 'Delete', 1)) return;
    await guard(async () => { await write('delete_service_partner', { p_partner_id: id }); openPartnerId = null; closeModal(); await load(); toast(`${name} deleted`, 'ok'); });
  },
  rerenderPartner() { if (openPartnerId) renderPartner().catch(() => {}); },
  formPartner(id) {
    const p = id ? S.partnerById.get(id) : {};
    openSheet(`${sheetHead(id ? 'Edit service partner' : 'Add a service partner', 'A technician or repair shop you send laptops to')}
    <label>Name</label><input id="pname" value="${esc(p.name || '')}" placeholder="e.g. Ravi">
    <label>Shop or technician name</label><input id="pshop" value="${esc(p.shop_name || '')}" placeholder="e.g. Ravi Chip Repair">
    <label>Mobile</label><input id="pmob" type="tel" inputmode="tel" value="${esc(p.mobile || '')}">
    <label>Address (optional)</label><input id="paddr" value="${esc(p.address || '')}">
    <label>What they repair</label>${multiChips('pskills', SKILLS, p.skills || [])}
    ${id ? `<label class="tog"><input type="checkbox" id="pactive" ${p.active ? 'checked' : ''}>Active (shown when giving a laptop)</label>` : ''}
    <button style="width:100%;margin-top:16px;padding:14px" onclick="A.savePartner(${id ? `'${id}'` : 'null'})">Save</button>`);
  },
  async savePartner(id) {
    if (!val('pname')) return toast('Enter the partner name');
    await guard(async () => {
      await write('save_service_partner', { p_id: id, p_name: val('pname'), p_shop_name: val('pshop'), p_mobile: val('pmob'), p_address: val('paddr'),
        p_skills: multiVals('pskills'), p_active: id ? $('pactive').checked : true });
      closeModal(); await load(); toast('Partner saved', 'ok');
    });
  }
};
