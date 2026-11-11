// Browser smoke test: runs the real app in headless Edge/Chrome against the local stand-in (devserver.mjs).
// Usage: npm i puppeteer-core  (anywhere), then
//   PUPPETEER_DIR=<folder with node_modules/puppeteer-core> BROWSER=<path to msedge.exe or chrome.exe> node tests/ui/smoke.mjs
import { createRequire } from 'node:module';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdirSync, writeFileSync, readdirSync, readFileSync, rmSync } from 'node:fs';
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

console.log('Add a new lot (cart)');
await go('stock'); await page.evaluate(() => A.stockTab('lots')); await page.evaluate(() => A.addLot()); await wait(500);
const sheetText = () => page.$eval('#sheet', e => e.innerText);
const addBtn = () => page.$eval('#lc_add', e => ({ text: e.textContent, disabled: e.disabled }));
const chip = (row, v) => page.evaluate((row, v) => [...document.querySelectorAll(`#${row} button`)].find(b => b.textContent === v).click(), row, v);
ok((await addBtn()).disabled, 'Add stays off until brand and processor are picked');
await chip('lcr_brand', 'Dell'); await chip('lcr_processor', 'i5');
ok(!(await addBtn()).disabled, 'Add turns on after brand and processor');
const y0 = await page.$eval('#sheet', e => { e.scrollTop = 120; return e.scrollTop; });
await chip('lcr_gen', '8th'); await chip('lcr_ram_gb', '8 GB'); await chip('lcr_storage_gb', '256');
ok(await page.$eval('#sheet', e => e.scrollTop) === y0, 'tapping chips keeps the scroll position');
await page.type('#lc_model', 'Latitude 5490');
await page.click('.stepper button[aria-label="One more"]'); await page.click('.stepper button[aria-label="One more"]');
await page.type('#lc_cost', '9000');
ok((await addBtn()).text === '+ Add 3 × Dell i5 8th 8/256 to lot', 'Add button says what will be added', (await addBtn()).text);
ok(await page.$eval('#lc_each', e => e.textContent) === '₹3,000 each', 'shows the cost each in green');
await page.$eval('.lotcard', e => e.scrollIntoView()); await shot('06a-add-card');
await page.$eval('#lc_add', b => b.click()); await wait(300);
ok(await page.$$eval('.grp', g => g.length) === 1 && !(await page.$('.lotcard')), 'group goes into the list and the card closes');
ok(/3×[\s\S]*Dell i5 8th 8\/256[\s\S]*Latitude 5490 · ₹9,000 \(₹3,000 each\)/.test(await sheetText()), 'list row: 3×, shorthand, model and cost');

await page.click('button.addmore'); await wait(300);
ok(await page.$eval('#lcr_brand .on', e => e.textContent).catch(() => '') === 'Dell', 'card opens again and keeps the brand');
await page.evaluate(() => A.lcMode('mixed')); await wait(200);
await page.click('.stepper button[aria-label="One more"]');
await chip('lcr_mbrands', 'HP'); await chip('lcr_mbrands', 'Lenovo');
await page.$eval('.lotcard', e => e.scrollIntoView()); await shot('06b-add-mixed');
ok((await addBtn()).text === '+ Add 2 mixed laptops to lot', 'mixed: button says "+ Add 2 mixed laptops to lot"');
await page.$eval('#lc_add', b => b.click()); await wait(300);

// a third group, to delete
await page.click('button.addmore'); await wait(200);
await page.evaluate(() => A.lcMode('known')); await wait(200);
await chip('lcr_brand', 'HP'); await chip('lcr_processor', 'i3'); await chip('lcr_storage', 'HDD');
await page.$eval('#lc_add', b => b.click()); await wait(300);
ok(await page.$$eval('.grp', g => g.length) === 3, 'three groups in the list');
await page.evaluate(() => document.querySelectorAll('.grp')[2].querySelector('button[aria-label="Remove"]').click()); await wait(300);
ok(await page.$$eval('.grp', g => g.length) === 2 && !/HP i3/.test(await sheetText()), 'delete removes a group');

