// Browser smoke test: runs the real app in headless Edge/Chrome against the local stand-in (devserver.mjs).
// Usage: npm i puppeteer-core  (anywhere), then
//   PUPPETEER_DIR=<folder with node_modules/puppeteer-core> BROWSER=<path to msedge.exe or chrome.exe> node tests/ui/smoke.mjs
import { createRequire } from 'node:module';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdirSync } from 'node:fs';
import { startDevServer, seed, USERS, PIN } from './devserver.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const puppeteer = createRequire(join(process.env.PUPPETEER_DIR || here, 'package.json'))('puppeteer-core');
const shots = join(here, 'screenshots'); mkdirSync(shots, { recursive: true });
let pass = 0, fail = 0; const errors = [];
const ok = (c, n, x = '') => { if (c) { pass++; console.log('  PASS', n); } else { fail++; console.log('  FAIL', n, x); } };

const srv = await startDevServer({ port: 8787, quiet: true });
const demo = await seed(srv);
const browser = await puppeteer.launch({ executablePath: process.env.BROWSER, headless: true, protocolTimeout: 30000, args: ['--no-sandbox'] });
const page = await browser.newPage();
await page.setViewport({ width: 400, height: 860, deviceScaleFactor: 1 });
page.on('pageerror', e => errors.push('pageerror: ' + e.message));
page.on('console', m => { if (m.type() === 'error' && !/realtime|websocket|WebSocket|404 \(Not Found\)|Failed to load resource/i.test(m.text())) errors.push('console: ' + m.text()); });
const wait = ms => new Promise(r => setTimeout(r, ms));
const main = () => page.$eval('#main', e => e.innerText);
const toastText = () => page.$eval('#toasts', e => e.innerText).catch(() => '');
const go = async v => { await page.evaluate(v => A.go(v), v); await wait(700); };
const shot = n => page.screenshot({ path: join(shots, n + '.png'), fullPage: false });
const q1 = async (sql, p) => (await srv.db.query(sql, p)).rows[0];

async function login(user, pin = PIN) {
  await page.goto('http://localhost:8787/', { waitUntil: 'networkidle0' });
  await page.evaluate(() => { localStorage.clear(); });
  await page.reload({ waitUntil: 'networkidle0' });
  await page.type('#lmob', user.mobile); await page.type('#lpin', pin);
  await page.click('#lbtn'); await wait(1500);
}

console.log('Login and Home (admin)');
await login(USERS[0]);
ok(!(await page.$eval('#app', e => e.classList.contains('hidden'))), 'admin logs in with mobile + PIN');
ok(/laptops on the shelf/.test(await main()), 'Home shows the stock count');
ok(/Stock value/.test(await main()) && /Owed to service partners/.test(await main()), 'admin Home: stock value and owed to service partners');
await shot('01-home-admin');

console.log('Every screen opens (admin)');
for (const v of ['stock', 'scan', 'sales', 'more', 'suppliers', 'debts', 'reports', 'backup', 'share', 'prices', 'money', 'activity', 'settings', 'partners', 'shopexp', 'lotpnl', 'users', 'pin']) {
  await go(v); await wait(400);
  const t = await main();
  ok(t.length > 20 && !/Could not show this screen/.test(t), `screen "${v}" shows`, t.slice(0, 120));
  if (['stock', 'reports', 'partners', 'debts', 'money'].includes(v)) await shot('02-' + v);
}

