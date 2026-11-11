// Small checks without a database: bill helpers, the photo-delete Cloudinary helpers, and that every
// Edge Function is valid code. Usage: node unit.mjs
import { rupeesInWords } from '../../ui/words.js';
import { addMonths } from '../../ui/dom.js';
import { readFileSync, writeFileSync, mkdtempSync, readdirSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

let pass = 0, fail = 0;
const eq = (a, b, n) => { if (a === b) { pass++; console.log('  PASS', n); } else { fail++; console.log('  FAIL', n, `(got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`); } };

console.log('Amount in words (Indian numbering)');
eq(rupeesInWords(8300), 'Eight Thousand Three Hundred Rupees Only/-', '₹8,300');
eq(rupeesInWords(125000), 'One Lakh Twenty Five Thousand Rupees Only/-', '₹1,25,000');
eq(rupeesInWords(1000000), 'Ten Lakh Rupees Only/-', '₹10,00,000');
eq(rupeesInWords(29500), 'Twenty Nine Thousand Five Hundred Rupees Only/-', '₹29,500');
eq(rupeesInWords(12345678), 'One Crore Twenty Three Lakh Forty Five Thousand Six Hundred Seventy Eight Rupees Only/-', '₹1,23,45,678');
eq(rupeesInWords(100), 'One Hundred Rupees Only/-', '₹100');
eq(rupeesInWords(0), 'Zero Rupees Only/-', '₹0');

console.log('Warranty end dates come from the bill date');
eq(addMonths('2026-10-04', 3), '2027-01-04', '3 months from 04-10-2026 is 04-01-2027');
eq(addMonths('2026-10-04', 12), '2027-10-04', '12 months from 04-10-2026 is 04-10-2027');
eq(addMonths('2026-01-31', 1), '2026-02-28', 'month end: 31-01-2026 + 1 month is 28-02-2026 (same as the database)');

console.log('Photo delete: Cloudinary helpers (supabase/functions/photo-delete)');
const fnDir = new URL('../../supabase/functions/', import.meta.url);
const tmp = mkdtempSync(join(tmpdir(), 'fcl-fn-'));
const src = readFileSync(new URL('photo-delete/index.ts', fnDir), 'utf8');
const helpers = src.slice(src.indexOf('// --- helpers'), src.indexOf('// --- end helpers ---'));
writeFileSync(join(tmp, 'helpers.mjs'), stripTypeScriptTypes(helpers) + '\nexport { publicIdOf, signParams };\n');
const { publicIdOf, signParams } = await import(pathToFileURL(join(tmp, 'helpers.mjs')).href);
eq(publicIdOf('https://res.cloudinary.com/fcl/image/upload/v1731300000/fcl/abc123.jpg', 'fcl'), 'fcl/abc123', 'public_id from a normal photo URL');
eq(publicIdOf('https://res.cloudinary.com/fcl/image/upload/c_fill,w_96,h_96,q_auto,f_auto/v17/fcl/abc.jpg', 'fcl'), 'fcl/abc', 'public_id from a thumbnail URL');
eq(publicIdOf('https://res.cloudinary.com/fcl/image/upload/abc.png', 'fcl'), 'abc', 'public_id without a folder or version');
eq(publicIdOf('https://res.cloudinary.com/other/image/upload/v1/x.jpg', 'fcl'), null, 'a photo from another Cloudinary account is not touched');
eq(publicIdOf('https://res.cloudinary.com/fcl/image/upload/v1/x.jpg', ''), null, 'no cloud name set: nothing is deleted');
const want = createHash('sha1').update('invalidate=true&public_id=fcl/abc&timestamp=1731300000' + 'SECRET').digest('hex');
eq(await signParams({ timestamp: '1731300000', public_id: 'fcl/abc', invalidate: 'true' }, 'SECRET'), want, 'signature: parameters sorted by name, then the secret, SHA-1');

console.log('Edge Functions are valid code');
for (const f of readdirSync(fnDir).filter(d => !d.includes('.'))) {
  writeFileSync(join(tmp, f + '.mjs'), stripTypeScriptTypes(readFileSync(new URL(f + '/index.ts', fnDir), 'utf8')));
  let res = true;
  try { execFileSync(process.execPath, ['--check', join(tmp, f + '.mjs')], { stdio: 'pipe' }); }
  catch (e) { res = String(e.stderr).split(/\r?\n/).slice(0, 4).join(' '); }
  eq(res, true, f);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
