// Export files built in the browser, in chunks so a phone does not freeze:
//   Excel (.xlsx): one sheet per table, bold frozen header, column widths, ₹ amounts as numbers, real dates, totals row
//   CSV (.zip): one CSV per table, for any other software
//   SQL (.sql): INSERT statements that load into a fresh project after setup_all.sql (or parts 1–3)
// The zip itself is made by the bundled SheetJS library (XLSX.CFB). No network, no CDN.
export const APP_VERSION = 'fcl-v10';

const tick = () => new Promise(r => setTimeout(r, 0));
const CHUNK = 400;
const enc = new TextEncoder();
const xmlEsc = v => String(v).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const colName = i => { let s = ''; i++; while (i) { const m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); } return s; };
// Excel date serial (days since 30-12-1899); "2026-11-11" or "2026-11-11T16:15:00" (already shop time)
export function excelDate(v) {
  const m = String(v).match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/); if (!m) return null;
  const days = (Date.UTC(+m[1], +m[2] - 1, +m[3]) - Date.UTC(1899, 11, 30)) / 864e5;
  return days + ((+(m[4] || 0)) * 3600 + (+(m[5] || 0)) * 60 + (+(m[6] || 0))) / 86400;
}
const dmy = v => { const m = String(v).match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/); return m ? `${m[3]}-${m[2]}-${m[1]}${m[4] ? ` ${m[4]}:${m[5]}` : ''}` : String(v); };
const sheetName = (n, used) => { let s = n.replace(/[\[\]:*?/\\]/g, ' ').slice(0, 31) || 'Sheet'; let k = s, i = 2; while (used.has(k)) k = s.slice(0, 28) + ' ' + i++; used.add(k); return k; };

function zip(XLSX, files) {
  const C = XLSX.CFB, z = C.utils.cfb_new({ root: 'R' });
  for (const [name, data] of files) C.utils.cfb_add(z, name, typeof data === 'string' ? enc.encode(data) : data);
  return C.write(z, { type: 'array', fileType: 'zip', compression: true });
}

// ---------- Excel ----------
// styles: 0 normal, 1 header (bold, grey fill, border), 2 date, 3 money, 4 total label (bold), 5 total money (bold), 6 date and time, 7 whole number
const STYLES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="3"><numFmt numFmtId="164" formatCode="dd\\-mm\\-yyyy"/><numFmt numFmtId="165" formatCode="&quot;₹&quot;#,##0;\\-&quot;₹&quot;#,##0"/><numFmt numFmtId="166" formatCode="dd\\-mm\\-yyyy hh:mm"/></numFmts>
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE8EEF8"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color rgb="FF8EA2C4"/></bottom><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="8"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="165" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyNumberFormat="1"/>
<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`;

function cell(ref, v, t) {
  if (v === null || v === undefined || v === '') return '';
  if (t === 'm' || t === 'i' || t === 'n') {
    const n = Number(v); if (!Number.isFinite(n)) return `<c r="${ref}" t="inlineStr"><is><t>${xmlEsc(v)}</t></is></c>`;
    return `<c r="${ref}" s="${t === 'm' ? 3 : 7}"><v>${n}</v></c>`;
  }
  if (t === 'd' || t === 't') {
    const n = excelDate(v); if (n == null) return `<c r="${ref}" t="inlineStr"><is><t>${xmlEsc(v)}</t></is></c>`;
    return `<c r="${ref}" s="${t === 'd' ? 2 : 6}"><v>${n}</v></c>`;
  }
  return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${xmlEsc(v)}</t></is></c>`;
}

async function sheetXml(sh, progress) {
  const cols = sh.cols, rows = sh.rows, last = colName(Math.max(cols.length - 1, 0));
  // widths from the header and the first rows
  const w = cols.map((c, i) => {
    let m = c.h.length + 2;
    for (const r of rows.slice(0, 300)) { const v = r[i]; const len = v == null ? 0 : c.t === 'd' ? 10 : c.t === 't' ? 16 : c.t === 'm' ? String(Math.round(+v)).length + 4 : String(v).length; if (len > m) m = len; }
    return Math.min(Math.max(m + 1, 8), 60);
  });
  const out = [`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<dimension ref="A1:${last}${rows.length + 1 + (sh.total ? 1 : 0)}"/>
<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>
<sheetFormatPr defaultRowHeight="15"/>
<cols>${w.map((x, i) => `<col min="${i + 1}" max="${i + 1}" width="${x}" customWidth="1"/>`).join('')}</cols>
<sheetData><row r="1">${cols.map((c, i) => `<c r="${colName(i)}1" s="1" t="inlineStr"><is><t>${xmlEsc(c.h)}</t></is></c>`).join('')}</row>`];
  for (let k = 0; k < rows.length; k += CHUNK) {
    let part = '';
    for (let j = k; j < Math.min(k + CHUNK, rows.length); j++) {
      const r = rows[j], rn = j + 2;
      part += `<row r="${rn}">${cols.map((c, i) => cell(colName(i) + rn, r[i], c.t)).join('')}</row>`;
    }
    out.push(part); progress?.(rows.length); await tick();
  }
  if (sh.total && rows.length) {
    const rn = rows.length + 2;
    out.push(`<row r="${rn}"><c r="A${rn}" s="4" t="inlineStr"><is><t>Total</t></is></c>${cols.map((c, i) => {
      if (c.t !== 'm' || i === 0) return '';
      const L = colName(i), sum = rows.reduce((s, r) => s + (Number(r[i]) || 0), 0);
      return `<c r="${L}${rn}" s="5"><f>SUM(${L}2:${L}${rn - 1})</f><v>${Math.round(sum * 100) / 100}</v></c>`;
    }).join('')}</row>`);
  }
  out.push(`</sheetData>${rows.length ? `<autoFilter ref="A1:${last}${rows.length + 1}"/>` : ''}<pageMargins left="0.5" right="0.5" top="0.75" bottom="0.75" header="0.3" footer="0.3"/></worksheet>`);
  return out.join('');
}