// edit the Dell group: cost 9,000 -> 10,500
await page.evaluate(() => A.lcEdit(0)); await wait(300);
ok(await page.$eval('#lc_cost', e => e.value) === '9000' && await page.$eval('#lc_model', e => e.value) === 'Latitude 5490', 'edit fills the card with the group');
await page.$eval('#lc_cost', e => { e.value = ''; }); await page.type('#lc_cost', '10500');
ok((await addBtn()).text === 'Save 3 × Dell i5 8th 8/256', 'edit button says Save', (await addBtn()).text);
await page.$eval('#lc_add', b => b.click()); await wait(300);
const txt = await sheetText();
ok(/₹10,500 \(₹3,500 each\)/.test(txt) && await page.$$eval('.grp', g => g.length) === 2, 'edit saves the new cost');
ok(/5 laptops/.test(txt) && await page.$eval('.lotsum', e => [...e.querySelectorAll('.tag')].map(t => t.lastElementChild.textContent).join(' to ')) === '001 to 005', 'summary: 5 laptops, stickers 001 to 005');
ok(/2 mixed laptops have no cost yet/.test(txt), 'summary: mixed laptops without cost');
ok(await page.$eval('#lotcreate', e => e.textContent) === 'Create lot and print 5 stickers', 'create button: "Create lot and print 5 stickers"');
ok(!/\bline\b/i.test(txt), 'the word "line" is not shown');
await shot('06-add-lot');
await page.click('#lotcreate'); await wait(1500);
await page.evaluate(() => document.getElementById('dlgno')?.click()); await wait(300);
const lotQ = `from public.laptops l join public.lots lo on lo.id = l.lot_id left join public.laptop_costs c on c.laptop_id = l.id
  where lo.lot_no = 2 and lo.supplier_id = (select id from public.suppliers where code = '01')`;
const nl = await q1(`select count(*) n, count(*) filter (where l.shorthand = 'Dell i5 8th 8/256' and l.model = 'Latitude 5490' and c.cost = 3500) dell,
  count(*) filter (where l.brand is null and c.cost is null) mixed, max(lo.note) note ${lotQ}`);
ok(+nl.n === 5 && +nl.dell === 3 && +nl.mixed === 2, 'lot created: 5 stickers, 3 Dell at ₹3,500 each, 2 mixed with no cost', JSON.stringify(nl));
ok(nl.note === 'Mixed: HP, Lenovo', 'mixed brands go into the lot note', nl.note);
ok(/Laptops in this lot/.test(await main()) && !/\bLine \d/.test(await main()), 'lot detail: "Laptops in this lot"');

console.log('Quick add');
await page.evaluate(() => A.addLot()); await wait(500);
const qn = await page.evaluate(() => { const b = [...document.querySelectorAll('.lquick button')].find(x => x.textContent === 'Dell i5 8th 8/256'); if (b) b.click(); return !!b; });
await wait(300);
const on = await page.evaluate(() => ['brand', 'processor', 'gen', 'ram_gb', 'storage_gb'].map(k => document.querySelector(`#lcr_${k} .on`)?.textContent || ''));
ok(qn && on.join('|') === 'Dell|i5|8th|8 GB|256' && await page.$eval('#lc_model', e => e.value) === 'Latitude 5490', 'quick add fills in the specs and model', on.join('|'));
await page.evaluate(() => A.closeModal());

