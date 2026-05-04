'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// Функции скопированы из dashboard.js (внутри IIFE — не импортируются напрямую)
// ─────────────────────────────────────────────────────────────────────────────

const fmt   = (n, d = 1) => (n === null || n === undefined || isNaN(n)) ? '—' : Number(n).toFixed(d);
const safe  = (v, fb = '—') => (v === null || v === undefined || v === '') ? fb : v;
const escape = (s) => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));

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
  if (sec < 5)    return 'NOW';
  if (sec < 60)   return sec + 's ago';
  if (sec < 3600) return Math.floor(sec / 60) + 'm ago';
  if (sec < 86400)return Math.floor(sec / 3600) + 'h ago';
  return Math.floor(sec / 86400) + 'd ago';
}
function colorForPercent(p) {
  if (p >= 90) return 'crit';
  if (p >= 70) return 'warn';
  return '';
}
function statusByLoad(p) {
  if (p >= 90) return { led: 'crit', label: 'CRITICAL', class: 'crit' };
  if (p >= 70) return { led: 'warn', label: 'WARNING',  class: 'warn' };
  return { led: '', label: 'OPERATIONAL', class: '' };
}
function gpuArr(g) {
  if (!g) return [];
  if (Array.isArray(g)) return g;
  return [g];
}

// ─────────────────────────────────────────────────────────────────────────────
// Мини-раннер (без зависимостей)
// ─────────────────────────────────────────────────────────────────────────────
let passed = 0, failed = 0;
const results = [];

function test(name, fn) {
  try {
    fn();
    passed++;
    results.push({ ok: true, name });
  } catch (e) {
    failed++;
    results.push({ ok: false, name, error: e.message });
  }
}
function eq(actual, expected, msg) {
  if (actual !== expected)
    throw new Error(`${msg ? msg + '\n' : ''}  expected: ${JSON.stringify(expected)}\n  got:      ${JSON.stringify(actual)}`);
}
function deepEq(actual, expected, msg) {
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(`${msg ? msg + '\n' : ''}  expected: ${JSON.stringify(expected)}\n  got:      ${JSON.stringify(actual)}`);
}

// ─────────────────────────────────────────────────────────────────────────────
// bytes()
// ─────────────────────────────────────────────────────────────────────────────
test('bytes: 0 → "0 B"',         () => eq(bytes(0),         '0 B'));
test('bytes: null → "0 B"',      () => eq(bytes(null),      '0 B'));
test('bytes: undefined → "0 B"', () => eq(bytes(undefined), '0 B'));
test('bytes: 512 → "512.0 B"',   () => eq(bytes(512),       '512.0 B'));
test('bytes: 1024 → "1.0 KB"',   () => eq(bytes(1024),      '1.0 KB'));
test('bytes: 1536 → "1.5 KB"',   () => eq(bytes(1536),      '1.5 KB'));
test('bytes: 1 MB',              () => eq(bytes(1024 ** 2),  '1.0 MB'));
test('bytes: 1 GB',              () => eq(bytes(1024 ** 3),  '1.0 GB'));
test('bytes: 1.5 GB',            () => eq(bytes(1.5 * 1024 ** 3), '1.5 GB'));
test('bytes: 1 TB',              () => eq(bytes(1024 ** 4),  '1.0 TB'));

// ─────────────────────────────────────────────────────────────────────────────
// bytesPerSec()
// ─────────────────────────────────────────────────────────────────────────────
test('bytesPerSec: 0 → "0 B/s"',       () => eq(bytesPerSec(0),        '0 B/s'));
test('bytesPerSec: negative → "0 B/s"',() => eq(bytesPerSec(-500),     '0 B/s'));
test('bytesPerSec: 1 KB/s',            () => eq(bytesPerSec(1024),      '1.0 KB/s'));
test('bytesPerSec: 1 MB/s',            () => eq(bytesPerSec(1024 ** 2), '1.0 MB/s'));
test('bytesPerSec: 1 GB/s',            () => eq(bytesPerSec(1024 ** 3), '1.0 GB/s'));

// ─────────────────────────────────────────────────────────────────────────────
// fmt()
// ─────────────────────────────────────────────────────────────────────────────
test('fmt: null → "—"',           () => eq(fmt(null),      '—'));
test('fmt: undefined → "—"',      () => eq(fmt(undefined), '—'));
test('fmt: NaN → "—"',            () => eq(fmt(NaN),       '—'));
test('fmt: 0 → "0.0"',            () => eq(fmt(0),         '0.0'));
test('fmt: 3.14159 d=2 → "3.14"', () => eq(fmt(3.14159, 2),'3.14'));
test('fmt: "42" строка → "42.0"', () => eq(fmt('42'),      '42.0'));
test('fmt: d=0 округление',       () => eq(fmt(3.7, 0),    '4'));

