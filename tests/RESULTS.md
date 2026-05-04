# CYBERFORTRESS // TEST RESULTS

**Date:** 2026-05-02 17:50:58

## Summary - ALL PASSED

| Suite | Passed | Failed |
|-------|--------|--------|
| PowerShell parsers | 25 | 0 |
| JavaScript helpers | 61 | 0 |
| **Total** | **86** | **0** |

## PowerShell - Parsing Logic

**Result:** All passed | Passed: 25 | Failed: 0

| Status | Test |
|--------|------|
| PASS | SSH parser: single section |
| PASS | SSH parser: multiple sections |
| PASS | SSH parser: multiline section value |
| PASS | SSH parser: empty section |
| PASS | SSH parser: END section not in result |
| PASS | SSH parser: empty output returns empty hash |
| PASS | SSH parser: whitespace is trimmed |
| PASS | SSH parser: real ASUS output |
| PASS | SSH parser: CRLF line endings handled |
| PASS | SSH parser: END marker presence = success detection |
| PASS | SSH parser: no END marker = failure detected |
| PASS | Load-Env: basic KEY=VALUE |
| PASS | Load-Env: comment line ignored |
| PASS | Load-Env: blank lines ignored |
| PASS | Load-Env: double quotes stripped |
| PASS | Load-Env: single quotes stripped |
| PASS | Load-Env: equals sign inside value preserved |
| PASS | Load-Env: spaces around = trimmed |
| PASS | Load-Env: multiple keys parsed |
| PASS | CR strip: removes \r from command |
| PASS | CR strip: clean command unchanged |
| PASS | Ping: PS7 .Latency property used |
| PASS | Ping: PS5 .ResponseTime property used |
| PASS | Ping: unknown object returns 0 |
| PASS | Ping: Latency takes priority over ResponseTime |

## JavaScript - Helper Functions

**Result:** All passed | Passed: 61 | Failed: 0

| Status | Test |
|--------|------|
| PASS | bytes: 0 → "0 B" |
| PASS | bytes: null → "0 B" |
| PASS | bytes: undefined → "0 B" |
| PASS | bytes: 512 → "512.0 B" |
| PASS | bytes: 1024 → "1.0 KB" |
| PASS | bytes: 1536 → "1.5 KB" |
| PASS | bytes: 1 MB |
| PASS | bytes: 1 GB |
| PASS | bytes: 1.5 GB |
| PASS | bytes: 1 TB |
| PASS | bytesPerSec: 0 → "0 B/s" |
| PASS | bytesPerSec: negative → "0 B/s" |
| PASS | bytesPerSec: 1 KB/s |
| PASS | bytesPerSec: 1 MB/s |
| PASS | bytesPerSec: 1 GB/s |
| PASS | fmt: null → "—" |
| PASS | fmt: undefined → "—" |
| PASS | fmt: NaN → "—" |
| PASS | fmt: 0 → "0.0" |
| PASS | fmt: 3.14159 d=2 → "3.14" |
| PASS | fmt: "42" строка → "42.0" |
| PASS | fmt: d=0 округление |
| PASS | safe: null → "—" |
| PASS | safe: undefined → "—" |
| PASS | safe: "" → "—" |
| PASS | safe: 0 → 0 (falsy но валид) |
| PASS | safe: false → false |
| PASS | safe: "hello" → "hello" |
| PASS | safe: кастомный fallback |
| PASS | escape: нет спецсимволов |
| PASS | escape: < и > |
| PASS | escape: & |
| PASS | escape: двойная кавычка |
| PASS | escape: одинарная кавычка |
| PASS | escape: null → "" |
| PASS | escape: XSS payload |
| PASS | escape: все символы вместе |
| PASS | relTime: null/undefined → "—" |
| PASS | relTime: 2 сек назад → NOW |
| PASS | relTime: 30 сек назад → "30s ago" |
| PASS | relTime: 5 мин назад → "5m ago" |
| PASS | relTime: 2 часа назад → "2h ago" |
| PASS | relTime: 3 дня назад → "3d ago" |
| PASS | colorForPercent: 0 → "" |
| PASS | colorForPercent: 69 → "" |
| PASS | colorForPercent: 70 → warn |
| PASS | colorForPercent: 89 → warn |
| PASS | colorForPercent: 90 → crit |
| PASS | colorForPercent: 100 → crit |
| PASS | statusByLoad: 0 → OPERATIONAL |
| PASS | statusByLoad: 69 → OPERATIONAL |
| PASS | statusByLoad: 70 → WARNING |
| PASS | statusByLoad: 89 → WARNING |
| PASS | statusByLoad: 90 → CRITICAL |
| PASS | statusByLoad: 100 → CRITICAL |
| PASS | gpuArr: null → [] |
| PASS | gpuArr: undefined → [] |
| PASS | gpuArr: массив пропускается |
| PASS | gpuArr: пустой массив пропускается |
| PASS | gpuArr: объект → оборачивается |
| PASS | gpuArr: число → оборачивается |