console.log('Laptop pop-up');
await go('stock'); await page.evaluate(() => A.stockTab('laps')); await wait(400);
const code = demo.l1.codes[4];
await page.evaluate(c => A.openLaptop(c), code); await wait(800);
ok(await page.$('.acts3') !== null, 'three big buttons shown');
ok(/Replace parts/.test(await page.$eval('#sheet', e => e.innerText)) && /Give for service/.test(await page.$eval('#sheet', e => e.innerText)), 'Replace parts, Delivery / Handover, Give for service');
await shot('03-laptop-hand');
// sell through the form
await page.evaluate(() => { document.querySelector('#hlead [data-v="Lead Matrix"]').click(); });
await page.$eval('#hprice', e => { e.value = ''; }); await page.type('#hprice', '22000');
await page.type('#hpaid', '20000'); await page.type('#hname', 'Rahul'); await page.type('#hmob', '9811111111'); await page.type('#hnote', 'cash at counter');
await page.click('button[onclick="A.sellOne()"]'); await wait(1200);
const sold = await q1(`select s.price, private.sale_paid(s.id) paid, s.lead_source from public.sales s join public.laptops l on l.id = s.laptop_id where l.code = $1 and s.status = 'active'`, [code]);
ok(sold && +sold.price === 22000 && +sold.paid === 20000 && sold.lead_source === 'Lead Matrix', 'sale saved from the form (₹22,000, ₹20,000 paid, Lead Matrix)', JSON.stringify(sold));
ok(/Balance/.test(await page.$eval('#sheet', e => e.innerText)), 'pop-up switches to the sold view with the balance');
await shot('04-laptop-sold');
const sNote = await q1(`select p.note, s.invoice_no, s.warranty_token, s.accessory_warranty_months acc from public.sale_payments p join public.sales s on s.id = p.sale_id join public.laptops l on l.id = s.laptop_id where l.code = $1`, [code]);
ok(sNote.note === 'cash at counter' && sNote.invoice_no >= 58 && +sNote.acc === 12, 'note, invoice number and charger/battery warranty saved with the sale', JSON.stringify(sNote));
ok(/cash at counter/.test(await page.$eval('#sheet', e => e.innerText)), 'the note shows under the payment');
// the bill
await page.evaluate(() => { window.print = () => { window.__printed = true; }; });
// sample bill details, as the dealer fills them in Settings (sample values, not the dealer's)
await srv.db.query(`update public.settings set bill_email = 'shop@example.com', bank_name = 'Sample Bank', bank_holder = 'Shop Owner', bank_account = '000011112222', bank_ifsc = 'SMPL0000001'`);
await page.evaluate(() => { A.closeModal(); dispatchEvent(new Event('online')); }); await wait(1200);   // the app reloads its data
await page.evaluate(c => A.openLaptop(c), code); await wait(600);
const showBill = async name => {
  await page.evaluate(() => { document.getElementById('printArea').style.cssText = 'display:block;background:#fff;padding:24px 0'; document.getElementById('app').style.display = 'none'; document.getElementById('modal').style.display = 'none'; });
  await page.setViewport({ width: 794, height: 1123 }); await wait(300); await shot(name);
  await page.setViewport({ width: 400, height: 860 });
  await page.evaluate(() => { document.getElementById('printArea').style.cssText = ''; document.getElementById('app').style.display = ''; document.getElementById('modal').style.display = ''; });
};
await page.evaluate(() => A.printBillCur('print')); await wait(1500);
const bill = await page.$eval('#printArea', e => { e.style.display = 'block'; const t = e.innerText; e.style.display = ''; return t; });   // read as printed (CSS capitals)
ok(await page.$('#printArea .inv.inv-bw') !== null && await page.evaluate(() => window.__printed === true), 'Print bill: black and white (setting on by default), print dialog opened');
ok(/INVOICE/.test(bill) && new RegExp('Invoice no\\.\\s+INV-' + sNote.invoice_no).test(bill) && /Invoice date\s+\d\d-\d\d-\d{4}/.test(bill), 'bill header: INVOICE, invoice no., invoice date', bill.slice(0, 300));
ok(/BILL TO\s+Rahul/.test(bill) && /Mobile 98111 11111/.test(bill) && /LAPTOP\s+Dell Latitude 5490/.test(bill) && new RegExp('Sticker code ' + code).test(bill), 'Bill To and the Laptop box with sticker code', bill.slice(0, 500));
ok(/Dell Latitude 5490, i5 8th gen/.test(bill) && /8GB RAM, 256GB SSD/.test(bill) && /6 months warranty for laptop, 1 year warranty for charger and battery/.test(bill), 'description lines as on the dealer\'s bill');
ok(/AMOUNT IN WORDS\s+Twenty Two Thousand Rupees Only\/-/.test(bill) && /Total\s+₹22,000\.00/.test(bill) && /Paid \d\d-\d\d-\d{4}, Cash\s+−₹20,000\.00/.test(bill) && /BALANCE\s+₹2,000\.00/.test(bill), 'amount in words, Total, payment line, BALANCE', bill.slice(bill.indexOf('AMOUNT'), bill.indexOf('AMOUNT') + 200));
ok(/Scan to check warranty/.test(bill) && /Laptop, 6 months\s+Valid till \d\d-\d\d-\d{4}/.test(bill) && /Charger and battery, 1 year\s+Valid till \d\d-\d\d-\d{4}/.test(bill) && /Warranty starts on the invoice date/.test(bill), 'warranty box: QR and both Valid till dates');
ok(/PAYMENT INSTRUCTIONS\s+Bank: Sample Bank/.test(bill) && /For, FIRST CHOICE LAPTOPS/.test(bill) && /AUTHORIZED SIGNATURE/.test(bill) && /Thank you for your purchase/.test(bill), 'payment instructions, "For, FIRST CHOICE LAPTOPS", signature, thank-you line');
ok(await page.$$eval('#printArea .iwb .q canvas, #printArea .iwb .q img', e => e.length) >= 1, 'warranty QR drawn');
await showBill('10-bill-bw');
await page.evaluate(() => A.printBillCur('pdf')); await wait(1500);
ok(await page.$('#printArea .inv.inv-color') !== null, 'Bill PDF: in colour');
await showBill('10-bill-colour');
await page.evaluate(() => { document.getElementById('printArea').innerHTML = ''; });
// the public warranty page (no login)
const wp = await browser.newPage(); await wp.setViewport({ width: 400, height: 700 });
await wp.goto('http://localhost:8787/w/?t=' + sNote.warranty_token, { waitUntil: 'networkidle0' }); await wait(500);
const wtext = await wp.$eval('#out', e => e.innerText);
ok(/Warranty check/.test(wtext) && /Valid till/.test(wtext) && new RegExp(code).test(wtext) && !/Rahul|98111|22,000|22000/.test(wtext), 'warranty page: valid till, sticker code, and no customer name, mobile or price', wtext);
await wp.screenshot({ path: join(shots, '11-warranty-page.png') });
await wp.goto('http://localhost:8787/w/?t=' + '0'.repeat(64), { waitUntil: 'networkidle0' }); await wait(400);
ok(/not found/i.test(await wp.$eval('#out', e => e.innerText)), 'warranty page: wrong code says not found');
await wp.close();
// give a laptop for service, then receive back
const code2 = demo.l1.codes[5];
await page.evaluate(() => A.closeModal()); await page.evaluate(c => A.openLaptop(c), code2); await wait(600);
await page.evaluate(() => A.lapTab('svc')); await wait(300);
await page.evaluate(() => document.querySelector('#sissue [data-v="Keyboard"]').click());
await page.click('button[onclick="A.giveService()"]'); await wait(1000);
ok((await q1(`select status from public.laptops where code = $1`, [code2])).status === 'at_service', 'given for service from the pop-up');
ok(/With Ravi Chip Repair/.test(await page.$eval('#sheet', e => e.innerText)), 'pop-up shows who has it and since when');
await shot('05-laptop-service');
await page.type('#rcharge', '1200'); await page.type('#rwork', 'keyboard replaced');
await page.click('button[onclick^="A.receiveService"]'); await wait(1000);
ok((await q1(`select status from public.laptops where code = $1`, [code2])).status === 'in_stock', 'received back: In stock again');
await page.evaluate(() => A.closeModal());

