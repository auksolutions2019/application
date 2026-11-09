// Hand-built SVG charts and tooltips (unchanged from the prototype).
import { esc } from './dom.js';
export const short=n=>{const a=Math.abs(n),s=n<0?'-':'';return a>=1e7?s+'₹'+(a/1e7).toFixed(1)+'Cr':a>=1e5?s+'₹'+(a/1e5).toFixed(1)+'L':a>=1e3?s+'₹'+Math.round(a/1e3)+'k':s+'₹'+Math.round(a)};
export function niceStep(r){const p=Math.pow(10,Math.floor(Math.log10(r||1)));return [1,2,2.5,5,10].map(m=>m*p).find(s=>r/s<=4)}
export function barChart(items,color){
 const W=380,H=200,L=42,T=10,B=24,ph=H-T-B,pw=W-L;
 const vals=items.map(i=>i.v),mx=Math.max(0,...vals),mn=Math.min(0,...vals);
 if(mx===0&&mn===0)return '<p class="muted">No data for this year yet.</p>';
 const st=niceStep(mx-mn),top=Math.ceil(mx/st)*st,bot=Math.floor(mn/st)*st;
 const y=v=>T+ph-(v-bot)/(top-bot)*ph,y0=y(0),slot=pw/items.length,bw=Math.min(18,slot*.62);
 let g='';
 for(let v=bot;v<=top+1e-9;v+=st)g+=`<line class="gl" x1="${L}" x2="${W}" y1="${y(v)}" y2="${y(v)}"${v===0?' style="stroke:#c3cee2"':''}/><text class="ax" x="${L-8}" y="${y(v)+4}" text-anchor="end">${short(v)}</text>`;
 const bars=items.map((it,i)=>{
  const cx=L+slot*i+slot/2,x=cx-bw/2,yv=y(it.v),h=Math.abs(yv-y0),r=Math.min(4,h);
  const path=!it.v?'':it.v>0
   ?`M${x},${y0}V${yv+r}Q${x},${yv} ${x+r},${yv}H${x+bw-r}Q${x+bw},${yv} ${x+bw},${yv+r}V${y0}Z`
   :`M${x},${y0}V${yv-r}Q${x},${yv} ${x+r},${yv}H${x+bw-r}Q${x+bw},${yv} ${x+bw},${yv-r}V${y0}Z`;
  return `<g data-tip="${esc(it.tip)}"><rect class="hit" x="${L+slot*i}" y="${T}" width="${slot}" height="${ph}"/><path class="bar" d="${path}" fill="${it.v<0?'#d93838':color}"/><text class="ax" x="${cx}" y="${H-8}" text-anchor="middle">${it.k}</text></g>`;
 }).join('');
 return `<svg viewBox="0 0 ${W} ${H}" role="img">${g}${bars}</svg>`;
}
export function kpi(title,val,now,before,icon,bg,fg,repYear){
 let ch='<span class="ch flat">—</span>';
 if(before>0){const p=(now-before)/before*100;ch=`<span class="ch ${p>0?'up':p<0?'down':'flat'}" title="vs ${repYear-1}">${p>0?'+':''}${p.toFixed(1)}%</span>`}
 return `<div class="kpi"><div class="ic" style="background:${bg};color:${fg}">${icon}</div><div class="tx"><span>${title}</span><b>${val}</b></div>${ch}</div>`;
}
export function areaChart(items,color){
 if(items.length<2||items.every(i=>!i.v))return '<p class="muted">Not enough sales yet to draw the trend.</p>';
 const W=380,H=210,L=10,R=10,T=14,B=26,ph=H-T-B,pw=W-L-R;
 const mx=Math.max(...items.map(i=>i.v)),top=Math.ceil(mx/niceStep(mx))*niceStep(mx);
 const pts=items.map((it,i)=>[L+pw*i/(items.length-1),T+ph-(it.v/top)*ph]);
 const base=T+ph,cl=y=>Math.min(base,Math.max(T,y));
 let d=`M${pts[0][0]},${pts[0][1]}`;
 for(let i=0;i<pts.length-1;i++){
  const p0=pts[i-1]||pts[i],p1=pts[i],p2=pts[i+1],p3=pts[i+2]||p2;
  d+=` C${p1[0]+(p2[0]-p0[0])/6},${cl(p1[1]+(p2[1]-p0[1])/6)} ${p2[0]-(p3[0]-p1[0])/6},${cl(p2[1]-(p3[1]-p1[1])/6)} ${p2[0]},${p2[1]}`;
 }
 const area=`${d} L${pts.at(-1)[0]},${base} L${pts[0][0]},${base}Z`;
 const step=Math.ceil(items.length/6),slot=pw/(items.length-1);
 let grid='';for(let k=1;k<=2;k++){const y=T+ph*k/3;grid+=`<line class="gl" x1="${L}" x2="${W-R}" y1="${y}" y2="${y}"/>`}
 const hov=pts.map((p,i)=>`<g class="pt" data-tip="${esc(items[i].tip)}"><rect class="hit" x="${p[0]-slot/2}" y="${T}" width="${slot}" height="${ph}"/><line class="xh" x1="${p[0]}" x2="${p[0]}" y1="${T}" y2="${base}"/><circle class="dot" cx="${p[0]}" cy="${p[1]}" r="5" fill="${color}" stroke="#fff" stroke-width="2"/></g>`).join('');
 const lbl=items.map((it,i)=>i%step===0?`<text class="ax" x="${pts[i][0]}" y="${H-6}" text-anchor="${i===0?'start':i===items.length-1?'end':'middle'}">${it.k}</text>`:'').join('');
 return `<svg viewBox="0 0 ${W} ${H}" role="img"><defs><linearGradient id="ag" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${color}" stop-opacity=".22"/><stop offset="1" stop-color="${color}" stop-opacity=".02"/></linearGradient></defs>${grid}<line class="gl" x1="${L}" x2="${W-R}" y1="${base}" y2="${base}" style="stroke:#c3cee2"/><path d="${area}" fill="url(#ag)"/><path d="${d}" fill="none" stroke="${color}" stroke-width="2.5" stroke-linecap="round"/>${hov}${lbl}</svg>`;
}
// tooltip for anything with data-tip (mouse hover + tap on phone)
export function initTips() {
  const tip = () => document.getElementById('tip');
  const show = (el, e) => { const t = tip(); t.innerHTML = el.getAttribute('data-tip'); t.style.display = 'block'; const r = t.getBoundingClientRect(); let x = e.clientX + 12, yy = e.clientY - r.height - 12; if (x + r.width > innerWidth - 8) x = e.clientX - r.width - 12; if (yy < 8) yy = e.clientY + 16; t.style.left = Math.max(8, x) + 'px'; t.style.top = yy + 'px'; };
  document.addEventListener('mousemove', e => { const el = e.target.closest && e.target.closest('[data-tip]'); el ? show(el, e) : tip().style.display = 'none'; });
  document.addEventListener('click', e => { const el = e.target.closest && e.target.closest('[data-tip]'); el ? show(el, e) : tip().style.display = 'none'; });
  addEventListener('scroll', () => tip().style.display = 'none', { passive: true });
}
