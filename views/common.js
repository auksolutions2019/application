// Helpers shared by the screens (ported from the prototype).
import { esc, rs, fmtD, tag, daysSince } from '../ui/dom.js';
import { S } from '../api/store.js';
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
export function lapRow(l) {
  const sub = l.service ? `With ${esc(l.service.partner)}, ${l.service.days_out} day${l.service.days_out === 1 ? '' : 's'}`
    : l.sale ? esc(l.sale.label) + ', ' + fmtD(l.sale.sold_on)
    : 'In stock' + (l.repairs?.length ? ', repairs ' + rs(l.repairs.reduce((s, r) => s + +r.amount, 0)) : '');
  return `<div class="lrow" onclick="A.openLaptop('${esc(l.code)}')"><div class="cm">${tag(l.code)}<b style="margin-top:7px">${esc(lapName(l))}</b><div class="muted">${sub}</div></div>${status(l)}</div>`;
}
export function lapList(list, max = 60) {
  return list.length ? `<div class="list flat" style="margin-top:10px">${list.slice(0, max).map(lapRow).join('')}</div>` : '<p class="muted" style="margin-top:10px">Nothing found.</p>';
}
export const matches = (l, q) => [l.code, l.serial, l.shorthand, l.model, l.sale?.name, l.sale?.mobile].some(v => (v || '').toLowerCase().includes(q));