// ─────────────────────────────────────────────────────────────────────────────
// safe()
// ─────────────────────────────────────────────────────────────────────────────
test('safe: null → "—"',              () => eq(safe(null),       '—'));
test('safe: undefined → "—"',         () => eq(safe(undefined),  '—'));
test('safe: "" → "—"',                () => eq(safe(''),         '—'));
test('safe: 0 → 0 (falsy но валид)',  () => eq(safe(0),          0));
test('safe: false → false',           () => eq(safe(false),      false));
test('safe: "hello" → "hello"',       () => eq(safe('hello'),    'hello'));
test('safe: кастомный fallback',      () => eq(safe(null, 'N/A'),'N/A'));

// ─────────────────────────────────────────────────────────────────────────────
// escape()
// ─────────────────────────────────────────────────────────────────────────────
test('escape: нет спецсимволов',     () => eq(escape('hello'),              'hello'));
test('escape: < и >',                () => eq(escape('<b>'),                '&lt;b&gt;'));
test('escape: &',                    () => eq(escape('a & b'),              'a &amp; b'));
test('escape: двойная кавычка',      () => eq(escape('"x"'),               '&quot;x&quot;'));
test('escape: одинарная кавычка',    () => eq(escape("it's"),              'it&#39;s'));
test('escape: null → ""',            () => eq(escape(null),                ''));
test('escape: XSS payload',          () => eq(
  escape('<script>alert("xss")</script>'),
  '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
));
test('escape: все символы вместе',   () => eq(
  escape(`<a href="x" onclick='y'> & </a>`),
  `&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt; &amp; &lt;/a&gt;`
));

// ─────────────────────────────────────────────────────────────────────────────
// relTime()
// ─────────────────────────────────────────────────────────────────────────────
test('relTime: null/undefined → "—"', () => {
  eq(relTime(null),      '—');
  eq(relTime(undefined), '—');
  eq(relTime(''),        '—');
});
test('relTime: 2 сек назад → NOW',    () => eq(relTime(new Date(Date.now() - 2000).toISOString()),  'NOW'));
test('relTime: 30 сек назад → "30s ago"', () => eq(relTime(new Date(Date.now() - 30000).toISOString()), '30s ago'));
test('relTime: 5 мин назад → "5m ago"',   () => eq(relTime(new Date(Date.now() - 5 * 60000).toISOString()), '5m ago'));
test('relTime: 2 часа назад → "2h ago"',  () => eq(relTime(new Date(Date.now() - 2 * 3600000).toISOString()), '2h ago'));
test('relTime: 3 дня назад → "3d ago"',   () => eq(relTime(new Date(Date.now() - 3 * 86400000).toISOString()), '3d ago'));

// ─────────────────────────────────────────────────────────────────────────────
// colorForPercent()
// ─────────────────────────────────────────────────────────────────────────────
test('colorForPercent: 0 → ""',    () => eq(colorForPercent(0),   ''));
test('colorForPercent: 69 → ""',   () => eq(colorForPercent(69),  ''));
test('colorForPercent: 70 → warn', () => eq(colorForPercent(70),  'warn'));
test('colorForPercent: 89 → warn', () => eq(colorForPercent(89),  'warn'));
test('colorForPercent: 90 → crit', () => eq(colorForPercent(90),  'crit'));
test('colorForPercent: 100 → crit',() => eq(colorForPercent(100), 'crit'));

// ─────────────────────────────────────────────────────────────────────────────
// statusByLoad()
// ─────────────────────────────────────────────────────────────────────────────
test('statusByLoad: 0 → OPERATIONAL',  () => deepEq(statusByLoad(0),  { led: '',     label: 'OPERATIONAL', class: '' }));
test('statusByLoad: 69 → OPERATIONAL', () => deepEq(statusByLoad(69), { led: '',     label: 'OPERATIONAL', class: '' }));
test('statusByLoad: 70 → WARNING',     () => deepEq(statusByLoad(70), { led: 'warn', label: 'WARNING',     class: 'warn' }));
test('statusByLoad: 89 → WARNING',     () => deepEq(statusByLoad(89), { led: 'warn', label: 'WARNING',     class: 'warn' }));
test('statusByLoad: 90 → CRITICAL',    () => deepEq(statusByLoad(90), { led: 'crit', label: 'CRITICAL',    class: 'crit' }));
test('statusByLoad: 100 → CRITICAL',   () => deepEq(statusByLoad(100),{ led: 'crit', label: 'CRITICAL',    class: 'crit' }));

// ─────────────────────────────────────────────────────────────────────────────
// gpuArr()
// ─────────────────────────────────────────────────────────────────────────────
test('gpuArr: null → []',                   () => deepEq(gpuArr(null),            []));
test('gpuArr: undefined → []',              () => deepEq(gpuArr(undefined),       []));
test('gpuArr: массив пропускается',         () => deepEq(gpuArr([{a:1},{b:2}]),   [{a:1},{b:2}]));
test('gpuArr: пустой массив пропускается',  () => deepEq(gpuArr([]),              []));
test('gpuArr: объект → оборачивается',      () => deepEq(gpuArr({name:'RTX4090'}), [{name:'RTX4090'}]));
test('gpuArr: число → оборачивается',       () => deepEq(gpuArr(42),              [42]));

// ─────────────────────────────────────────────────────────────────────────────
// Экспорт для run-tests.ps1
// ─────────────────────────────────────────────────────────────────────────────
module.exports = { passed, failed, results };
