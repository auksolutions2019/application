// Backup and import (admin): download a backup, restore one, bring in the old app's backup or the dealer's Excel.
import { $, esc, rs, todayIN, enc, dec } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, confirmBox, dialog, guard } from '../ui/feedback.js';
import { S, load } from '../api/store.js';
import { read, write } from '../api/client.js';
import { readWorkbook, defaultAnswers, buildPlan, NOT_NAMES } from '../lib/excel-plan.js';

let xl = null;    // { raw, answers, expected }
const LEAD_OPTS = ['OLX', 'Instagram', 'Lead Matrix', 'Circle app', 'Octo', 'Walk-in', 'Old customer', 'Dealer', 'Other'];

function loadScript(src) {
  return new Promise((res, rej) => { if (window.XLSX) return res(); const s = document.createElement('script'); s.src = src; s.onload = res; s.onerror = () => rej(new Error('Could not load the Excel reader')); document.head.appendChild(s); });
}
function readFile(f, asText) {
  return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = () => rej(new Error('Could not read the file')); asText ? r.readAsText(f) : r.readAsArrayBuffer(f); });
}
const hasData = () => S.d.lots.some(x => x.kind !== 'exchange') || S.d.laptops.some(l => l.sale);

function excelPreview() {
  const P = buildPlan(xl.raw, xl.answers), t = P.totals, a = xl.answers, ex = xl.expected;
  const cmp = (label, got, want) => `<div class="kv"><span>${label}</span><b>${typeof got === 'number' && label !== 'Lots' && label !== 'Laptops' && label !== 'Sales (laptops)' ? rs(got) : got}
    ${want != null && want !== '' ? (Math.round(got) === Math.round(+want) ? ' <span style="color:var(--green)">✓ matches</span>' : ` <span style="color:var(--red)">✗ Excel says ${rs(want)}</span>`) : ''}</b></div>`;
  const errors = P.flags.filter(f => f.kind === 'error');
  return `<div class="card"><h3>Excel import: check before saving</h3><p class="muted">Nothing is saved until you press Import. Change anything below that is not right, and the totals update.</p>
  ${cmp('Lots', t.lots)}${cmp('Laptops', t.laptops)}${cmp('Lot cost', t.cost)}<div class="kv"><span>Laptops with cost missing</span><b>${t.cost_missing}</b></div>
  ${cmp('Sales (laptops)', t.sales)}${cmp('Total sales', t.sales_total, ex.sales)}
  ${Object.entries(t.sales_by_month).sort().map(([m, v]) => cmp('Sales ' + m, v, ex.months[m])).join('')}
  ${cmp('Lot expenses', t.expenses_total, ex.expenses)}
  <details class="tipbox"><summary>Excel Dashboard totals to compare with</summary>
   <label>Total sales</label><input type="number" value="${esc(ex.sales)}" onchange="A.xlExpect('sales',this.value)">
   ${Object.keys(t.sales_by_month).sort().map(m => `<label>Sales ${m}</label><input type="number" value="${esc(ex.months[m] ?? '')}" onchange="A.xlExpect('m:${m}',this.value)">`).join('')}
   <label>Total expenses</label><input type="number" value="${esc(ex.expenses)}" onchange="A.xlExpect('expenses',this.value)"></details></div>
  ${errors.length ? `<div class="note bad">${ICON.alert}<span>${errors.map(f => esc(f.text)).join('<br>')}</span></div>` : ''}
  <div class="card"><h3>Lots</h3>${P.lotKeys.map(k => { const fl = P.flags.filter(f => f.lot === k);
    return `<div class="preview-flag" style="${fl.length ? '' : 'background:var(--ice)'}"><b>Excel lot ${esc(k)}</b>${fl.map(f => `<div>${esc(f.text)}</div>`).join('')}
    <div class="row nw"><div><label>Purchase date</label><input type="date" value="${esc(a.lotDates[k])}" onchange="A.xlSet('lotDates','${k}',this.value)"></div><div><label>Note</label><input value="${esc(a.lotNotes[k])}" onchange="A.xlSet('lotNotes','${k}',this.value)"></div></div>
    <div class="row nw"><div><label>Type</label><select onchange="A.xlSet('lotKinds','${k}',this.value)"><option value="purchase" ${a.lotKinds[k] === 'purchase' ? 'selected' : ''}>Bought lot</option><option value="opening" ${a.lotKinds[k] === 'opening' ? 'selected' : ''}>Opening stock</option></select></div>
    <div><label>Cost column is</label><select onchange="A.xlSet('costMode','${k}',this.value)"><option value="line" ${a.costMode[k] === 'line' ? 'selected' : ''}>Total for that row</option><option value="unit" ${a.costMode[k] === 'unit' ? 'selected' : ''}>Price of one laptop</option></select></div></div></div>`; }).join('')}</div>
  ${P.flags.filter(f => f.kind === 'wc' || f.kind === 'dup' || f.kind === 'check').length ? `<div class="card"><h3>Sales to check</h3>${P.flags.filter(f => f.kind === 'wc').map(f => `<div class="preview-flag">${esc(f.text)}<select onchange="A.xlSet('wcLot','${f.saleIndex}',this.value)">${f.options.map(o => `<option ${String(a.wcLot[f.saleIndex]) === String(o) ? 'selected' : ''} value="${esc(o)}">Lot ${esc(o)}</option>`).join('')}</select></div>`).join('')}
    ${P.flags.filter(f => f.kind === 'dup').map(f => `<div class="preview-flag">${esc(f.text)}<label class="tog"><input type="checkbox" ${a.removeDup[f.key] ? 'checked' : ''} onchange="A.xlSet('removeDup','${enc(f.key)}',this.checked)">Remove one (it was entered twice)</label></div>`).join('')}
    ${P.flags.filter(f => f.kind === 'check').map(f => `<div class="preview-flag">${esc(f.text)}</div>`).join('')}</div>` : ''}
  <div class="card"><h3>Customer column</h3><p class="muted">Lead words become the lead source with no name. Set each name as a dealer, walk-in or old customer.</p>
  ${Object.entries(a.customers).map(([key, c]) => `<div class="preview-flag" style="background:var(--ice)"><b>"${esc(key)}"</b><span class="muted">${esc(c.why || '')}</span>
    <div class="row nw"><div><select onchange="A.xlCust('${enc(key)}','lead',this.value)">${LEAD_OPTS.map(o => `<option ${o === c.lead ? 'selected' : ''}>${o}</option>`).join('')}</select></div>
    <div><select onchange="A.xlCust('${enc(key)}','type',this.value)">${['Retail', 'Dealer'].map(o => `<option ${o === c.type ? 'selected' : ''}>${o}</option>`).join('')}</select></div>
    <div>${NOT_NAMES.includes(key) ? '<input value="" placeholder="Walk-in, no name" disabled>' : `<input value="${esc(c.name)}" placeholder="No name" onchange="A.xlCust('${enc(key)}','name',this.value)">`}</div></div></div>`).join('')}</div>
  <div class="card"><h3>Assumptions</h3><ol style="margin:8px 0 0 18px;display:grid;gap:6px">${P.assumptions.map(x => `<li>${esc(x)}</li>`).join('')}</ol></div>
  <button style="width:100%;padding:14px" ${errors.length ? 'disabled' : ''} onclick="A.xlImport()">Import ${t.laptops} laptops and ${t.sales} sales</button>
  <button class="ghost" style="width:100%;margin-top:8px" onclick="A.xlCancel()">Cancel</button>`;
}