export async function buildXlsx(sheets, XLSX, progress) {
  const used = new Set(), names = sheets.map(s => sheetName(s.name, used)), files = [];
  let done = 0; const total = sheets.reduce((t, s) => t + s.rows.length, 0) || 1;
  for (let i = 0; i < sheets.length; i++) {
    progress?.(`Sheet ${i + 1} of ${sheets.length}: ${sheets[i].name}`, done / total);
    files.push([`xl/worksheets/sheet${i + 1}.xml`, await sheetXml(sheets[i])]);
    done += sheets[i].rows.length; await tick();
  }
  files.push(['[Content_Types].xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
${sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')}</Types>`]);
  files.push(['_rels/.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`]);
  files.push(['xl/workbook.xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews>
<sheets>${names.map((n, i) => `<sheet name="${xmlEsc(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('')}</sheets></workbook>`]);
  files.push(['xl/_rels/workbook.xml.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${names.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')}
<Relationship Id="rId${names.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`]);
  files.push(['xl/styles.xml', STYLES]);
  progress?.('Packing the file', 1); await tick();
  return zip(XLSX, files);
}

// ---------- CSV (.zip) ----------
const csvVal = (v, t) => {
  if (v === null || v === undefined) return '';
  const s = t === 'd' || t === 't' ? dmy(v) : String(v);
  return /[",\r\n]/.test(s) || /^\s|\s$/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
export async function buildCsvZip(sheets, XLSX, progress) {
  const files = [], used = new Set();
  for (let i = 0; i < sheets.length; i++) {
    const sh = sheets[i]; progress?.(`File ${i + 1} of ${sheets.length}: ${sh.name}`, i / sheets.length);
    const parts = ['﻿' + sh.cols.map(c => csvVal(c.h, 's')).join(',')];
    for (let k = 0; k < sh.rows.length; k += CHUNK) {
      parts.push(sh.rows.slice(k, k + CHUNK).map(r => sh.cols.map((c, j) => csvVal(r[j], c.t)).join(',')).join('\r\n'));
      await tick();
    }
    const base = sheetName(sh.name, used).replace(/\s+/g, '-');
    files.push([`${String(i + 1).padStart(2, '0')}-${base}.csv`, parts.join('\r\n') + '\r\n']);
  }
  progress?.('Packing the file', 1); await tick();
  return zip(XLSX, files);
}

// ---------- SQL ----------
// dump: { exported_at, tables: [{ table: 'public.sales', cols: 'a, b', rows: ["('..', NULL)", …] }] }
export async function buildSql(dump, meta = {}, progress) {
  const counts = dump.tables.map(t => [t.table, t.rows.length]);
  const total = counts.reduce((s, x) => s + x[1], 0) || 1;
  const out = [`-- First Choice Laptops, Stock Manager: SQL export of all business data
-- Exported: ${dump.exported_at}${meta.by ? ` by ${meta.by}` : ''}
-- App version: ${APP_VERSION}
--
-- How to load it: in a NEW Supabase project, first run supabase/setup_all.sql (or setup_part1, 2 and 3),
-- then run this file. It refuses to load into a database that already has laptops.
-- Not included: logins (users and PINs), secrets, and who read which notification. "Who did it" links are left
-- empty; the Activity log keeps the names as text. Create the admin again after loading (README step 6).
-- If the SQL Editor says the file is too big, run it with psql instead.
--
-- Rows per table:
${counts.map(([t, n]) => `--   ${t.padEnd(32)} ${n}`).join('\n')}

begin;

do $$ begin
  if exists (select 1 from public.laptops) then
    raise exception 'This database already has laptops. Load this file into a new, empty project only.';
  end if;
end $$;

-- the app's own load mode: no activity lines, no new notifications, guards stand aside (as in Restore)
select set_config('app.no_log', 'on', true);
select set_config('app.no_invoice', 'on', true);

-- the empty setup's own settings row and "Customer exchange" supplier are replaced by the ones in this file
delete from public.settings;
delete from public.suppliers s where s.code = '00' and not exists (select 1 from public.lots l where l.supplier_id = s.id);
`];
  let done = 0;
  for (const t of dump.tables) {
    progress?.(`Writing ${t.table.replace(/^(public|private)\./, '')}`, done / total);
    if (t.rows.length) {
      out.push(`\n-- ${t.table}: ${t.rows.length} row${t.rows.length === 1 ? '' : 's'}`);
      for (let k = 0; k < t.rows.length; k += 200) {
        out.push(`insert into ${t.table} (${t.cols}) values\n${t.rows.slice(k, k + 200).join(',\n')};`);
        if (k % 2000 === 0) await tick();
      }
    }
    done += t.rows.length;
  }
  // a check query: one line per table
  out.push(`\ncommit;\n\n-- Check: these counts should match the list at the top.\n${counts.map(([t]) => `select '${t}' as table_name, count(*) from ${t}`).join('\nunion all ')};\n`);
  progress?.('Done', 1);
  return out.join('\n');
}

// File names like first-choice-export-2026-11-11.xlsx
export const exportName = (ext, today) => `first-choice-export-${today}.${ext}`;