console.log('Add a lot with two lines');
await go('stock'); await page.evaluate(() => A.stockTab('lots')); await page.evaluate(() => A.addLot()); await wait(500);
await page.evaluate(() => { document.querySelector('#ln0_brand [data-v="HP"]').click(); document.querySelector('#ln0_processor [data-v="i5"]').click(); document.querySelector('#ln0_genc [data-v="8"]').click(); document.querySelector('#ln0_ram [data-v="8"]').click(); });
await page.type('#ln0_model', '840 G5'); await page.type('#ln0_qty', '2'); await page.type('#ln0_cost', '30000');
await page.evaluate(() => A.lotAddLine()); await wait(400);
await page.evaluate(() => { document.querySelector('#ln1_mixed').click(); }); await wait(300);
await page.type('#ln1_qty', '3');
await shot('06-add-lot');
await page.evaluate(() => { A.createLot(); }); await wait(1500);
await page.evaluate(() => document.getElementById('dlgno')?.click()); await wait(300);
const nl = await q1(`select count(*) n, count(*) filter (where shorthand = 'HP i5 8th 8/N') hp from public.laptops l join public.lots lo on lo.id = l.lot_id where lo.lot_no = 2 and lo.supplier_id = (select id from public.suppliers where code = '01')`);
ok(+nl.n === 5 && +nl.hp === 2, 'lot created: 5 laptops, 2 of them "HP i5 8th 8/N"', JSON.stringify(nl));

