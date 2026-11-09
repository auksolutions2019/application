// Printing: QR stickers (A4 gum paper, 4 per row), bill + warranty card, report PDF.
import { $, esc, rs, fmtD, addMonths, codeDigits } from './dom.js';
import { toast } from './feedback.js';
import { lapName } from './specs.js';

export function printStickers(codes) {
  if (typeof QRCode === 'undefined') return toast('The QR maker did not load. Reload the app and try again.');
  const pa = $('printArea');
  pa.innerHTML = '<div class="stickers">' + codes.map((c, i) => `<div class="stk"><div class="q" id="qr${i}"></div><div class="c">${esc(c)}</div><div class="n">FIRST CHOICE LAPTOPS</div></div>`).join('') + '</div>';
  codes.forEach((c, i) => new QRCode($('qr' + i), { text: c, width: 240, height: 240, correctLevel: QRCode.CorrectLevel.M }));
  setTimeout(() => window.print(), 700);
}

export function warrantyOf(l) {
  const s = l.sale; if (!s) return null;
  const mo = s.warranty_months || 0, svc = addMonths(s.sold_on, 24);
  if (!mo) return null;
  const end = addMonths(s.sold_on, mo), ok = end >= new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10);
  return { months: mo, end, svc, ok, badge: `<span class="pill ${ok ? 'sold' : 'grey'}">${ok ? 'Warranty till ' + fmtD(end) : 'Warranty ended'}</span>` };
}

export function billText(l, S) {
  const sl = l.sale, w = warrantyOf(l);
  return `*${S.shop_name}*\nBill for ${sl.label}, ${fmtD(sl.sold_on)}\n\n${lapName(l)}\nSticker ${l.code}${l.serial ? `\nSerial ${l.serial}` : ''}\nPrice ${rs(sl.price)}\nPaid ${rs(sl.paid)}${sl.due > 0 ? `\nBalance ${rs(sl.due)}` : ''}\n\n${w ? `Warranty ${w.months} months, till ${fmtD(w.end)}\nService support till ${fmtD(w.svc)}\n\n` : ''}Please keep the QR sticker on the laptop for warranty.\n${S.addr}\n${S.phone}`;
}

export function printBill(l, S) {
  const sl = l.sale, w = warrantyOf(l);
  const no = 'FCL-' + sl.sold_on.replace(/-/g, '').slice(2) + '-' + codeDigits(l.code).slice(-5);
  $('printArea').innerHTML = `<div class="bill">
  <div class="bh"><img src="assets/logo.jpg" alt=""><div class="right"><b>Bill and warranty card</b><div>No. ${no}</div><div>Date ${fmtD(sl.sold_on)}</div></div></div>
  <div class="bs">${esc(S.addr)}<br>Phone and WhatsApp ${esc(S.phone)}</div>
  <div class="bg"><div><span>Customer</span><b>${esc(sl.label)}</b><div>${esc(sl.mobile || '')}${sl.address ? '<br>' + esc(sl.address) : ''}</div></div><div><span>Laptop</span><b>${esc(lapName(l))}</b><div>${l.grade ? 'Grade ' + esc(l.grade) : ''}</div><div>Sticker ${esc(l.code)}${l.serial ? '<br>Serial ' + esc(l.serial) : ''}</div></div></div>
  <table class="bt"><tr><td>Selling price</td><td class="right">${rs(sl.price)}</td></tr>
  ${sl.payments.map(p => `<tr><td>${p.method === 'Exchange' ? `Exchange laptop (${esc(p.ref)})` : `Paid ${fmtD(p.paid_on)}, ${esc(p.method)}`}</td><td class="right">−${rs(p.amount)}</td></tr>`).join('')}
  <tr class="tot"><td>${sl.due > 0 ? 'Balance to pay' : 'Fully paid'}</td><td class="right">${rs(sl.due)}</td></tr></table>
  <div class="bw"><b>${w ? `Warranty: ${w.months} months, valid till ${fmtD(w.end)}` : 'No warranty on this laptop'}</b><div>Service support till ${fmtD(addMonths(sl.sold_on, 24))}${w ? '' : ' (paid repairs)'}.</div>
  <div>Warranty covers hardware faults found in normal use. It does not cover physical damage, liquid damage, burnt parts, or a removed or damaged QR sticker. Please bring this bill for any service.</div></div>
  <div class="bsig"><div>Customer signature</div><div>For ${esc(S.shop_name)}</div></div></div>`;
  document.body.classList.add('billp');
  setTimeout(() => window.print(), 300);
}
addEventListener('afterprint', () => document.body.classList.remove('billp', 'rep'));
export function printReport() { document.body.classList.add('rep'); setTimeout(() => window.print(), 200); }