console.log('Scan from gallery');
const tmpDir = join(here, 'screenshots', 'tmp'); mkdirSync(tmpDir, { recursive: true });
// A photo like one a customer sends on WhatsApp: a QR (made with the app's own QR maker) on a beige background
async function photoFile(text, name) {
  const data = await page.evaluate(async t => {
    const c = document.createElement('canvas'); c.width = 1800; c.height = 1300; const x = c.getContext('2d');
    x.fillStyle = '#D9CFC1'; x.fillRect(0, 0, c.width, c.height);
    if (t) {
      const box = document.createElement('div'); document.body.appendChild(box);
      new QRCode(box, { text: t, width: 420, height: 420, correctLevel: QRCode.CorrectLevel.M });
      await new Promise(r => setTimeout(r, 150));
      x.fillStyle = '#fff'; x.fillRect(640, 380, 520, 520); x.drawImage(box.querySelector('canvas'), 690, 430); box.remove();
    }
    return c.toDataURL('image/png');
  }, text);
  const f = join(tmpDir, name); writeFileSync(f, Buffer.from(data.split(',')[1], 'base64')); return f;
}
const sheetCode = () => page.evaluate(() => document.querySelector('#modal:not(.hidden) #sheet .tag')?.textContent || '');
const photoMsgNow = () => page.$eval('#photomsg', e => ({ text: e.innerText, cls: e.className, shown: !e.hidden }));
await go('scan');
ok(await page.$eval('#photocam', e => e.getAttribute('capture')) === 'environment' && await page.$eval('#photogal', e => !e.hasAttribute('capture') && e.accept === 'image/*'),
  'Take photo uses the camera; Choose from gallery opens photos (no capture)');
ok(/Works with the laptop sticker QR and the warranty QR on a bill/.test(await main()), 'hint under the two photo buttons');
await shot('07a-scan-buttons');
const gCode = demo.l1.codes[2];
await (await page.$('#photogal')).uploadFile(await photoFile(gCode, 'sticker.png')); await wait(1800);
ok(/QR found/.test((await photoMsgNow()).text) && (await photoMsgNow()).cls.includes('ok'), 'sticker QR: green "QR found … opening"', JSON.stringify(await photoMsgNow()));
ok(await sheetCode() === gCode.replace(/-/g, ''), 'sticker QR from the gallery opens that laptop', await sheetCode());
await page.evaluate(() => A.closeModal()); await wait(300);
const wt = await q1(`select s.warranty_token t, l.code from public.sales s join public.laptops l on l.id = s.laptop_id where s.warranty_token is not null order by s.created_at limit 1`);
await (await page.$('#photogal')).uploadFile(await photoFile(`http://localhost:8787/w/?t=${wt.t}`, 'bill.png')); await wait(1800);
ok(await sheetCode() === wt.code.replace(/-/g, ''), 'warranty QR from a bill opens the laptop on that bill', `${await sheetCode()} vs ${wt.code}`);
await page.evaluate(() => A.closeModal()); await wait(300);
await (await page.$('#photogal')).uploadFile(await photoFile('', 'noqr.png')); await wait(1500);
const nq = await photoMsgNow();
ok(nq.cls.includes('bad') && nq.text === 'No QR found in this photo. Try a clearer photo, or type the sticker number below.', 'no QR: red message', JSON.stringify(nq));
await shot('07b-scan-noqr');

console.log('Laptop thumbnails');
const thumbCode = demo.l1.codes[3];
await srv.db.query(`insert into public.photos (laptop_id, url) select id, 'https://res.cloudinary.com/demo/image/upload/v1/fcl/test-laptop.jpg' from public.laptops where code = $1`, [thumbCode]);
await page.reload({ waitUntil: 'networkidle0' }); await wait(1500);
await go('stock'); await page.evaluate(() => A.stockFilter('all')); await wait(600);
const th = await page.evaluate(code => {
  const row = [...document.querySelectorAll('#main .lrow')].find(r => r.querySelector('.tag')?.textContent === code.replace(/-/g, ''));
  const img = row?.querySelector('img.lthumb');
  return { src: img?.getAttribute('src') || '', lazy: img?.loading, first: row?.firstElementChild === img, none: document.querySelectorAll('#main .lrow .lthumb.none svg').length };
}, thumbCode);
ok(th.src === 'https://res.cloudinary.com/demo/image/upload/c_fill,w_96,h_96,q_auto,f_auto/v1/fcl/test-laptop.jpg' && th.lazy === 'lazy' && th.first, 'thumbnail: Cloudinary 96px, lazy, left of the sticker number', JSON.stringify(th));
ok(th.none > 0, 'no photo: grey box with a laptop outline');
await shot('07c-thumbnails');
await page.evaluate(code => A.openLaptop(code), thumbCode); await wait(600);
ok(/c_fill,w_120,h_120/.test(await page.$eval('#sheet img.lthumb.lg', e => e.getAttribute('src')).catch(() => '')), 'laptop pop-up shows the first photo next to the code');
await page.evaluate(() => A.closeModal());

