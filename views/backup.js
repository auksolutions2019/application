// Backup and import (admin): export, restore, bring in the old app's backup or the dealer's Excel.
// Co-admin sees only Export (Excel and CSV, without costs, profit, supplier money or debts).
import { $, esc, rs, todayIN, enc, dec, chips, chipVal } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast, confirmBox, dialog, guard } from '../ui/feedback.js';
import { S, load, isAdmin } from '../api/store.js';
import { buildXlsx, buildCsvZip, buildSql, exportName } from '../ui/exporters.js';
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
    const empty = !hasData(), adm = isAdmin();
    const exp = `<div class="card"><h3>Export</h3><p class="muted">${adm ? 'Everything is saved in Supabase. Download a backup every week as well, and keep it somewhere safe.' : 'Download stock, sales and customers for Excel or other software.'}</p>
    <label>Date range</label>${chips('xrange', [['all', 'All time'], ['month', 'This month'], ['year', 'This year'], ['custom', 'Custom']], 'all', 'wrap')}
    <div id="xcustom" class="row nw hidden"><div><label>From</label><input id="xfrom" type="date" max="${todayIN()}"></div><div><label>To</label><input id="xto" type="date" max="${todayIN()}" value="${todayIN()}"></div></div>
    <p class="muted" style="margin-top:6px">The range applies to sales, payments, expenses, service jobs and stock movements. Lots, laptops, customers and suppliers are always complete.</p>
    <label class="tog"><input type="checkbox" id="xdel">Include deleted items (Recently deleted)</label>
    <div class="xbtns">
      <button onclick="A.exportAs('xlsx')">📊 Excel (.xlsx)<small>A sheet per table, easy to read</small></button>
      <button class="ghost" onclick="A.exportAs('csv')">🗂 CSV (.zip)<small>One file per table, for other software</small></button>
      ${adm ? `<button class="ghost" onclick="A.exportAs('sql')">🛢 SQL (.sql)<small>Full backup that loads into a new Supabase project</small></button>
      <button class="ghost" onclick="A.exportData()">${ICON.cloud} JSON backup<small>For Restore in this app</small></button>` : ''}</div>
    ${adm ? '<p class="muted" style="margin-top:8px">SQL and JSON are always complete backups: the date range and deleted-items choice do not apply to them.</p>' : ''}
    <div id="xprog" class="xprog hidden"></div></div>`;
    if (!adm) return exp;
    return `${exp}
    <div class="card"><h3>Restore from a backup file</h3><p class="muted">Replaces all stock, sales and money records with the file. Users and PINs are not changed.</p>
    <input type="file" accept=".json,application/json" style="margin-top:10px" onchange="A.restoreData(this.files[0]);this.value=''"></div>
    <div class="card"><h3>Bring in old data (one time)</h3><p class="muted">${empty ? 'Do this once, before adding anything else.' : 'Only works on an empty database. Use Restore above to replace everything.'}</p>
    <label>Dealer's Excel file (.xlsx)</label><input type="file" accept=".xlsx" ${empty ? '' : 'disabled'} onchange="A.xlOpen(this.files[0]);this.value=''">
    <label>Backup from the old one-page app (.json)</label><input type="file" accept=".json,application/json" ${empty ? '' : 'disabled'} onchange="A.importOld(this.files[0]);this.value=''"></div>
    <div class="card"><h3>Danger zone</h3><button class="red" onclick="A.resetAll()">Delete all data</button></div>`;
  }
};

const PRIVATE = 'This file contains customer names, mobiles and money details. Keep it private.';
function save(blob, name) {
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name;
  document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 4000);
}
function progress(text, frac) {
  const p = $('xprog'); if (!p) return;
  p.classList.remove('hidden'); p.innerHTML = `<span>${esc(text)}</span>${frac != null ? `<div class="btrack"><div style="width:${Math.round(frac * 100)}%"></div></div>` : ''}`;
}
const doneProgress = () => $('xprog')?.classList.add('hidden');
function range() {
  const k = chipVal('xrange') || 'all', t = todayIN();
  if (k === 'month') return { p_from: t.slice(0, 8) + '01', p_to: t };
  if (k === 'year') return { p_from: t.slice(0, 5) + '01-01', p_to: t };
  if (k === 'custom') {
    const f = $('xfrom').value, to = $('xto').value || t;
    if (!f) throw new Error('Choose the start date');
    if (f > to) throw new Error('The start date is after the end date');
    return { p_from: f, p_to: to };
  }
  return { p_from: null, p_to: null };
}
export function after(view) {
  if (view !== 'backup') return;
  $('xrange')?.addEventListener('change', () => $('xcustom')?.classList.toggle('hidden', chipVal('xrange') !== 'custom'));
}

export const actions = {
  async exportData() {
    if (!await confirmBox('Keep this file private', PRIVATE, 'Download')) return;
    await guard(async () => {
      progress('Getting all data…');
      const d = await read('export_backup');
      save(new Blob([JSON.stringify(d)], { type: 'application/json' }), exportName('json', todayIN()));
      doneProgress(); toast('Backup downloaded', 'ok');
    }); doneProgress();
  },
  async exportAs(fmt) {
    let r; try { r = range(); } catch (e) { return toast(e.message); }
    if (!await confirmBox('Keep this file private', PRIVATE, 'Download')) return;
    await guard(async () => {
      const T = todayIN();
      if (fmt === 'sql') {
        progress('Getting all data…');
        const dump = await read('export_dump');
        const sql = await buildSql(dump, { by: S.d.me?.name }, (t, f) => progress('Building the SQL file. ' + t, f));
        save(new Blob([sql], { type: 'application/sql' }), exportName('sql', T));
      } else {
        progress('Getting the data…');
        const data = await read('export_sheets', { ...r, p_deleted: $('xdel').checked, p_format: fmt });
        await loadScript('lib/xlsx.full.min.js');
        const step = (t, f) => progress(`Building the ${fmt === 'xlsx' ? 'Excel' : 'CSV'} file. ${t}`, f);
        const bytes = fmt === 'xlsx' ? await buildXlsx(data.sheets, window.XLSX, step) : await buildCsvZip(data.sheets, window.XLSX, step);
        save(new Blob([bytes], { type: fmt === 'xlsx' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'application/zip' }),
             exportName(fmt === 'xlsx' ? 'xlsx' : 'zip', T));
      }
      doneProgress(); toast(`${fmt === 'xlsx' ? 'Excel' : fmt.toUpperCase()} file downloaded`, 'ok');
    }); doneProgress();
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
