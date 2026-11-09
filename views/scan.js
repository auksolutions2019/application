// Scan: live camera (BarcodeDetector, then bundled html5-qrcode), photo of sticker (BarcodeDetector, then jsQR),
// find by typed or pasted sticker number.
import { $, esc, codeDigits, codeFromDigits } from '../ui/dom.js';
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

export const views = {
  scan() {
    const quick = `<div class="card quick-find"><h3>Find by sticker number</h3>
    <p class="muted">Type the numbers printed under the QR. Dashes are not needed. It opens by itself when all 11 digits match.</p>
    <div class="row nw" style="margin-top:12px"><input id="qcode" class="bigcode" inputmode="numeric" autocomplete="off" placeholder="01 01 03 25 002" oninput="A.quickFind(this.value)" onkeydown="if(event.key==='Enter')A.quickOpen()"><button class="ghost" style="flex:none" onclick="A.pasteCode()">Paste</button></div>
    <div id="qres"></div>
    <details class="tipbox"><summary>Scan with your phone's camera instead</summary><ol><li>Open the phone camera or Google Lens and point it at the sticker.</li><li>Tap the code that appears, then tap <b>Copy</b>.</li><li>Come back here and tap <b>Paste</b>. The laptop opens straight away.</li></ol></details></div>`;
    const cam = `<div class="card"><h3>${camOk() ? 'Scan with live camera' : 'Live camera'}</h3>
    ${camOk() ? '' : '<p class="muted" style="margin-bottom:10px">The live camera only works when the app is opened from an https link, like GitHub Pages. Until then, use <b>Find by sticker number</b>.</p>'}
    <div class="camwrap" id="camwrap"><div id="reader"></div><div class="aim"></div><div class="camidle" id="camidle"><svg class="i" viewBox="0 0 24 24" style="width:40px;height:40px"><path d="M4 8V5a1 1 0 011-1h3M16 4h3a1 1 0 011 1v3M20 16v3a1 1 0 01-1 1h-3M8 20H5a1 1 0 01-1-1v-3"/></svg><span>Tap Start camera</span></div></div>
    <p class="muted" id="scanmsg" style="margin-top:8px;text-align:center">${navigator.onLine ? 'Point the camera at the QR sticker' : 'You are offline. Scanning works for laptops already on this phone.'}</p>
    <div class="row" style="margin-top:10px"><button onclick="A.startScan()">${ICON.cam}Start camera</button><button class="ghost" onclick="A.stopScan()">Stop</button></div>
    <label class="photobtn">${ICON.scan}Take photo of sticker<input type="file" accept="image/*" capture="environment" style="display:none" onchange="A.scanPhoto(this.files[0]);this.value=''"></label></div>`;
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
    if (!camOk()) { camIdle(true); return scanMsg('Live camera needs the app to be opened from an <b>https</b> link (like GitHub Pages).<br>For now, use <b>Take photo of sticker</b> below.', true); }
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
        : n === 'NoLib' ? 'The scanner could not load. Use <b>Take photo of sticker</b>.'
        : 'Could not open camera. Use <b>Take photo of sticker</b> below.', true);
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
  async gotCode(txt) {
    const wt = String(txt || '').match(/[?&]t=([0-9a-fA-F]{64})\b/);
    const raw = (txt || '').trim().toUpperCase();
    const code = /^\d{11}$/.test(raw) ? codeFromDigits(raw) : raw;
    actions.stopScan(); if (navigator.vibrate) navigator.vibrate(80);
    try {
      if (wt) {                                   // warranty QR printed on a bill
        const l = await read('find_by_warranty_token', { p_token: wt[1].toLowerCase() });
        if (l) { S.extra.set(l.code, l); return A.openLaptop(l.code); }
        return scanMsg('This warranty QR does not match any sale in this app.', true);
      }
      const l = await laptopByCode(code);
      if (l) return A.openLaptop(l.code);
      scanMsg('QR read: <b class="mono">' + esc(code) + '</b> — no laptop has this code in this app.', true);
    } catch (e) {
      scanMsg(navigator.onLine ? esc(e.message) : 'You are offline and this laptop is not saved on this phone.', true);
    }
  },
  async scanPhoto(f) {
    if (!f) return; scanMsg('Reading photo…');
    try {
      const bmp = await createImageBitmap(f);
      if (await hasNativeQR()) { const r = await new BarcodeDetector({ formats: ['qr_code'] }).detect(bmp); if (r.length) return actions.gotCode(r[0].rawValue); }
      if (typeof jsQR !== 'undefined') {
        const sc = Math.min(1, 1400 / Math.max(bmp.width, bmp.height)), c = document.createElement('canvas');
        c.width = bmp.width * sc; c.height = bmp.height * sc; const x = c.getContext('2d'); x.drawImage(bmp, 0, 0, c.width, c.height);
        const r = jsQR(x.getImageData(0, 0, c.width, c.height).data, c.width, c.height); if (r) return actions.gotCode(r.data);
      }
      scanMsg('No QR found in the photo. Take it closer, in good light, with the sticker filling the photo.', true);
    } catch (e) { scanMsg('Could not read the photo. Try again.', true); }
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
