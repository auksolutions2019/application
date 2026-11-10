// Scan: live camera (BarcodeDetector, then bundled html5-qrcode); a photo from the camera or the gallery
// (BarcodeDetector, then jsQR), also a photo shared into the app from WhatsApp; find by typed or pasted sticker number.
// Works with the laptop sticker QR and the warranty QR printed on a bill.
import { $, esc, tag, codeDigits, codeFromDigits } from '../ui/dom.js';
import { ICON } from '../ui/icons.js';
import { toast } from '../ui/feedback.js';
import { S, laptopByCode } from '../api/store.js';
import { read } from '../api/client.js';
import { lapRow } from './common.js';

let stream = null, loopT = null, busy = false, scanner = null;
const scanMsg = (t, bad) => { const m = $('scanmsg'); if (m) { m.innerHTML = t; m.style.color = bad ? 'var(--red)' : ''; } };
const camIdle = on => { const c = $('camidle'); if (c) c.style.display = on ? '' : 'none'; };
const camOk = () => window.isSecureContext && !!navigator.mediaDevices?.getUserMedia;
async function hasNativeQR() { try { return 'BarcodeDetector' in window && (await BarcodeDetector.getSupportedFormats()).includes('qr_code'); } catch (e) { return false; } }
const all = () => [...S.d.laptops, ...S.extra.values()];
// Result of reading a photo, shown under the photo buttons: green when a QR was found, red when not
const photoMsg = (t, bad) => { const m = $('photomsg'); if (m) { m.className = 'photomsg ' + (bad ? 'bad' : 'ok'); m.innerHTML = t; m.hidden = false; } };
const STICKER = /^\d{2}-\d{2}-\d{2}-\d{2}-\d{3}$/;
const NO_QR = 'No QR found in this photo. Try a clearer photo, or type the sticker number below.';
export const SHARED_PHOTO = 'shared-photo';   // cache key the service worker uses for a photo shared into the app

export const views = {
  scan() {
    const quick = `<div class="card quick-find"><h3>Find by sticker number</h3>
    <p class="muted">Type the numbers printed under the QR. Dashes are not needed. It opens by itself when all 11 digits match.</p>
    <div class="row nw" style="margin-top:12px"><input id="qcode" class="bigcode" inputmode="numeric" autocomplete="off" placeholder="01 01 03 25 002" oninput="A.quickFind(this.value)" onkeydown="if(event.key==='Enter')A.quickOpen()"><button class="ghost" style="flex:none" onclick="A.pasteCode()">Paste</button></div>
    <div id="qres"></div>
    <details class="tipbox"><summary>Scan with your phone's camera instead</summary><ol><li>Open the phone camera or Google Lens and point it at the sticker.</li><li>Tap the code that appears, then tap <b>Copy</b>.</li><li>Come back here and tap <b>Paste</b>. The laptop opens straight away.</li></ol></details></div>`;
    const cam = `<div class="card"><h3>${camOk() ? 'Scan with live camera' : 'Live camera'}</h3>
    ${camOk() ? '' : '<p class="muted" style="margin-bottom:10px">The live camera only works when the app is opened from its https link. Until then, use <b>Take photo</b>, <b>Choose from gallery</b> or <b>Find by sticker number</b>.</p>'}
    <div class="camwrap" id="camwrap"><div id="reader"></div><div class="aim"></div><div class="camidle" id="camidle"><svg class="i" viewBox="0 0 24 24" style="width:40px;height:40px"><path d="M4 8V5a1 1 0 011-1h3M16 4h3a1 1 0 011 1v3M20 16v3a1 1 0 01-1 1h-3M8 20H5a1 1 0 01-1-1v-3"/></svg><span>Tap Start camera</span></div></div>
    <p class="muted" id="scanmsg" style="margin-top:8px;text-align:center">${navigator.onLine ? 'Point the camera at the QR sticker' : 'You are offline. Scanning works for laptops already on this phone.'}</p>
    <div class="row" style="margin-top:10px"><button onclick="A.startScan()">${ICON.cam}Start camera</button><button class="ghost" onclick="A.stopScan()">Stop</button></div>
    <div class="photo2">
      <label class="pbtn navy">📷 Take photo<small>Use the camera</small><input id="photocam" type="file" accept="image/*" capture="environment" onchange="A.scanPhoto(this.files[0]);this.value=''"></label>
      <label class="pbtn blue">🖼 Choose from gallery<small>Photo a customer sent</small><input id="photogal" type="file" accept="image/*" onchange="A.scanPhoto(this.files[0]);this.value=''"></label>
    </div>
    <p class="muted photohint">Works with the laptop sticker QR and the warranty QR on a bill</p>
    <div id="photomsg" class="photomsg" hidden></div></div>`;
    return camOk() ? cam + quick : quick + cam;
  }
};
export function after(view) {
  if (view !== 'scan') return;
  if (camOk()) setTimeout(actions.startScan, 300); else setTimeout(() => $('qcode')?.focus(), 200);
}