console.log('Delete, Recently deleted and Restore');
const dlgText = () => page.evaluate(() => document.querySelector('#dlg:not(.hidden) .dbox')?.innerText || '');
const menuItems = scope => page.evaluate(s => { const r = document.querySelector(s); r?.querySelector('.kbtn')?.click();
  return [...(r?.querySelectorAll('.kmenu button') || [])].map(b => (b.classList.contains('kred') ? 'red:' : '') + b.textContent); }, scope);
const pickMenu = (scope, label) => page.evaluate((s, t) => { const b = [...document.querySelectorAll(s + ' .kmenu button')].find(x => x.textContent === t); b?.click(); return !!b; }, scope, label);
const cartLot = await q1(`select lo.id, lo.prefix from public.lots lo join public.suppliers s on s.id = lo.supplier_id where s.code = '01' and lo.lot_no = 2`);
const dells = (await srv.db.query(`select id, code from public.laptops where lot_id = $1 and brand = 'Dell' order by piece_no`, [cartLot.id])).rows;
const costIs = async id => +(await q1(`select cost from public.laptop_costs where laptop_id = $1`, [id])).cost;
// laptop: the ⋮ menu, keep the lot cost
await page.evaluate(c => A.openLaptop(c), dells[0].code); await wait(600);
const lm = await menuItems('#sheet');
ok(lm.join('|') === 'Edit specs|Reprint sticker|red:Delete laptop', 'laptop ⋮ menu: Edit specs, Reprint sticker, Delete (in red)', lm.join('|'));
await pickMenu('#sheet', 'Delete laptop'); await wait(600);
ok(/Delete laptop/.test(await dlgText()) && /Reduce the lot cost by ₹3,500/.test(await dlgText()) && /Keep the lot cost/.test(await dlgText()), 'delete asks: reduce the lot cost by ₹3,500, or keep it');
await page.evaluate(() => document.querySelector('#dlcost [data-v="keep"]').click());
await shot('08a-delete-laptop');
await page.click('#dlgok'); await wait(1500);
ok((await q1(`select deleted_at from public.laptops where id = $1`, [dells[0].id])).deleted_at && await costIs(dells[1].id) === 5250 && await costIs(dells[2].id) === 5250,
   'laptop deleted; its ₹3,500 shared over the other 2 (₹5,250 each)');
