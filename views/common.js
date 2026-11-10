// Helpers shared by the screens (ported from the prototype).
import { esc, rs, fmtD, tag, daysSince } from '../ui/dom.js';
import { S, cachedLaptop } from '../api/store.js';
import { ICON } from '../ui/icons.js';
import { lapName } from '../ui/specs.js';

export const TESTS = ['Display', 'Keyboard', 'Touchpad', 'Battery', 'Charging', 'USB ports', 'Wi-Fi', 'Audio', 'Camera', 'Storage'];
export const LEADS = ['OLX', 'Instagram', 'Lead Matrix', 'Circle app', 'Octo', 'Walk-in', 'Old customer', 'Dealer', 'Other'];
export const testCount = l => TESTS.filter(t => l.tests?.[t] === 'ok').length;
export const testsPassed = l => testCount(l) === TESTS.length;
export const testFails = l => TESTS.filter(t => l.tests?.[t] === 'fail').length;
export const owned = l => !l.sale;                       // the shop's laptop (in stock, booked or at service as stock)
export const onShelf = l => !l.sale && l.status !== 'at_service';
export const atService = l => l.status === 'at_service';
export const ageDays = l => daysSince(l.added_on);
export const oldDays = () => S.d?.settings?.old_days || 60;
export const lotOf = l => S.lotById?.get(l.lot_id);

export function status(l) {
  if (atService(l)) return `<span class="pill svc">At service</span>`;
  if (!l.sale && l.booking) return '<span class="pill res">Booked</span>';
  if (!l.sale) return '<span class="pill stock">In stock</span>';
  return l.sale.due > 0 ? `<span class="pill due">Due ${rs(l.sale.due)}</span>` : '<span class="pill sold">Sold</span>';
}
export function testBadge(l) {
  if (l.sale) return '';
  return testsPassed(l) ? '<span class="pill sold">Tested</span>'
    : testFails(l) ? `<span class="pill due">${testFails(l)} test${testFails(l) > 1 ? 's' : ''} failed</span>`
    : `<span class="pill grey">Tested ${testCount(l)}/${TESTS.length}</span>`;
}
// Small photo of a laptop: its first Cloudinary photo as a square thumbnail, or a grey box with a laptop outline.
// l is a laptop, or a sticker code (looked up among the laptops on this phone). size: '' (44px), 'sm' (28px) or 'lg' (56px).
// open: also open the laptop when the thumbnail is tapped (for rows that are not tappable themselves).
export const cloudThumb = (u, px = 96) => /^https:\/\/res\.cloudinary\.com\/[^/]+\/image\/upload\//.test(u || '')
  ? u.replace('/image/upload/', `/image/upload/c_fill,w_${px},h_${px},q_auto,f_auto/`) : u;
export function thumb(l, size = '', open = false) {
  const lap = typeof l === 'string' ? cachedLaptop(l) : l, code = typeof l === 'string' ? l : l?.code;
  const u = lap?.photos?.[0], cls = `lthumb${size ? ' ' + size : ''}`;
  const tap = open && code ? ` onclick="event.stopPropagation();A.openLaptop('${esc(code)}')"` : '';
  return u ? `<img class="${cls}" src="${esc(cloudThumb(u, size === 'lg' ? 120 : 96))}" loading="lazy" decoding="async" alt=""${tap}>`
    : `<span class="${cls} none" aria-hidden="true"${tap}>${ICON.stock}</span>`;
}
export function lapRow(l) {
  const sub = l.service ? `With ${esc(l.service.partner)}, ${l.service.days_out} day${l.service.days_out === 1 ? '' : 's'}`
    : l.sale ? esc(l.sale.label) + ', ' + fmtD(l.sale.sold_on)
    : 'In stock' + (l.repairs?.length ? ', repairs ' + rs(l.repairs.reduce((s, r) => s + +r.amount, 0)) : '');
  return `<div class="lrow" onclick="A.openLaptop('${esc(l.code)}')">${thumb(l)}<div class="cm">${tag(l.code)}<b style="margin-top:7px">${esc(lapName(l))}</b><div class="muted">${sub}</div></div>${status(l)}</div>`;
}
export function lapList(list, max = 60) {
  return list.length ? `<div class="list flat" style="margin-top:10px">${list.slice(0, max).map(lapRow).join('')}</div>` : '<p class="muted" style="margin-top:10px">Nothing found.</p>';
}
// A payment's note, shown under it. The admin gets a pencil to change the note (never the amount).
export function noteLine(note, kind, id) {
  const adm = S.d?.me?.role === 'admin' && kind && id;
  if (!note && !adm) return '';
  return `<div class="pnote">${note ? esc(note) : '<span class="muted">No note</span>'}${adm ? ` <a class="link" onclick="event.stopPropagation();A.editNote('${kind}','${id}','${encodeURIComponent(note || '').replace(/'/g, '%27')}')" aria-label="Edit note">✎</a>` : ''}</div>`;
}
export const matches = (l, q) => [l.code, l.serial, l.shorthand, l.model, l.sale?.name, l.sale?.mobile].some(v => (v || '').toLowerCase().includes(q));
