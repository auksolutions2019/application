// Printing: QR stickers (A4 gum paper, 4 per row), the bill (dealer's invoice layout, A4) and the report PDF.
import { $, esc, rs, addMonths, todayIN } from './dom.js';
import { toast } from './feedback.js';
import { lapName } from './specs.js';
import { rupeesInWords } from './words.js';

export function printStickers(codes) {
  if (typeof QRCode === 'undefined') return toast('The QR maker did not load. Reload the app and try again.');
  const pa = $('printArea');
  pa.innerHTML = '<div class="stickers">' + codes.map((c, i) => `<div class="stk"><div class="q" id="qr${i}"></div><div class="c">${esc(c)}</div><div class="n">FIRST CHOICE LAPTOPS</div></div>`).join('') + '</div>';
  codes.forEach((c, i) => new QRCode($('qr' + i), { text: c, width: 240, height: 240, correctLevel: QRCode.CorrectLevel.M }));
  setTimeout(() => window.print(), 700);
}

const dmy = iso => iso ? String(iso).slice(0, 10).split('-').reverse().join('-') : '';
const monthsText = m => m >= 12 && m % 12 === 0 ? `${m / 12} year${m > 12 ? 's' : ''}` : `${m} month${m > 1 ? 's' : ''}`;
// The public warranty check page on this site, e.g. https://first-choice-laptops.pages.dev/w/?t=…
export const warrantyUrl = token => token ? new URL('w/?t=' + token, location.href.split(/[?#]/)[0].replace(/[^/]*$/, '')).href : '';
const billDate = sl => sl.bill_date || sl.sold_on;

// Warranty dates are fixed from the bill date
export function warrantyOf(l) {
  const s = l.sale; if (!s) return null;
  const mo = s.warranty_months || 0, acc = s.accessory_warranty_months || 0;
  if (!mo && !acc) return null;
  const bd = billDate(s), end = mo ? addMonths(bd, mo) : null, aend = acc ? addMonths(bd, acc) : null;
  const main = end || aend, ok = main >= todayIN();
  return { months: mo, acc, end, aend, main, ok, svc: addMonths(s.sold_on, 24),
    badge: `<span class="pill ${ok ? 'sold' : 'grey'}">${ok ? 'Warranty till ' + dmy(main) : 'Warranty ended'}</span>` };
}
export function warrantyText(sl) {
  const p = [];
  if (sl.warranty_months) p.push(`${monthsText(sl.warranty_months)} warranty for laptop`);
  if (sl.accessory_warranty_months) p.push(`${monthsText(sl.accessory_warranty_months)} warranty for charger and battery`);
  return p.join(', ') || 'No warranty';
}

// Description lines, as on the dealer's bill: "HP 240 G3 i3 4th gen" / "8GB RAM, 320GB HDD" / warranty
const ord = n => (n % 100 >= 11 && n % 100 <= 13) ? n + 'th' : n + (['th', 'st', 'nd', 'rd'][n % 10] || 'th');
function descLines(l) {
  const brand = l.brand === 'Other' ? l.brand_other : l.brand, proc = l.processor === 'Other' ? l.processor_other : l.processor;
  const line1 = [brand, l.model, proc, l.gen ? ord(l.gen) + ' gen' : ''].filter(Boolean).join(' ') || lapName(l);
  const st = l.storage_gb ? `${l.storage_gb >= 1000 && l.storage_gb % 1000 === 0 ? l.storage_gb / 1000 + 'TB' : l.storage_gb + 'GB'} ${l.storage_type || ''}`.trim() : '';
  const line2 = [l.ram_gb ? `${l.ram_gb}GB RAM` : '', st].filter(Boolean).join(', ');
  return { line1, line2 };
}

// Everything on one bill: the laptops (one, or all of a bulk sale), minus lines, totals.
export function billData(laptops, S) {
  const items = [], minus = [];
  let paid = 0, due = 0;
  for (const l of laptops) {
    const sl = l.sale, w = warrantyOf(l), d = descLines(l);
    items.push({ l, sl, ...d, wtext: warrantyText(sl), qty: 1, price: +sl.price, w, token: sl.warranty_token });
    for (const p of sl.payments) {
      if (p.method === 'Exchange') minus.push({ text: `Less: exchange laptop${p.ref ? ' (' + p.ref + ')' : ''}`, amount: +p.amount });
      else if (p.from_booking) minus.push({ text: `Less: advance paid on ${dmy(p.paid_on)}`, amount: +p.amount });
      else paid += +p.amount;
    }
    due += Math.max(0, +sl.due);
  }
  // Rows without a warranty QR and with the same description and price are grouped with a quantity
  const rows = [];
  for (const it of items) {
    const same = !it.w && rows.find(r => !r.w && r.line1 === it.line1 && r.line2 === it.line2 && r.price === it.price && r.wtext === it.wtext);
    if (same) same.qty++; else rows.push({ ...it });
  }
  const itemsTotal = rows.reduce((t, r) => t + r.qty * r.price, 0), less = minus.reduce((t, m) => t + m.amount, 0);
  const first = laptops[0].sale;
  return { rows, minus, itemsTotal, grand: itemsTotal - less, paid, due, sale: first, invoice: first.invoice_no ? 'INV-' + first.invoice_no : '', date: billDate(first),
    biz: S.bill_name || S.shop_name };
}

export function billText(laptops, S) {
  const b = billData(laptops, S), sl = b.sale;
  const lines = [`*${b.biz}*`, `Invoice ${b.invoice || ''}, ${dmy(b.date)}`, `Bill to ${sl.label}`, ''];
  b.rows.forEach((r, i) => { lines.push(`${i + 1}. ${r.line1}${r.qty > 1 ? ` × ${r.qty}` : ''}`); if (r.line2) lines.push(`   ${r.line2}`); lines.push(`   ${rs(r.qty * r.price)}`); });
  b.minus.forEach(m => lines.push(`${m.text}: −${rs(m.amount)}`));
  lines.push('', `GRAND TOTAL ${rs(b.grand)}`);
  if (b.due > 0) lines.push(`Paid ${rs(b.paid)}`, `Balance ${rs(b.due)}`);
  lines.push('');
  b.rows.filter(r => r.w).forEach(r => {
    lines.push(`Warranty${b.rows.length > 1 ? ' ' + r.l.code : ''}: ${r.wtext}`);
    if (r.w.end) lines.push(`Laptop till ${dmy(r.w.end)}`);
    if (r.w.aend) lines.push(`Charger and battery till ${dmy(r.w.aend)}`);
    if (r.token) lines.push(`Check warranty: ${warrantyUrl(r.token)}`);
  });
  lines.push('Please keep the QR sticker on the laptop for warranty.', S.addr, S.phone);
  return lines.filter(x => x != null).join('\n');
}

export function printBill(laptops, S) {
  const b = billData(laptops, S), sl = b.sale;
  const bank = [['Bank', S.bank_name], ['Account holder', S.bank_holder], ['Account number', S.bank_account], ['IFSC', S.bank_ifsc]].filter(x => x[1]);
  let q = 0;
  const html = `<div class="inv">
  <div class="ih"><img src="${esc(S.logo_url || 'assets/logo.jpg')}" alt="">
    <div class="biz"><b>${esc(b.biz)}</b><div>${esc(S.addr)}</div><div>${esc(S.phone)}${S.bill_email ? ' · ' + esc(S.bill_email) : ''}</div></div>
    <h1>INVOICE</h1></div>
  <div class="ibill"><div><span>BILL TO</span><b>${esc(sl.label)}</b>${sl.address ? `<div>${esc(sl.address)}</div>` : ''}${sl.mobile ? `<div>${esc(sl.mobile)}</div>` : ''}</div>
    <div style="text-align:right"><span>INVOICE NO</span><b>${esc(b.invoice)}</b><span style="margin-top:2mm">INVOICE DATE</span><b>${dmy(b.date)}</b></div></div>
  <table><tr><th>#</th><th>Description</th><th class="r">Qty</th><th class="r">Price</th><th class="r">Total</th></tr>
  ${b.rows.map((r, i) => `<tr><td>${i + 1}</td><td><div class="d1">${esc(r.line1)}</div>${r.line2 ? `<div class="d2">${esc(r.line2)}</div>` : ''}<div class="d2">Sticker ${esc(r.l.code)}${r.l.serial ? ', serial ' + esc(r.l.serial) : ''}</div>
      <div class="d3">${esc(r.wtext)}</div>${r.w && r.token ? `<div class="wq"><div class="q" id="wq${q++}" data-url="${esc(warrantyUrl(r.token))}"></div><small>Scan to check warranty. Valid till ${dmy(r.w.main)}</small></div>` : ''}</td>
      <td class="r">${r.qty}</td><td class="r">${rs(r.price)}</td><td class="r">${rs(r.qty * r.price)}</td></tr>`).join('')}
  ${b.minus.map(m => `<tr class="minus"><td></td><td>${esc(m.text)}</td><td></td><td></td><td class="r">−${rs(m.amount)}</td></tr>`).join('')}</table>
  <div class="tot"><div class="words"><span>AMOUNT IN WORDS</span>${esc(rupeesInWords(b.grand))}</div>
    <div class="sums"><div class="gt"><span>GRAND TOTAL</span><span>${rs(b.grand)}</span></div>
    ${b.due > 0 ? `<div><span>Paid</span><span>${rs(b.paid)}</span></div><div><b>Balance</b><b>${rs(b.due)}</b></div>` : ''}</div></div>
  <div class="ft"><div>${bank.length ? `<span>PAYMENT INSTRUCTIONS</span>${bank.map(([k, v]) => `<div>${k}: <b>${esc(v)}</b></div>`).join('')}` : ''}</div>
    <div class="sign"><div>For, ${esc(b.biz.toUpperCase())}</div><div class="sl">AUTHORIZED SIGNATURE</div></div></div></div>`;
  $('printArea').innerHTML = html;
  if (typeof QRCode !== 'undefined') document.querySelectorAll('#printArea .wq .q').forEach(el => new QRCode(el, { text: el.dataset.url, width: 200, height: 200, correctLevel: QRCode.CorrectLevel.M }));
  document.body.classList.add('billp');
  setTimeout(() => window.print(), 500);
}
addEventListener('afterprint', () => document.body.classList.remove('billp', 'rep'));
export function printReport() { document.body.classList.add('rep'); setTimeout(() => window.print(), 200); }