export const views = {
  backup() {
    if (xl) return excelPreview();
    const empty = !hasData();
    return `<div class="card"><h3>Backup</h3><p class="muted">Everything is saved in Supabase. Download a backup file every week as well, and keep it somewhere safe.</p>
    <button style="width:100%;margin-top:12px" onclick="A.exportData()">${ICON.cloud}Download backup</button></div>
    <div class="card"><h3>Restore from a backup file</h3><p class="muted">Replaces all stock, sales and money records with the file. Users and PINs are not changed.</p>
    <input type="file" accept=".json,application/json" style="margin-top:10px" onchange="A.restoreData(this.files[0]);this.value=''"></div>
    <div class="card"><h3>Bring in old data (one time)</h3><p class="muted">${empty ? 'Do this once, before adding anything else.' : 'Only works on an empty database. Use Restore above to replace everything.'}</p>
    <label>Dealer's Excel file (.xlsx)</label><input type="file" accept=".xlsx" ${empty ? '' : 'disabled'} onchange="A.xlOpen(this.files[0]);this.value=''">
    <label>Backup from the old one-page app (.json)</label><input type="file" accept=".json,application/json" ${empty ? '' : 'disabled'} onchange="A.importOld(this.files[0]);this.value=''"></div>
    <div class="card"><h3>Danger zone</h3><button class="red" onclick="A.resetAll()">Delete all data</button></div>`;
  }
};

