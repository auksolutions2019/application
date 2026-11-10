// Customers, Suppliers, Liabilities.
import { $, esc, rs, fmtD, tag, sum, chips, chipVal, val, num, initials, waLink, enc, dec, daysSince, todayIN } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, empty, openSheet, sheetHead, closeModal, confirmBox, amountBox, dialog, guard } from '../ui/feedback.js';
import { noteLine, thumb } from './common.js';
import { S, load, isAdmin } from '../api/store.js';
import { read, write } from '../api/client.js';

let custF = 'due', custs = null;
const waMsg = c => c.due > 0
  ? `Assalamu Alaikum ${c.name}, this is ${S.d.settings.shop_name}, R.T Nagar. A balance of ${rs(c.due)} is pending for your laptop purchase. Kindly clear it at your convenience. Thank you.`
  : `Assalamu Alaikum ${c.name}, thank you for buying from ${S.d.settings.shop_name}, R.T Nagar.`;

export const views = {
  async sales() {
    custs = await read('customer_summary');
    const list = custs.map(c => ({ ...c, days: c.oldest_due ? daysSince(c.oldest_due) : 0 }));
    const pend = list.filter(c => c.due > 0);
    const shown = (custF === 'due' ? pend : list).sort((a, b) => custF === 'due' ? b.days - a.days || b.due - a.due : String(b.last).localeCompare(String(a.last)));
    const over30 = pend.filter(c => c.days > 30).length;
    return `<section class="hero mini"><div class="l">Customers owe you</div><div class="n" style="font-size:36px">${rs(sum(pend, c => c.due))}</div><div class="l">from ${pend.length} customer${pend.length === 1 ? '' : 's'}${over30 ? `, ${over30} pending over 30 days` : ''}</div></section>
    <div class="seg"><button class="${custF === 'due' ? 'on' : ''}" onclick="A.custTab('due')">Owes money</button><button class="${custF === 'all' ? 'on' : ''}" onclick="A.custTab('all')">All customers</button></div>
    <div class="list">${shown.length ? shown.map(c => `<div class="crow">
      <div class="av">${esc(initials(c.name))}</div>
      <div class="cm"><b>${esc(c.name)}${c.customer_type === 'Dealer' ? ' <span class="mtag">Dealer</span>' : ''}</b><div class="muted">${c.n} laptop${c.n > 1 ? 's' : ''}, last on ${fmtD(c.last)}</div>${c.due > 0 ? `<div class="age ${c.days > 30 ? 'bad' : ''}">Pending ${c.days} day${c.days === 1 ? '' : 's'}</div>` : ''}</div>
      <div class="cr">${c.due > 0 ? `<span class="pill due">${rs(c.due)}</span>` : '<span class="pill sold">Paid up</span>'}
       <div class="acts"><a class="ib" href="tel:${esc(c.mobile)}" aria-label="Call">${ICON.phone}</a><a class="ib wa" href="${esc(waLink(c.mobile, waMsg(c)))}" target="_blank" aria-label="WhatsApp">${ICON.wa}</a>${c.due > 0 ? `<button class="sm" onclick="A.payCustomer('${enc(c.mobile)}')">Receive</button>` : ''}</div></div>
      <div class="codes">${(c.codes || []).map(code => `<span class="codet" onclick="A.openLaptop('${esc(code)}')">${thumb(code, 'sm')}${tag(code)}</span>`).join('')}${c.n > 4 ? `<span class="muted" style="align-self:center">+${c.n - 4} more</span>` : ''}</div>
     </div>`).join('') : empty(ICON.cust, custF === 'due' ? 'Nobody owes you money' : 'No customers yet', custF === 'due' ? 'Every sale is fully paid.' : 'Customers with a mobile number appear here after a sale.')}</div>`;
  },

  suppliers() {
    const adm = isAdmin(), list = S.d.suppliers;
    return `${adm ? `<button class="addbig" onclick="A.formSupplier()">${ICON.plus}Add a supplier</button>` : ''}
    <div class="list">${list.length ? list.map(s => {
      const q = s.quality, lots = S.d.lots.filter(x => x.supplier_id === s.id).length;
      return `<div class="crow" ${adm && s.code !== '00' ? `style="cursor:pointer" onclick="A.supPayments('${s.id}')"` : ''}><div class="av sq">${esc(s.code)}</div>
      <div class="cm"><b>${esc(s.name)}</b><div class="muted">${lots} lot${lots === 1 ? '' : 's'}${adm ? `, bought ${rs(s.bought)}` : ''}${adm && s.cost_missing ? ` <span class="warnmark">${s.cost_missing} cost missing</span>` : ''}</div>
       ${q ? `<div class="qual"><span class="${q.pct_rep > 50 ? 'bad' : q.pct_rep > 25 ? 'mid' : 'good'}">${q.pct_rep}% needed repair</span><span>Repairs ${rs(q.avg_rep)} per laptop</span>${adm && q.avg_profit != null ? `<span>Profit ${rs(q.avg_profit)} each</span>` : ''}</div>` : ''}
       ${adm && s.code !== '00' ? `<div class="prog sm"><i style="width:${s.bought ? Math.min(100, s.paid / s.bought * 100) : 0}%;background:var(--green)"></i></div>` : ''}</div>
      <div class="cr">${adm && s.code !== '00' ? (s.due > 0 ? `<span class="pill due">${rs(s.due)}</span>` : '<span class="pill sold">Settled</span>') : ''}
       <div class="acts">${s.phone ? `<a class="ib" href="tel:${esc(s.phone)}" aria-label="Call">${ICON.phone}</a>` : ''}${adm && s.code !== '00' ? `<button class="sm" onclick="event.stopPropagation();A.paySup('${s.id}')">Pay</button>` : ''}</div></div></div>`;
    }).join('') : empty(ICON.truck, 'No suppliers yet', 'Add the people you buy lots from. Each gets a number used in the sticker codes.')}</div>`;
  },

  debts() {
    const d = S.d, sd = d.suppliers.filter(s => s.due > 0 && s.code !== '00'), parts = (d.partners || []).filter(p => p.owed > 0);
    const other = d.debts.filter(x => x.balance > 0), cleared = d.debts.filter(x => x.balance <= 0);
    const tot = sum(sd, s => s.due) + sum(parts, p => p.owed) + sum(other, x => x.balance);
    const drow = x => `<div class="crow"><div class="av sq" style="background:#FCE8E6;color:#C4362E">${ICON.wallet}</div>
      <div class="cm"><b>${esc(x.name)}</b><div class="muted">${esc(x.type)}${x.due_on ? `, due ${fmtD(x.due_on)}` : ''}${x.due_on && x.due_on < todayIN() && x.balance > 0 ? ' <b style="color:var(--red)">overdue</b>' : ''}</div>
      <div class="prog sm"><i style="width:${Math.min(100, (x.amount - x.balance) / x.amount * 100)}%;background:var(--green)"></i></div></div>
      <div class="cr">${x.balance > 0 ? `<span class="pill due">${rs(x.balance)}</span>` : '<span class="pill sold">Cleared</span>'}
      <div class="acts">${x.payments?.length ? `<button class="sm ghost" onclick="A.debtPayments('${x.id}')">History</button>` : ''}${x.balance > 0 ? `<button class="sm" onclick="A.payDebt('${x.id}')">Pay</button>` : ''}<button class="sm ghost" onclick="A.delDebt('${x.id}')" aria-label="Delete">${ICON.trash}</button></div></div></div>`;
    return `<section class="hero mini"><div class="l">You owe in total</div><div class="n" style="font-size:36px">${rs(tot)}</div><div class="l">${rs(sum(sd, s => s.due))} to suppliers, ${rs(sum(parts, p => p.owed))} to service partners, ${rs(sum(other, x => x.balance))} other</div></section>
    <button class="addbig" onclick="A.formDebt()">${ICON.plus}Add rent, loan or other debt</button>
    ${sd.length ? `<h3 class="sh">Suppliers</h3><div class="list">${sd.map(s => `<div class="crow"><div class="av sq">${esc(s.code)}</div><div class="cm"><b>${esc(s.name)}</b><div class="muted">for laptop lots</div></div><div class="cr"><span class="pill due">${rs(s.due)}</span><div class="acts"><button class="sm" onclick="A.paySup('${s.id}')">Pay</button></div></div></div>`).join('')}</div>` : ''}
    ${parts.length ? `<h3 class="sh">Service partners</h3><div class="list">${parts.map(p => `<div class="crow"><div class="av sq">${ICON.tool}</div><div class="cm"><b>${esc(p.label)}</b><div class="muted">unpaid service charges</div></div><div class="cr"><span class="pill due">${rs(p.owed)}</span><div class="acts"><button class="sm" onclick="A.payPartner('${p.id}')">Pay</button></div></div></div>`).join('')}</div>` : ''}
    <h3 class="sh">Other debts</h3><div class="list">${other.length ? other.map(drow).join('') : '<p class="muted" style="padding:16px">No open debts.</p>'}</div>
    ${cleared.length ? `<h3 class="sh">Cleared</h3><div class="list">${cleared.map(drow).join('')}</div>` : ''}`;
  }
};