export const actions = {
  async startScan() {
    if (busy || stream || scanner || !$('reader')) return;
    if (!camOk()) { camIdle(true); return scanMsg('Live camera needs the app to be opened from its <b>https</b> link.<br>For now, use <b>Take photo</b> or <b>Choose from gallery</b> below.', true); }
    busy = true; scanMsg('Opening camera…');
    try {
      if (await hasNativeQR()) {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false });
        if (!$('reader')) { actions.stopScan(); return; }
        const v = document.createElement('video'); v.setAttribute('playsinline', ''); v.muted = true; v.autoplay = true; v.srcObject = stream;
        $('reader').innerHTML = ''; $('reader').appendChild(v); await v.play();
        const det = new BarcodeDetector({ formats: ['qr_code'] });
        const loop = async () => { if (!stream) return; try { const r = await det.detect(v); if (r.length) return actions.gotCode(r[0].rawValue); } catch (e) { /* frame not ready */ } loopT = setTimeout(loop, 180); };
        loop();
      } else if (typeof Html5Qrcode !== 'undefined') {
        scanner = new Html5Qrcode('reader');
        await scanner.start({ facingMode: 'environment' }, { fps: 10, qrbox: { width: 220, height: 220 } }, t => actions.gotCode(t), () => {});
      } else throw { name: 'NoLib' };
      camIdle(false); scanMsg('Point the camera at the QR sticker');
    } catch (e) {
      actions.stopScan(); camIdle(true);
      const n = e && e.name;
      scanMsg(n === 'NotAllowedError' ? 'Camera permission is blocked. Tap the 🔒 icon in the address bar → Permissions → allow Camera, then try again.'
        : n === 'NotFoundError' || n === 'OverconstrainedError' ? 'No camera found on this device. Use <b>Find by sticker number</b>.'
        : n === 'NotReadableError' ? 'Camera is being used by another app. Close it and try again.'
        : n === 'NoLib' ? 'The scanner could not load. Use <b>Take photo</b> below.'
        : 'Could not open camera. Use <b>Take photo</b> or <b>Choose from gallery</b> below.', true);
    } finally { busy = false; }
  },
  stopScan() {
    clearTimeout(loopT);
    if (stream) { stream.getTracks().forEach(t => t.stop()); stream = null; }
    if (scanner) {   // html5-qrcode throws (not rejects) when it never started, e.g. no camera
      const s = scanner; scanner = null;
      try { Promise.resolve(s.stop()).then(() => s.clear()).catch(() => {}); } catch (e) { try { s.clear(); } catch (x) { /* already clear */ } }
    }
    const r = $('reader'); if (r) r.innerHTML = ''; camIdle(true);
  },
  // txt: what the QR says. fromPhoto: the answer goes under the photo buttons instead of under the camera.
  async gotCode(txt, fromPhoto = false) {
    const msg = fromPhoto ? photoMsg : scanMsg;
    const wt = String(txt || '').match(/[?&]t=([0-9a-fA-F]{64})\b/);
    const raw = (txt || '').trim().toUpperCase();
    const code = /^\d{11}$/.test(raw) ? codeFromDigits(raw) : raw;
    actions.stopScan(); if (navigator.vibrate) navigator.vibrate(80);
    try {
      if (wt) {                                   // warranty QR printed on a bill: open the laptop that bill is for
        if (fromPhoto) msg('✓ Warranty QR found on a bill, opening the laptop…');
        const l = await read('find_by_warranty_token', { p_token: wt[1].toLowerCase() });
        if (l) { S.extra.set(l.code, l); if (fromPhoto) msg(`✓ Warranty QR found: ${tag(l.code)} opening…`); return A.openLaptop(l.code); }
        return msg('This warranty QR does not match any sale in this app.', true);
      }
      if (!STICKER.test(code)) return msg('This QR is not a First Choice laptop sticker or bill. Type the sticker number below.', true);
      if (fromPhoto) msg(`✓ QR found: ${tag(code)} opening…`);
      const l = await laptopByCode(code);
      if (l) return A.openLaptop(l.code);
      msg(`QR read: ${tag(code)} but no laptop has this code in this app.`, true);
    } catch (e) {
      msg(navigator.onLine ? esc(e.message) : 'You are offline and this laptop is not saved on this phone.', true);
    }
  },
  // A photo from the camera, the gallery or shared from WhatsApp. Shrunk to at most 1400 px, then
  // BarcodeDetector (built into Android Chrome) and, if that finds nothing, the bundled jsQR.
  async scanPhoto(f) {
    if (!f) return;
    photoMsg('Reading the photo…');
    let c;
    try {
      const bmp = await createImageBitmap(f);
      const sc = Math.min(1, 1400 / Math.max(bmp.width, bmp.height));
      c = document.createElement('canvas'); c.width = Math.round(bmp.width * sc); c.height = Math.round(bmp.height * sc);
      c.getContext('2d', { willReadFrequently: true }).drawImage(bmp, 0, 0, c.width, c.height);
      bmp.close?.();
    } catch (e) { return photoMsg('Could not open this photo. Save it as a normal photo (JPG or PNG) and try again.', true); }
    try {
      if (await hasNativeQR()) { const r = await new BarcodeDetector({ formats: ['qr_code'] }).detect(c); if (r.length) return actions.gotCode(r[0].rawValue, true); }
    } catch (e) { /* fall back to jsQR */ }
    if (typeof jsQR !== 'undefined') {
      const img = c.getContext('2d').getImageData(0, 0, c.width, c.height);
      const r = jsQR(img.data, c.width, c.height, { inversionAttempts: 'attemptBoth' }); if (r) return actions.gotCode(r.data, true);
    }
    photoMsg(NO_QR, true);
  },
  // A photo shared into the app (Android: Share → First Choice). The service worker keeps it in the cache.
  async takeShared() {
    try {
      const cache = await caches.open('fcl-share'), key = new URL(SHARED_PHOTO, location.href).href;
      const r = await cache.match(key); if (!r) return;
      await cache.delete(key);
      await actions.scanPhoto(await r.blob());
    } catch (e) { photoMsg('Could not read the shared photo. Save it and use Choose from gallery.', true); }
  },
  async quickFind(v) {
    const d = codeDigits(v), box = $('qres'); if (!box) return;
    if (!d) { box.innerHTML = ''; return; }
    const full = codeFromDigits(d.slice(0, 11));
    if (d.length >= 11 && full) {
      const l = S.byCode.get(full) || await laptopByCode(full).catch(() => null);
      if (l) { box.innerHTML = ''; $('qcode')?.blur(); return A.openLaptop(l.code); }
    }
    const m = all().filter(l => codeDigits(l.code).includes(d));
    box.innerHTML = m.length ? `<p class="muted" style="margin:12px 2px 6px">${m.length} match${m.length > 1 ? 'es' : ''}${m.length > 8 ? ', showing 8' : ''}</p><div class="list flat">${m.slice(0, 8).map(lapRow).join('')}</div>`
      : `<p class="muted" style="margin-top:10px;color:var(--red)">No sticker number contains ${esc(d)}. Check the digits.</p>`;
  },
  quickOpen() { const d = codeDigits($('qcode').value), m = all().filter(l => codeDigits(l.code).includes(d)); if (m.length === 1) A.openLaptop(m[0].code); else if (!m.length) toast('No laptop matches ' + d); },
  async pasteCode() {
    try {
      const t = await navigator.clipboard.readText(); if (!t) throw 0;
      if (/[?&]t=[0-9a-fA-F]{64}/.test(t)) return actions.gotCode(t);   // a pasted warranty link from a bill
      $('qcode').value = t.trim(); actions.quickFind(t);
    }
    catch (e) { $('qcode').focus(); toast('Long-press the box and tap Paste'); }
  }
};
