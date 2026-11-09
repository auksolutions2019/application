// Structured specs: quick-pick chips with "Other", and the shop shorthand ("Dell i5 7th 8/256").
// shorthand() mirrors private.shorthand() in the database.
import { $, esc, chips, chipVal, val } from './dom.js';

export const BRANDS = ['Dell', 'HP', 'Lenovo', 'Acer', 'Asus', 'Apple', 'Other'];
export const PROCS = ['i3', 'i5', 'i7', 'i9', 'Pentium', 'Celeron', 'Ryzen 3', 'Ryzen 5', 'Ryzen 7', 'Other'];
export const GENS = [2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13];
export const RAMS = [4, 6, 8, 12, 16, 32];
export const SIZES = [128, 256, 320, 500, 512, 1000];
export const SKILLS = ['Chip-level', 'Screen', 'Keyboard', 'Battery', 'Hinge/body', 'Software', 'Other'];

const ord = n => n == null ? null : (n % 100 >= 11 && n % 100 <= 13) ? n + 'th' : n + (['th', 'st', 'nd', 'rd'][n % 10] || 'th');
export function shorthand(s) {
  if (!s) return '';
  const brand = s.brand === 'Other' ? (s.brand_other || '').trim() : (s.brand || '');
  const proc = s.processor === 'Other' ? (s.processor_other || '').trim() : (s.processor || '');
  const st = s.storage_gb == null ? 'N' : (s.storage_gb >= 1000 && s.storage_gb % 1000 === 0 ? s.storage_gb / 1000 + 'TB' : s.storage_gb);
  const mem = s.ram_gb == null && s.storage_gb == null ? '' : `${s.ram_gb ?? '?'}/${st}`;
  return [brand, proc, ord(s.gen), mem, s.storage_type === 'HDD' ? 'HDD' : ''].filter(Boolean).join(' ');
}
// Name used in lists: shorthand plus model, e.g. "Lenovo i5 8th 8/256 · T480"
export const lapName = l => [l.shorthand || shorthand(l), l.model].filter(Boolean).join(' · ') || 'Laptop';

const fallback = (list, v) => v == null || v === '' ? '' : (list.map(String).includes(String(v)) ? String(v) : 'more');

// Editor: id prefix p, current values s
export function specEditor(p, s = {}) {
  const gen = s.gen == null ? '' : String(s.gen);
  return `<div class="specrow"><span>Brand</span>${chips(p + 'brand', BRANDS, s.brand || '')}
    <input class="sm ${s.brand === 'Other' ? '' : 'hidden'}" id="${p}brand_other" placeholder="Brand name" value="${esc(s.brand_other || '')}"></div>
  <div class="specrow"><span>Model</span><input class="sm" id="${p}model" placeholder="e.g. Latitude 5490, T480, 840 G5" value="${esc(s.model || '')}"></div>
  <div class="specrow"><span>Processor</span>${chips(p + 'processor', PROCS, s.processor || '')}
    <input class="sm ${s.processor === 'Other' ? '' : 'hidden'}" id="${p}processor_other" placeholder="Processor" value="${esc(s.processor_other || '')}"></div>
  <div class="specrow"><span>Generation</span>${chips(p + 'genc', GENS.map(g => [g, ord(g)]), fallback(GENS, gen))}
    <input class="sm" id="${p}gen" type="number" inputmode="numeric" placeholder="Other generation" value="${GENS.map(String).includes(gen) ? '' : gen}"></div>
  <div class="specrow"><span>RAM (GB)</span>${chips(p + 'ram', RAMS, s.ram_gb ?? '')}</div>
  <div class="specrow"><span>Storage</span>${chips(p + 'stype', ['SSD', 'HDD'], s.storage_type || '')}
    ${chips(p + 'sizec', SIZES.map(z => [z, z >= 1000 ? z / 1000 + ' TB' : z + ' GB']), fallback(SIZES, s.storage_gb))}
    <input class="sm" id="${p}size" type="number" inputmode="numeric" placeholder="Other size (GB)" value="${s.storage_gb != null && !SIZES.includes(s.storage_gb) ? s.storage_gb : ''}"></div>`;
}
// Show the "Other" text boxes when Other is picked
export function wireSpecEditor(p) {
  for (const k of ['brand', 'processor']) {
    const box = $(p + k); if (!box) continue;
    box.addEventListener('change', () => $(p + k + '_other')?.classList.toggle('hidden', chipVal(p + k) !== 'Other'));
  }
}
export function readSpecs(p) {
  const n = v => v == null || v === '' ? null : Number(v);
  const brand = chipVal(p + 'brand') || null, processor = chipVal(p + 'processor') || null;
  return {
    brand, brand_other: brand === 'Other' ? val(p + 'brand_other') : '',
    model: val(p + 'model'),
    processor, processor_other: processor === 'Other' ? val(p + 'processor_other') : '',
    gen: n(val(p + 'gen')) ?? n(chipVal(p + 'genc')),
    ram_gb: n(chipVal(p + 'ram')),
    storage_type: chipVal(p + 'stype') || null,
    storage_gb: n(val(p + 'size')) ?? n(chipVal(p + 'sizec'))
  };
}
