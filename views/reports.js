// Reports: KPIs vs last year, earnings trend, monthly sales / profit, money collected, stock sold per batch,
// gross and net profit, service and warranty costs, lead sources. Download Report (PDF).
import { esc, rs, sum, stat, fmtD, todayIN, MON } from '../ui/dom.js';
import { barChart, areaChart, kpi } from '../ui/charts.js';
import { isAdmin } from '../api/store.js';
import { read } from '../api/client.js';
import { printReport } from '../ui/print.js';

let repYear = new Date().getFullYear();

export const views = {
  async reports() {
    const [r, leads] = await Promise.all([read('report_year', { p_year: repYear }), read('lead_report', { p_year: repYear })]);
    const adm = isAdmin(), months = r.months.map(x => ({ ...x, mn: MON[x.m - 1] }));
    const yS = sum(months, x => x.sales), yN = sum(months, x => x.n), yG = sum(months, x => x.gross), yNet = sum(months, x => x.net);
    const curM = repYear === new Date().getFullYear() ? new Date().getMonth() + 1 : 12, shown = months.slice(0, curM);
    const tip = x => `<b>${x.mn} ${repYear}</b><br>${x.n} laptops sold<br>Sales ${rs(x.sales)}${adm ? `<br>Gross profit ${rs(x.gross)}<br>Net profit ${rs(x.net)}` : ''}`;
    const cPct = yS ? Math.round(r.collected / yS * 100) : 0;
    const missing = adm ? sum(months, x => x.cost_missing) : 0;
    // lead sources: totals for the year
    const ls = {}; leads.forEach(x => { const t = ls[x.lead_source] = ls[x.lead_source] || { n: 0, sales: 0, gross: 0 }; t.n += x.n; t.sales += +x.sales; t.gross += +(x.gross || 0); });
    const lsRows = Object.entries(ls).sort((a, b) => b[1].sales - a[1].sales);
    const maxLs = Math.max(1, ...lsRows.map(x => x[1].sales));
    return `<div class="printonly" style="text-align:center;margin-bottom:12px"><img src="assets/logo.jpg" style="width:200px" alt=""><h2>Sales Report ${repYear}</h2><p class="muted">Generated ${fmtD(todayIN())}</p></div>
    <div class="card noprint"><div class="row" style="align-items:center"><h3 style="margin:0">Year report</h3><select style="max-width:130px" onchange="A.setRepYear(this.value)">${r.years.map(y => `<option ${y === repYear ? 'selected' : ''}>${y}</option>`).join('')}</select></div></div>
    ${kpi('Total Revenue', rs(yS), yS, r.prev.sales, '↗', '#e8f1ff', '#1e6fe8', repYear)}
    ${kpi('Laptops Sold', yN.toLocaleString('en-IN'), yN, r.prev.n, '💻', '#e5f6ec', '#17924f', repYear)}
    ${adm ? kpi('Gross Profit', rs(yG), yG, r.prev.gross, '₹', '#eef0ff', '#0f1f3d', repYear) : ''}
    ${adm ? `<div class="grid">${stat('Shop expenses', rs(sum(months, x => x.shop)))}${stat('Warranty repairs', rs(sum(months, x => x.warranty)))}${stat('Net profit', rs(yNet))}</div>` : ''}
    ${missing ? `<p class="warnmark" style="margin:0 0 12px">${missing} sold laptop${missing > 1 ? 's have' : ' has'} cost missing, so profit leaves them out</p>` : ''}
    <div class="card chart"><div class="chead"><h3 style="margin:0">Earnings trend</h3><span class="muted">${repYear}</span></div>
    ${areaChart(shown.map(x => ({ k: x.mn, v: +x.sales, tip: tip(x) })), '#1e6fe8')}</div>
    <button class="pdfbtn noprint" onclick="A.printReport()">Download Report (PDF)</button>
    <div class="grid">${stat('Collected', rs(r.collected))}${stat('Pending', rs(r.pending))}${adm ? stat('Repairs (sold)', rs(r.repairs_sold)) : ''}</div>
    <div class="card chart"><div class="chead"><h3 style="margin:0">Sales by month</h3><span class="big">${rs(yS)}</span></div>
    ${barChart(months.map(x => ({ k: x.mn.slice(0, 3), v: +x.sales, tip: tip(x) })), '#1e6fe8')}</div>
    ${adm ? `<div class="card chart"><div class="chead"><h3 style="margin:0">Gross profit by month</h3><span class="big">${rs(yG)}</span></div>
    ${barChart(months.map(x => ({ k: x.mn.slice(0, 3), v: +x.gross, tip: tip(x) })), '#0f1f3d')}</div>
    <div class="card chart"><div class="chead"><h3 style="margin:0">Net profit by month</h3><span class="big">${rs(yNet)}</span></div>
    ${barChart(months.map(x => ({ k: x.mn.slice(0, 3), v: +x.net, tip: tip(x) })), '#0F9D6B')}<p class="muted" style="margin-top:8px">Net = gross profit − shop expenses − warranty repairs.</p></div>` : ''}
    <div class="card"><div class="chead"><h3 style="margin:0">Money collected</h3><span class="big">${cPct}%</span></div>
    ${yS ? `<div class="split"><div style="flex:${r.collected};background:var(--blue)"></div>${r.pending ? `<div style="flex:${r.pending};background:var(--red)"></div>` : ''}</div>
    <div class="legend"><span><i style="background:var(--blue)"></i>Collected ${rs(r.collected)}</span><span><i style="background:var(--red)"></i>Pending ${rs(r.pending)}</span></div>` : '<p class="muted">No sales this year yet.</p>'}</div>
    <div class="card"><h3>Lead sources ${repYear}</h3>${lsRows.length ? lsRows.map(([k, v]) => `<div class="brow" data-tip="<b>${esc(k)}</b><br>${v.n} laptops<br>Sales ${rs(v.sales)}${adm ? `<br>Gross profit ${rs(v.gross)}` : ''}"><span>${esc(k)}</span><div class="btrack"><div style="width:${v.sales / maxLs * 100}%"></div></div><span class="right muted">${v.n}</span></div>`).join('')
      + `<div class="tw" style="margin-top:12px"><table><tr><th>Month</th><th>Source</th><th>Sold</th><th>Sales</th>${adm ? '<th>Profit</th>' : ''}</tr>${leads.map(x => `<tr><td>${MON[x.m - 1]}</td><td>${esc(x.lead_source)}</td><td>${x.n}</td><td>${rs(x.sales)}</td>${adm ? `<td>${rs(x.gross)}</td>` : ''}</tr>`).join('')}</table></div>`
      : '<p class="muted">No sales this year yet.</p>'}</div>
    ${r.batches.length ? `<div class="card"><h3>Stock sold per batch</h3>${r.batches.map(x => `<div class="brow" data-tip="<b>${esc(x.prefix)}</b><br>${x.sold} sold · ${x.qty - x.sold} left<br>Sales ${rs(x.sales)}"><span class="mono">${esc(x.prefix)}</span><div class="btrack"><div style="width:${x.qty ? x.sold / x.qty * 100 : 0}%"></div></div><span class="right muted">${x.sold}/${x.qty}</span></div>`).join('')}
    <div class="legend"><span><i style="background:var(--blue)"></i>Sold</span><span><i style="background:#e3ecfb"></i>Still in stock</span></div></div>` : ''}
    <div class="card"><h3>Monthly sales – ${repYear}</h3><div class="tw"><table><tr><th>Month</th><th>Sold</th><th>Sales</th>${adm ? '<th>Gross</th><th>Shop</th><th>Service</th><th>Warranty</th><th>Net</th>' : ''}</tr>${months.map(x => `<tr><td>${x.mn}</td><td>${x.n}</td><td>${rs(x.sales)}</td>${adm ? `<td>${rs(x.gross)}</td><td>${rs(x.shop)}</td><td>${rs(x.service_stock)}</td><td>${rs(x.warranty)}</td><td>${rs(x.net)}</td>` : ''}</tr>`).join('')}</table></div>
    ${adm ? '<p class="muted" style="margin-top:8px">Service = charges on stock laptops (already inside each laptop\'s cost when it sells). Warranty = repairs on customers\' laptops.</p>' : ''}</div>`;
  }
};

export const actions = {
  setRepYear(y) { repYear = +y; A.refresh(); },
  printReport
};
