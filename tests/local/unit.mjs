// Small checks for the bill helpers (no database). Usage: node unit.mjs
import { rupeesInWords } from '../../ui/words.js';
import { addMonths } from '../../ui/dom.js';

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

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
