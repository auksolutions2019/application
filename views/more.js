// More menu and its screens.
import { $, esc, rs, fmtD, tag, sum, stat, chips, chipVal, val, num, todayIN, enc, dec, MON } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, empty, openSheet, sheetHead, closeModal, confirmBox, dialog, guard, METHODS } from '../ui/feedback.js';
import { S, load, isAdmin, isMgr, role } from '../api/store.js';
import { read, write, fn, client } from '../api/client.js';
import { lapName } from '../ui/specs.js';
import { onShelf, testsPassed } from './common.js';

let moneyDay = null, sharePrice = true, shareTested = true, actF = 'all', older = [], shopMonth = null;
const ROLE_NAME = { admin: 'Admin', coadmin: 'Co-admin', staff: 'Staff' };

export const views = {
  more() {
    const it = (v, ic, t, s) => `<a onclick="A.go('${v}')">${ICON[ic]}<span>${t}<small>${s}</small></span></a>`;
    const mgr = isMgr(), adm = isAdmin();
    return `<div class="card more">${mgr ? it('money', 'cash', "Today's money", 'Cash, UPI and bank in and out for any day') : ''}${it('share', 'share', 'Share stock list', 'Ready-made WhatsApp message of what is available')}${it('prices', 'tag', 'Model prices', 'Usual selling price for each model')}${it('partners', 'tool', 'Service partners', 'Technicians and repair shops, laptops with them')}</div>
    ${mgr ? `<div class="card more">${it('reports', 'chart', 'Reports', 'Sales, profit, lead sources and graphs by month and year')}${it('suppliers', 'truck', 'Suppliers', adm ? 'Supplier numbers and what you owe each one' : 'Supplier numbers and repair quality')}${adm ? it('debts', 'wallet', 'Liabilities', 'Supplier and service dues, rent, loans and borrowed money') + it('shopexp', 'cash', 'Shop expenses', 'Rent, electricity, salaries and other running costs') + it('lotpnl', 'list', 'Lot P&L', 'Cost, sales and profit of each lot') : ''}${it('activity', 'list', 'Activity', 'Who did what, and when')}</div>` : ''}
    <div class="card more">${adm ? it('users', 'user', 'Users', 'Add people, change roles, reset PINs') + it('settings', 'gear', 'Settings', 'Shop details, warranty and photo storage') + it('backup', 'cloud', 'Backup and import', 'Download, restore, bring in the Excel or old app data') : ''}${it('pin', 'key', 'Change my PIN', 'Your 6-digit login PIN')}</div>`;
  },

  async money() {
    const d = moneyDay || (moneyDay = todayIN());
    const m = await read('money_day', { p_date: d });
    const ins = m.ins || [], outs = m.outs || [];
    const cashIn = ins.filter(x => x.m !== 'Exchange'), ex = ins.filter(x => x.m === 'Exchange');
    const by = (a, k) => sum(a.filter(x => x.m === k), x => x.amt);
    const row = x => `<div class="lrow" style="cursor:default"><span class="cm">${esc(x.t)}</span><span class="mtag">${esc(x.m)}</span><b>${rs(x.amt)}</b></div>`;
    return `<div class="card"><div class="row nw" style="align-items:center"><h3 style="margin:0">Money on</h3><input type="date" value="${d}" max="${todayIN()}" onchange="A.setMoneyDay(this.value)" style="max-width:170px"></div></div>
    <div class="grid">${METHODS.map(k => stat(k + ' in', rs(by(cashIn, k)))).join('')}${stat('Paid out', rs(sum(outs, x => x.amt)))}</div>
    <div class="card"><h3>Cash drawer check</h3><div class="kv"><span>Cash received</span><b>${rs(by(cashIn, 'Cash'))}</b></div><div class="kv"><span>Cash paid out</span><b>−${rs(by(outs, 'Cash'))}</b></div><div class="kv"><span>Cash change for the day</span><b style="color:${by(cashIn, 'Cash') - by(outs, 'Cash') >= 0 ? 'var(--green)' : 'var(--red)'}">${rs(by(cashIn, 'Cash') - by(outs, 'Cash'))}</b></div>
    <p class="muted" style="margin-top:8px">Built from the payments you already entered. Nothing extra to type.</p></div>
    <h3 class="sh">Money in</h3><div class="list">${cashIn.length ? cashIn.map(row).join('') : '<p class="muted" style="padding:16px">Nothing received on this day.</p>'}</div>
    ${ex.length ? `<h3 class="sh">Exchange laptops taken (not cash)</h3><div class="list">${ex.map(row).join('')}</div>` : ''}
    <h3 class="sh">Money out</h3><div class="list">${outs.length ? outs.map(row).join('') : '<p class="muted" style="padding:16px">Nothing paid out on this day.</p>'}</div>`;
  },

  share() {
    const avail = S.d.laptops.filter(l => onShelf(l) && !l.booking && (!shareTested || testsPassed(l)));
    const g = {}; avail.forEach(l => { const k = lapName(l); (g[k] = g[k] || { sh: l.shorthand, n: 0 }).n++; });
    const rows = Object.entries(g).sort((a, b) => b[1].n - a[1].n);
    const st = S.d.settings, prices = S.d.prices || {};
    const txt = `*${st.shop_name}*\nAvailable today, ${fmtD(todayIN())}\n\n${rows.map(([k, v]) => `• ${k}${sharePrice && prices[v.sh] ? ` – ${rs(prices[v.sh])}` : ''}${v.n > 1 ? ` (${v.n} pcs)` : ''}`).join('\n')}\n\nAll laptops tested, with warranty.\nVisit: ${st.addr}\nCall or WhatsApp: ${st.phone}`;
    window._shareTxt = txt;
    return `<div class="card"><h3>Stock list for WhatsApp</h3><p class="muted">Send this to customers or groups. Booked, sold and at-service laptops are left out.</p>
    <label class="tog"><input type="checkbox" ${sharePrice ? 'checked' : ''} onchange="A.shareOpt('price',this.checked)">Show prices (set them in Model prices)</label>
    <label class="tog"><input type="checkbox" ${shareTested ? 'checked' : ''} onchange="A.shareOpt('tested',this.checked)">Only laptops that passed all tests</label>
    <pre class="sharebox">${esc(txt)}</pre>
    <div class="row"><a class="btnlink solid" target="_blank" href="https://wa.me/?text=${encodeURIComponent(txt)}">${ICON.wa}Share on WhatsApp</a><button class="ghost" onclick="A.copyShare()">Copy text</button></div></div>`;
  },

  prices() {
    const g = {};
    S.d.laptops.forEach(l => { if (!l.shorthand) return; const k = l.shorthand; (g[k] = g[k] || { n: 0, inS: 0, cost: 0, costN: 0 }).n++; if (!l.sale) { g[k].inS++; if (l.full_cost != null) { g[k].cost += +l.full_cost; g[k].costN++; } } });
    Object.keys(S.d.prices || {}).forEach(k => { g[k] = g[k] || { n: 0, inS: 0, cost: 0, costN: 0 }; });
    const rows = Object.entries(g).sort((a, b) => b[1].inS - a[1].inS), adm = isAdmin();
    return `<div class="card"><h3>Usual selling price per model</h3><p class="muted">${adm ? 'Set once. The sale form fills it in, and the WhatsApp stock list can show it.' : 'Set by the admin. The sale form fills it in.'}</p></div>
    <div class="list">${rows.length ? rows.map(([m, v]) => { const avg = v.costN ? v.cost / v.costN : 0, p = S.d.prices?.[m] || 0;
      return `<div class="crow"><div class="cm"><b>${esc(m)}</b><div class="muted">${v.inS} in stock${adm && avg ? `, average cost ${rs(avg)}` : ''}</div>${p && avg && adm ? `<div class="muted" style="color:${p < avg ? 'var(--red)' : 'var(--green)'}">${p < avg ? 'Below cost by ' + rs(avg - p) : 'Profit about ' + rs(p - avg) + ' each'}</div>` : ''}</div>
      ${adm ? `<div class="pin"><span>₹</span><input type="number" inputmode="decimal" value="${p || ''}" placeholder="Price" onchange="A.setPrice('${enc(m)}',this.value)"></div>` : `<b>${p ? rs(p) : '–'}</b>`}</div>`; }).join('')
      : empty(ICON.tag, 'No models yet', 'Models appear here once laptops have their specs entered.')}</div>`;
  },

  activity() {
    const all = [...S.d.activity, ...older];
    const L = all.filter(x => actF === 'all' || x.actor_role === actF);
    let last = '';
    const rows = L.map(x => { const dt = new Date(x.at), day = dt.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }), h = day !== last ? `${last ? '</div>' : ''}<h3 class="sh">${day}</h3><div class="list">` : ''; last = day;
      return h + `<div class="lrow" style="cursor:default"><span class="when">${dt.toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' })}</span><span class="cm">${esc(x.message)}</span><span class="pill ${x.actor_role === 'admin' ? 'stock' : 'grey'}">${esc(x.actor_name)}</span></div>`; }).join('');
    return `<div class="seg"><button class="${actF === 'all' ? 'on' : ''}" onclick="A.actFilter('all')">Everyone</button><button class="${actF === 'admin' ? 'on' : ''}" onclick="A.actFilter('admin')">Admin</button><button class="${actF === 'coadmin' ? 'on' : ''}" onclick="A.actFilter('coadmin')">Co-admin</button><button class="${actF === 'staff' ? 'on' : ''}" onclick="A.actFilter('staff')">Staff</button></div>
    ${L.length ? rows + '</div>' : empty(ICON.list, 'Nothing recorded yet', 'Every sale, payment and change is listed here with who did it.')}
    ${all.length >= 300 ? `<button class="ghost" style="width:100%;margin-top:12px" onclick="A.olderActivity()">Show older</button>` : ''}`;
  },

  settings() {
    const st = S.d.settings;
    return `<div class="card"><h3>Shop details</h3><p class="muted">Printed on bills and the WhatsApp stock list.</p>
    <label>Shop name</label><input id="st_shop_name" value="${esc(st.shop_name)}">
    <label>Phone and WhatsApp</label><input id="st_phone" value="${esc(st.phone)}">
    <label>Address</label><input id="st_addr" value="${esc(st.addr)}">
    <div class="row nw"><div><label>Default warranty (months)</label><input id="st_warranty" type="number" value="${st.default_warranty_months}"></div><div><label>Old stock after (days)</label><input id="st_old" type="number" value="${st.old_days}"></div></div></div>
    <div class="card"><h3>Photos (Cloudinary)</h3><p class="muted">Laptop photos are stored in your free Cloudinary account, not on the phone. Photos are shrunk before upload to save your free credits.</p>
    <label>Cloud name</label><input id="st_cloud" value="${esc(st.cloud_name)}" placeholder="e.g. dxyz123ab" autocapitalize="off">
    <label>Unsigned upload preset</label><input id="st_preset" value="${esc(st.upload_preset)}" placeholder="e.g. fcl_laptops" autocapitalize="off">
    <details class="tipbox"><summary>How to get these</summary><ol><li>Sign in at cloudinary.com. The cloud name is on the dashboard.</li><li>Go to Settings, then Upload, then Upload presets, and tap Add upload preset.</li><li>Set Signing mode to Unsigned, save, and copy the preset name here.</li></ol></details></div>
    <button style="width:100%;padding:14px" onclick="A.saveSettings()">Save settings</button>`;
  },

  async shopexp() {
    const m = shopMonth || (shopMonth = todayIN().slice(0, 7));
    const [y, mo] = m.split('-').map(Number), last = new Date(y, mo, 0).getDate();
    const rows = await read('shop_expense_list', { p_from: `${m}-01`, p_to: `${m}-${String(last).padStart(2, '0')}` });
    return `<div class="card"><div class="row nw" style="align-items:center"><h3 style="margin:0">Month</h3><input type="month" value="${m}" onchange="A.setShopMonth(this.value)" style="max-width:170px"></div></div>
    <div class="grid">${stat('Shop expenses', rs(sum(rows, x => x.amount)))}${stat('From Liabilities', rs(sum(rows.filter(x => x.from_liabilities), x => x.amount)))}</div>
    <button class="addbig" onclick="A.formShopExp()">${ICON.plus}Add a shop expense</button>
    <div class="list">${rows.length ? rows.map(x => `<div class="lrow" style="cursor:default"><span class="cm"><b>${esc(x.type)}</b><span class="muted">${fmtD(x.spent_on)}${x.note ? ', ' + esc(x.note) : ''}${x.ref ? ', ' + esc(x.ref) : ''}</span></span>
      ${x.from_liabilities ? '<span class="mtag">from Liabilities</span>' : `<span class="mtag">${esc(x.method)}</span>`}<b>${rs(x.amount)}</b>${x.from_liabilities ? '' : `<button class="sm ghost" onclick="A.delShopExp('${x.id}')" aria-label="Delete">${ICON.trash}</button>`}</div>`).join('')
      : '<p class="muted" style="padding:16px">No shop expenses this month.</p>'}</div>
    <p class="muted" style="margin:8px 2px">Rent and bills paid in Liabilities show here by themselves, so they are never entered twice.</p>`;
  },

  async lotpnl() {
    const rows = await read('lot_pnl');
    return `<div class="list">${rows.length ? rows.map(x => `<div class="crow" style="cursor:pointer" onclick="A.openLot && A.openLot('${(S.d.lots.find(l => l.prefix === x.prefix) || {}).id}')">
      <div class="cm">${tag(x.prefix)}<div class="muted" style="margin-top:4px">${esc(x.supplier)}, ${fmtD(x.bought_on)}${x.note ? ', ' + esc(x.note) : ''}</div>
      <div class="qual"><span>${x.sold} sold, ${x.left} left</span><span>Cost ${rs(x.total_cost)}${x.cost_missing ? ` <b class="mid">(${x.cost_missing} cost missing)</b>` : ''}</span><span>Sales ${rs(x.sales)}</span></div></div>
      <div class="cr"><span class="pill ${x.status === 'Sold out' ? 'sold' : x.status === 'Unsold' ? 'grey' : 'stock'}">${x.status}</span><b style="color:${x.gross >= 0 ? 'var(--green)' : 'var(--red)'}">${rs(x.gross)}</b><span class="muted">${x.margin_pct != null ? x.margin_pct + '% margin' : ''}</span></div></div>`).join('')
      : empty(ICON.list, 'No lots yet', 'Lots appear here once they are added.')}</div>
    <p class="muted" style="margin:8px 2px">Profit is for the laptops sold so far: sale price minus their cost, parts, repairs and service. Laptops with cost missing are left out of profit.</p>`;
  },

  async users() {
    const { data, error } = await client().from('profiles').select('id,name,mobile,role,active,last_login_at').order('name');
    if (error) throw new Error(error.message);
    return `<button class="addbig" onclick="A.formUser()">${ICON.plus}Add a user</button>
    <div class="list">${data.map(u => `<div class="crow userrow"><div class="av">${esc(u.name.slice(0, 2).toUpperCase())}</div>
      <div class="cm"><b>${esc(u.name)}${u.id === S.d.me.id ? ' (you)' : ''}</b><div class="muted">+91 ${esc(u.mobile)}, <b>${ROLE_NAME[u.role]}</b>${u.active ? '' : ', <span style="color:var(--red)">turned off</span>'}${u.last_login_at ? `, last login ${fmtD(u.last_login_at)}` : ''}</div></div>
      <div class="cr"><div class="acts"><button class="sm ghost" onclick="A.userRole('${u.id}','${u.role}','${enc(u.name)}')">Role</button><button class="sm ghost" onclick="A.userPin('${u.id}','${enc(u.name)}')">Reset PIN</button>
      ${u.id === S.d.me.id ? '' : `<button class="sm ${u.active ? 'red' : ''}" onclick="A.userActive('${u.id}',${!u.active},'${enc(u.name)}')">${u.active ? 'Turn off' : 'Turn on'}</button>`}</div></div></div>`).join('')}</div>
    <p class="muted" style="margin:8px 2px">Turned-off users cannot log in, and their history stays.</p>`;
  },

  pin() {
    return `<div class="card"><h3>Change my PIN</h3><p class="muted">Your PIN is 6 digits. Do not share it.</p>
    <label>Current PIN</label><input id="pin_old" class="pinf" type="password" inputmode="numeric" maxlength="6" autocomplete="current-password">
    <label>New PIN</label><input id="pin_new" class="pinf" type="password" inputmode="numeric" maxlength="6" autocomplete="new-password">
    <label>New PIN again</label><input id="pin_new2" class="pinf" type="password" inputmode="numeric" maxlength="6" autocomplete="new-password">
    <button style="width:100%;margin-top:16px" onclick="A.changePin()">Change PIN</button></div>`;
  }
};