ok(!(await page.evaluate(c => !!A.S?.byCode?.get?.(c), dells[0].code)) && /deleted/.test(await toastText()), 'it disappears from the app');
// laptop with a sale: refused with the reason
await page.evaluate(c => A.openLaptop(c), demo.l1.codes[0]); await wait(600);
await page.evaluate(() => { A.delLaptop(); }); await wait(700);
ok(/cannot be deleted/.test(await dlgText()) && /has a sale\. Use Undo sale or Return instead\./.test(await dlgText()), 'sold laptop: "This laptop has a sale. Use Undo sale or Return instead."');
await page.click('#dlgok'); await wait(200); await page.evaluate(() => A.closeModal());
// Recently deleted: restore
await go('deleted');
ok(new RegExp(dells[0].code).test(await main()) && /Deleted by Ayan/.test(await main()) && /30 days left/.test(await main()), 'Recently deleted lists the laptop, who and days left');
await shot('08b-recently-deleted');
await page.evaluate(code => [...document.querySelectorAll('#main .crow')].find(r => r.innerText.includes(code)).querySelector('button').click(), dells[0].code); await wait(1500);
ok(!(await q1(`select deleted_at from public.laptops where id = $1`, [dells[0].id])).deleted_at && await costIs(dells[1].id) === 3500 && await costIs(dells[0].id) === 3500, 'Restore brings it back with the costs as before');
// lot: blocked, then deleted by typing the code, then restored
const l1Id = (await q1(`select lot_id from public.laptops where code = $1`, [demo.l1.codes[0]])).lot_id;
await go('stock'); await page.evaluate(() => A.stockTab('lots')); await wait(300);
await page.evaluate(id => A.toggleLot(id), l1Id); await wait(800);
const lotMenu = await menuItems('#bdetail');
ok(lotMenu.includes('red:Delete lot') && lotMenu.includes('Print all stickers'), 'lot ⋮ menu has Delete lot (red)', lotMenu.join('|'));
await pickMenu('#bdetail', 'Delete lot'); await wait(800);
ok(/cannot be deleted/.test(await dlgText()) && await page.$$eval('#dlg .blk .lrow', r => r.length) >= 3, 'lot with sold, booked and serviced laptops: refused, listing them');
await page.click('#dlgok'); await wait(200);
await page.evaluate(id => A.toggleLot(id), l1Id); await wait(300);
await page.evaluate(id => A.toggleLot(id), cartLot.id); await wait(800);
await menuItems('#bdetail'); await pickMenu('#bdetail', 'Delete lot'); await wait(800);
ok(new RegExp(`Type ${cartLot.prefix} to confirm`).test(await dlgText()), 'lot delete asks to type the lot code');
await page.type('#dlgv', '01-02'); await page.click('#dlgok'); await wait(600);
ok(!(await q1(`select deleted_at from public.lots where id = $1`, [cartLot.id])).deleted_at, 'a wrong code does not delete the lot');
await menuItems('#bdetail'); await pickMenu('#bdetail', 'Delete lot'); await wait(800);
await page.type('#dlgv', cartLot.prefix); await page.click('#dlgok'); await wait(1500);
const lotGone = await q1(`select lo.deleted_at, (select count(*) from public.laptops where lot_id = lo.id and deleted_at is not null) n from public.lots lo where lo.id = $1`, [cartLot.id]);
ok(lotGone.deleted_at && +lotGone.n === 5 && !new RegExp(cartLot.prefix.split('-').join('')).test(await page.$eval('#main', e => e.innerText.replace(/\s/g, ''))), 'lot deleted with its 5 laptops, gone from Stock');
await go('deleted');
await page.evaluate(p => [...document.querySelectorAll('#main .crow')].find(r => r.innerText.includes('Lot ' + p)).querySelector('button').click(), cartLot.prefix); await wait(1500);
ok(!(await q1(`select deleted_at from public.lots where id = $1`, [cartLot.id])).deleted_at, 'Restore brings the lot back');
// photos: Edit photos ✕ (photo-delete removes it from the app and Cloudinary)
await page.evaluate(c => A.openLaptop(c), thumbCode); await wait(700);
await page.evaluate(() => [...document.querySelectorAll('#sheet .phhead a')].find(a => a.textContent === 'Edit photos').click()); await wait(300);
ok(await page.$$eval('#sheet .photos .phx', b => b.length) === 1, 'Edit photos shows a ✕ on each photo');
await page.click('#sheet .photos .phx'); await wait(400);
ok(/Delete this photo\?/.test(await dlgText()), 'asks "Delete this photo?"');
await page.click('#dlgok'); await wait(1500);
const phd = await q1(`select p.deleted_at, d.cloud_status from public.photos p join private.deletions d on d.item_id = p.id where p.laptop_id = (select id from public.laptops where code = $1)`, [thumbCode]);
ok(phd?.deleted_at && phd.cloud_status === 'deleted', 'photo deleted from the app and Cloudinary', JSON.stringify(phd));
// photo-delete not deployed yet: still removed from the app
await srv.db.query(`insert into public.photos (laptop_id, url) select id, 'https://res.cloudinary.com/demo/image/upload/v1/fcl/second.jpg' from public.laptops where code = $1`, [thumbCode]);
srv.setPhotoDelete('missing');
await page.reload({ waitUntil: 'networkidle0' }); await wait(1500);
await page.evaluate(c => A.openLaptop(c), thumbCode); await wait(700);
await page.evaluate(() => A.viewPhoto(0)); await wait(300);
ok(await page.$eval('#phview img', e => e.getAttribute('src')) === 'https://res.cloudinary.com/demo/image/upload/v1/fcl/second.jpg', 'a tap opens the photo full size');
await page.evaluate(() => [...document.querySelectorAll('#phview button')].find(b => /Delete/.test(b.textContent)).click()); await wait(400);
await page.click('#dlgok'); await wait(1500);
ok(+(await q1(`select count(*) n from public.photos where url like '%second.jpg' and deleted_at is not null`)).n === 1 && /stays until photo-delete is set up/.test(await toastText()),
   'photo-delete not set up: the photo still leaves the app', await toastText() + ' / ' + JSON.stringify(await q1("select count(*) n, max(deleted_at::text) d from public.photos where url like '%second.jpg'")));