export const actions = {
  custTab(t) { custF = t; A.refresh(); },
  async payCustomer(m) {
    m = dec(m);
    const c = custs.find(x => x.mobile === m);
    const r = await amountBox(`Payment from ${esc(c.name)}`, `Balance ${rs(c.due)}. The oldest balance is cleared first.`, c.due);
    if (!r) return;
    await guard(async () => { await write('receive_customer_payment', { p_mobile: m, p_amount: r.amount, p_method: r.method, p_ref: r.ref, p_note: r.note }); await load(); toast(`${rs(r.amount)} received from ${c.name}`, 'ok'); });
  },
  formSupplier() {
    const next = String(S.d.suppliers.filter(s => s.code !== '00').reduce((m, s) => Math.max(m, +s.code), 0) + 1).padStart(2, '0');
    openSheet(`${sheetHead('Add a supplier', `They will get number <b>${next}</b>, used at the start of every sticker code`)}
    <label>Name</label><input id="sname" placeholder="e.g. Ali Traders">
    <label>Phone (optional)</label><input id="sphone" type="tel" inputmode="tel">
    <button style="width:100%;margin-top:16px;padding:14px" onclick="A.addSup()">Add supplier</button>`);
    setTimeout(() => $('sname')?.focus(), 100);
  },
  async addSup() {
    const n = val('sname'); if (!n) return toast('Enter the supplier name');
    await guard(async () => { const r = await write('add_supplier', { p_name: n, p_phone: val('sphone') }); closeModal(); await load(); toast(`${n} added as supplier ${r.code}`, 'ok'); });
  },
  async paySup(id) {
    const s = S.supById.get(id);
    const r = await amountBox(`Pay ${esc(s.name)}`, `You owe ${rs(s.due)}`, s.due > 0 ? s.due : null);
    if (!r) return;
    await guard(async () => { await write('pay_supplier', { p_supplier_id: id, p_amount: r.amount, p_method: r.method, p_ref: r.ref, p_note: r.note }); await load(); toast(`${rs(r.amount)} paid to ${s.name}`, 'ok'); });
  },
  async payPartner(id) {
    const p = S.partnerById.get(id);
    const r = await amountBox(`Pay ${esc(p.label)}`, `Owed ${rs(p.owed)} for service`, p.owed);
    if (!r) return;
    await guard(async () => { await write('pay_service_partner', { p_partner_id: id, p_amount: r.amount, p_method: r.method, p_ref: r.ref, p_note: r.note }); await load(); toast(`${rs(r.amount)} paid to ${p.label}`, 'ok'); A.rerenderPartner?.(); });
  },
  formDebt() {
    openSheet(`${sheetHead('Add a debt', 'Rent, a loan, money borrowed, or a bill')}
    <label>What is it?</label><input id="dname" placeholder="e.g. Shop rent, December">
    <label>Type</label>${chips('dtypes', ['Shop rent', 'Loan', 'Borrowed', 'Bill', 'Other'], 'Shop rent')}
    <div class="row"><div><label>Amount (₹)</label><input id="damt" type="number" inputmode="decimal"></div><div><label>Due date</label><input id="ddue" type="date"></div></div>
    <p class="muted" style="margin-top:8px">Payments of Shop rent and Bill debts also show in Shop expenses by themselves.</p>
    <button style="width:100%;margin-top:16px;padding:14px" onclick="A.addDebt()">Add debt</button>`);
  },
  async addDebt() {
    const n = val('dname'), a = num('damt'); if (!n || !a) return toast('Enter what it is and the amount');
    await guard(async () => { await write('add_debt', { p_name: n, p_type: chipVal('dtypes'), p_amount: a, p_due_on: val('ddue') || null }); closeModal(); await load(); toast(n + ' added', 'ok'); });
  },
  async payDebt(id) {
    const x = S.d.debts.find(d => d.id === id);
    const r = await amountBox(`Pay: ${esc(x.name)}`, `Balance ${rs(x.balance)}`, x.balance);
    if (!r) return;
    await guard(async () => { await write('pay_debt', { p_debt_id: id, p_amount: r.amount, p_method: r.method, p_ref: r.ref, p_note: r.note }); await load(); toast(`${rs(r.amount)} paid`, 'ok'); });
  },
  // Payment history with notes (admin)
  supPayments(id) {
    const s = S.supById.get(id);
    openSheet(`${sheetHead(esc(s.name), `Supplier ${esc(s.code)}: bought ${rs(s.bought)}, paid ${rs(s.paid)}, owed ${rs(s.due)}`)}
    <div class="list flat">${(s.payments || []).length ? s.payments.map(p => `<div class="lrow" style="cursor:default"><span class="cm">${fmtD(p.paid_on)}<span class="mtag">${esc(p.method)}</span>${p.ref ? `<span class="muted"> ${esc(p.ref)}</span>` : ''}${noteLine(p.note, 'supplier_payment', p.id)}</span><b>${rs(p.amount)}</b></div>`).join('') : '<p class="muted" style="padding:12px">No payments yet.</p>'}</div>
    ${s.due > 0 ? `<button style="width:100%;margin-top:14px" onclick="A.closeModal();A.paySup('${s.id}')">Pay</button>` : ''}`);
  },
  debtPayments(id) {
    const x = S.d.debts.find(d => d.id === id);
    openSheet(`${sheetHead(esc(x.name), `${esc(x.type)}: ${rs(x.amount)}, balance ${rs(x.balance)}`)}
    <div class="list flat">${x.payments.map(p => `<div class="lrow" style="cursor:default"><span class="cm">${fmtD(p.paid_on)}<span class="mtag">${esc(p.method)}</span>${p.ref ? `<span class="muted"> ${esc(p.ref)}</span>` : ''}${noteLine(p.note, 'debt_payment', p.id)}</span><b>${rs(p.amount)}</b></div>`).join('')}</div>`);
  },
  // The admin changes a note later (never the amount); the old text stays in Activity
  async editNote(kind, id, cur) {
    const v = await dialog({ title: 'Edit note', body: 'The amount cannot change. The old note is kept in Activity.', ok: 'Save note', text: true, value: dec(cur), placeholder: 'Note' });
    if (v === null) return;
    await guard(async () => { await write('edit_payment_note', { p_kind: kind, p_id: id, p_note: v });
      if (!document.querySelector('#sheet .acts3, #sheet [data-partner]')) A.closeModal();   // the laptop pop-up and partner page refresh in place
      await load(); toast('Note saved', 'ok'); A.rerenderPartner?.(); });
  },
  async delDebt(id) {
    if (!await confirmBox('Delete this debt?', 'It is hidden from Liabilities. Its payments stay in the history.', 'Delete', 1)) return;
    await guard(async () => { await write('delete_debt', { p_debt_id: id }); await load(); });
  }
};
