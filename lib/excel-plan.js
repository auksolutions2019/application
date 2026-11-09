// One-time import of the dealer's Excel (Lot Entry, Expenses, Sales; the "wc" tab is checked against Sales).
// Pure functions (no screen code), used by the Backup screen and by the Node test.
// readWorkbook(wb, XLSX) -> raw rows;  defaultAnswers(raw) -> editable choices;  buildPlan(raw, answers) -> plan + preview.

const RAMS = [2, 4, 6, 8, 12, 16, 24, 32, 64];
const title = s => String(s || '').trim().replace(/\s+/g, ' ').toLowerCase().replace(/\b[a-z]/g, c => c.toUpperCase());
const clean = s => String(s ?? '').trim().replace(/\s+/g, ' ');

export function toISO(v) {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return new Date(Date.UTC(1899, 11, 30) + Math.round(v) * 864e5).toISOString().slice(0, 10);
  if (v instanceof Date) return new Date(v.getTime() + 5.5 * 3600e3).toISOString().slice(0, 10);
  const s = String(v).trim();
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})/); if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})$/);
  if (m) return `${m[3].length === 2 ? '20' + m[3] : m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  return null;
}
const swapDM = iso => { const [y, m, d] = iso.split('-').map(Number); if (d > 12) return null; return `${y}-${String(d).padStart(2, '0')}-${String(m).padStart(2, '0')}`; };
const days = (a, b) => Math.round((new Date(b) - new Date(a)) / 864e5);

// Typo fixes the dealer's sheet needs, listed so the preview can show them.
const FIXES = [[/\bascer\b/g, 'acer'], [/\bpentinum\b/g, 'pentium'], [/(\d)\s*ed\b/g, '$1rd'], [/\bcustomar\b/g, 'customer'], [/\bconector\b/g, 'connector']];
export const FIX_LIST = ['"ascer" → Acer', '"pentinum" → Pentium', '"3ed" → 3rd', 'extra spaces removed', 'names in Title Case'];

// "lenovo i5 7th 8/256", "HP pentinum 360", "dell i3 6th 4/500 hdd", "E450", "i7 8th 16/512"
export function parseSpecs(text) {
  let t = ' ' + String(text || '').toLowerCase().replace(/\s+/g, ' ') + ' ';
  for (const [re, to] of FIXES) t = t.replace(re, to);
  const out = { brand: null, brand_other: '', model: '', processor: null, processor_other: '', gen: null, ram_gb: null, storage_type: null, storage_gb: null };
  const take = re => { const m = t.match(re); if (m) t = t.replace(m[0], ' '); return m; };
  if (take(/\bdell\b/)) out.brand = 'Dell';
  else if (take(/\bhp\b/)) out.brand = 'HP';
  else if (take(/\blenovo\b/)) out.brand = 'Lenovo';
  else if (take(/\bacer\b/)) out.brand = 'Acer';
  else if (take(/\basus\b/)) out.brand = 'Asus';
  else if (take(/\b(apple|macbook)\b/)) out.brand = 'Apple';
  let m;
  if ((m = take(/\bi\s?([3579])\b/))) out.processor = 'i' + m[1];
  else if (take(/\bpentium\b/)) out.processor = 'Pentium';
  else if (take(/\bceleron\b/)) out.processor = 'Celeron';
  else if ((m = take(/\bryzen\s?([357])\b/))) out.processor = 'Ryzen ' + m[1];
  if ((m = take(/\b(\d{1,2})\s?(?:st|nd|rd|th|gen)\b/))) out.gen = +m[1];
  if ((m = take(/\b(\d{1,2})\s?\/\s?(\d{2,4}|n)\b/))) {
    out.ram_gb = RAMS.includes(+m[1]) ? +m[1] : null;
    out.storage_gb = m[2] === 'n' ? null : +m[2];
  }
  const hdd = !!take(/\bhdd\b/); take(/\bssd\b/);
  if (out.storage_gb != null) out.storage_type = hdd || [300, 320, 500, 1000].includes(out.storage_gb) ? 'HDD' : 'SSD';
  const rest = t.trim().split(' ').filter(w => w && !['all', 'no', 'laptop'].includes(w));
  out.model = rest.map(w => /^[a-z]\d{3}[a-z]?$/.test(w) || /^v\d+/.test(w) ? w.toUpperCase() : w).join(' ');
  // ThinkPad-style codes without a brand (E450, T430, X280, L450, V130)
  if (!out.brand && /^(e|t|x|l|v)\d{3}/i.test(out.model)) out.brand = 'Lenovo';
  return out;
}

// ---------- reading the workbook ----------
export function readWorkbook(wb, XLSX) {
  const rows = name => wb.Sheets[name] ? XLSX.utils.sheet_to_json(wb.Sheets[name], { header: 1, defval: '', raw: true }) : [];
  const after = (r, test) => { const i = r.findIndex(test); return i < 0 ? [] : r.slice(i + 1); };
  const lots = after(rows('Lot Entry'), r => /lot no/i.test(r[0])).filter(r => r[0] !== '' && r[7] !== '')
    .map((r, i) => ({ i, lot: String(r[0]).trim(), date: toISO(r[1]), supplier: clean(r[2]), what: clean(r[3]), proc: clean(r[4]), ram: clean(r[5]), ssd: clean(r[6]), qty: +r[7], cost: r[8] === '' ? null : +r[8] }));
  const expenses = after(rows('Expenses'), r => String(r[0]).trim() === 'Date').filter(r => r[1] !== '' && r[5] !== '')
    .map((r, i) => ({ i, date: toISO(r[0]), lot: String(r[1]).trim(), what: clean(r[2]), type: clean(r[3]), count: +r[4] || 1, amount: +r[5], method: clean(r[6]), note: clean(r[7]) }));
  const sales = after(rows('Sales'), r => String(r[0]).trim() === 'Date').filter(r => r[1] !== '' && r[2] !== '')
    .map((r, i) => ({ i, date: toISO(r[0]), lot: String(r[1]).trim(), qty: +r[2] || 1, what: clean(r[3]), customer: clean(r[4]), method: clean(r[5]), price: +r[6], total: r[7] === '' ? null : +r[7] }));
  const wc = rows('wc').filter(r => typeof r[0] === 'number' && r[1] !== '')
    .map((r, i) => ({ i, date: toISO(r[0]), lot: String(r[1]).trim(), qty: +r[2] || 1, what: clean(r[3]), customer: clean(r[4]), price: +r[6] }));
  return { lots, expenses, sales, wc };
}

// ---------- customers column ----------
const LEAD_WORDS = [[/olx/, 'OLX'], [/insta/, 'Instagram'], [/lead ?matrix/, 'Lead Matrix'], [/circle/, 'Circle app'], [/\bocto\b/, 'Octo']];
export function classifyCustomer(raw) {
  const s = String(raw || '').toLowerCase().trim();
  for (const [re, lead] of LEAD_WORDS) if (re.test(s)) return { lead, type: 'Retail', name: '', why: 'lead word, no name' };
  if (/old cust/.test(s)) return { lead: 'Old customer', type: 'Retail', name: title(s.replace(/old\s*custom\w*/, '')), why: 'old customer' };
  if (/^(shahid|kalu|blue eye|elec(tronic)? city( office)?)$/.test(s)) return { lead: 'Dealer', type: 'Dealer', name: title(s), why: 'dealer named by you' };
  if (['lady', 'gents', 'customer', 'walk in', 'walkin'].includes(s)) return { lead: 'Walk-in', type: 'Retail', name: '', why: 'not a name' };
  if (s === 'gandu') return { lead: 'Walk-in', type: 'Retail', name: '', why: 'looks like a nickname, not printed on bills' };
  return { lead: 'Walk-in', type: 'Retail', name: title(s), why: 'a person\'s name, assumed walk-in' };
}
const EXP_TYPES = [[/ssd/, 'SSD'], [/\bram\b/, 'RAM'], [/batt/, 'Battery'], [/char.*\+|\+.*char/, 'Other'], [/charger/, 'Charger'], [/hdd ?con/, 'Other'], [/\bhdd\b/, 'HDD'], [/\bkb\b|keyboard/, 'Keyboard'], [/screen|display|panel/, 'Screen'], [/transport|courier/, 'Transport'], [/labou?r|repair/, 'Repair labour']];
export function expenseType(raw) {
  const s = String(raw || '').toLowerCase();
  for (const [re, t] of EXP_TYPES) if (re.test(s)) return t;
  return 'Other';
}
const methodOf = m => /cash/i.test(m) ? 'Cash' : /bank|neft|imps|rtgs/i.test(m) ? 'Bank' : 'UPI';

// ---------- default answers (editable in the preview) ----------
// The dealer's own answers for this file (still to be confirmed by the dealer).
const DEALER = { lotDates: { '10': '2026-09-01', '13': '2026-10-09' }, lotNotes: { '13': 'entered late' } };

export function defaultAnswers(raw) {
  const a = { lotDates: {}, lotNotes: {}, lotKinds: {}, costMode: {}, customers: {}, wcLot: {}, removeDup: {}, lotNo: {} };
  const lotKeys = [...new Set(raw.lots.map(r => r.lot))];
  for (const k of lotKeys) {
    const rs = raw.lots.filter(r => r.lot === k);
    const first = firstActivity(raw, k);
    const dates = [...new Set(rs.map(r => r.date))].sort();
    let d = dates[0];
    const sw = d && swapDM(d);
    if (DEALER.lotDates[k]) d = DEALER.lotDates[k];
    else if (first && d > first) d = first;
    else if (first && sw && sw <= first && days(d, first) > 30) d = sw;
    a.lotDates[k] = d;
    a.lotNotes[k] = DEALER.lotNotes[k] || '';
    a.lotKinds[k] = rs.every(r => r.cost == null) ? 'opening' : 'purchase';
    a.costMode[k] = 'line';
    a.lotNo[k] = +k >= 1 && +k <= 99 ? +k : null;
  }
  for (const s of raw.sales) { const key = s.customer.toLowerCase(); if (!a.customers[key]) a.customers[key] = classifyCustomer(s.customer); }
  for (const p of wcPairs(raw)) a.wcLot[p.saleIndex] = p.salesLot;
  return a;
}
function firstActivity(raw, k) {
  const ds = [...raw.sales.filter(s => s.lot === k).map(s => s.date), ...raw.expenses.filter(e => e.lot === k).map(e => e.date)].filter(Boolean).sort();
  return ds[0] || null;
}
// Sales rows repeated on the "wc" tab under another lot
function wcPairs(raw) {
  const out = [];
  for (const w of raw.wc) {
    const s = raw.sales.find(x => x.date === w.date && x.price === w.price && x.qty === w.qty && x.what.toLowerCase() === w.what.toLowerCase() && x.customer.toLowerCase() === w.customer.toLowerCase());
    if (s && s.lot !== w.lot) out.push({ saleIndex: s.i, salesLot: s.lot, wcLot: w.lot, sale: s });
  }
  return out;
}
// Same date, price, specs and customer in two lots (possible double entry)
function dupGroups(raw) {
  const g = {};
  for (const s of raw.sales) { const k = [s.date, s.price, s.qty, s.what.toLowerCase(), s.customer.toLowerCase()].join('|'); (g[k] = g[k] || []).push(s); }
  return Object.entries(g).filter(([, v]) => v.length > 1).map(([k, v]) => ({ key: k, rows: v }));
}

// ---------- the plan ----------
export function buildPlan(raw, a) {
  const flags = [], assumptions = [], lotKeys = [...new Set(raw.lots.map(r => r.lot))];
  const lots = [], lineInfo = {};
  for (const k of lotKeys) {
    const rs = raw.lots.filter(r => r.lot === k);
    const dates = [...new Set(rs.map(r => r.date))].sort(), first = firstActivity(raw, k);
    const lines = rs.map(r => {
      const mixed = /mix|un ?listed/i.test(r.what) || /^all$/i.test(r.proc);
      const sp = mixed ? {} : parseSpecs(`${r.what} ${r.proc}`);
      if (!mixed) {
        const ram = parseInt(r.ram, 10), ssd = parseInt(r.ssd, 10);
        if (RAMS.includes(ram)) sp.ram_gb = ram;
        if (ssd >= 16) { sp.storage_gb = ssd; sp.storage_type = 'SSD'; }
      }
      const cost = r.cost == null ? null : a.costMode[k] === 'unit' ? r.cost * r.qty : r.cost;
      return { is_mixed: mixed, ...sp, qty: r.qty, cost, _what: r.what };
    });
    lineInfo[k] = lines;
    const sup = title(rs[0].supplier);
    lots.push({ key: k, supplier: sup, lot_no: a.lotNo[k], bought_on: a.lotDates[k], kind: a.lotKinds[k],
      note: [`Excel lot ${k}`, rs.every(r => /un ?listed/i.test(r.what)) ? 'all unlisted' : '', a.lotNotes[k]].filter(Boolean).join(', '),
      lines: lines.map(({ _what, ...l }) => l) });
    // flags about dates
    if (dates.length > 1) flags.push({ kind: 'date', lot: k, text: `Lot ${k}: its lines have different dates (${dates.join(', ')}).` });
    if (first && dates[0] > first) flags.push({ kind: 'date', lot: k, text: `Lot ${k}: purchase date ${dates[0]} is after its first sale or expense (${first}).` });
    else if (first && days(dates[0], first) > 30 && swapDM(dates[0]) && swapDM(dates[0]) !== dates[0]) flags.push({ kind: 'date', lot: k, text: `Lot ${k}: purchase date ${dates[0]} is ${days(dates[0], first)} days before its first sale or expense (${first}). Day and month may be swapped (${swapDM(dates[0])}).` });
    if (a.lotDates[k] !== dates[0]) assumptions.push(`Lot ${k} dated ${a.lotDates[k]} instead of ${dates.join(' / ')}${a.lotNotes[k] ? ` (note: ${a.lotNotes[k]})` : ''}.`);
    if (a.lotKinds[k] === 'opening') assumptions.push(`Lot ${k} (${sup}) is opening stock with cost missing until the admin fills it in.`);
    if (lines.some(l => l.cost != null)) assumptions.push(`Lot ${k}: the cost column is ${a.costMode[k] === 'unit' ? 'the price of ONE laptop (multiplied by the quantity)' : 'the total for the line'}.`);
    if (a.lotNo[k] == null) assumptions.push(`Lot ${k}: the number is too big for a sticker, so it gets the next free lot number for ${sup}. "Excel lot ${k}" stays in its note.`);
    if (lines.some(l => l.is_mixed)) assumptions.push(`Lot ${k}: "${rs.find(r => /mix|un ?listed/i.test(r.what) || /^all$/i.test(r.proc)).what}" becomes a Mixed line; each laptop's specs come from its sale, or are filled in later.`);
  }
  const lotSet = new Set(lotKeys);

  // sales, one per laptop
  const pairs = wcPairs(raw), dups = dupGroups(raw), removed = new Set();
  for (const g of dups) if (a.removeDup[g.key]) removed.add(g.rows[g.rows.length - 1].i);
  const sales = [];
  for (const s of raw.sales) {
    if (removed.has(s.i)) continue;
    const lot = a.wcLot[s.i] ?? s.lot;
    if (!lotSet.has(lot)) { flags.push({ kind: 'error', text: `Sales row ${s.i + 1}: lot ${lot} is not in Lot Entry.` }); continue; }
    const c = a.customers[s.customer.toLowerCase()] || classifyCustomer(s.customer);
    if (s.total != null && s.total !== s.qty * s.price && s.total !== s.price) flags.push({ kind: 'check', text: `Sales row ${s.i + 1}: total ${s.total} is not ${s.qty} × ${s.price}.` });
    for (let n = 0; n < s.qty; n++) sales.push({ lot_key: lot, sold_on: s.date, price: s.price, lead_source: c.lead, customer_type: c.type, name: c.name, method: methodOf(s.method), specs: parseSpecs(s.what), _row: s.i, _text: s.what });
  }
  const oddMethods = [...new Set(raw.sales.map(s => s.method.toLowerCase().trim()).filter(m => m && !['upi', 'cash', 'bank'].includes(m)))];
  if (oddMethods.length) assumptions.push(`Payment method ${oddMethods.map(m => `"${m}"`).join(', ')} read as UPI. Every sale is paid in full.`);
  else assumptions.push('Every sale is paid in full.');
  assumptions.push('Each sales row with a quantity of more than 1 becomes one sale per laptop at the unit price.');
  assumptions.push('Each sale goes to an unsold laptop of its lot with the same model, otherwise the same brand and processor, otherwise a Mixed one.');
  for (const p of pairs) flags.push({ kind: 'wc', saleIndex: p.saleIndex, text: `Sales row ${p.saleIndex + 1} (${p.sale.date}, ${p.sale.what}, ₹${p.sale.price}) is also on the "wc" tab under lot ${p.wcLot}. Using lot ${a.wcLot[p.saleIndex] ?? p.salesLot}.`, options: [p.salesLot, p.wcLot] });
  for (const g of dups) flags.push({ kind: 'dup', key: g.key, text: `Possible double entry: ${g.rows.length} rows on ${g.rows[0].date} for "${g.rows[0].what}", ${g.rows[0].customer}, ₹${g.rows[0].price} (lots ${g.rows.map(r => r.lot).join(' and ')}). ${a.removeDup[g.key] ? 'Removing the last one.' : 'Keeping all.'}` });

  // laptops per lot vs sales per lot
  for (const k of lotKeys) {
    const have = lineInfo[k].reduce((t, l) => t + l.qty, 0), sold = sales.filter(s => s.lot_key === k).length;
    if (sold > have) flags.push({ kind: 'error', text: `Lot ${k} has ${sold} sales but only ${have} laptops.` });
  }

  // expenses
  const expenses = [];
  for (const e of raw.expenses) {
    if (!lotSet.has(e.lot)) { flags.push({ kind: 'error', text: `Expenses row ${e.i + 1}: lot ${e.lot} is not in Lot Entry.` }); continue; }
    const type = expenseType(e.type), brand = parseSpecs(e.what).brand;
    const lines = lineInfo[e.lot].map((l, i) => ({ ...l, no: i + 1 })).filter(l => !l.is_mixed && brand && l.brand === brand);
    const line_no = lines.length === 1 ? lines[0].no : null;
    expenses.push({ lot_key: e.lot, spent_on: e.date, type, count: e.count, amount: e.amount, method: methodOf(e.method || 'cash'), line_no,
      note: [type.toLowerCase() !== e.type.toLowerCase() ? e.type : '', /^all$/i.test(e.what) ? '' : e.what, e.note].filter(Boolean).join(', ') });
  }
  assumptions.push('Expense types read from the text (e.g. "hp charger blue pin" → Charger, "dell 360 kb" → Keyboard, "char+hdd+ram" → Other); the original text is kept in the note.');
  assumptions.push('An expense applies to one line when its brand matches exactly one line of the lot; otherwise it is shared across the whole lot.');
  assumptions.push(`Text cleaned: ${FIX_LIST.join(', ')}.`);

  const month = d => d.slice(0, 7), byMonth = {};
  sales.forEach(s => { byMonth[month(s.sold_on)] = (byMonth[month(s.sold_on)] || 0) + s.price; });
  const totals = {
    lots: lots.length, lines: lots.reduce((t, l) => t + l.lines.length, 0),
    laptops: lots.reduce((t, l) => t + l.lines.reduce((u, x) => u + x.qty, 0), 0),
    cost: lots.reduce((t, l) => t + l.lines.reduce((u, x) => u + (x.cost || 0), 0), 0),
    cost_missing: lots.reduce((t, l) => t + l.lines.filter(x => x.cost == null).reduce((u, x) => u + x.qty, 0), 0),
    sales: sales.length, sales_total: sales.reduce((t, s) => t + s.price, 0), sales_by_month: byMonth,
    expenses: expenses.length, expenses_total: expenses.reduce((t, e) => t + e.amount, 0)
  };
  const plan = { lots, expenses, sales: sales.map(({ _row, _text, ...s }) => s) };
  return { plan, flags, assumptions, totals, customers: a.customers, lotKeys, dups, pairs };
}