const pinOk = p => /^\d{6}$/.test(p) && !/^(\d)\1{5}$/.test(p) && !['123456', '654321'].includes(p);

export const actions = {
  setMoneyDay(v) { moneyDay = v || todayIN(); A.refresh(); },
  setShopMonth(v) { shopMonth = v || todayIN().slice(0, 7); A.refresh(); },
  shareOpt(k, v) { if (k === 'price') sharePrice = v; else shareTested = v; A.refresh(); },
  copyShare() { (navigator.clipboard ? navigator.clipboard.writeText(window._shareTxt) : Promise.reject()).then(() => toast('Copied', 'ok')).catch(() => toast('Long-press the text to copy it')); },
  async setPrice(m, v) { m = dec(m); const n = +v; await guard(async () => { await write('set_model_price', { p_shorthand: m, p_price: n > 0 ? n : null }); await load(); toast('Price saved', 'ok'); }); },
  actFilter(f) { actF = f; A.refresh(); },
  async olderActivity() {
    const all = [...S.d.activity, ...older];
    await guard(async () => { const more = await read('activity_page', { p_before: all.at(-1).id }); older = older.concat(more); if (!more.length) toast('Nothing older'); A.refresh(); });
  },
  async saveSettings() {
    await guard(async () => {
      await write('save_settings', { p_shop_name: val('st_shop_name'), p_phone: val('st_phone'), p_addr: val('st_addr'), p_default_warranty_months: num('st_warranty') || 0,
        p_old_days: num('st_old') || 60, p_cloud_name: val('st_cloud'), p_upload_preset: val('st_preset') });
      await load(); toast('Settings saved', 'ok');
    });
  },
  formShopExp() {
    openSheet(`${sheetHead('Add a shop expense', 'Running costs not tied to a lot')}
    <label>Type</label>${chips('setype', ['Rent', 'Electricity', 'Salary', 'Internet', 'Transport', 'Other'], 'Salary', 'wrap')}
    <div class="row nw"><div><label>Amount (₹)</label><input id="seamt" type="number" inputmode="decimal"></div><div><label>Date</label><input id="sedate" type="date" value="${todayIN()}" max="${todayIN()}"></div></div>
    ${chips('semeth', METHODS, 'Cash')}<input id="seref" placeholder="Ref / UTR (optional)">
    <label>Note</label><input id="senote" placeholder="e.g. Imran, November salary">
    <button style="width:100%;margin-top:16px;padding:14px" onclick="A.saveShopExp()">Save</button>`);
  },
  async saveShopExp() {
    const a = num('seamt'); if (!a) return toast('Enter the amount');
    await guard(async () => { await write('add_shop_expense', { p_type: chipVal('setype'), p_amount: a, p_method: chipVal('semeth'), p_ref: val('seref'), p_note: val('senote'), p_spent_on: val('sedate') || null }); closeModal(); await load(); toast('Saved', 'ok'); });
  },
  async delShopExp(id) {
    if (!await confirmBox('Delete this expense?', 'It is removed from the month\'s net profit.', 'Delete', 1)) return;
    await guard(async () => { await write('delete_shop_expense', { p_id: id }); await load(); });
  },
  formUser() {
    openSheet(`${sheetHead('Add a user', 'They log in with their mobile number and the PIN you set')}
    <label>Name</label><input id="uname" placeholder="e.g. Imran">
    <label>Mobile number</label><div class="mob"><span>+91</span><input id="umob" type="tel" inputmode="numeric" maxlength="10"></div>
    <label>Role</label>${chips('urole', [['staff', 'Staff'], ['coadmin', 'Co-admin'], ['admin', 'Admin']], 'staff')}
    <p class="muted" style="margin-top:4px">Staff: scan, stock, tests, repairs, photos, service, booking and selling. Co-admin: also lots, payments, customers, reports. Admin: everything.</p>
    <label>First PIN (6 digits)</label><input id="upin" class="pinf" type="password" inputmode="numeric" maxlength="6" autocomplete="new-password">
    <button style="width:100%;margin-top:16px;padding:14px" onclick="A.addUser()">Add user</button>`);
  },
  async addUser() {
    const name = val('uname'), mobile = val('umob').replace(/\D/g, '').slice(-10), pin = val('upin');
    if (!name) return toast('Enter the name');
    if (!/^[6-9]\d{9}$/.test(mobile)) return toast('Enter a 10-digit mobile number');
    if (!pinOk(pin)) return toast('Choose a 6-digit PIN that is not easy to guess');
    await guard(async () => { await fn('admin-users', { action: 'create', name, mobile, role: chipVal('urole'), pin }); closeModal(); toast(`${name} added. They can log in now.`, 'ok'); A.refresh(); });
  },
  async userRole(id, cur, name) {
    name = dec(name);
    openSheet(`${sheetHead('Change role', esc(name))}${chips('nrole', [['staff', 'Staff'], ['coadmin', 'Co-admin'], ['admin', 'Admin']], cur)}
    <button style="width:100%;margin-top:16px" onclick="A.saveRole('${id}')">Save</button>`);
  },
  async saveRole(id) { await guard(async () => { await fn('admin-users', { action: 'set_role', user_id: id, role: chipVal('nrole') }); closeModal(); toast('Role changed', 'ok'); A.refresh(); }); },
  async userPin(id, name) {
    const pin = await dialog({ title: 'Reset PIN', body: `New 6-digit PIN for ${esc(dec(name))}. They will be logged out on their phone.`, ok: 'Reset PIN', text: true, placeholder: '6 digits' });
    if (pin == null) return;
    if (!pinOk(pin.trim())) return toast('Choose a 6-digit PIN that is not easy to guess');
    await guard(async () => { await fn('admin-users', { action: 'reset_pin', user_id: id, pin: pin.trim() }); toast('PIN reset', 'ok'); });
  },
  async userActive(id, on, name) {
    name = dec(name);
    if (!on && !await confirmBox(`Turn off ${esc(name)}?`, 'They cannot log in any more, and are logged out now. Their history stays.', 'Turn off', 1)) return;
    await guard(async () => { await fn('admin-users', { action: 'set_active', user_id: id, active: on }); toast(on ? `${name} can log in again` : `${name} is turned off`, 'ok'); A.refresh(); });
  },
  async changePin() {
    const o = val('pin_old'), n = val('pin_new'), n2 = val('pin_new2');
    if (!/^\d{6}$/.test(o)) return toast('Enter your current 6-digit PIN');
    if (!pinOk(n)) return toast('Choose a new 6-digit PIN that is not easy to guess');
    if (n !== n2) return toast('The two new PINs do not match');
    await guard(async () => {
      try { await fn('change-pin', { old_pin: o, new_pin: n }); }
      catch (e) { if (e.data?.error === 'locked') throw new Error('Too many wrong PINs. Try again in 15 minutes.'); throw e; }
      ['pin_old', 'pin_new', 'pin_new2'].forEach(i => { $(i).value = ''; });
      toast('PIN changed', 'ok');
    });
  }
};
