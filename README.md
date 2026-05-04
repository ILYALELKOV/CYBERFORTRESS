# CYBERFORTRESS // SYSTEM CONTROL

Live-дашборд состояния ПК, роутера и Synology NAS в кибер-стилистике.

> Все IP, имена и порты в этом README — **примеры**. Реальные значения подставляются через `.env` и `config.json`.

## ⚡ Быстрый старт (1 клик)

Двойной клик по **`START.bat`** — всё запускается автоматически:
1. В фоне стартует телеметрия (обновление каждые 3 сек).
2. В браузере открывается `dashboard.html`.
3. Дашборд САМ перечитывает данные без перезагрузки страницы.

Для остановки — закрытие чёрного окна `START.bat` (любая клавиша).

```
┌─────────────────────────────────────────────────────────────────────┐
│ START.bat ──┬── Get-SystemInfo.ps1 -Watch  →  system-data.js  ◄──┐  │
│             └── start dashboard.html       (auto-refetch every 3s)  │
└─────────────────────────────────────────────────────────────────────┘
```

## Состав

| Файл | Назначение |
|---|---|
| **`START.bat`** | **Главный лаунчер. Двойной клик — всё работает.** |
| `Get-SystemInfo.ps1` | Опрашивает ПК (CIM/WMI), роутер (ping/ARP), NAS (SSH) и пишет `system-data.js` |
| `config.json` | Настройки IP/SSH NAS, имя оператора, заголовок |
| `dashboard.html` | UI: гейджи, live-графики, история CPU/RAM/GPU, sparklines |
| `system-data.js` | Генерируется скриптом, дашборд подхватывает каждые 3 сек |

---

## 1. Настройка `config.json`

В файле `config.json` заполняются параметры:

```json
{
  "synology": {
    "enabled": true,
    "host": "192.168.X.X",      ← пример: IP NAS в локальной сети
    "user": "admin",            ← пример: SSH-пользователь NAS
    "port": 22,
    "sshKeyPath": ""            ← путь к id_rsa, если ключ не в стандартном месте
  },
  "router": {
    "enabled": true,
    "host": "",                 ← пусто = авто (default gateway)
    "model": "ASUS"
  },
  "dashboard": {
    "title": "CYBERFORTRESS // SYSTEM CONTROL",
    "operator": "OPERATOR"
  }
}
```

### Важно про SSH к Synology

PowerShell использует встроенный `ssh.exe` (есть в Windows 10/11 из коробки).

**Авторизация — только по ключу**, без пароля (BatchMode), иначе скрипт зависнет.

Если ключа нет — он генерируется и публичная часть копируется на NAS:

```powershell
# 1) Генерация ключа (если нет)
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_ed25519

# 2) Включение SSH в DSM:
#    Control Panel → Terminal & SNMP → Enable SSH service

# 3) Копирование публичного ключа на NAS (USER и HOST — примеры):
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh USER@192.168.X.X `
  "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"

# 4) Проверка входа без пароля:
ssh USER@192.168.X.X "uname -a"
```

Для использования ключа из нестандартного места — путь прописывается в `sshKeyPath`.

При отсутствии NAS / роутера соответствующее `"enabled": false` отключает сборщик.

---

## 2. Первый запуск

В PowerShell из папки со скриптами:

```powershell
# разрешить запуск (один раз для текущей сессии)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# одноразовый сбор + автоткрытие дашборда
.\Get-SystemInfo.ps1 -Open
```

Ожидаемый вывод:

```
==================================================
  CYBERFORTRESS // Telemetry Collector
==================================================

[+] Сбор данных ОС...
[+] CPU...
[+] RAM...
[+] GPU...
[+] Диски...
[+] Материнская плата...
[+] Сеть...
[+] Роутер...
[+] Synology NAS (192.168.X.X)...

[OK] Снепшот сохранён: .\system-data.js
[+] Открытие dashboard...
```

---

## 3. Live-режим (рекомендуется)

Для постоянно обновляющегося дашборда:

```powershell
# обновление каждые 5 секунд
.\Get-SystemInfo.ps1 -Watch