export const actions = {
  async exportData() {
    await guard(async () => {
      const d = await read('export_backup');
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([JSON.stringify(d)], { type: 'application/json' }));
      a.download = `first-choice-backup-${todayIN()}.json`; a.click();
      toast('Backup downloaded', 'ok');
    });
  },
  async restoreData(f) {
    if (!f) return;
    await guard(async () => {
      const x = JSON.parse(await readFile(f, true));
      const n = x.format === 'fcl-v2' ? (x.tables?.laptops || []).length : (x.laptops || []).length;
      const v = await dialog({ title: 'Restore this backup?', body: `It has ${n} laptops. All current stock, sales and money records will be replaced. Type RESTORE to confirm.`, ok: 'Restore', danger: true, text: true });
      if (v === null) return;
      if (v.trim() !== 'RESTORE') return toast('Not restored. Type RESTORE exactly.');
      await write('restore_backup', { p_data: x, p_confirm: 'RESTORE' }); await load(); toast('Backup restored', 'ok');
    });
  },
  async importOld(f) {
    if (!f) return;
    await guard(async () => {
      const x = JSON.parse(await readFile(f, true));
      if (!await confirmBox('Bring in the old app\'s data?', `${(x.laptops || []).length} laptops, with their codes, sales, payments and history.`, 'Import')) return;
      const r = await write('import_backup', { p_data: x }); await load(); toast(`Imported ${r.laptops} laptops`, 'ok'); A.go('home');
    });
  },
  async resetAll() {
    const v = await dialog({ title: 'Delete all data?', body: 'Download a backup first. Users and PINs stay. Type DELETE to confirm.', ok: 'Delete everything', danger: true, text: true });
    if (v === null) return;
    if (v.trim() !== 'DELETE') return toast('Not deleted. Type DELETE exactly.');
    await guard(async () => { await write('restore_backup', { p_data: { format: 'fcl-v2', tables: {} }, p_confirm: 'RESTORE' }); await load(); A.go('home'); toast('All data deleted', 'ok'); });
  },
  async xlOpen(f) {
    if (!f) return;
    await guard(async () => {
      await loadScript('lib/xlsx.full.min.js');
      const wb = window.XLSX.read(await readFile(f, false));
      const raw = readWorkbook(wb, window.XLSX);
      if (!raw.lots.length) throw new Error('No rows found in the "Lot Entry" sheet');
      // The dealer's live Dashboard totals (from the Google Sheet), editable in the preview
      xl = { raw, answers: defaultAnswers(raw), expected: { sales: 497400, expenses: 60900, months: { '2026-09': 267500, '2026-10': 229900 } } };
      A.refresh(); scrollTo(0, 0);
    });
  },
  xlSet(group, key, v) { xl.answers[group][group === 'removeDup' ? dec(key) : key] = v; A.refresh(); },
  xlCust(key, k, v) { xl.answers.customers[dec(key)][k] = v; A.refresh(); },
  xlExpect(k, v) { if (k.startsWith('m:')) xl.expected.months[k.slice(2)] = v; else xl.expected[k] = v; A.refresh(); },
  xlCancel() { xl = null; A.refresh(); },
  async xlImport() {
    const P = buildPlan(xl.raw, xl.answers);
    if (!await confirmBox('Import the Excel now?', `${P.totals.lots} lots, ${P.totals.laptops} laptops, ${P.totals.sales} sales (${rs(P.totals.sales_total)}) and ${P.totals.expenses} expenses (${rs(P.totals.expenses_total)}). This runs only once.`, 'Import')) return;
    await guard(async () => {
      const r = await write('import_excel', { p: P.plan });
      xl = null; await load();
      toast(`Imported ${r.laptops} laptops and ${r.sales} sales (${rs(r.sales_total)})`, 'ok'); A.go('stock');
    });
  }
};