srv.setPhotoDelete('ok');
await page.evaluate(() => A.closeModal());

console.log('Accessories, notifications, photo sheet');
{
  ok(!(await page.$('#outbtn')) && !!(await page.$('#bellbtn')), 'top bar: the bell replaces the log-out button');
  await go('more');
  ok(/Log out/.test(await main()) && /Change my PIN/.test(await main()), 'Log out is in More, with Change my PIN');
  // add an accessory
  await go('stock'); await page.evaluate(() => A.stockTab('acc')); await wait(400);
  ok(/Lots[\s\S]*All laptops[\s\S]*Accessories/.test(await main()) && /No accessories yet/.test(await main()), 'Stock has a third tab: Accessories');
  await page.evaluate(() => A.addAccessory()); await wait(400);
  await page.type('#acc_name', 'Keyboard, USB');
  await page.$eval('#acc_open', e => { e.value = ''; }); await page.type('#acc_open', '10');
  await page.type('#acc_cost', '250'); await page.type('#acc_price', '400');
  ok(/alert when only 2 are left/.test(await page.$eval('#sheet', e => e.innerText)), 'Add accessory: alert at 2 by default, with the hint');
  await shot('09a-add-accessory');
  await page.click('button[onclick="A.saveNewAccessory()"]'); await wait(1200);
  ok(/Keyboard, USB[\s\S]*10[\s\S]*left/.test(await main()), 'the list shows "Keyboard, USB 10 left"');
  const kbId = (await q1(`select id from public.accessories where name = 'Keyboard, USB'`)).id;
  // given free with a laptop sale: 8 → 2 left, low stock, one notification
  const saleCode = (await q1(`select l.code from public.laptops l where l.status = 'in_stock' and l.deleted_at is null
    and (select count(*) from public.laptop_tests t where t.laptop_id = l.id and t.result = 'pass') = 10 order by l.code limit 1`)).code;
  await page.evaluate(c => A.openLaptop(c), saleCode); await wait(700);
  await page.evaluate(() => A.lapTab('hand')); await wait(300);
  ok(/Accessories given with this sale/.test(await page.$eval('#sheet', e => e.innerText)), 'laptop sale: "Accessories given with this sale"');
  await page.$eval('#h_acc select', (e, id) => { e.value = id; e.dispatchEvent(new Event('change')); }, kbId); await wait(200);
  for (let i = 0; i < 7; i++) await page.click('#h_acc .accrow button[aria-label="One more"]');
  const pk = await page.$eval('#h_acc', e => e.innerText);
  ok(/10 in stock/.test(pk) && /\b8\b/.test(pk) && /After this sale: Keyboard, USB 2 left/.test(pk) && /Free with the laptops/.test(pk), 'picker: 10 in stock, 8 picked, "After this sale: 2 left", free', pk.replace(/\n/g, ' | '));
  await page.$eval('#sheet', e => e.querySelector('.accgive').scrollIntoView()); await shot('09b-sale-accessories');
  await page.$eval('#hprice', e => { e.value = '40000'; }); await page.$eval('#hpaid', e => { e.value = '40000'; });
  await page.$eval('#hname', e => { e.value = 'Shahid'; }); await page.$eval('#hmob', e => { e.value = '9800000123'; });
  await page.evaluate(() => document.querySelector('#hlead [data-v="Walk-in"]').click());
  await page.evaluate(() => { A.sellOne(); }); await wait(2500);
  const mv = await q1(`select sum(delta) q, count(*) filter (where sale_id is not null and free) n from public.accessory_moves where accessory_id = $1`, [kbId]);
  ok(+mv.q === 2 && +mv.n === 1, 'sold: 8 given free with the sale, 2 left', JSON.stringify(mv) + ' ' + await toastText() + ' ' + await page.evaluate(() => document.querySelector('#dlg:not(.hidden)')?.innerText || '') + ' ' + JSON.stringify(await q1('select status from public.laptops where code = $1', [saleCode])));
  ok(+(await q1(`select count(*) n from public.notifications where kind = 'low_stock' and link_id = $1`, [kbId])).n === 1, 'one low-stock notification');
  await page.evaluate(() => A.closeModal()); await wait(200);
  // the bill has the accessory line
  const billOk = await page.evaluate(async code => {
    const { S } = await import('/api/store.js'); const { billHtml } = await import('/ui/print.js');
    const l = S.d.laptops.find(x => x.code === code); const h = billHtml([l], S.d.settings, true);
    return /Keyboard, USB/.test(h) && /Free with the laptop/.test(h);
  }, saleCode);
  ok(billOk, 'the bill lists "Keyboard, USB × 8, free with the laptop"');
  // bell and notifications
  await go('stock'); await page.evaluate(() => A.stockTab('acc')); await wait(400);
  ok(/Low stock, alert at 2/.test(await main()), 'the list shows it red: "Low stock, alert at 2"');
  await shot('09c-accessories');
  const bell = await page.$eval('#bellcount', e => ({ n: +e.textContent, shown: !e.classList.contains('hidden') }));
  ok(bell.shown && bell.n >= 1, 'the bell shows a red count', JSON.stringify(bell));
  await page.click('#bellbtn'); await wait(900);
  ok(/Keyboard, USB: only 2 left/.test(await main()) && await page.$$eval('#main .nrow.unread', r => r.length) >= 1, 'Notifications: "Keyboard, USB: only 2 left", unread');
  await shot('09d-notifications');
  await page.evaluate(() => [...document.querySelectorAll('#main .nrow')].find(r => /only 2 left/.test(r.innerText)).click()); await wait(1200);
  ok(/Keyboard, USB/.test(await page.$eval('#sheet', e => e.innerText)) && /Sell or give/.test(await page.$eval('#sheet', e => e.innerText)), 'tapping it opens the accessory');
  // can't sell more than in stock
  await page.$eval('#aout_qty', e => { e.value = '5'; }); await page.click('button[onclick="A.accOut()"]'); await wait(500);
  ok(/Only 2 Keyboard, USB left/.test(await toastText()), "can't sell more than in stock");
  await page.evaluate(() => A.closeModal());
  await page.click('#bellbtn'); await wait(800);
  if (await page.$('button[onclick="A.markAllRead()"]')) { await page.click('button[onclick="A.markAllRead()"]'); await wait(900); }
  ok(await page.$eval('#bellcount', e => e.classList.contains('hidden')) && !(await page.$('#main .nrow.unread')), 'Mark all as read clears the bell');
  // laptop photo: camera or gallery
  await page.evaluate(c => A.openLaptop(c), demo.l1.codes[5]); await wait(600);
  await page.click('#sheet .addph'); await wait(300);
  const ph = await page.evaluate(() => ({ cam: document.getElementById('phcam')?.getAttribute('capture'), camMulti: document.getElementById('phcam')?.multiple,
    gal: document.getElementById('phgal') && !document.getElementById('phgal').hasAttribute('capture'), galMulti: document.getElementById('phgal')?.multiple,
    text: document.querySelector('#dlg .dbox')?.innerText || '' }));
  ok(ph.cam === 'environment' && ph.gal && ph.galMulti && /Camera[\s\S]*Gallery/.test(ph.text), 'Add photos: Camera (snap now) and Gallery (several saved photos)', JSON.stringify(ph));
  await shot('09e-photo-sheet');
  await page.click('#dlgno'); await page.evaluate(() => A.closeModal());
}