console.log('Offline');
await page.setOfflineMode(true); await page.evaluate(() => dispatchEvent(new Event('offline'))); await wait(300);
ok(await page.$eval('#offline', e => !e.classList.contains('hidden')), 'offline banner shows');
await page.evaluate(c => A.openLaptop(c), demo.l1.codes[6]); await wait(500);
await page.evaluate(() => A.setAllTests()); await wait(500);
await wait(800); const offState = await page.evaluate(() => ({ online: navigator.onLine, dlg: !document.getElementById('dlg').classList.contains('hidden'), toasts: document.getElementById('toasts').innerText }));
ok(/offline/i.test(offState.toasts), 'saving is blocked with a clear message', JSON.stringify(offState));
await page.setOfflineMode(false); await page.evaluate(() => { dispatchEvent(new Event('online')); A.closeModal(); }); await wait(800);

console.log('Staff');
await login(USERS[2]);
const dock = await page.$eval('#dock', e => e.innerText);
ok(!/Customers/.test(dock) && /Service/.test(dock), 'staff dock: Service instead of Customers');
ok(!/Stock value|Customers owe/.test(await main()), 'staff Home: no money');
await go('more'); ok(!/Reports|Liabilities|Settings|Backup|Activity|Suppliers/.test(await main()), 'staff More: no reports, money, suppliers, activity, settings or backup');
await go('reports'); ok(/laptops on the shelf/.test(await main()), 'staff opening Reports lands on Home');
await page.evaluate(c => A.openLaptop(c), code2); await wait(600);
await page.evaluate(() => A.lapTab('svc')); await wait(300);
const svcText = await page.$eval('#sheet', e => e.innerText);
ok(!/₹1,200/.test(svcText) && !/charge entered/.test(svcText), 'staff sees no service charge');
await page.evaluate(() => A.lapTab('hand')); await wait(300);
ok(!(await page.$eval('#sheet', e => e.innerText)).includes('Lowest safe price'), 'staff sees no lowest safe price');
await shot('07-staff-laptop');
await page.evaluate(() => A.closeModal());

console.log('Co-admin');
await login(USERS[1]);
ok(!/You owe/.test(await main()), 'co-admin Home: no "You owe"');
await go('money'); ok(!/Supplier|Ravi/.test(await main()), "co-admin Today's money: no supplier or partner names");
await go('reports'); ok(!/Gross profit|Net profit/.test(await main()), 'co-admin Reports: no profit');

console.log('Wrong PIN lock');
await page.goto('http://localhost:8787/', { waitUntil: 'networkidle0' });
await page.evaluate(() => localStorage.clear()); await page.reload({ waitUntil: 'networkidle0' });
for (let i = 0; i < 5; i++) {
  if (i === 0) await page.type('#lmob', USERS[1].mobile);
  await page.$eval('#lpin', e => { e.value = ''; }); await page.type('#lpin', '111111'); await page.click('#lbtn'); await wait(600);
}
ok(/Try again in 1[45]:\d\d/.test(await page.$eval('#lmsg', e => e.innerText)), '5 wrong PINs: blocked with a countdown', await page.$eval('#lmsg', e => e.innerText));
await shot('08-login-locked');

console.log('Remembered mobile');
await srv.db.query(`delete from public.login_attempts`);
await login(USERS[0]);
await page.evaluate(() => { localStorage.removeItem('fcl_login_at'); }); await page.reload({ waitUntil: 'networkidle0' }); await wait(500);
ok(/Not you\?/.test(await page.$eval('#lbody', e => e.innerText)) && !(await page.$('#lmob')), 'next time only the PIN is asked, with "Not you?"');
await shot('09-login-remembered');

console.log('\nErrors in the page:', errors.length ? '\n - ' + [...new Set(errors)].join('\n - ') : 'none');
ok(errors.length === 0, 'no JavaScript errors');
console.log(`\n${pass} passed, ${fail} failed. Screenshots in tests/ui/screenshots`);
await browser.close(); await srv.close();
process.exit(fail ? 1 : 0);
