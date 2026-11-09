// Printing: QR stickers (A4 gum paper, 4 per row), the bill (the dealer's invoice design, A4 only) and the report PDF.
// Bill: colour for the PDF that is saved / sent on WhatsApp, black and white for printing (Settings: "Print in black and white").
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

export const dmy = iso => iso ? String(iso).slice(0, 10).split('-').reverse().join('-') : '';
// ₹8,300.00 as on the bill
export const rs2 = n => '₹' + (Number(n) || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const monthsText = m => m >= 12 && m % 12 === 0 ? `${m / 12} year${m > 12 ? 's' : ''}` : `${m} month${m > 1 ? 's' : ''}`;
const mobileText = m => { const d = String(m || '').replace(/\D/g, '').slice(-10); return d.length === 10 ? `${d.slice(0, 5)} ${d.slice(5)}` : String(m || ''); };
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

// Wording as on the dealer's bill: "HP 240 G3" / "HP 240 G3, i3 4th gen" / "8GB RAM, 320GB HDD"
const ord = n => (n % 100 >= 11 && n % 100 <= 13) ? n + 'th' : n + (['th', 'st', 'nd', 'rd'][n % 10] || 'th');
function names(l) {
  const brand = l.brand === 'Other' ? l.brand_other : l.brand, proc = l.processor === 'Other' ? l.processor_other : l.processor;
  const title = [brand, l.model].filter(Boolean).join(' ') || l.shorthand || 'Laptop';
  const cpu = [proc, l.gen ? ord(l.gen) + ' gen' : ''].filter(Boolean).join(' ');
  const st = l.storage_gb ? `${l.storage_gb >= 1000 && l.storage_gb % 1000 === 0 ? l.storage_gb / 1000 + 'TB' : l.storage_gb + 'GB'} ${l.storage_type || ''}`.trim() : '';
  return { title, line1: cpu ? `${title}, ${cpu}` : title, line2: [l.ram_gb ? `${l.ram_gb}GB RAM` : '', st].filter(Boolean).join(', ') };
}

// Everything on one bill: one laptop, or all laptops of a bulk sale
export function billData(laptops, S) {
  const items = [], pays = [];
  let due = 0;
  for (const l of laptops) {
    const sl = l.sale, n = names(l);
    items.push({ l, sl, ...n, wtext: warrantyText(sl), qty: 1, price: +sl.price, w: warrantyOf(l), token: sl.warranty_token });
    for (const p of sl.payments) {
      pays.push({ text: p.method === 'Exchange' ? `Exchange laptop${p.ref ? ' ' + p.ref : ''}`
        : `${p.from_booking ? 'Advance' : 'Paid'} ${dmy(p.paid_on)}, ${p.method}`, amount: +p.amount, date: p.paid_on, method: p.method });
    }
    due += Math.max(0, +sl.due);
  }
  // same laptop, same price, same warranty → one row with a quantity (only without a warranty QR)
  const rows = [];
  for (const it of items) {
    const same = !it.w && rows.find(r => !r.w && r.line1 === it.line1 && r.line2 === it.line2 && r.price === it.price && r.wtext === it.wtext);
    if (same) same.qty++; else rows.push({ ...it });
  }
  // payments made the same day, the same way, on a bulk bill are shown as one line
  const merged = [];
  for (const p of pays) { const m = merged.find(x => x.text === p.text); if (m) m.amount += p.amount; else merged.push({ ...p }); }
  const total = rows.reduce((t, r) => t + r.qty * r.price, 0);
  const first = laptops[0].sale;
  return { rows, pays: merged, total, due, sale: first, items, invoice: first.invoice_no ? 'INV-' + first.invoice_no : '', date: billDate(first),
    biz: S.bill_name || S.shop_name || 'First Choice Laptops' };
}

export function billText(laptops, S) {
  const b = billData(laptops, S), sl = b.sale;
  const lines = [`*${b.biz}*`, `Invoice ${b.invoice || ''}, ${dmy(b.date)}`, `Bill to ${sl.label}`, ''];
  b.rows.forEach((r, i) => { lines.push(`${i + 1}. ${r.line1}${r.qty > 1 ? ` × ${r.qty}` : ''}`); if (r.line2) lines.push(`   ${r.line2}`); lines.push(`   ${rs2(r.qty * r.price)}`); });
  lines.push('', `Total ${rs2(b.total)}`);
  b.pays.forEach(p => lines.push(`${p.text} −${rs2(p.amount)}`));
  lines.push(`*BALANCE ${rs2(b.due)}*`, '');
  b.items.filter(r => r.w).forEach(r => {
    lines.push(`Warranty${b.items.length > 1 ? ' ' + r.l.code : ''}:`);
    if (r.w.end) lines.push(`Laptop, ${monthsText(r.w.months)}: valid till ${dmy(r.w.end)}`);
    if (r.w.aend) lines.push(`Charger and battery, ${monthsText(r.w.acc)}: valid till ${dmy(r.w.aend)}`);
    if (r.token) lines.push(`Check warranty: ${warrantyUrl(r.token)}`);
  });
  lines.push('Please keep this invoice and the QR sticker on the laptop for warranty.', S.addr, S.phone);
  return lines.filter(x => x != null && x !== undefined).join('\n');
}

export function billHtml(laptops, S, color) {
  const b = billData(laptops, S), sl = b.sale;
  // the built-in First Choice logo already says the name; an uploaded logo gets the name beside it
  const custom = !!S.logo_url, logo = S.logo_url || 'assets/logo.jpg';
  const bank = [['Bank', S.bank_name], ['Account holder', S.bank_holder], ['Account no.', S.bank_account], ['IFSC', S.bank_ifsc]].filter(x => x[1]);
  const one = laptops.length === 1 ? laptops[0] : null, n1 = one ? names(one) : null;
  let q = 0;
  return `<div class="inv ${color ? 'inv-color' : 'inv-bw'}">
  <div class="ih"><img class="logo${custom ? ' sq' : ''}" src="${esc(logo)}" alt="">
    <div class="biz">${custom ? `<b>${esc(b.biz)}</b>` : ''}<div>${esc(S.addr)}</div><div>${[S.phone ? 'Phone ' + esc(S.phone) : '', esc(S.bill_email || '')].filter(Boolean).join(' &nbsp;│&nbsp; ')}</div></div>
    <div class="no"><h1>INVOICE</h1><table><tr><td>Invoice no.</td><td><b>${esc(b.invoice)}</b></td></tr><tr><td>Invoice date</td><td><b>${dmy(b.date)}</b></td></tr></table></div></div>
  <div class="two"><div><span class="lbl">Bill to</span><b>${esc(sl.label)}</b>${sl.address ? `<div>${esc(sl.address)}</div>` : ''}${sl.mobile ? `<div>Mobile ${esc(mobileText(sl.mobile))}</div>` : ''}</div>
    <div><span class="lbl">Laptop</span>${one ? `<b>${esc(n1.title)}</b><div>Sticker code ${esc(one.code)}</div>${one.serial ? `<div>Serial ${esc(one.serial)}</div>` : ''}`
      : `<b>${laptops.length} laptops</b><div>Sticker codes ${laptops.map(l => esc(l.code)).join(', ')}</div>`}</div></div>
  <table class="it"><tr><th style="width:9mm">#</th><th>Description</th><th class="r">Qty</th><th class="r">Price</th><th class="r">Total</th></tr>
  ${b.rows.map((r, i) => `<tr><td>${i + 1}</td><td><div class="d1">${esc(r.line1)}</div>${r.line2 ? `<div class="d2">${esc(r.line2)}</div>` : ''}${one ? '' : `<div class="d2">Sticker code ${esc(r.l.code)}${r.l.serial ? ', serial ' + esc(r.l.serial) : ''}</div>`}<div class="d2">${esc(r.wtext)}</div></td>
     <td class="r">${r.qty}</td><td class="r">${rs2(r.price)}</td><td class="r">${rs2(r.qty * r.price)}</td></tr>`).join('')}</table>
  <div class="tot"><div class="words"><span class="lbl">Amount in words</span><div>${esc(rupeesInWords(b.total))}</div></div>
    <div class="sums"><div class="l"><span>Total</span><span>${rs2(b.total)}</span></div>
    ${b.pays.map(p => `<div class="l"><span>${esc(p.text)}</span><span>−${rs2(p.amount)}</span></div>`).join('')}
    <div class="bal"><span>BALANCE</span><span>${rs2(b.due)}</span></div></div></div>
  ${b.items.filter(r => r.w).map(r => `<div class="iwb">${r.token ? `<div class="qr"><div class="q" id="wq${q++}" data-url="${esc(warrantyUrl(r.token))}"></div><small>Scan to check warranty</small></div>` : ''}
    <div class="wt"><h4>Warranty${b.items.length > 1 ? ' – ' + esc(r.l.code) : ''}</h4>
    ${r.w.end ? `<div class="wl"><span>Laptop, ${monthsText(r.w.months)}</span><b>Valid till ${dmy(r.w.end)}</b></div>` : ''}
    ${r.w.aend ? `<div class="wl"><span>Charger and battery, ${monthsText(r.w.acc)}</span><b>Valid till ${dmy(r.w.aend)}</b></div>` : ''}
    <p>Warranty starts on the invoice date. It covers hardware faults in normal use. It does not cover physical damage, liquid damage, burnt parts, or a removed or damaged sticker. Please bring this invoice for any service.</p></div></div>`).join('')}
  <div class="ft"><div class="bank">${bank.length ? `<span class="lbl">Payment instructions</span>${bank.map(([k, v]) => `<div>${k}: ${esc(v)}</div>`).join('')}` : ''}</div>
    <div class="sign"><b>For, ${esc(b.biz.toUpperCase())}</b><div class="sl">AUTHORIZED SIGNATURE</div></div></div>
  <div class="thanks">Thank you for your purchase. Keep this invoice and the QR sticker on the laptop for warranty.</div></div>`;
}

// mode 'print' → black and white if the setting is on; mode 'pdf' → always colour (to save and share on WhatsApp)
export function printBill(laptops, S, mode = 'print') {
  const color = mode === 'pdf' || S.bill_print_bw === false;
  $('printArea').innerHTML = billHtml(laptops, S, color);
  if (typeof QRCode !== 'undefined') document.querySelectorAll('#printArea .iwb .q').forEach(el => new QRCode(el, { text: el.dataset.url, width: 220, height: 220, correctLevel: QRCode.CorrectLevel.M }));
  if (mode === 'pdf') toast('In the print screen choose "Save as PDF". Then share the PDF on WhatsApp.', 'ok');
  document.body.classList.add('billp');
  const old = document.title;
  document.title = `Bill ${billData(laptops, S).invoice || ''}`.trim();   // becomes the PDF's file name
  setTimeout(() => { window.print(); document.title = old; }, 500);
}
addEventListener('afterprint', () => document.body.classList.remove('billp', 'rep'));
export function printReport() { document.body.classList.add('rep'); setTimeout(() => window.print(), 200); }