console.log('Export');
{
  const dl = join(here, 'screenshots', 'downloads'); rmSync(dl, { recursive: true, force: true }); mkdirSync(dl, { recursive: true });
  const cdp = await page.createCDPSession(); await cdp.send('Page.setDownloadBehavior', { behavior: 'allow', downloadPath: dl });
  const XLSX = createRequire(join(here, '..', '..', 'lib', 'x.js'))('./xlsx.full.min.js');
  const waitFile = async ext => { for (let i = 0; i < 60; i++) { const f = readdirSync(dl).find(x => x.endsWith(ext)); if (f) { await wait(300); return f; } await wait(250); } return null; };
  const today = (await q1('select private.today()::text d')).d;
  await go('backup');
  ok(/Export/.test(await main()) && /Excel \(\.xlsx\)/.test(await main()) && /CSV \(\.zip\)/.test(await main()) && /SQL \(\.sql\)/.test(await main()) && /JSON backup/.test(await main()),
     'admin Export: Excel, CSV, SQL and JSON');
  await page.evaluate(() => document.querySelector('#xrange [data-v="custom"]').click()); await wait(200);
  ok(await page.$eval('#xcustom', e => !e.classList.contains('hidden')), 'Custom shows From and To dates');
  await page.evaluate(() => document.querySelector('#xrange [data-v="all"]').click());
  await shot('10a-export');
  await page.evaluate(() => { A.exportAs('xlsx'); }); await wait(500);
  ok(/customer names, mobiles and money details\. Keep it private\./.test(await page.$eval('#dlg', e => e.innerText)), 'warning before download: keep it private');
  await page.click('#dlgok');
  const xf = await waitFile('.xlsx');
  ok(xf === 'first-choice-export-' + today + '.xlsx', 'Excel file: first-choice-export-DATE.xlsx', xf);
  if (xf) {
    const wb = XLSX.read(readFileSync(join(dl, xf)), { cellNF: true });
    const lap = XLSX.utils.sheet_to_json(wb.Sheets.Laptops, { header: 1 });
    ok(wb.SheetNames.length === 16 && lap[0][0] === 'Sticker code' && lap.length > 5, 'the downloaded Excel opens: 16 sheets, laptops listed', wb.SheetNames.length);
  }
  await page.evaluate(() => { A.exportAs('csv'); }); await wait(400); await page.click('#dlgok');
  ok(await waitFile('.zip') === 'first-choice-export-' + today + '.zip', 'CSV zip downloaded');
  await page.evaluate(() => { A.exportAs('sql'); }); await wait(400); await page.click('#dlgok');
  const sf = await waitFile('.sql');
  ok(sf && /^-- First Choice Laptops/.test(readFileSync(join(dl, sf), 'utf8')) && /\ncommit;/.test(readFileSync(join(dl, sf), 'utf8')), 'SQL file downloaded', sf);
  ok(+(await q1("select count(*) n from public.activity_log where action = 'export'")).n >= 3, 'each export is in Activity');
}

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
await go('backup'); ok(!/Export/.test(await main()) && /laptops on the shelf/.test(await main()), 'staff cannot open Export');
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
await go('more'); ok(/Export/.test(await main()), 'co-admin More: Export');
await go('backup'); ok(/Excel \(\.xlsx\)/.test(await main()) && /CSV \(\.zip\)/.test(await main()) && !/SQL \(\.sql\)|JSON backup|Restore|Danger zone/.test(await main()), 'co-admin Export: Excel and CSV only, no restore');

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
