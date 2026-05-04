/* ============================================================ */
/* SYSTEM DASHBOARD — RENDER + LIVE RELOAD                       */
/* ============================================================ */
(function () {
  'use strict';

  /* ---------- helpers ---------- */
  const $ = (id) => document.getElementById(id);
  const fmt = (n, d = 1) => (n === null || n === undefined || isNaN(n)) ? '—' : Number(n).toFixed(d);
  const safe = (v, fb = '—') => (v === null || v === undefined || v === '') ? fb : v;
  const escape = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

  function bytes(n) {
    if (!n) return '0 B';
    const u = ['B','KB','MB','GB','TB']; let i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return n.toFixed(1) + ' ' + u[i];
  }
  function bytesPerSec(n) {
    if (!n || n < 0) return '0 B/s';
    const u = ['B/s','KB/s','MB/s','GB/s']; let i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return n.toFixed(1) + ' ' + u[i];
  }
  function relTime(iso) {
    if (!iso) return '—';
    const sec = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
    if (sec < 5)   return 'NOW';
    if (sec < 60)  return sec + 's ago';
    if (sec < 3600) return Math.floor(sec/60) + 'm ago';
    if (sec < 86400) return Math.floor(sec/3600) + 'h ago';
    return Math.floor(sec/86400) + 'd ago';
  }
  function colorForPercent(p) {
    if (p >= 90) return 'crit';
    if (p >= 70) return 'warn';
    return '';
  }
  function systemStatus(cpuLoad, memLoad, gpuUtil) {
    const n = { cpu: `CPU ${Math.round(cpuLoad)}%`, mem: `MEM ${Math.round(memLoad)}%`, gpu: `GPU ${Math.round(gpuUtil)}%` };
    const crit = [cpuLoad >= 90 && n.cpu, memLoad >= 90 && n.mem, gpuUtil >= 90 && n.gpu].filter(Boolean);
    if (crit.length) return { led: 'crit', label: crit.join(' · '), tip: 'CRITICAL — immediate action required', class: 'crit' };
    const warn = [cpuLoad >= 70 && n.cpu, memLoad >= 70 && n.mem, gpuUtil >= 70 && n.gpu].filter(Boolean);
    if (warn.length) return { led: 'warn', label: warn.join(' · '), tip: 'WARNING — monitor these components', class: 'warn' };
    return { led: '', label: 'OPERATIONAL', tip: 'All systems within normal parameters', class: '' };
  }
  function tempColor(t, warn = 70, crit = 85) {
    if (t == null) return 'var(--tx-mid)';
    if (t >= crit) return 'var(--crit)';
    if (t >= warn) return 'var(--warn)';
    return 'var(--ok)';
  }
  function parseLinuxUptime(raw) {
    if (!raw) return '—';
    // Вырезаем "up ..." до ", N users" или " load" или конца
    const upMatch = raw.match(/up\s+(.+?)(?:,\s*\d+\s+user|\s+load|$)/i);
    if (!upMatch) return '—';
    const s = upMatch[1].trim();
    let d = 0, h = 0, mn = 0;
    // "X day(s), H:MM"
    const dhm = s.match(/(\d+)\s+days?,\s*(\d+):(\d+)/i);
    if (dhm) { d = +dhm[1]; h = +dhm[2]; mn = +dhm[3]; }
    // "H:MM" (без дней)
    else { const hm = s.match(/^(\d+):(\d+)$/); if (hm) { h = +hm[1]; mn = +hm[2]; } }
    // "X min"
    if (!dhm && !s.match(/:/)) { const mm = s.match(/(\d+)\s+min/i); if (mm) mn = +mm[1]; }
    return d > 0 ? `${d}d ${h}h ${mn}m` : h > 0 ? `${h}h ${mn}m` : `${mn}m`;
  }
  function gpuArr(g) {
    // PowerShell sometimes serializes single-GPU as object instead of array
    if (!g) return [];
    if (Array.isArray(g)) return g;
    return [g];
  }

  function chartColors() {
    const light = document.body.classList.contains('theme-light');
    return {
      tick:    light ? '#64748b' : '#5b6b85',
      grid:    light ? 'rgba(15, 80, 120, 0.08)' : 'rgba(0, 240, 220, 0.05)',
      tooltipBg: light ? '#ffffff' : '#0a0e15',
      tooltipBorder: light ? 'rgba(15, 80, 120, 0.2)' : 'rgba(0, 240, 220, 0.4)',
      tooltipTitle: light ? '#0f172a' : '#e6edf7',
      tooltipBody:  light ? '#334155' : '#b4c0d0',
    };
  }

  /* ============================================================ */
  /* HISTORY BUFFER                                                */
  /* ============================================================ */
  const MAX_SAMPLES = 60; // ~3 minutes at 3-sec interval
  const H = {
    ts:   [],
    cpu:  [],
    mem:  [],
    gpu:  [],
    disk: [],
    rx:   [], // raw bytes (PC primary interface)
    tx:   [],
    ping: [],
    synoRx: [], synoTx: [],     // cumulative bytes на NAS
    routerRx: [], routerTx: [], // cumulative bytes на роутере
    cpuTemp: [], // °C
    gpuTemp: [], // °C
  };

  function pushSample(D) {
    H.ts.push(Date.now());
    H.cpu.push(D.cpu?.load_percent ?? 0);
    H.mem.push(D.memory?.used_percent ?? 0);
    const gpu0 = gpuArr(D.gpu)[0];
    H.gpu.push(gpu0?.gpu_util_percent ?? 0);
    const sysDrive = D.disk?.logical?.find(d => d.drive === 'C:') || (D.disk?.logical && D.disk.logical[0]);
    H.disk.push(sysDrive?.used_percent ?? 0);

    const primaryIf = (D.network?.interfaces || []).find(i => i.ip4 && i.ip4 !== '172.18.0.1' && !i.ip4.startsWith('169.')) || (D.network?.interfaces || [])[0];
    H.rx.push(primaryIf?.rx_bytes ?? 0);
    H.tx.push(primaryIf?.tx_bytes ?? 0);
    H.ping.push(D.router?.ping_ms ?? 0);

    H.synoRx.push(D.synology?.info?.net_total?.rx_bytes ?? 0);
    H.synoTx.push(D.synology?.info?.net_total?.tx_bytes ?? 0);
    H.routerRx.push(D.router?.info?.net_total?.rx_bytes ?? 0);
    H.routerTx.push(D.router?.info?.net_total?.tx_bytes ?? 0);
    H.cpuTemp.push(D.cpu?.temp_c ?? null);
    H.gpuTemp.push(gpu0?.temp_c ?? null);

    Object.keys(H).forEach(k => {
      while (H[k].length > MAX_SAMPLES) H[k].shift();
    });
  }

  // Скорость в bytes/sec из последних двух семплов кумулятивных байтов.
  function rateFrom(arr) {
    const n = arr.length;
    if (n < 2) return 0;
    const dt = (H.ts[n - 1] - H.ts[n - 2]) / 1000;
    if (dt <= 0) return 0;
    return Math.max(0, (arr[n - 1] - arr[n - 2]) / dt);
  }

  // Виджет ↓RX ↑TX в углу карточки.
  function netThroughputHtml(rxRate, txRate) {
    const fmtRate = (n) => {
      if (!n || n < 1) return { v: '0', u: 'B/s' };
      const u = ['B/s','KB/s','MB/s','GB/s']; let i = 0; let x = n;
      while (x >= 1024 && i < u.length - 1) { x /= 1024; i++; }
      return { v: x >= 100 ? x.toFixed(0) : x.toFixed(1), u: u[i] };
    };
    const r = fmtRate(rxRate), t = fmtRate(txRate);
    return `
      <div class="net-throughput" title="Сетевой трафик: входящий / исходящий">
        <span class="nt-item nt-down"><span class="nt-arrow">↓</span><span class="nt-val">${r.v}</span><span class="nt-unit">${r.u}</span></span>
        <span class="nt-item nt-up"><span class="nt-arrow">↑</span><span class="nt-val">${t.v}</span><span class="nt-unit">${t.u}</span></span>
      </div>
    `;
  }

  /* ============================================================ */
  /* RADIAL GAUGE                                                  */
  /* ============================================================ */
  function gaugeColors(value, base) {
    // base: 'cyan', 'pink', 'amber', 'violet'
    const palette = {
      cyan:   ['#00f0dc', '#00ffe0'],
      pink:   ['#ff3672', '#ff7aa6'],
      amber:  ['#ffa400', '#ffd166'],
      violet: ['#9d4edd', '#c77dff']
    }[base] || ['#00f0dc', '#00ffe0'];

    if (value >= 90) return ['#ff3838', '#ff7070'];
    if (value >= 75) return ['#ffaa00', '#ffd166'];
    return palette;
  }

  function renderGauge(host, opts) {
    const { value = 0, label = '', base = 'cyan', max = 100, suffix = '%', display, secondary } = opts;
    const pct = Math.min(100, Math.max(0, (value / max) * 100));

    // arc 220° from -200° to 20°
    const r = 60, cx = 90, cy = 80;
    const start = -200 * Math.PI / 180;
    const end   =  20  * Math.PI / 180;
    const sx = cx + r * Math.cos(start), sy = cy + r * Math.sin(start);
    const ex = cx + r * Math.cos(end),   ey = cy + r * Math.sin(end);
    const trackPath = `M ${sx.toFixed(2)} ${sy.toFixed(2)} A ${r} ${r} 0 1 1 ${ex.toFixed(2)} ${ey.toFixed(2)}`;
    const arcLen = (220 / 360) * 2 * Math.PI * r;
    const dashFill = (pct / 100) * arcLen;

    // tick marks every 22° (10 segments)
    const ticks = [];
    for (let i = 0; i <= 10; i++) {
      const ang = start + (i / 10) * (end - start);
      const r1 = r - 6, r2 = r + 4;
      const x1 = cx + r1 * Math.cos(ang), y1 = cy + r1 * Math.sin(ang);
      const x2 = cx + r2 * Math.cos(ang), y2 = cy + r2 * Math.sin(ang);
      ticks.push(`<line x1="${x1.toFixed(2)}" y1="${y1.toFixed(2)}" x2="${x2.toFixed(2)}" y2="${y2.toFixed(2)}" class="gauge-tick${i % 5 === 0 ? ' major' : ''}"/>`);
    }

    const [c1, c2] = gaugeColors(value, base);
    const gradId = 'gg_' + Math.random().toString(36).slice(2, 8);

    host.innerHTML = `
      <svg viewBox="0 0 180 120">
        <defs>
          <linearGradient id="${gradId}" x1="0%" y1="0%" x2="100%" y2="0%">
            <stop offset="0%" stop-color="${c1}"/>
            <stop offset="100%" stop-color="${c2}"/>
          </linearGradient>
        </defs>
        <path class="gauge-track" d="${trackPath}" />
        <g>${ticks.join('')}</g>
        <path class="gauge-bar"  d="${trackPath}"
              style="stroke:url(#${gradId});color:${c1};stroke-dasharray:${arcLen.toFixed(2)};stroke-dashoffset:${(arcLen - dashFill).toFixed(2)};"/>
      </svg>
      <div class="gauge-center">
        <div class="gauge-value" style="color:${c1};">${display !== undefined ? display : fmt(value, 0)}<span class="unit">${suffix}</span></div>
        <div class="gauge-label">${label}</div>
        ${secondary ? `<div class="gauge-secondary">${secondary}</div>` : ''}
      </div>
    `;
  }

  /* ============================================================ */
  /* HISTORY CHART (big)                                            */
  /* ============================================================ */
  let historyChart = null;
  function renderHistory() {
    const cv = document.getElementById('historyChart');
    if (!cv) return;
    const ctx = cv.getContext('2d');
    const labels = H.ts.map(t => {
      const d = new Date(t);
      return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    });

    function mkGrad(c) {
      const g = ctx.createLinearGradient(0, 0, 0, cv.clientHeight || 220);
      g.addColorStop(0, c + '55');
      g.addColorStop(1, c + '00');
      return g;
    }

    const ds = [
      { label: 'CPU',    data: H.cpu,     borderColor: '#00f0dc', bg: mkGrad('#00f0dc'), yAxisID: 'yPct', fill: true },
      { label: 'MEM',    data: H.mem,     borderColor: '#ff3672', bg: mkGrad('#ff3672'), yAxisID: 'yPct', fill: true },
      { label: 'GPU',    data: H.gpu,     borderColor: '#ffa400', bg: mkGrad('#ffa400'), yAxisID: 'yPct', fill: true },
      { label: 'DISK',   data: H.disk,    borderColor: '#9d4edd', bg: mkGrad('#9d4edd'), yAxisID: 'yPct', fill: true },
      { label: 'CPU°C',  data: H.cpuTemp, borderColor: '#4ade80', bg: 'transparent',     yAxisID: 'yTemp', fill: false, borderDash: [4, 3] },
      { label: 'GPU°C',  data: H.gpuTemp, borderColor: '#fb923c', bg: 'transparent',     yAxisID: 'yTemp', fill: false, borderDash: [4, 3] },
    ];

    if (historyChart) {
      historyChart.data.labels = labels;
      ds.forEach((d, i) => {
        historyChart.data.datasets[i].data = d.data;
        historyChart.data.datasets[i].backgroundColor = d.bg;
      });
      historyChart.update('none');
      return;
    }

    const cc = chartColors();
    historyChart = new Chart(ctx, {
      type: 'line',
      data: {
        labels,
        datasets: ds.map(d => ({
          label: d.label,
          data: d.data,
          borderColor: d.borderColor,
          backgroundColor: d.bg,
          borderWidth: d.yAxisID === 'yTemp' ? 1.5 : 1.8,
          fill: d.fill,
          tension: 0.35,
          pointRadius: 0,
          pointHoverRadius: 4,
          pointHoverBackgroundColor: d.borderColor,
          pointHoverBorderColor: '#fff',
          yAxisID: d.yAxisID,
          borderDash: d.borderDash || [],
          spanGaps: true,
        }))
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        animation: { duration: 350 },
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: cc.tooltipBg,
            borderColor: cc.tooltipBorder,
            borderWidth: 1,
            titleColor: cc.tooltipTitle,
            bodyColor: cc.tooltipBody,
            titleFont: { family: 'JetBrains Mono', size: 10 },
            bodyFont: { family: 'JetBrains Mono', size: 11 },
            padding: 10,
            callbacks: {
              label: (c) => {
                if (c.parsed.y === null) return null;
                return c.dataset.yAxisID === 'yTemp'
                  ? `${c.dataset.label}: ${c.parsed.y?.toFixed(0)}°C`
                  : `${c.dataset.label}: ${c.parsed.y?.toFixed(0)}%`;
              }
            }
          }
        },
        scales: {
          x: {
            ticks: { color: cc.tick, font: { family: 'JetBrains Mono', size: 9 }, maxRotation: 0, autoSkip: true, maxTicksLimit: 8 },
            grid: { color: cc.grid }
          },
          yPct: {
            position: 'left',
            ticks: { color: cc.tick, font: { family: 'JetBrains Mono', size: 9 }, callback: v => v + '%' },
            grid: { color: cc.grid },
            beginAtZero: true,
            max: 100
          },
          yTemp: {
            position: 'right',
            ticks: { color: '#9ca3af', font: { family: 'JetBrains Mono', size: 9 }, callback: v => v + '°' },
            grid: { drawOnChartArea: false },
            beginAtZero: false,
            min: 20,
            max: 110,
          }
        }
      }
    });
  }

  /* ============================================================ */
  /* NETWORK THROUGHPUT CHART                                       */
  /* ============================================================ */
  let netChart = null;
  function renderNetThroughput() {
    const cv = document.getElementById('netThroughputChart');
    if (!cv) return;
    const ctx = cv.getContext('2d');

    // calc deltas from cumulative bytes
    const rxRates = [], txRates = [], labels = [];
    for (let i = 1; i < H.rx.length; i++) {
      const dt = (H.ts[i] - H.ts[i-1]) / 1000;
      if (dt <= 0) { rxRates.push(0); txRates.push(0); }
      else {
        const dr = Math.max(0, H.rx[i] - H.rx[i-1]);
        const dx = Math.max(0, H.tx[i] - H.tx[i-1]);
        rxRates.push(dr / dt);
        txRates.push(dx / dt);
      }
      const d = new Date(H.ts[i]);
      labels.push(d.toLocaleTimeString([], { minute: '2-digit', second: '2-digit' }));
    }

    function mkGrad(c) {
      const g = ctx.createLinearGradient(0, 0, 0, cv.clientHeight || 140);
      g.addColorStop(0, c + '55');
      g.addColorStop(1, c + '00');
      return g;
    }

    if (netChart) {
      netChart.data.labels = labels;
      netChart.data.datasets[0].data = rxRates;
      netChart.data.datasets[1].data = txRates;
      netChart.data.datasets[0].backgroundColor = mkGrad('#45b7ff');
      netChart.data.datasets[1].backgroundColor = mkGrad('#00f0dc');
      netChart.update('none');
      return;
    }

    const cc = chartColors();
    netChart = new Chart(ctx, {
      type: 'line',
      data: {
        labels,
        datasets: [
          { label: 'RX', data: rxRates, borderColor: '#45b7ff', backgroundColor: mkGrad('#45b7ff'),
            borderWidth: 1.8, fill: true, tension: 0.35, pointRadius: 0 },
          { label: 'TX', data: txRates, borderColor: '#00f0dc', backgroundColor: mkGrad('#00f0dc'),
            borderWidth: 1.8, fill: true, tension: 0.35, pointRadius: 0 }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 300 },
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: {
            display: true,
            position: 'top',
            align: 'end',
            labels: {
              color: cc.tooltipBody,
              font: { family: 'JetBrains Mono', size: 9 },
              boxWidth: 10, boxHeight: 2,
              usePointStyle: false
            }
          },
          tooltip: {
            backgroundColor: cc.tooltipBg,
            borderColor: cc.tooltipBorder,
            borderWidth: 1,
            titleColor: cc.tooltipTitle,
            bodyColor: cc.tooltipBody,
            titleFont: { family: 'JetBrains Mono', size: 10 },
            bodyFont: { family: 'JetBrains Mono', size: 11 },
            callbacks: {
              label: (c) => `${c.dataset.label}: ${bytesPerSec(c.parsed.y)}`
            }
          }
        },
        scales: {
          x: {
            ticks: { color: cc.tick, font: { family: 'JetBrains Mono', size: 9 }, maxRotation: 0, autoSkip: true, maxTicksLimit: 6 },
            grid: { color: cc.grid }
          },
          y: {
            ticks: {
              color: cc.tick,
              font: { family: 'JetBrains Mono', size: 9 },
              callback: v => bytesPerSec(v)
            },
            grid: { color: cc.grid },
            beginAtZero: true
          }
        }
      }
    });
  }

  /* ============================================================ */
  /* MAIN RENDER                                                   */
  /* ============================================================ */
  function render(D) {
    if (!D) {
      $('bootscreen').style.display = 'grid';
      return;
    }
    $('bootscreen').style.display = 'none';

    pushSample(D);
    $('sampleCount').textContent = H.cpu.length;

    /* ---------- header (unified topbar) ---------- */
    $('metaOperator').textContent = D.meta?.operator || '—';
    $('metaHostname').textContent = D.os?.hostname || '—';
    $('metaUptime').textContent = D.os?.uptime_str || '—';
    $('genTime').textContent = D.meta?.generated_at || '—';

    /* ---------- overall status ---------- */
    const cpuLoad = D.cpu?.load_percent ?? 0;
    const memLoad = D.memory?.used_percent ?? 0;
    const gpu0 = gpuArr(D.gpu)[0];
    const gpuUtil = gpu0?.gpu_util_percent ?? 0;
    const st = systemStatus(cpuLoad, memLoad, gpuUtil);
    $('statusLed').className = 'status-led ' + st.led;
    $('statusLabel').className = 'status-label ' + st.class;
    $('statusLabel').textContent = st.label;
    $('statusPod').title = st.tip;

    /* ---------- gauges ---------- */
    const cpuMhz = D.cpu?.current_mhz || 0;
    const cpuGhz = (cpuMhz / 1000).toFixed(2);
    const cpuTemp = D.cpu?.temp_c;
    const cpuTempStr = cpuTemp != null ? `${cpuTemp}°C` : 'N/A';
    $('cpuTag').innerHTML = `${D.cpu?.cores || '?'}C/${D.cpu?.threads || '?'}T · <span style="color:${tempColor(cpuTemp)}">${cpuTempStr}</span>`;
    renderGauge($('gaugeCpu'), {
      value: cpuLoad, label: 'LOAD', base: 'cyan',
      secondary: `${cpuGhz} GHz · <span style="color:${tempColor(cpuTemp)};font-weight:600;">${cpuTempStr}</span>`
    });

    // memory frequency from highest module
    const memMods = D.memory?.modules || [];
    const memSpeed = memMods.length ? Math.max(...memMods.map(m => m.speed_mhz || 0)) : 0;
    const memType = memMods[0]?.memory_type || '';
    $('memTag').textContent = `${fmt(D.memory?.used_gb, 1)} / ${fmt(D.memory?.total_gb, 1)} GB`;
    renderGauge($('gaugeMem'), {
      value: memLoad, label: 'USED', base: 'pink',
      secondary: `<span class="v">${memSpeed || '—'}</span> MHz${memType ? ' · <span class="v">' + escape(memType) + '</span>' : ''}`
    });

    if (gpu0 && gpu0.gpu_util_percent !== undefined && gpu0.gpu_util_percent !== null) {
      $('gpuTag').innerHTML = `<span style="color:${tempColor(gpu0.temp_c, 75, 90)}">${gpu0.temp_c ?? '?'}°C</span> · ${fmt(gpu0.power_w ?? 0, 0)}W`;
      renderGauge($('gaugeGpu'), {
        value: gpu0.gpu_util_percent, label: 'UTIL', base: 'amber',
        secondary: `<span style="color:${tempColor(gpu0.temp_c, 75, 90)};font-weight:600;">${gpu0.temp_c ?? '?'}°C</span> · <span class="v">${fmt(gpu0.power_w ?? 0, 0)}</span> W`
      });
    } else if (gpu0) {
      $('gpuTag').textContent = gpu0.resolution || '—';
      renderGauge($('gaugeGpu'), {
        value: 0, label: 'IDLE', base: 'amber', display: '—',
        secondary: `<span class="v">${escape(gpu0.resolution || '—')}</span> @ <span class="v">${gpu0.refresh_hz || '?'}</span>Hz`
      });
    } else {
      $('gpuTag').textContent = 'NO GPU';
      renderGauge($('gaugeGpu'), { value: 0, label: 'N/A', base: 'amber', display: '—' });
    }

    const sysDrive = D.disk?.logical?.find(d => d.drive === 'C:') || (D.disk?.logical && D.disk.logical[0]);
    const sysPhysDisk = D.disk?.physical?.[0];
    const diskTemp = sysPhysDisk?.temp_c;
    const diskTempStr = diskTemp != null ? `${diskTemp}°C` : 'N/A';
    if (sysDrive) {
      $('diskTag').innerHTML = `${sysDrive.drive} · <span style="color:${tempColor(diskTemp, 45, 60)}">${diskTempStr}</span>`;
      renderGauge($('gaugeDisk'), {
        value: sysDrive.used_percent, label: sysDrive.label || sysDrive.drive, base: 'violet',
        secondary: `<span class="v">${fmt(sysDrive.free_gb, 0)}</span> GB free · <span style="color:${tempColor(diskTemp, 45, 60)};font-weight:600;">${diskTempStr}</span>`
      });
    } else {
      $('diskTag').textContent = '—';
      renderGauge($('gaugeDisk'), { value: 0, label: 'N/A', base: 'violet', display: '—' });
    }

    /* ---------- legend live values ---------- */
    $('legendCpu').textContent  = fmt(cpuLoad, 0) + '%';
    $('legendMem').textContent  = fmt(memLoad, 0) + '%';
    $('legendGpu').textContent  = fmt(gpuUtil, 0) + '%';
    $('legendDisk').textContent = fmt(sysDrive?.used_percent ?? 0, 0) + '%';
    const cpuTempNow = D.cpu?.temp_c;
    const gpuTempNow = gpu0?.temp_c;
    $('legendCpuTemp').textContent = cpuTempNow != null ? cpuTempNow + '°C' : 'N/A';
    $('legendGpuTemp').textContent = gpuTempNow != null ? gpuTempNow + '°C' : 'N/A';

    /* ---------- history chart ---------- */
    renderHistory();
    renderNetThroughput();

    /* ---------- CPU detail ---------- */
    const cpu = D.cpu || {};
    $('cpuDetail').innerHTML = `
      <div class="kv">
        <div class="k">MODEL</div><div class="v mono">${escape(cpu.name || '—')}</div>
        <div class="k">SOCKET</div><div class="v">${escape(cpu.socket || '—')}</div>
        <div class="k">ARCHITECTURE</div><div class="v">${escape(cpu.architecture || '—')}</div>
        <div class="k">CORES / THREADS</div><div class="v">${cpu.cores ?? '—'} / ${cpu.threads ?? '—'}</div>
        <div class="k">BASE CLOCK</div><div class="v">${cpu.base_clock_mhz ?? '—'} MHz</div>
        <div class="k">CURRENT CLOCK</div><div class="v">${cpu.current_mhz ?? '—'} MHz</div>
        <div class="k">L2 / L3 CACHE</div><div class="v">${(cpu.l2_cache_kb || 0)/1024} MB / ${(cpu.l3_cache_kb || 0)/1024} MB</div>
      </div>
      <div class="divider"></div>
      <div class="kv">
        <div class="k">CURRENT LOAD</div>
        <div class="v" style="color:var(--acc-cyan);font-family:'Orbitron',sans-serif;">${cpu.load_percent ?? 0}%</div>
      </div>
      <div class="bar" style="margin-top:6px;"><div class="bar-fill ${colorForPercent(cpu.load_percent ?? 0)}" style="width:${cpu.load_percent ?? 0}%"></div></div>
    `;

    /* ---------- memory modules ---------- */
    $('memModTag').textContent = `${memMods.length} module${memMods.length === 1 ? '' : 's'}`;
    $('memModules').innerHTML = memMods.length ? `
      <div class="mod-grid">
        ${memMods.map(m => `
          <div class="mod">
            <div class="mod-slot">${escape(m.slot || m.bank || '—')}</div>
            <div class="mod-cap">${m.capacity_gb} GB</div>
            <div class="mod-info">
              ${escape(m.memory_type || '')} · ${m.speed_mhz || '?'} MHz<br>
              ${escape(m.manufacturer || 'Unknown')}<br>
              ${escape(m.part_number || '')}
            </div>
          </div>
        `).join('')}
      </div>
    ` : '<div class="empty">// NO MODULE DATA</div>';

    /* ---------- GPU detail (FIXED: handle array OR object) ---------- */
    const gpus = gpuArr(D.gpu);
    if (gpus.length === 0 || gpus[0]?.error) {
      $('gpuDetail').innerHTML = '<div class="empty">// NO GPU DATA</div>';
      $('gpuLiveTag').textContent = 'OFFLINE';
    } else {
      const hasLive = gpus.some(g => g.gpu_util_percent !== undefined && g.gpu_util_percent !== null);
      $('gpuLiveTag').innerHTML = hasLive ? '<span class="live-dot"></span>NVIDIA-SMI' : 'DXGI';

      $('gpuDetail').innerHTML = gpus.map((g, idx) => {
        let live = '';
        if (g.gpu_util_percent !== undefined && g.gpu_util_percent !== null) {
          const vramPct = g.vram_total_mb ? Math.round((g.vram_used_mb / g.vram_total_mb) * 100) : 0;
          const gpuTempClr = (g.temp_c >= 80) ? 'var(--crit)' : (g.temp_c >= 70 ? 'var(--warn)' : 'var(--acc-amber)');
          live = `
            <div class="divider"></div>
            <div class="kv">
              <div class="k">UTILIZATION</div>
              <div class="v" style="color:var(--acc-amber);font-family:'Orbitron',sans-serif;">${g.gpu_util_percent}%</div>
            </div>
            <div class="bar" style="margin:4px 0 12px 0;"><div class="bar-fill warn" style="width:${g.gpu_util_percent}%"></div></div>
            <div class="kv">
              <div class="k">VRAM USED</div>
              <div class="v" style="font-family:'Orbitron',sans-serif;">${(g.vram_used_mb/1024).toFixed(1)} / ${(g.vram_total_mb/1024).toFixed(1)} GB <span style="color:var(--tx-mid);">(${vramPct}%)</span></div>
            </div>
            <div class="bar" style="margin:4px 0 12px 0;"><div class="bar-fill ${colorForPercent(vramPct)}" style="width:${vramPct}%"></div></div>
            <div class="kv">
              <div class="k">TEMPERATURE</div>
              <div class="v" style="color:${gpuTempClr};font-family:'Orbitron',sans-serif;">${g.temp_c}°C</div>
              <div class="k">POWER DRAW</div>
              <div class="v" style="font-family:'Orbitron',sans-serif;">${fmt(g.power_w, 1)} W</div>
            </div>
          `;
        }
        return `
          ${idx > 0 ? '<div class="divider"></div>' : ''}
          <div class="kv">
            <div class="k">MODEL</div><div class="v" style="color:var(--acc-amber);">${escape(g.name)}</div>
            <div class="k">DRIVER</div><div class="v mono">${escape(g.driver_version || '—')}</div>
            <div class="k">DRIVER DATE</div><div class="v">${escape(g.driver_date || '—')}</div>
            <div class="k">CURRENT MODE</div><div class="v">${escape(g.resolution || '—')} @ ${g.refresh_hz || '—'} Hz</div>
            <div class="k">STATUS</div><div class="v"><span class="chip ${g.status === 'OK' ? 'ok' : 'warn'}">${escape(g.status || 'OK')}</span></div>
          </div>
          ${live}
        `;
      }).join('');
    }

    /* ---------- platform ---------- */
    const mb = D.motherboard || {};
    const os = D.os || {};
    $('platformDetail').innerHTML = `
      <div class="kv">
        <div class="k">MANUFACTURER</div><div class="v">${escape(mb.manufacturer || '—')}</div>
        <div class="k">MODEL</div><div class="v">${escape(mb.product || '—')}</div>
        <div class="k">VERSION</div><div class="v">${escape(mb.version || '—')}</div>
        <div class="k">SERIAL</div><div class="v mono dim">${escape(mb.serial || '—')}</div>
      </div>
      <div class="divider"></div>
      <div class="kv">
        <div class="k">BIOS VENDOR</div><div class="v">${escape(os.bios_vendor || '—')}</div>
        <div class="k">BIOS VERSION</div><div class="v mono">${escape(os.bios_version || '—')}</div>
        <div class="k">BIOS DATE</div><div class="v">${escape(os.bios_date || '—')}</div>
      </div>
      <div class="divider"></div>
      <div class="kv">
        <div class="k">OS</div><div class="v">${escape(os.os || '—')}</div>
        <div class="k">BUILD</div><div class="v">${escape(os.build || '—')} (${escape(os.arch || '?')})</div>
        <div class="k">INSTALLED</div><div class="v">${escape(os.install_date || '—')}</div>
        <div class="k">LAST BOOT</div><div class="v">${escape(os.last_boot || '—')}</div>
        <div class="k">UPTIME</div><div class="v" style="color:var(--acc-cyan);">${escape(os.uptime_str || '—')}</div>
      </div>
    `;

    /* ---------- storage ---------- */
    const logical = D.disk?.logical || [];
    const physical = D.disk?.physical || [];
    $('storageTag').textContent = `${physical.length} drives · ${logical.length} volumes`;

    let storageHtml = '';
    if (logical.length) {
      storageHtml += '<div style="margin-bottom:14px;">';
      storageHtml += '<div style="font-size:9px;letter-spacing:2px;color:var(--tx-mid);margin-bottom:8px;">LOGICAL VOLUMES</div>';
      storageHtml += logical.map(d => `
        <div class="drive">
          <div class="drive-icon">▣</div>
          <div class="drive-meta">
            <div class="drive-name">${escape(d.drive)} <span class="chip cyan">${escape(d.label || 'no-label')}</span></div>
            <div class="drive-detail">${escape(d.filesystem || '?')} · ${fmt(d.used_gb, 1)} GB used of ${fmt(d.total_gb, 1)} GB · ${fmt(d.free_gb, 1)} GB free</div>
          </div>
          <div class="drive-bar">
            <div class="num">${d.used_percent}%</div>
            <div class="bar"><div class="bar-fill ${colorForPercent(d.used_percent)}" style="width:${d.used_percent}%"></div></div>
          </div>
        </div>
      `).join('');
      storageHtml += '</div>';
    }
    if (physical.length) {
      storageHtml += '<div>';
      storageHtml += '<div style="font-size:9px;letter-spacing:2px;color:var(--tx-mid);margin-bottom:8px;">PHYSICAL DEVICES</div>';
      storageHtml += physical.map(p => {
        const healthChip = (p.health === 'Healthy') ? 'ok' : (p.health === 'Warning' ? 'warn' : 'crit');
        const ic = (p.media_type || '').toLowerCase().includes('ssd') ? '◆' : '◉';
        return `
          <div class="drive">
            <div class="drive-icon">${ic}</div>
            <div class="drive-meta">
              <div class="drive-name">${escape(p.friendly_name || p.model)}
                <span class="chip ${healthChip}">${escape(p.health || 'OK')}</span>
                <span class="chip">${escape(p.media_type || '')}</span>
                <span class="chip">${escape(p.bus_type || '')}</span>
              </div>
              <div class="drive-detail">${escape(p.model || '')} · S/N: ${escape(p.serial || '—')} · ${escape(p.operational || '—')}</div>
            </div>
            <div class="drive-bar">
              <div class="num">${fmt(p.size_gb, 0)} GB</div>
            </div>
          </div>
        `;
      }).join('');
      storageHtml += '</div>';
    }
    $('storageDetail').innerHTML = storageHtml || '<div class="empty">// NO STORAGE DATA</div>';

    /* ---------- network ---------- */
    const net = D.network || {};
    const ifs = net.interfaces || [];
    $('netTag').textContent = `${ifs.length} active`;

    let netHtml = '';
    if (ifs.length) {
      netHtml += ifs.map(i => `
        <div style="padding:10px 0; border-bottom: 1px dashed var(--line-faint);">
          <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;">
            <div style="color:var(--tx-bright);font-weight:500;font-size:12px;">${escape(i.name)}</div>
            <span class="chip ok">${escape(i.status)}</span>
          </div>
          <div class="kv">
            <div class="k">DESCRIPTION</div><div class="v dim">${escape(i.description)}</div>
            ${i.mac ? `<div class="k">MAC</div><div class="v mono">${escape(i.mac)}</div>` : ''}
            <div class="k">IPv4</div><div class="v mono accent" style="color:var(--acc-blue);">${escape(i.ip4 || '—')}</div>
            ${i.ip6 ? `<div class="k">IPv6</div><div class="v mono dim">${escape(i.ip6)}</div>` : ''}
            <div class="k">RX / TX (TOTAL)</div><div class="v">${bytes(i.rx_bytes)} ↓ / ${bytes(i.tx_bytes)} ↑</div>
          </div>
        </div>
      `).join('');
    }
    netHtml += `
      <div class="divider"></div>
      <div class="kv">
        <div class="k">DEFAULT GATEWAY</div><div class="v mono accent" style="color:var(--acc-pink);">${escape(net.gateway || '—')}</div>
        <div class="k">DNS SERVERS</div><div class="v mono">${(net.dns || []).map(escape).join(', ') || '—'}</div>
        <div class="k">EXTERNAL IP</div><div class="v mono">${escape(net.external_ip || '—')}</div>
      </div>
    `;
    $('netDetail').innerHTML = netHtml;

    /* ---------- router ---------- */
    renderRouter(D.router || {});

    /* ---------- synology ---------- */
    renderSyno(D.synology, D.network?.gateway);

    /* ---------- RELEASES / UPDATES / ERRORS ---------- */
    renderReleases(D.releases, D.meta?.proxy_links);
    renderUpdates(D.updates);
    renderSysErrors(D.sys_errors);

    /* ---------- JUNK CLEANER ---------- */
    renderJunk(D.junk);

    /* ---------- LAN devices (tile grid) ---------- */
    const devs = D.router?.devices || [];
    $('lanTag').textContent = `${devs.length} hosts via ARP`;
    if (devs.length === 0) {
      $('lanDetail').innerHTML = '<div class="empty">// NO ARP ENTRIES</div>';
    } else {
      const sorted = [...devs].sort((a, b) => {
        if (a.is_gateway) return -1;
        if (b.is_gateway) return 1;
        return (a.ip || '').localeCompare(b.ip || '', undefined, { numeric: true });
      });
      $('lanDetail').innerHTML = `
        <div class="dev-grid">
          ${sorted.map(d => {
            const oui = (d.mac || '').slice(0, 8);
            return `
            <div class="dev-tile ${d.is_gateway ? 'gateway' : ''}">
              ${d.is_gateway ? '<div class="dev-tag" style="color:var(--acc-pink);">GATEWAY</div>' : `<div class="dev-tag">${escape(d.type)}</div>`}
              <div class="dev-ip">${escape(d.ip)}</div>
              <div class="dev-mac">${escape(d.mac)}</div>
              <div class="dev-vendor">OUI: ${escape(oui)}</div>
            </div>
          `;}).join('')}
        </div>
      `;
    }
  }

  /* ============================================================ */
  /* SYNOLOGY (compact)                                            */
  /* ============================================================ */
  function renderSyno(s, gw) {
    if (!s || !s.enabled) {
      $('synoDetail').innerHTML = '<div class="empty">// NAS DISABLED</div>';
      $('synoTag').textContent = 'OFF'; return;
    }
    if (!s.reachable) {
      $('synoDetail').innerHTML = `
        <div class="alert-error">${escape(s.error || 'NAS unreachable')}</div>
        <div class="kv">
          <div class="k">HOST</div><div class="v mono">${escape(s.host)}</div>
          <div class="k">HINT</div><div class="v dim">IP должен быть в подсети ${escape(gw || '?')}</div>
        </div>`;
      $('synoTag').textContent = 'OFFLINE'; return;
    }
    const i = s.info || {};
    $('synoTag').innerHTML = '<span class="live-dot"></span>ONLINE · ' + escape(i.hostname || s.host);

    // расчёты для метрик
    const cpuLoadPct = i.cpu_cores ? Math.min(100, Math.round((i.load_1m / i.cpu_cores) * 100)) : 0;
    const memPct = Math.round(i.mem_used_percent || 0);
    const tempC = i.cpu_temp_c;
    const disks = i.disks || [];
    const diskMaxPct = disks.length ? Math.max(...disks.map(d => d.used_percent || 0)) : 0;
    const totalSizeStr = disks.length ? disks.map(d => d.size).filter(Boolean)[0] || '—' : '—';
    const ports = (i.ports && i.ports.flat) ? i.ports.flat() : (i.ports || []);

    // Статус температуры (NORMAL / WARM / HIGH)
    let tempStatusHtml = '<span style="color:var(--tx-mid)">no sensor</span>';
    if (tempC !== undefined && tempC !== null) {
      if (tempC >= 75)      tempStatusHtml = '<span style="color:var(--crit)">⚠ HIGH</span>';
      else if (tempC >= 60) tempStatusHtml = '<span style="color:var(--warn)">WARM</span>';
      else                  tempStatusHtml = '<span style="color:var(--ok)">NORMAL</span>';
    }

    const synoUptime = (() => {
      if (i.uptime_sec) {
        const us = i.uptime_sec;
        const d = Math.floor(us / 86400), h = Math.floor((us % 86400) / 3600),
              m = Math.floor((us % 3600) / 60), s = us % 60;
        return d > 0 ? `${d}d ${h}h ${m}m ${s}s` : h > 0 ? `${h}h ${m}m ${s}s` : `${m}m ${s}s`;
      }
      return parseLinuxUptime(i.uptime_raw);
    })();

    // Сетевая нагрузка (трафик-индикатор в углу)
    const synoRxRate = rateFrom(H.synoRx);
    const synoTxRate = rateFrom(H.synoTx);

    // Модель — главный акцент карточки
    const deviceModel = 'SYNOLOGY DS920+';

    let html = `
      <div class="dev-head">
        <div class="dev-head-info">
          <div class="dev-name">${escape(deviceModel)}</div>
          <div class="dev-sub"><span class="uptime-badge">UPTIME&nbsp;${escape(synoUptime)}</span></div>
        </div>
        <div class="dev-head-actions">
          ${netThroughputHtml(synoRxRate, synoTxRate)}
        </div>
      </div>
      <div class="dev-hero">
        <div class="dev-image">
          <img src="img/img.png" alt="Synology NAS" loading="lazy" onerror="this.parentElement.style.display='none'">
        </div>
        <div class="dev-metrics">
          <div class="dev-metric cpu">
            <div class="dev-metric-row">
              <div class="dev-metric-label">CPU LOAD</div>
              <div class="dev-metric-value">${cpuLoadPct}<span class="unit">%</span></div>
            </div>
            <div class="bar"><div class="bar-fill ${colorForPercent(cpuLoadPct)}" style="width:${cpuLoadPct}%"></div></div>
            <div class="dev-metric-sub">avg: <b>${fmt(i.load_1m, 2)}</b> / ${fmt(i.load_5m, 2)} / ${fmt(i.load_15m, 2)}</div>
          </div>
          <div class="dev-metric mem">
            <div class="dev-metric-row">
              <div class="dev-metric-label">MEMORY</div>
              <div class="dev-metric-value">${memPct}<span class="unit">%</span></div>
            </div>
            <div class="bar"><div class="bar-fill ${colorForPercent(memPct)}" style="width:${memPct}%"></div></div>
            <div class="dev-metric-sub"><b>${fmt(i.mem_used_gb, 1)}</b> / ${fmt(i.mem_total_gb, 1)} GB used</div>
          </div>
          <div class="dev-metric temp">
            <div class="dev-metric-row">
              <div class="dev-metric-label">CPU TEMP</div>
              <div class="dev-metric-value">${tempC ?? '—'}<span class="unit">°C</span></div>
            </div>
            <div class="bar"><div class="bar-fill ${tempC >= 75 ? 'crit' : tempC >= 60 ? 'warn' : 'amber'}" style="width:${tempC ? Math.min(100, tempC) : 0}%"></div></div>
            <div class="dev-metric-sub">status: ${tempStatusHtml}</div>
          </div>
          <div class="dev-metric disk">
            <div class="dev-metric-row">
              <div class="dev-metric-label">DISK USAGE</div>
              <div class="dev-metric-value">${diskMaxPct}<span class="unit">%</span></div>
            </div>
            <div class="bar"><div class="bar-fill ${colorForPercent(diskMaxPct)}" style="width:${diskMaxPct}%"></div></div>
            <div class="dev-metric-sub"><b>${disks.length}</b> volume${disks.length===1?'':'s'} · max ${diskMaxPct}%</div>
          </div>
        </div>
      </div>
    `;

    if (ports.length) {
      html += `<div class="syno-section-title">OPEN PORTS · ${ports.length}</div>`;
      html += '<div class="port-grid">' + ports.map(p => `
        <div class="port-chip ${p.public ? 'pub' : ''}" title="${escape(p.bind || '')}:${p.port}">
          <span class="port-num">${p.port}</span>
          ${p.service ? `<span class="port-svc">${escape(p.service)}</span>` : ''}
        </div>
      `).join('') + '</div>';
    }

    $('synoDetail').innerHTML = html;
  }

  /* ============================================================ */
  /* ROUTER (полная карточка с фото + 2×2 метрик)                  */
  /* ============================================================ */
  function renderRouter(r) {
    if (!r || !r.host) {
      $('routerDetail').innerHTML = '<div class="empty">// ROUTER DISABLED</div>';
      $('routerTag').textContent = 'OFF'; return;
    }
    if (!r.reachable) {
      $('routerDetail').innerHTML = `
        <div class="alert-error">${escape(r.error || 'Router unreachable')}</div>
        <div class="kv">
          <div class="k">HOST</div><div class="v mono">${escape(r.host)}</div>
        </div>`;
      $('routerTag').textContent = 'OFFLINE'; return;
    }

    $('routerTag').innerHTML = '<span class="live-dot"></span>ONLINE · ' + escape(r.host);

    const i = r.info || {};
    const cpuLoadPct = i.cpu_cores ? Math.min(100, Math.round((i.load_1m / i.cpu_cores) * 100)) : 0;
    const memPct = Math.round(i.mem_used_percent || 0);
    const tempC = i.cpu_temp_c;
    const pingMs = r.ping_ms;
    const pingPct = (pingMs !== undefined && pingMs !== null)
      ? Math.min(100, Math.max(0, (pingMs / 50) * 100)) : 0;

    let tempStatusHtml = '<span style="color:var(--tx-mid)">no sensor</span>';
    if (tempC !== undefined && tempC !== null) {
      if (tempC >= 80)      tempStatusHtml = '<span style="color:var(--crit)">⚠ HIGH</span>';
      else if (tempC >= 65) tempStatusHtml = '<span style="color:var(--warn)">WARM</span>';
      else                  tempStatusHtml = '<span style="color:var(--ok)">NORMAL</span>';
    }

    let pingStatus = '<span style="color:var(--ok)">EXCELLENT</span>';
    if (pingMs >= 20) pingStatus = '<span style="color:var(--warn)">SLOW</span>';
    else if (pingMs >= 5) pingStatus = '<span style="color:var(--info)">GOOD</span>';

    let routerUptime = '';
    if (i.uptime_sec) {
      const us = i.uptime_sec;
      const d = Math.floor(us / 86400), h = Math.floor((us % 86400) / 3600),
            m = Math.floor((us % 3600) / 60), s = us % 60;
      routerUptime = d > 0 ? `${d}d ${h}h ${m}m ${s}s` : h > 0 ? `${h}h ${m}m ${s}s` : `${m}m ${s}s`;
    } else if (i.uptime_str) {
      routerUptime = i.uptime_str;
    }
    if (!routerUptime) routerUptime = '—';

    // Сетевая нагрузка
    const routerRxRate = rateFrom(H.routerRx);
    const routerTxRate = rateFrom(H.routerTx);

    // Модель — главный акцент карточки (как у NAS)
    const modelLine = (i.model || r.model_hint || 'ROUTER').toString().toUpperCase();

    let html = `
      <div class="dev-head">
        <div class="dev-head-info">
          <div class="dev-name">${escape(modelLine)}</div>
          <div class="dev-sub"><span class="uptime-badge">UPTIME&nbsp;${escape(routerUptime)}</span></div>
        </div>
        <div class="dev-head-actions">
          ${netThroughputHtml(routerRxRate, routerTxRate)}
        </div>
      </div>
      <div class="dev-hero">
        <div class="dev-image">
          <img src="img/rt-ax89x.png" alt="Router" loading="lazy" onerror="this.parentElement.style.display='none'">
        </div>
        <div class="dev-metrics">
          <div class="dev-metric cpu">
            <div class="dev-metric-row">
              <div class="dev-metric-label">CPU LOAD</div>
              <div class="dev-metric-value">${cpuLoadPct}<span class="unit">%</span></div>
            </div>
            <div class="bar"><div class="bar-fill ${colorForPercent(cpuLoadPct)}" style="width:${cpuLoadPct}%"></div></div>
            <div class="dev-metric-sub">${i.load_1m !== undefined ? `avg: <b>${fmt(i.load_1m, 2)}</b> / ${fmt(i.load_5m, 2)} / ${fmt(i.load_15m, 2)}` : 'load avg: —'}</div>
          </div>
          <div class="dev-metric mem">
            <div class="dev-metric-row">
              <div class="dev-metric-label">MEMORY</div>
              <div class="dev-metric-value">${memPct}<span class="unit">%</span></div>
            </div>
            <div class="bar"><div class="bar-fill ${colorForPercent(memPct)}" style="width:${memPct}%"></div></div>
            <div class="dev-metric-sub">${i.mem_total_mb ? `<b>${fmt(i.mem_used_mb, 0)}</b> / ${fmt(i.mem_total_mb, 0)} MB used` : 'no SSH access'}</div>
          </div>
          <div class="dev-metric temp">
            <div class="dev-metric-row">
              <div class="dev-metric-label">CPU TEMP</div>
              <div class="dev-metric-value">${tempC ?? '—'}<span class="unit">°C</span></div>
            </div>
            <div class="bar"><div class="bar-fill ${tempC >= 80 ? 'crit' : tempC >= 65 ? 'warn' : 'amber'}" style="width:${tempC ? Math.min(100, tempC) : 0}%"></div></div>
            <div class="dev-metric-sub">status: ${tempStatusHtml}</div>
          </div>
          <div class="dev-metric disk">
            <div class="dev-metric-row">
              <div class="dev-metric-label">PING (avg)</div>
              <div class="dev-metric-value">${pingMs ?? '—'}<span class="unit">ms</span></div>
            </div>
            <div class="bar"><div class="bar-fill ${colorForPercent(pingPct)}" style="width:${pingPct}%"></div></div>
            <div class="dev-metric-sub">${r.ping_min !== undefined ? `min <b>${r.ping_min}</b> / max <b>${r.ping_max}</b> ms · ${pingStatus}` : pingStatus}</div>
          </div>
        </div>
      </div>
    `;

    // Открытые порты роутера (когда SSH доступен)
    const routerPorts = (i.ports && i.ports.flat) ? i.ports.flat() : (i.ports || []);
    if (routerPorts.length) {
      html += `<div class="syno-section-title">OPEN PORTS · ${routerPorts.length}</div>`;
      html += '<div class="port-grid">' + routerPorts.map(p => `
        <div class="port-chip ${p.public ? 'pub' : ''}" title="${escape(p.bind || '')}:${p.port}">
          <span class="port-num">${p.port}</span>
          ${p.service ? `<span class="port-svc">${escape(p.service)}</span>` : ''}
        </div>
      `).join('') + '</div>';
    }

    if (r.ssh_ok === false && r.ssh_error) {
      html += `<div class="alert-error" style="margin-top:12px;">SSH failed: ${escape(r.ssh_error.toString().slice(0, 120))}</div>`;
    }

    $('routerDetail').innerHTML = html;
  }


  /* ============================================================ */
  /* GITHUB RELEASES                                               */
  /* ============================================================ */
  function relDate(iso) {
    if (!iso) return '—';
    try {
      const d = new Date(iso);
      const dd = String(d.getDate()).padStart(2, '0');
      const mm = String(d.getMonth() + 1).padStart(2, '0');
      const yyyy = d.getFullYear();
      return `${dd}.${mm}.${yyyy}`;
    } catch { return iso; }
  }
  function proxyButtonsHtml(proxyLinks) {
    proxyLinks = proxyLinks || {};
    // 4 слота. Заполненные показываются как кнопки; пустые — как placeholder.
    const slots = [
      { name: 'RIGA',      url: proxyLinks.riga      || '' },
      { name: 'AMSTERDAM', url: proxyLinks.amsterdam || '' },
      { name: '',          url: '' },
      { name: '',          url: '' }
    ];
    const renderSlot = (s) => {
      if (!s.name) {
        return `<div class="proxy-btn empty"><span>+ EMPTY SLOT</span></div>`;
      }
      if (!s.url) {
        return `<div class="proxy-btn empty"><span>${escape(s.name)} · NO URL</span></div>`;
      }
      return `<a class="proxy-btn server" href="${escape(s.url)}" target="_blank" rel="noopener noreferrer">
        <span>${escape(s.name)}</span>
      </a>`;
    };
    return `
      <div class="proxy-buttons">
        <div class="proxy-label">VPS SERVER</div>
        ${slots.map(renderSlot).join('')}
      </div>
    `;
  }

  function renderReleases(r, proxyLinks) {
    const btns = proxyButtonsHtml(proxyLinks);
    if (!r || r.status === 'scanning' || !r.items) {
      $('releasesTag').textContent = r?.status === 'scanning' ? 'SCANNING...' : '—';
      $('releasesDetail').innerHTML = btns + '<div class="empty">// FETCHING FROM GITHUB...</div>';
      return;
    }
    const items = Array.isArray(r.items) ? r.items : [];
    const flat = items.flat ? items.flat() : items;
    $('releasesTag').textContent = `${flat.length} repos · cached 10m`;

    // Пилл-блок (stable / pre) — кликабельная если url есть
    const renderPill = (cls, label, rel) => {
      if (!rel) {
        return `<div class="rel-line ${cls} empty">
          <div class="rel-label">${label}</div>
          <div class="rel-tag" style="color:var(--tx-mid);">—</div>
          <div class="rel-date">—</div>
        </div>`;
      }
      const inner = `
        <div class="rel-label">${label}</div>
        <div class="rel-tag">${escape(rel.tag)}</div>
        <div class="rel-date">${relDate(rel.published)}</div>`;
      return rel.url
        ? `<a class="rel-line ${cls}" href="${escape(rel.url)}" target="_blank" rel="noopener noreferrer">${inner}</a>`
        : `<div class="rel-line ${cls}">${inner}</div>`;
    };

    const repoNames = {
      'MHSanaei/3x-ui':           '3X-UI',
      'XTLS/Xray-core':           'Xray-Core',
      'amnezia-vpn/amneziawg-go': 'AmneziaWG',
      'apernet/hysteria':         'Hysteria2'
    };

    $('releasesDetail').innerHTML = btns + `
      <div class="rel-grid">
        ${flat.map(it => {
          const displayName = repoNames[it.repo] || it.repo;
          if (it.error) {
            return `<div class="rel-card">
              <div class="rel-repo">${escape(displayName)}</div>
              <div class="alert-error">${escape(it.error)}</div>
            </div>`;
          }
          return `<div class="rel-card">
            <div class="rel-repo">${escape(displayName)}</div>
            <div class="rel-versions">
              ${renderPill('stable', 'STABLE',  it.stable)}
              ${renderPill('pre',    'PRE-REL', it.prerelease)}
            </div>
          </div>`;
        }).join('')}
      </div>
    `;
  }

  /* ============================================================ */
  /* WINDOWS UPDATES                                               */
  /* ============================================================ */
  function renderUpdates(u) {
    if (!u || u.status === 'scanning') {
      $('updatesTag').textContent = u?.status === 'scanning' ? 'SCANNING...' : '—';
      $('updatesDetail').innerHTML = '<div class="empty">// CHECKING WINDOWS UPDATE...</div>';
      return;
    }
    if (u.error) {
      $('updatesTag').textContent = 'ERROR';
      $('updatesDetail').innerHTML = `<div class="alert-error">${escape(u.error)}</div>`;
      return;
    }
    const items = Array.isArray(u.items) ? u.items : (u.items ? u.items : []);
    const flat = items.flat ? items.flat() : items;
    const n = u.available || 0;
    $('updatesTag').textContent = `cached 30m`;
    $('updatesDetail').innerHTML = `
      <div class="upd-summary">
        <div class="upd-count ${n === 0 ? 'zero' : ''}">${n}</div>
        <div class="upd-meta">
          обновлений доступно<br>
          из них критических: <b>${u.critical || 0}</b><br>
          скан: <b>${escape(u.scanned_at || '—')}</b>
        </div>
      </div>
      ${flat.length ? `<div class="upd-list">${flat.map(i => `
        <div class="upd-item${i.critical ? ' crit' : ''}">
          <div class="t">${escape(i.title || '—')}</div>
          <div class="meta">${i.size_mb ? i.size_mb + ' MB' : '—'}${i.critical ? ' · CRITICAL' : ''}</div>
        </div>
      `).join('')}</div>` : (n === 0 ? '<div class="empty" style="color:var(--ok);">// SYSTEM UP-TO-DATE</div>' : '')}
    `;
  }

  /* ============================================================ */
  /* SYSTEM ERRORS                                                 */
  /* ============================================================ */
  function renderSysErrors(e) {
    if (!e || e.status === 'scanning') {
      $('errorsTag').textContent = e?.status === 'scanning' ? 'SCANNING...' : '—';
      $('errorsDetail').innerHTML = '<div class="empty">// READING EVENT LOG...</div>';
      return;
    }
    const items = Array.isArray(e.items) ? e.items : (e.items ? e.items : []);
    const flat = items.flat ? items.flat() : items;
    const crits = flat.filter(x => x.level === 'CRITICAL').length;
    $('errorsTag').innerHTML = crits > 0
      ? `<span style="color:var(--crit);">${crits} CRIT</span> · ${flat.length} total`
      : `${flat.length} errors`;
    if (!flat.length) {
      $('errorsDetail').innerHTML = '<div class="empty" style="color:var(--ok);">// NO ERRORS IN LAST 2 DAYS</div>';
      return;
    }
    $('errorsDetail').innerHTML = `
      <div class="err-list">
        ${flat.map(i => `
          <div class="err-item ${i.level === 'CRITICAL' ? 'critical' : ''}">
            <div class="t">
              <span class="level ${i.level === 'CRITICAL' ? 'critical' : 'error'}">${i.level}</span>
              ${escape(i.message || '—')}
            </div>
            <div class="meta">${escape(i.time)} · ${escape(i.source)} · ${escape(i.log)} · #${i.event_id}</div>
          </div>
        `).join('')}
      </div>
    `;
  }

  /* ============================================================ */
  /* JUNK CLEANER                                                  */
  /* ============================================================ */
  function bytesShort(n) {
    if (!n || n < 0) return { v: '0', u: 'B' };
    const u = ['B','KB','MB','GB','TB']; let i = 0; let x = n;
    while (x >= 1024 && i < u.length - 1) { x /= 1024; i++; }
    return { v: x >= 100 ? x.toFixed(0) : x.toFixed(1), u: u[i] };
  }

  function renderJunk(j) {
    if (!j) {
      $('junkTag').textContent = 'SCANNING...';
      $('junkTotal').innerHTML = '—<span class="unit">GB</span>';
      $('junkMeta').textContent = 'Сканирование при каждом запуске занимает ~5-10 сек.';
      $('junkList').innerHTML = '<div class="empty">// JUNK DATA NOT YET COLLECTED</div>';
      $('btnClean').disabled = true;
      return;
    }
    const cats = Array.isArray(j.categories) ? j.categories : (j.categories ? [j.categories] : []);
    const flat = cats.flat ? cats.flat() : cats;

    const total = j.total_bytes || 0;
    const totalShort = bytesShort(total);
    $('junkTotal').innerHTML = `${totalShort.v}<span class="unit">${totalShort.u}</span>`;

    const nonZero = flat.filter(c => (c.size_bytes || 0) > 0).length;
    $('junkTag').textContent = `${flat.length} cats · ${nonZero} non-empty`;
    $('junkMeta').innerHTML = `<b>${nonZero}</b> категорий с данными · скан: <b>${escape(j.scanned_at || '—')}</b>`;

    if (!_isCleaning) $('btnClean').disabled = total < 1024 * 1024;

    // sort: largest first
    const sorted = [...flat].sort((a, b) => (b.size_bytes || 0) - (a.size_bytes || 0));
    $('junkList').innerHTML = sorted.map(c => {
      const sz = bytesShort(c.size_bytes || 0);
      const isZero = !(c.size_bytes && c.size_bytes > 0);
      return `
        <div class="junk-row${isZero ? ' empty' : ''}">
          <div class="junk-icon">${escape(c.icon || '·')}</div>
          <div class="junk-name">
            <div class="n">${escape(c.name)}</div>
            <div class="p">${escape(c.path)}</div>
          </div>
          <div class="junk-size${isZero ? ' zero' : ''}">${sz.v} ${sz.u}</div>
        </div>
      `;
    }).join('');

    // last cleanup info
    const lc = j.last_cleanup;
    if (lc) {
      const freed = bytesShort(lc.freed_bytes || 0);
      $('lastCleanBox').innerHTML = `
        <div class="last-clean">
          <b>LAST CLEAN:</b> ${escape(lc.finished_at || '—')}<br>
          Освобождено: <b>${freed.v} ${freed.u}</b> за ${lc.elapsed_sec ?? '?'}s${lc.dry_run ? ' (DRY-RUN)' : ''}
        </div>
      `;
    } else {
      $('lastCleanBox').innerHTML = '';
    }
  }

  /* ---- Cleaning state machine ------------------------------------ */
  let _isCleaning      = false;
  let _cleanTick       = null;
  let _cleanStart      = 0;
  let _cleanPrevTs     = null;   // last_cleanup.finished_at before this run
  let _cleanConfirmTmo = null;   // pending double-click confirm timer

  function _sendSignal() {
    const blob = new Blob(['cleanup-' + Date.now()], { type: 'text/plain' });
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href = url; a.download = 'cybfortress_cleanup.signal';
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  function _cpSetLabel(text) {
    const lbl = $('cpLabel');
    if (lbl) lbl.textContent = text;
  }

  function _cleanFinish() {
    clearInterval(_cleanTick); _cleanTick = null;
    _isCleaning = false;
    const fill = $('cpFill');
    const lbl  = $('cpLabel');
    if (fill) fill.classList.add('done');
    if (lbl)  { lbl.textContent = 'ОЧИСТКА ЗАВЕРШЕНА ✓'; lbl.classList.add('done'); }
    const span = $('btnClean')?.querySelector('span:last-child');
    if (span) span.textContent = 'ОЧИСТИТЬ МУСОР';
    setTimeout(() => {
      const cp = $('cleanProgress');
      if (cp) cp.style.display = 'none';
      if (fill) fill.classList.remove('done');
      if (lbl)  lbl.classList.remove('done');
      const btn = $('btnClean');
      if (btn) btn.disabled = false;
    }, 7000);
  }

  function _tickCleaning() {
    const elapsed = Math.floor((Date.now() - _cleanStart) / 1000);
    const mm = String(Math.floor(elapsed / 60)).padStart(2,'0');
    const ss = String(elapsed % 60).padStart(2,'0');
    const el = $('cpElapsed');
    if (el) el.textContent = `${mm}:${ss}`;

    // Честные фазовые метки — не врём о процентах
    if      (elapsed <  8)  _cpSetLabel('ОЖИДАНИЕ UAC...');
    else if (elapsed < 25)  _cpSetLabel('ЗАПУСК ОЧИСТКИ...');
    else if (elapsed < 90)  _cpSetLabel('ОЧИСТКА ФАЙЛОВ...');
    else if (elapsed < 240) _cpSetLabel('ГЛУБОКАЯ ОЧИСТКА...');
    else                    _cpSetLabel('ФИНАЛИЗАЦИЯ...');

    // Детектор завершения: timestamp last_cleanup изменился
    const curTs = window.SYSTEM_DATA?.junk?.last_cleanup?.finished_at;
    if (curTs && curTs !== _cleanPrevTs) { _cleanFinish(); return; }

    // Защитный таймаут: 20 минут
    if (elapsed > 1200) {
      clearInterval(_cleanTick); _cleanTick = null;
      _isCleaning = false;
      _cpSetLabel('ТАЙМАУТ — ОТКРОЙТЕ КОНСОЛЬ');
      const fill = $('cpFill');
      if (fill) { fill.classList.remove('done'); fill.style.animation = 'none'; }
      const btn = $('btnClean');
      if (btn) { btn.disabled = false; btn.querySelector('span:last-child').textContent = 'ОЧИСТИТЬ МУСОР'; }
    }
  }

  function triggerCleanup() {
    if (_isCleaning) return;
    _isCleaning  = true;
    _cleanStart  = Date.now();
    _cleanPrevTs = window.SYSTEM_DATA?.junk?.last_cleanup?.finished_at || null;

    _sendSignal();

    const btn  = $('btnClean');
    const span = btn?.querySelector('span:last-child');
    if (btn)  btn.disabled = true;
    if (span) span.textContent = 'ОЧИСТКА...';
    const cp   = $('cleanProgress');
    if (cp) cp.style.display = 'block';
    const fill = $('cpFill');
    if (fill) { fill.classList.remove('done'); fill.style.animation = ''; }
    const lbl = $('cpLabel');
    if (lbl)  lbl.classList.remove('done');
    const el = $('cpElapsed');
    if (el) el.textContent = '00:00';
    _cpSetLabel('ОЖИДАНИЕ UAC...');

    _cleanTick = setInterval(_tickCleaning, 1000);
  }

  /* ============================================================ */
  /* THEME TOGGLE                                                  */
  /* ============================================================ */
  function applyTheme(theme) {
    document.body.classList.toggle('theme-light', theme === 'light');
    const btn = $('themeToggle');
    if (btn) btn.textContent = (theme === 'light' ? '☾' : '☀');
    try { localStorage.setItem('cyberfortress.theme', theme); } catch {}

    // re-render charts so gradient backgrounds match new theme
    if (historyChart) { historyChart.destroy(); historyChart = null; }
    if (netChart)     { netChart.destroy();     netChart = null; }
    if (window.SYSTEM_DATA) render(window.SYSTEM_DATA);
  }
  function initTheme() {
    let theme = 'dark';
    try { theme = localStorage.getItem('cyberfortress.theme') || 'dark'; } catch {}
    applyTheme(theme);
    const btn = $('themeToggle');
    if (btn) {
      btn.addEventListener('click', () => {
        const cur = document.body.classList.contains('theme-light') ? 'light' : 'dark';
        applyTheme(cur === 'light' ? 'dark' : 'light');
      });
    }
    const cleanBtn = $('btnClean');
    if (cleanBtn) {
      cleanBtn.addEventListener('click', () => {
        if (_isCleaning) return;
        if (_cleanConfirmTmo) {
          // Second click within 3 s → go
          clearTimeout(_cleanConfirmTmo); _cleanConfirmTmo = null;
          const s = cleanBtn.querySelector('span:last-child');
          if (s) s.textContent = 'ОЧИСТИТЬ МУСОР';
          cleanBtn.classList.remove('confirming');
          triggerCleanup();
        } else {
          // First click → ask for second confirm
          const s = cleanBtn.querySelector('span:last-child');
          if (s) s.textContent = 'НАЖМИ ЕЩЁ РАЗ';
          cleanBtn.classList.add('confirming');
          _cleanConfirmTmo = setTimeout(() => {
            _cleanConfirmTmo = null;
            if (s) s.textContent = 'ОЧИСТИТЬ МУСОР';
            cleanBtn.classList.remove('confirming');
          }, 3000);
        }
      });
    }

    // Scroll-to-top
    const sBtn = $('scrollTop');
    if (sBtn) {
      const onScroll = () => {
        if (window.scrollY > 400) sBtn.classList.add('visible');
        else sBtn.classList.remove('visible');
      };
      window.addEventListener('scroll', onScroll, { passive: true });
      onScroll();
      sBtn.addEventListener('click', () => {
        window.scrollTo({ top: 0, behavior: 'smooth' });
      });
    }
  }

  /* ============================================================ */
  /* AGE TICKER                                                    */
  /* ============================================================ */
  function startAgeTicker() {
    setInterval(() => {
      const D = window.SYSTEM_DATA;
      if (D?.meta?.generated_iso) {
        $('metaAge').innerHTML = relTime(D.meta.generated_iso) + '<span class="live-tick"></span>';
      }
    }, 1000);
  }

  /* ============================================================ */
  /* LIVE DATA RELOAD (no page refresh)                            */
  /* ============================================================ */
  const RELOAD_INTERVAL_MS = 3000;
  $('reloadInterval').textContent = (RELOAD_INTERVAL_MS / 1000) + 's';

  function reloadData() {
    return new Promise((resolve) => {
      const old = document.getElementById('telemetry-script');
      if (old) old.remove();
      const s = document.createElement('script');
      s.id = 'telemetry-script';
      s.src = `../data/system-data.js?_=${Date.now()}`;
      s.onload = () => resolve(window.SYSTEM_DATA);
      s.onerror = () => resolve(null);
      document.body.appendChild(s);
    });
  }

  function startLiveReload() {
    setInterval(async () => {
      const D = await reloadData();
      if (D) {
        const bs = $('bootscreen');
        if (bs && bs.style.display !== 'none') bs.style.display = 'none';
        render(D);
      }
    }, RELOAD_INTERVAL_MS);
  }

  /* ============================================================ */
  /* BOOT                                                          */
  /* ============================================================ */
  function boot() {
    initTheme();
    if (window.SYSTEM_DATA) {
      render(window.SYSTEM_DATA);
    } else {
      $('bootscreen').style.display = 'grid';
    }
    startAgeTicker();
    startLiveReload();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