# или каждые 10 секунд
.\Get-SystemInfo.ps1 -Watch -Interval 10
```

Скрипт работает в цикле, пишет `system-data.js`. После открытия `dashboard.html` в браузере достаточно обновить страницу (F5) — отобразятся свежие данные. Время в правом верхнем углу (`SNAPSHOT: NOW / 5s ago / ...`) показывает актуальность.

> **Авто-рефреш страницы.** Добавляется в `<head>` `dashboard.html`:
> ```html
> <meta http-equiv="refresh" content="5">
> ```

---

## 4. Что собирается

### С ПК (через CIM/WMI):
- ОС: версия, билд, аптайм, дата установки, последний boot
- CPU: модель, архитектура, ядра/потоки, частоты, кэш, текущая загрузка
- RAM: модули в каждом слоте (бренд, P/N, скорость, тип DDR)
- GPU: модель, драйвер, разрешение, refresh rate; **при наличии `nvidia-smi`** — live util/temp/power/VRAM
- Диски: физические (SSD/HDD, S/N, health) + логические (свободно/занято)
- Материнка + BIOS: вендор, модель, версия, дата
- Сеть: интерфейсы, MAC, IPv4/IPv6, RX/TX, gateway, DNS, внешний IP

### С роутера (через ping + ARP):
- Доступность, latency (avg/min/max + история на графике)
- Все устройства в LAN из ARP-таблицы (IP, MAC, тип)
- Проверка интернета (DNS на 8.8.8.8:53)

### С Synology NAS (через SSH в один батч):
- Hostname, kernel, uptime, load average (1/5/15 мин)
- CPU модель, ядра, температура (если доступна через thermal_zone)
- RAM: total / used / free, %
- Volumes (df -h): размер, занято, mount point
- Кол-во процессов

---

## 5. Архитектура и обоснование

**Зачем разделены сборщик и UI.**
Браузер не может сам опрашивать WMI или ходить по SSH из песочницы. PowerShell — может. Поэтому: PS1 пишет статичный JS-файл с глобальной переменной `window.SYSTEM_DATA`, HTML подгружает его обычным `<script src="system-data.js">`. Никаких CORS, никакого локального сервера.

**Один SSH-вызов на NAS.** Все команды (`hostname`, `uname`, `free`, `df`, `cat /proc/...`) объединены в один скрипт с маркерами `===SECTION===` и парсятся в PS1. Это экономит ~3 секунды и одно SSH-соединение на снепшот.

**Адаптив.** На десктопе — 4 колонки гейджей, на планшете — 2, на мобильном — 1. CRT-сканлайны, шум через SVG-фильтр, бэкдроп-блюр на карточках.

---

## 6. Возможные проблемы

| Симптом | Решение |
|---|---|
| `Get-SystemInfo.ps1 cannot be loaded because running scripts is disabled` | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| `ssh: command not found` | Установка OpenSSH-клиента: Settings → Apps → Optional features → OpenSSH Client |
| NAS показывает `SSH failed: Permission denied` | Ключ не настроен. См. раздел про SSH выше. |
| `BOOTSCREEN: NO TELEMETRY DATA` в браузере | `system-data.js` не сгенерирован. Запуск PS1 решает проблему. |
| Файл `dashboard.html` пустой при открытии локально | Подойдёт любой современный браузер (Chrome/Firefox/Edge), `file://` работает |
| GPU не показывает live util/temp | Установлен только встроенный драйвер, либо `nvidia-smi` не в PATH. Не критично — статичные данные всё равно есть. |
| Внешний IP не определился | Нет интернета или провайдер блокирует `api.ipify.org`. Не критично. |

---

## 7. Безопасность

- Файл `system-data.js` содержит IP, MAC-адреса, серийники железа, hostname NAS. **Не должен попадать в публичный репозиторий.**
- `config.json` содержит IP NAS и юзера. Также приватно.
- SSH-ключи хранятся в `~/.ssh` с правами 600. Скрипт использует `BatchMode=yes` — пароль никогда не запрашивается в открытую.
- Дашборд — статичный HTML без бэкенда. Никаких сетевых запросов наружу, кроме шрифтов Google и CDN Chart.js (могут быть скачаны локально для устранения зависимости).

---

## 8. Структура файлов после первого запуска

```
sysdash/
├── Get-SystemInfo.ps1   ← запуск
├── config.json          ← редактирование под себя
├── dashboard.html       ← открывается в браузере
├── system-data.js       ← генерируется автоматически
└── README.md            ← этот файл
```

В случае ошибок — см. stderr скрипта, он не глотает ошибки молча.
