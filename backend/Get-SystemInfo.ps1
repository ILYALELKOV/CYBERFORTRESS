# =============================================================================
# Get-SystemInfo.ps1
# CYBERFORTRESS // System Telemetry Collector
# -----------------------------------------------------------------------------
# Собирает данные о ПК, роутере и Synology NAS, генерирует system-data.js,
# который подхватывает dashboard.html.
#
# Использование:
#   .\Get-SystemInfo.ps1                        # одноразовый сбор
#   .\Get-SystemInfo.ps1 -Watch                 # цикл с интервалом 5 сек
#   .\Get-SystemInfo.ps1 -Watch -Interval 10    # цикл с интервалом 10 сек
#   .\Get-SystemInfo.ps1 -Open                  # открытие dashboard после сбора
# =============================================================================

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$OutputPath,
    [string]$EnvPath,
    [switch]$Watch,
    [int]$Interval = 5,
    [switch]$Open
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ----------------------------------------------------------------------------
# КРИТИЧНО: $PSScriptRoot может быть пустым если скрипт вызван не через -File
# (например через -Command "& '...'"). Тогда дефолтный путь подмешивается к
# C:\ — и Set-Content ругается на отказ доступа. Берём путь из MyInvocation.
# ----------------------------------------------------------------------------
$script:HereDir = $PSScriptRoot
if (-not $script:HereDir -or $script:HereDir -eq '') {
    $script:HereDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $script:HereDir -or $script:HereDir -eq '') {
    $script:HereDir = (Get-Location).Path
}

$script:RootDir = Split-Path $script:HereDir -Parent
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:RootDir 'config.json' }
if (-not $OutputPath) { $OutputPath = Join-Path $script:RootDir 'data\system-data.js' }
if (-not $EnvPath)    { $EnvPath    = Join-Path $script:RootDir '.env' }

# Force absolute paths
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$EnvPath    = [System.IO.Path]::GetFullPath($EnvPath)

# Принудительно UTF-8 для вывода в консоль (для русских строк в Windows PowerShell 5.1)
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# ----------------------------------------------------------------------------
# Синхронизированный кэш для фонового Runspace (тяжёлые операции).
# Основной цикл читает из него мгновенно, без блокировки.
# ----------------------------------------------------------------------------
$script:bgCache = [System.Collections.Hashtable]::Synchronized(@{})
$script:bgCache['junk']        = @{ status='scanning'; scanned_at=''; total_bytes=0; total_categories=0; categories=,@() }
$script:bgCache['releases']    = @{ status='scanning'; scanned_at=''; items=,@() }
$script:bgCache['updates']     = @{ status='scanning'; scanned_at=''; available=0; critical=0; items=,@() }
$script:bgCache['sysErrors']   = @{ status='scanning'; scanned_at=''; count=0; items=,@() }
$script:bgCache['forceJunk']   = $false
$script:bgCache['githubToken'] = ''
$script:bgCache['rootDir']     = ''

# Последний собранный снепшот в виде JSON-строки (для /api/data)
$script:currentSnapshotJson = ''
# Кэш медленных WMI/SSH вызовов: @{ key = @{data=...; expiresAt=[DateTime]} }
$script:slowCache = @{}
# Когда последний раз писали файл system-data.js
$script:lastFileWrite = [DateTime]::MinValue
$script:bgRunspace    = $null
$script:bgPowerShell  = $null
$script:firstSnapshot = $true   # пропускаем роутер/синолоджи на первом вызове
# Shared state between main loop and dedicated HTTP server runspace
$script:httpShared = [System.Collections.Hashtable]::Synchronized(@{
    json           = ''
    cleanupPending = $false
    cleanupPayload = $null
})
$script:httpRunspace   = $null
$script:httpPowerShell = $null

# ----------------------------------------------------------------------------
# Загрузка .env (KEY=VALUE построчно, # — комментарий)
# ----------------------------------------------------------------------------
function Load-Env {
    param([string]$Path)
    $env = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $env }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $t.Substring(0, $eq).Trim()
        $v = $t.Substring($eq + 1).Trim()
        # снять кавычки
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $env[$k] = $v
    }
    return $env
}

# ----------------------------------------------------------------------------
# Загрузка конфига
# ----------------------------------------------------------------------------
function Load-Config {
    param([string]$Path, [hashtable]$EnvVars)

    $cfg = $null
    if (Test-Path $Path) {
        try {
            $cfg = Get-Content -Raw -Path $Path | ConvertFrom-Json
        } catch {
            Write-Warning "Не удалось прочитать config.json: $_"
        }
    }
    if (-not $cfg) {
        $cfg = [pscustomobject]@{
            synology = [pscustomobject]@{ enabled=$true; host=""; user=""; port=22; sshKeyPath="" }
            router   = [pscustomobject]@{ enabled=$true; host=""; model="ASUS" }
            dashboard= [pscustomobject]@{ title="SYSTEM CONTROL"; operator="OPERATOR" }
        }
    }

    # Подмешать секреты из .env (приоритет над config.json).
    # Используем Add-Member -Force, потому что в config.json соответствующих полей
    # может не быть (host/user/port вынесены в .env).
    function Set-CfgProp {
        param($Obj, [string]$Name, $Value)
        if ($null -eq $Obj) { return }
        $Obj | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }

    if ($EnvVars) {
        if ($EnvVars['SYNOLOGY_HOST']) { Set-CfgProp $cfg.synology 'host' $EnvVars['SYNOLOGY_HOST'] }
        if ($EnvVars['SYNOLOGY_USER']) { Set-CfgProp $cfg.synology 'user' $EnvVars['SYNOLOGY_USER'] }
        if ($EnvVars['SYNOLOGY_PORT']) { Set-CfgProp $cfg.synology 'port' ([int]$EnvVars['SYNOLOGY_PORT']) }
        if ($EnvVars['SYNOLOGY_PASS']) { Set-CfgProp $cfg.synology 'pass' $EnvVars['SYNOLOGY_PASS'] }
        if ($EnvVars['ROUTER_HOST'])       { Set-CfgProp $cfg.router    'host'  $EnvVars['ROUTER_HOST'] }
        if ($EnvVars['ROUTER_MODEL'])      { Set-CfgProp $cfg.router    'model' $EnvVars['ROUTER_MODEL'] }
        if ($EnvVars['ROUTER_USER'])       { Set-CfgProp $cfg.router    'user'  $EnvVars['ROUTER_USER'] }
        if ($EnvVars['ROUTER_PASS'])       { Set-CfgProp $cfg.router    'pass'  $EnvVars['ROUTER_PASS'] }
        if ($EnvVars['ROUTER_PORT'])       { Set-CfgProp $cfg.router    'port'  ([int]$EnvVars['ROUTER_PORT']) }
        if ($EnvVars['DASHBOARD_TITLE'])   { Set-CfgProp $cfg.dashboard 'title' $EnvVars['DASHBOARD_TITLE'] }
        if ($EnvVars['DASHBOARD_OPERATOR']){ Set-CfgProp $cfg.dashboard 'operator' $EnvVars['DASHBOARD_OPERATOR'] }
        if ($EnvVars['GITHUB_TOKEN'])      { Set-CfgProp $cfg 'github_token' $EnvVars['GITHUB_TOKEN'] }
        if ($EnvVars['PROXY_RIGA_URL'])      { Set-CfgProp $cfg 'proxy_riga_url'      $EnvVars['PROXY_RIGA_URL'] }
        if ($EnvVars['PROXY_AMSTERDAM_URL']) { Set-CfgProp $cfg 'proxy_amsterdam_url' $EnvVars['PROXY_AMSTERDAM_URL'] }
    }

    # Гарантируем, что обязательные поля для synology существуют (даже если ни config.json,
    # ни .env их не задали) — иначе дальше Get-SynologyInfo упадёт на null.
    foreach ($p in @('host','user','port','sshKeyPath')) {
        if (-not $cfg.synology.PSObject.Properties[$p]) {
            $default = if ($p -eq 'port') { 22 } else { '' }
            Set-CfgProp $cfg.synology $p $default
        }
    }
    return $cfg
}

# ----------------------------------------------------------------------------
# СБОР: ОПЕРАЦИОННАЯ СИСТЕМА
# ----------------------------------------------------------------------------
function Get-OSInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $uptime = (Get-Date) - $os.LastBootUpTime

        return @{
            hostname     = $env:COMPUTERNAME
            user         = $env:USERNAME
            os           = $os.Caption
            version      = $os.Version
            build        = $os.BuildNumber
            arch         = $os.OSArchitecture
            install_date = $os.InstallDate.ToString('yyyy-MM-dd')
            last_boot    = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
            uptime_sec   = [int]$uptime.TotalSeconds
            uptime_str   = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
            manufacturer = $cs.Manufacturer
            model        = $cs.Model
            domain       = $cs.Domain
            bios_vendor  = $bios.Manufacturer
            bios_version = $bios.SMBIOSBIOSVersion
            bios_date    = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { '' }
        }
    } catch {
        return @{ error = "OS info failed: $($_.Exception.Message)" }
    }
}

# ----------------------------------------------------------------------------
# СБОР: ПРОЦЕССОР
# ----------------------------------------------------------------------------
function Get-CPUInfo {
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        # Текущая загрузка через CIM (быстрее чем Get-Counter)
        $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average

        # CPU temperature — three methods, first success wins
        $cpuTempC = $null

        # Method 1: MSAcpi_ThermalZoneTemperature (laptops + some desktops)
        if ($null -eq $cpuTempC) {
            try {
                $tzList = Get-WmiObject -Namespace 'root/WMI' -Class MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
                if ($tzList) {
                    $best = @($tzList) | Sort-Object CurrentTemperature -Descending | Select-Object -First 1
                    $t = [math]::Round($best.CurrentTemperature / 10 - 273.15, 0)
                    if ($t -ge 20 -and $t -le 105) { $cpuTempC = $t }
                }
            } catch {}
        }

        # Method 2: Performance counter Thermal Zone (Windows 10/11, values in Kelvin)
        if ($null -eq $cpuTempC) {
            try {
                $tc = (Get-Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction SilentlyContinue).CounterSamples
                if ($tc) {
                    $maxK = ($tc | Measure-Object CookedValue -Maximum).Maximum
                    $t = [math]::Round($maxK - 273.15, 0)
                    if ($t -ge 20 -and $t -le 105) { $cpuTempC = $t }
                }
            } catch {}
        }

        # Method 3: Win32_PerfFormattedData_Counters_ThermalZoneInformation
        if ($null -eq $cpuTempC) {
            try {
                $pf = Get-WmiObject Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction SilentlyContinue |
                      Sort-Object Temperature -Descending | Select-Object -First 1
                if ($pf) {
                    $t = [math]::Round($pf.Temperature - 273.15, 0)
                    if ($t -ge 20 -and $t -le 105) { $cpuTempC = $t }
                }
            } catch {}
        }

        return @{
            name           = ($cpu.Name -replace '\s+', ' ').Trim()
            manufacturer   = $cpu.Manufacturer
            socket         = $cpu.SocketDesignation
            cores          = [int]$cpu.NumberOfCores
            threads        = [int]$cpu.NumberOfLogicalProcessors
            base_clock_mhz = [int]$cpu.MaxClockSpeed
            current_mhz    = [int]$cpu.CurrentClockSpeed
            l2_cache_kb    = [int]$cpu.L2CacheSize
            l3_cache_kb    = [int]$cpu.L3CacheSize
            load_percent   = [int]$load
            temp_c         = $cpuTempC
            architecture   = switch ($cpu.Architecture) {
                0 {'x86'} 1 {'MIPS'} 2 {'Alpha'} 3 {'PowerPC'} 5 {'ARM'} 6 {'IA-64'} 9 {'x64'} 12 {'ARM64'}
                default {'unknown'}
            }
        }
    } catch {
        return @{ error = "CPU info failed: $($_.Exception.Message)" }
    }
}

# ----------------------------------------------------------------------------
# СБОР: ПАМЯТЬ
# ----------------------------------------------------------------------------
function Get-MemoryInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $totalKB = [int64]$os.TotalVisibleMemorySize
        $freeKB  = [int64]$os.FreePhysicalMemory
        $usedKB  = $totalKB - $freeKB

        $modules = @()
        foreach ($m in (Get-CimInstance Win32_PhysicalMemory)) {
            $modules += @{
                slot         = $m.DeviceLocator
                bank         = $m.BankLabel
                manufacturer = $m.Manufacturer
                part_number  = ($m.PartNumber -as [string]).Trim()
                serial       = ($m.SerialNumber -as [string]).Trim()
                capacity_gb  = [math]::Round($m.Capacity / 1GB, 0)
                speed_mhz    = [int]$m.Speed
                form_factor  = switch ($m.FormFactor) {
                    8 {'DIMM'} 12 {'SODIMM'} default {'unknown'}
                }
                memory_type  = switch ($m.SMBIOSMemoryType) {
                    24 {'DDR3'} 26 {'DDR4'} 34 {'DDR5'} default { "type-$($m.SMBIOSMemoryType)" }
                }
            }
        }

        return @{
            total_gb     = [math]::Round($totalKB / 1MB, 2)
            used_gb      = [math]::Round($usedKB / 1MB, 2)
            free_gb      = [math]::Round($freeKB / 1MB, 2)
            used_percent = [math]::Round(($usedKB / $totalKB) * 100, 1)
            modules      = $modules
            module_count = $modules.Count
        }
    } catch {
        return @{ error = "Memory info failed: $($_.Exception.Message)" }
    }
}

# ----------------------------------------------------------------------------
# СБОР: ВИДЕОКАРТА
# ----------------------------------------------------------------------------
function Get-GPUInfo {
    try {
        $gpus = @()
        foreach ($v in (Get-CimInstance Win32_VideoController)) {
            # nvidia-smi если доступен
            $nvidiaData = $null
            if ($v.Name -match 'NVIDIA') {
                $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
                if ($nvidiaSmi) {
                    try {
                        $smiRaw = & nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>$null
                        if ($smiRaw) {
                            $parts = $smiRaw -split ',' | ForEach-Object { $_.Trim() }
                            $nvidiaData = @{
                                gpu_util_percent = [int]($parts[0])
                                vram_used_mb     = [int]($parts[1])
                                vram_total_mb    = [int]($parts[2])
                                temp_c           = [int]($parts[3])
                                power_w          = [double]($parts[4])
                            }
                        }
                    } catch { }
                }
            }

            $gpu = @{
                name           = $v.Name
                driver_version = $v.DriverVersion
                driver_date    = if ($v.DriverDate) { $v.DriverDate.ToString('yyyy-MM-dd') } else { '' }
                vram_mb        = if ($v.AdapterRAM -gt 0) { [math]::Round($v.AdapterRAM / 1MB, 0) } else { 0 }
                resolution     = "$($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution)"
                refresh_hz     = [int]$v.CurrentRefreshRate
                video_mode     = $v.VideoModeDescription
                status         = $v.Status
            }
            if ($nvidiaData) { $gpu += $nvidiaData }
            $gpus += $gpu
        }
        # Запятая = принудительно сохраняем массив (иначе ConvertTo-Json развернёт 1-элементный массив в объект)
        return ,$gpus
    } catch {
        return ,@(@{ error = "GPU info failed: $($_.Exception.Message)" })
    }
}

# ----------------------------------------------------------------------------
# СБОР: ДИСКИ
# ----------------------------------------------------------------------------
function Get-DiskInfo {
    try {
        $physical = @()
        foreach ($d in (Get-PhysicalDisk)) {
            $diskTemp = $null
            try {
                $rel = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                if ($rel -and $rel.Temperature -gt 0) { $diskTemp = [int]$rel.Temperature }
            } catch {}
            $physical += @{
                friendly_name = $d.FriendlyName
                model         = $d.Model
                serial        = ($d.SerialNumber -as [string]).Trim()
                media_type    = $d.MediaType
                bus_type      = $d.BusType
                size_gb       = [math]::Round($d.Size / 1GB, 2)
                health        = $d.HealthStatus
                operational   = $d.OperationalStatus
                temp_c        = $diskTemp
            }
        }

        $logical = @()
        foreach ($v in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")) {
            $totalGB = [math]::Round($v.Size / 1GB, 2)
            $freeGB  = [math]::Round($v.FreeSpace / 1GB, 2)
            $logical += @{
                drive        = $v.DeviceID
                label        = $v.VolumeName
                filesystem   = $v.FileSystem
                total_gb     = $totalGB
                free_gb      = $freeGB
                used_gb      = [math]::Round($totalGB - $freeGB, 2)
                used_percent = if ($totalGB -gt 0) { [math]::Round((($totalGB - $freeGB) / $totalGB) * 100, 1) } else { 0 }
            }
        }

        return @{
            physical = $physical
            logical  = $logical
        }
    } catch {
        return @{ error = "Disk info failed: $($_.Exception.Message)" }
    }
}

# ----------------------------------------------------------------------------
# СБОР: МАТЕРИНСКАЯ ПЛАТА
# ----------------------------------------------------------------------------
function Get-MotherboardInfo {
    try {
        $mb = Get-CimInstance Win32_BaseBoard
        return @{
            manufacturer = $mb.Manufacturer
            product      = $mb.Product
            version      = $mb.Version
            serial       = ($mb.SerialNumber -as [string]).Trim()
        }
    } catch {
        return @{ error = "Motherboard info failed: $($_.Exception.Message)" }
    }
}

# ----------------------------------------------------------------------------
# СБОР: СЕТЬ
# ----------------------------------------------------------------------------
function Get-NetworkInfo {
    try {
        $interfaces = @()
        foreach ($if in (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')) {
            $ip4 = (Get-NetIPAddress -InterfaceIndex $if.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
            $ip6 = (Get-NetIPAddress -InterfaceIndex $if.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
            $stat = Get-NetAdapterStatistics -Name $if.Name -ErrorAction SilentlyContinue

            $interfaces += @{
                name        = $if.Name
                description = $if.InterfaceDescription
                mac         = $if.MacAddress
                speed_mbps  = try { if ($if.LinkSpeed -match '([\d.]+)\s*(G|M)bps') { $v=[double]$matches[1]; if ($matches[2]-eq'G'){[int]($v*1000)}else{[int]$v} } else { 0 } } catch { 0 }
                ip4         = $ip4
                ip6         = $ip6
                status      = $if.Status
                media_type  = $if.MediaType
                rx_bytes    = if ($stat) { [int64]$stat.ReceivedBytes } else { 0 }
                tx_bytes    = if ($stat) { [int64]$stat.SentBytes } else { 0 }
            }
        }

        # Default Gateway — skip virtual adapters (Docker, Hyper-V, WSL, VPN)
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $ad = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
                    $ad -and $ad.Status -eq 'Up' -and
                    $ad.Description -notmatch 'Virtual|Hyper-V|Docker|WSL|Loopback|TAP|VPN|Tunnel|vEthernet'
                } catch { $false }
            } |
            Sort-Object RouteMetric | Select-Object -First 1).NextHop

        # DNS серверы
        $dns = @()
        try {
            $dns = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.ServerAddresses.Count -gt 0 } |
                    Select-Object -First 1).ServerAddresses
        } catch { }

        # Внешний IP (best-effort)
        $extIp = ''
        try {
            $extIp = (Invoke-WebRequest -Uri 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 3).Content
        } catch { }

        return @{
            interfaces = $interfaces
            gateway    = $gw
            dns        = $dns
            external_ip = $extIp
        }
    } catch {
        return @{ error = "Network info failed: $($_.Exception.Message)" }
    }
}

# ----------------------------------------------------------------------------
# СБОР: РОУТЕР
# ----------------------------------------------------------------------------
function Get-RouterInfo {
    param([pscustomobject]$Cfg, [string]$AutoGateway)

    $routerHost = if ($Cfg.host -and $Cfg.host.Trim() -ne '') { $Cfg.host } else { $AutoGateway }
    if (-not $routerHost) {
        return @{ error = 'Не удалось определить IP роутера'; reachable = $false }
    }

    $result = @{
        host       = $routerHost
        model_hint = $Cfg.model
        reachable  = $false
        ping_ms    = $null
        ping_history = @()
    }

    # Ping latency (5 пакетов для среднего)
    try {
        $pings = Test-Connection -ComputerName $routerHost -Count 5 -ErrorAction SilentlyContinue
        if ($pings) {
            $result.reachable = $true
            # PS7 → .Latency, PS5 → .ResponseTime
            $latencies = $pings | ForEach-Object {
                if ($_.PSObject.Properties['Latency'])      { [int]$_.Latency }
                elseif ($_.PSObject.Properties['ResponseTime']) { [int]$_.ResponseTime }
                else { 0 }
            }
            $result.ping_ms = [math]::Round(($latencies | Measure-Object -Average).Average, 1)
            $result.ping_min = ($latencies | Measure-Object -Minimum).Minimum
            $result.ping_max = ($latencies | Measure-Object -Maximum).Maximum
            $result.ping_history = $latencies
        }
    } catch { }

    # ARP таблица для устройств в сети
    try {
        $arpRaw = arp -a 2>$null
        $devices = @()
        foreach ($line in $arpRaw) {
            if ($line -match '^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F\-:]{17})\s+(\w+)') {
                $ip  = $matches[1]
                $mac = $matches[2]
                $type = $matches[3]
                # пропускаем мультикаст и broadcast
                if ($ip -notmatch '^(224|239|255)\.' -and $mac -ne 'ff-ff-ff-ff-ff-ff') {
                    $devices += @{
                        ip   = $ip
                        mac  = $mac.ToUpper()
                        type = $type
                        is_gateway = ($ip -eq $routerHost)
                    }
                }
            }
        }
        $result.devices = $devices
        $result.device_count = $devices.Count
    } catch {
        $result.devices = @()
        $result.device_count = 0
    }

    # Internet connectivity — async TCP к 1.1.1.1:443 (timeout 2s, не виснет на firewall)
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $result.internet_dns_ok = $tcp.ConnectAsync('1.1.1.1', 443).Wait(2000)
        try { $tcp.Close() } catch { }
    } catch {
        $result.internet_dns_ok = $false
    }

    # SSH-метрики роутера (если есть учётка)
    $rUser = ''; $rPass = ''; $rPort = 22
    if ($Cfg.PSObject.Properties['user']) { $rUser = [string]$Cfg.user }
    if ($Cfg.PSObject.Properties['pass']) { $rPass = [string]$Cfg.pass }
    if ($Cfg.PSObject.Properties['port']) { $rPort = [int]$Cfg.port }

    if ($rUser -and $rPass) {
        $sshScript = @'
echo "===HOSTNAME==="; hostname 2>/dev/null
echo "===UNAME==="; uname -a 2>/dev/null
echo "===MODEL==="; (nvram get productid 2>/dev/null || nvram get model 2>/dev/null || cat /tmp/syslog.log 2>/dev/null | grep -i "model" | head -1 || echo "")
echo "===FW==="; (nvram get buildno 2>/dev/null; nvram get extendno 2>/dev/null) | tr "\n" "." | sed "s/\.$//"
echo "===UPTIME==="; cat /proc/uptime 2>/dev/null
echo "===LOADAVG==="; cat /proc/loadavg 2>/dev/null
echo "===MEMINFO==="; head -5 /proc/meminfo 2>/dev/null
echo "===CPUINFO==="; grep -m1 "model name\|cpu model\|Hardware\|machine" /proc/cpuinfo 2>/dev/null
echo "===CPUCORES==="; grep -c "^processor" /proc/cpuinfo 2>/dev/null
echo "===TEMP==="; for f in /sys/class/thermal/thermal_zone0/temp /sys/class/hwmon/hwmon0/temp1_input /sys/class/hwmon/hwmon1/temp1_input /sys/class/hwmon/hwmon2/temp1_input; do if [ -f "$f" ]; then v=$(cat "$f" 2>/dev/null); if [ -n "$v" ]; then echo "$v"; break; fi; fi; done
echo "===NET==="; cat /proc/net/dev 2>/dev/null | grep -E "eth|wan|wl|br0" | head -10
echo "===WAN==="; nvram get wan0_ipaddr 2>/dev/null
echo "===CLIENTS==="; cat /proc/net/arp 2>/dev/null | tail -n +2 | wc -l
echo "===PORTS==="; (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | awk 'NR>1 && /LISTEN/ {print $4}' | head -50
echo "===END==="
'@
        try {
            $rssh = Invoke-NasSsh -User $rUser -NasHost $routerHost -Port $rPort `
                -Pass $rPass -Command $sshScript
            if ($rssh.ok) {
                $sections = @{}
                $current = $null; $buf = @()
                # Normalize: put section markers on their own lines even if glued to previous output
                $normalizedOutput = $rssh.output -replace '(===\w+===)', "`n`$1`n"
                foreach ($line in ($normalizedOutput -split "`n")) {
                    if ($line -match '^===(.+?)===\r?$') {
                        if ($current) { $sections[$current] = ($buf -join "`n").Trim() }
                        $current = $matches[1]; $buf = @()
                    } else {
                        $buf += $line
                    }
                }
                if ($current -and $current -ne 'END') { $sections[$current] = ($buf -join "`n").Trim() }

                $rinfo = @{}
                $rinfo.hostname = $sections['HOSTNAME']
                $rinfo.kernel   = $sections['UNAME']
                $rinfo.model    = $sections['MODEL']
                $rinfo.firmware = $sections['FW']
                $rinfo.wan_ip   = $sections['WAN']
                if ($sections['CLIENTS'] -match '^\d+$') { $rinfo.clients = [int]$sections['CLIENTS'] }

                # Uptime (секунды → форматированная строка)
                if ($sections['UPTIME'] -match '^([\d.]+)\s') {
                    $upSec = [int][double]$matches[1]
                    $d = [int]($upSec / 86400)
                    $h = [int](($upSec % 86400) / 3600)
                    $m = [int](($upSec % 3600) / 60)
                    $rinfo.uptime_str = "${d}d ${h}h ${m}m"
                    $rinfo.uptime_sec = $upSec
                }

                # Loadavg
                if ($sections['LOADAVG'] -match '^([\d.]+)\s+([\d.]+)\s+([\d.]+)') {
                    $rinfo.load_1m  = [double]$matches[1]
                    $rinfo.load_5m  = [double]$matches[2]
                    $rinfo.load_15m = [double]$matches[3]
                }

                # Memory
                $mem = @{}
                foreach ($l in ($sections['MEMINFO'] -split "`n")) {
                    if ($l -match '^(\w+):\s+(\d+)\s+kB') { $mem[$matches[1]] = [int64]$matches[2] }
                }
                if ($mem.Count -gt 0) {
                    $totKB = $mem['MemTotal']
                    $freeKB = $mem['MemAvailable']
                    if (-not $freeKB) { $freeKB = $mem['MemFree'] }
                    $rinfo.mem_total_mb = [math]::Round($totKB / 1024, 1)
                    $rinfo.mem_used_mb  = [math]::Round(($totKB - $freeKB) / 1024, 1)
                    $rinfo.mem_used_percent = if ($totKB -gt 0) { [math]::Round((($totKB - $freeKB) / $totKB) * 100, 1) } else { 0 }
                }

                # CPU
                if ($sections['CPUINFO'] -match '(?:model name|cpu model|Hardware|machine)\s*:\s*(.+)') {
                    $rinfo.cpu_model = $matches[1].Trim()
                }
                if ($sections['CPUCORES'] -match '^\d+$') { $rinfo.cpu_cores = [int]$sections['CPUCORES'] }

                # Temperature
                if ($sections['TEMP']) {
                    $tempLine = ($sections['TEMP'] -split "`n" | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
                    if ($tempLine) {
                        $tempVal = [int]$tempLine
                        if ($tempVal -gt 1000) { $tempVal = [int]($tempVal / 1000) }
                        if ($tempVal -ge 5 -and $tempVal -le 150) { $rinfo.cpu_temp_c = $tempVal }
                    }
                }

                # NET totals (для трафик-индикатора)
                $totalRx = [int64]0; $totalTx = [int64]0
                foreach ($l in ($sections['NET'] -split "`n")) {
                    $l = $l.Trim()
                    if ($l -match '^\S+:\s+(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)') {
                        $totalRx += [int64]$matches[1]
                        $totalTx += [int64]$matches[2]
                    }
                }
                $rinfo.net_total = @{ rx_bytes = $totalRx; tx_bytes = $totalTx }

                # Open ports (router)
                $portMap = @{
                    '22'='SSH'; '21'='FTP'; '23'='Telnet'; '53'='DNS'; '80'='HTTP'; '443'='HTTPS'
                    '1025'='SSH-ALT'; '139'='SMB'; '445'='SMB'; '8443'='HTTPS-ALT'
                    '8080'='HTTP-ALT'; '5000'='UPnP'; '1900'='SSDP'; '5353'='mDNS'
                    '161'='SNMP'; '500'='IPSec'; '4500'='IPSec-NAT'; '1701'='L2TP'; '1723'='PPTP'
                    '51820'='WireGuard'; '11211'='Memcached'; '631'='IPP'
                }
                $ports = @(); $seen = @{}
                foreach ($l in ($sections['PORTS'] -split "`n")) {
                    $l = $l.Trim(); if (-not $l) { continue }
                    $portStr = $null; $bind = $null
                    if ($l -match '^\[?([0-9a-f:.\*]+)\]?:(\d+)$') {
                        $bind = $matches[1]; $portStr = $matches[2]
                    }
                    if (-not $portStr) { continue }
                    $portNum = [int]$portStr
                    if ($seen.ContainsKey($portNum)) { continue }
                    $seen[$portNum] = $true
                    $isPublic = ($bind -eq '0.0.0.0' -or $bind -eq '::' -or $bind -eq '*')
                    $ports += @{
                        port    = $portNum
                        bind    = $bind
                        service = if ($portMap.ContainsKey($portStr)) { $portMap[$portStr] } else { '' }
                        public  = $isPublic
                    }
                }
                $rinfo.ports = ,($ports | Sort-Object { $_.port })

                $result.info = $rinfo
                $result.ssh_ok = $true
            } else {
                $result.ssh_ok = $false
                $result.ssh_error = $rssh.output
            }
        } catch {
            $result.ssh_ok = $false
            $result.ssh_error = $_.Exception.Message
        }
    }

    return $result
}

# ----------------------------------------------------------------------------
# СБОР: GITHUB RELEASES (3x-ui, Xray-core)
# ----------------------------------------------------------------------------
$script:lastReleasesCheck = [DateTime]::MinValue
$script:lastReleasesData  = $null

function Get-ReleasesInfo {
    param([string]$Token = '')
    $now = Get-Date
    if ($script:lastReleasesData -and ($now - $script:lastReleasesCheck).TotalSeconds -lt 600) {
        return $script:lastReleasesData
    }

    $repos = @(
        'MHSanaei/3x-ui',
        'XTLS/Xray-core',
        'amnezia-vpn/amneziawg-go',
        'apernet/hysteria'
    )

    # Все 4 запроса параллельно через .NET HttpClient — вместо 4×8s получаем ~8s макс.
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [System.TimeSpan]::FromSeconds(10)
    $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'CYBERFORTRESS-dashboard') | Out-Null
    $client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'application/vnd.github+json') | Out-Null
    if ($Token) { $client.DefaultRequestHeaders.TryAddWithoutValidation('Authorization', "Bearer $Token") | Out-Null }

    # per_page=10 — нужно чтобы у репо с частыми pre-release тоже нашёлся stable
    $taskArr = [System.Threading.Tasks.Task[]]($repos | ForEach-Object {
        $client.GetStringAsync("https://api.github.com/repos/$_/releases?per_page=10")
    })

    try { [System.Threading.Tasks.Task]::WaitAll($taskArr, 11000) } catch { }

    $items = for ($i = 0; $i -lt $repos.Count; $i++) {
        if ($taskArr[$i].Status -eq 'RanToCompletion') {
            try {
                $resp   = $taskArr[$i].Result | ConvertFrom-Json
                $stable = $resp | Where-Object { -not $_.prerelease -and -not $_.draft } | Select-Object -First 1
                $pre    = $resp | Where-Object {     $_.prerelease -and -not $_.draft } | Select-Object -First 1
                @{
                    repo       = $repos[$i]
                    stable     = if ($stable) { @{ tag=$stable.tag_name; name=$stable.name; published=$stable.published_at; url=$stable.html_url } } else { $null }
                    prerelease = if ($pre)    { @{ tag=$pre.tag_name;    name=$pre.name;    published=$pre.published_at;    url=$pre.html_url    } } else { $null }
                    error      = $null
                }
            } catch {
                @{ repo=$repos[$i]; stable=$null; prerelease=$null; error=$_.Exception.Message }
            }
        } else {
            $errMsg = if ($taskArr[$i].Exception) { $taskArr[$i].Exception.GetBaseException().Message } else { 'timeout' }
            @{ repo=$repos[$i]; stable=$null; prerelease=$null; error=$errMsg }
        }
    }
    $client.Dispose()

    $data = @{
        scanned_at = $now.ToString('yyyy-MM-dd HH:mm:ss')
        items      = ,$items
    }
    $script:lastReleasesData  = $data
    $script:lastReleasesCheck = $now
    return $data
}

# ----------------------------------------------------------------------------
# СБОР: WINDOWS UPDATES (через Microsoft.Update.Session COM, lazy)
# ----------------------------------------------------------------------------
$script:lastUpdatesCheck = [DateTime]::MinValue
$script:lastUpdatesData  = $null

function Get-WindowsUpdatesInfo {
    $now = Get-Date
    if ($script:lastUpdatesData -and ($now - $script:lastUpdatesCheck).TotalSeconds -lt 1800) {
        return $script:lastUpdatesData
    }
    $result = @{
        scanned_at = $now.ToString('yyyy-MM-dd HH:mm:ss')
        available  = 0
        critical   = 0
        items      = ,@()
        error      = $null
    }
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $sr = $searcher.Search("IsInstalled=0 and IsHidden=0")
        $items = @()
        $crit = 0
        foreach ($u in $sr.Updates) {
            $isCrit = $false
            try {
                foreach ($cat in $u.Categories) {
                    if ($cat.Name -match 'Critical|Security') { $isCrit = $true; break }
                }
            } catch { }
            if ($isCrit) { $crit++ }
            $items += @{
                title     = $u.Title
                size_mb   = if ($u.MaxDownloadSize) { [math]::Round([int64]$u.MaxDownloadSize / 1MB, 1) } else { 0 }
                critical  = $isCrit
            }
            if ($items.Count -ge 15) { break }
        }
        $result.available = $sr.Updates.Count
        $result.critical  = $crit
        $result.items     = ,$items
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($session) | Out-Null
    } catch {
        $result.error = $_.Exception.Message
    }
    $script:lastUpdatesData  = $result
    $script:lastUpdatesCheck = $now
    return $result
}

# ----------------------------------------------------------------------------
# СБОР: ОШИБКИ СИСТЕМЫ (последние Error/Critical из System+Application)
# ----------------------------------------------------------------------------
function Get-SystemErrors {
    $errors = @()
    try {
        $cutoff = (Get-Date).AddDays(-2)
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'System','Application'
            Level = 1,2  # 1=Critical, 2=Error
            StartTime = $cutoff
        } -MaxEvents 25 -ErrorAction SilentlyContinue
        foreach ($e in $events) {
            $msg = $e.Message
            if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240) + '...' }
            $errors += @{
                time     = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                source   = $e.ProviderName
                log      = $e.LogName
                level    = if ($e.Level -eq 1) { 'CRITICAL' } else { 'ERROR' }
                event_id = $e.Id
                message  = $msg
            }
        }
    } catch { }
    return @{
        scanned_at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        count      = $errors.Count
        items      = ,$errors
    }
}

# ----------------------------------------------------------------------------
# СБОР: МУСОР WINDOWS (temp, корзина, кэши)
# ----------------------------------------------------------------------------
$script:lastJunkCheck = [DateTime]::MinValue
$script:lastJunkData  = $null

function Get-FolderSize {
    param(
        [string]$Path,
        [int]$TimeoutSec = 8
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $sum = [int64]0
        # .NET enumerate в разы быстрее Get-ChildItem -Recurse
        $files = [System.IO.Directory]::EnumerateFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)
        foreach ($f in $files) {
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { break }
            try { $sum += [System.IO.FileInfo]::new($f).Length } catch { }
        }
        return [int64]$sum
    } catch { return 0 }
    finally { $sw.Stop() }
}

function Get-RecycleBinSize {
    $total = [int64]0
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $drives = [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.IsReady -and $_.DriveType -eq [System.IO.DriveType]::Fixed }
        foreach ($drv in $drives) {
            $binPath = Join-Path $drv.RootDirectory.FullName "`$Recycle.Bin\$sid"
            if (Test-Path -LiteralPath $binPath) {
                $total += Get-FolderSize $binPath
            }
        }
    } catch { }
    return $total
}

function Get-JunkInfo {
    param([switch]$Force)
    $now = Get-Date
    if (-not $Force -and $script:lastJunkData -and ($now - $script:lastJunkCheck).TotalSeconds -lt 120) {
        return $script:lastJunkData
    }

    # Sum sizes of multiple paths safely
    function Measure-Paths {
        param([string[]]$Paths)
        $sz = [int64]0
        foreach ($p in $Paths) {
            try { $ok = Test-Path -LiteralPath $p -ErrorAction SilentlyContinue } catch { continue }
            if ($ok) { $sz += Get-FolderSize $p }
        }
        return $sz
    }

    $cats = @()

    # 1. User Temp
    $tempPaths = [System.Collections.Generic.List[string]]::new()
    $tempPaths.Add($env:TEMP)
    $la = "$env:LOCALAPPDATA\Temp"
    if ($la -ne $env:TEMP) { $tempPaths.Add($la) }
    $cats += @{ id='user_temp'; name='User Temp'; icon='T'; path=$env:TEMP
                size_bytes=(Measure-Paths $tempPaths.ToArray()) }

    # 2. Windows Temp
    $cats += @{ id='windows_temp'; name='Windows Temp'; icon='W'; path="$env:WINDIR\Temp"
                size_bytes=(Measure-Paths @("$env:WINDIR\Temp")) }

    # 3. Error Reports (WER + CrashDumps + WER Queue)
    $cats += @{ id='error_reports'; name='Error Reports'; icon='!'; path='WER + CrashDumps'
                size_bytes=(Measure-Paths @(
                    "$env:LOCALAPPDATA\Microsoft\Windows\WER",
                    "$env:LOCALAPPDATA\CrashDumps",
                    "$env:ProgramData\Microsoft\Windows\WER\ReportQueue")) }

    # 4. Browser Cache (Chrome + Edge + Firefox, all profiles)
    $bpaths = [System.Collections.Generic.List[string]]::new()
    $bpaths.Add("$env:LOCALAPPDATA\Microsoft\Windows\INetCache")
    foreach ($sub in @('Default\Cache','Default\Code Cache','Default\GPUCache')) {
        $bpaths.Add("$env:LOCALAPPDATA\Google\Chrome\User Data\$sub")
        $bpaths.Add("$env:LOCALAPPDATA\Microsoft\Edge\User Data\$sub")
    }
    $ffBase = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $ffBase) {
        Get-ChildItem $ffBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $c = Join-Path $_.FullName 'cache2'
            if (Test-Path $c) { $bpaths.Add($c) }
        }
    }
    $cats += @{ id='browser_cache'; name='Browser Cache'; icon='B'; path='Chrome/Edge/Firefox'
                size_bytes=(Measure-Paths $bpaths.ToArray()) }

    # 5. GPU Cache (NVIDIA + AMD + Intel + D3DS)
    $cats += @{ id='gpu_cache'; name='GPU Cache'; icon='G'; path='D3DS/NVIDIA/AMD/Intel'
                size_bytes=(Measure-Paths @(
                    "$env:LOCALAPPDATA\D3DSCache",
                    "$env:LOCALAPPDATA\NVIDIA\DXCache",
                    "$env:LOCALAPPDATA\NVIDIA\GLCache",
                    "$env:LOCALAPPDATA\AMD\DxCache",
                    "$env:LOCALAPPDATA\AMD\GLCache",
                    "$env:LOCALAPPDATA\Intel\ShaderCache")) }

    # 6. Thumbnails (*.db files only — fast)
    $thumbSz = [int64]0
    $thumbDir = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    if (Test-Path $thumbDir) {
        Get-ChildItem $thumbDir -Filter '*.db' -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $thumbSz += $_.Length }
    }
    $cats += @{ id='thumbnails'; name='Thumbnails'; icon='I'; path=$thumbDir; size_bytes=$thumbSz }

    # 7. App Cache (Teams + Discord + Spotify + VS Code + Telegram + Office)
    $apaths = [System.Collections.Generic.List[string]]::new()
    foreach ($sub in @('Cache','blob_storage','databases','gpucache','logs')) {
        $apaths.Add("$env:LOCALAPPDATA\Microsoft\Teams\$sub")
    }
    foreach ($sub in @('Cache','Code Cache','GPUCache')) { $apaths.Add("$env:APPDATA\discord\$sub") }
    $apaths.Add("$env:LOCALAPPDATA\Spotify\Storage")
    $apaths.Add("$env:LOCALAPPDATA\Spotify\Data")
    foreach ($sub in @('Cache','Code Cache','GPUCache','logs')) { $apaths.Add("$env:APPDATA\Code\$sub") }
    # Telegram — enumerate all account hash-dirs under tdata\
    $tdataPath = "$env:APPDATA\Telegram Desktop\tdata"
    if (Test-Path $tdataPath) {
        Get-ChildItem -LiteralPath $tdataPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($cacheSub in @('cache','media_cache','cache2')) {
                $cp = Join-Path $_.FullName $cacheSub
                if (Test-Path $cp) { $apaths.Add($cp) }
            }
        }
    }
    Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $p = Join-Path $_.FullName 'OfficeFileCache'; if (Test-Path $p) { $apaths.Add($p) } }
    $cats += @{ id='app_cache'; name='App Cache'; icon='A'; path='Teams/Discord/Spotify/VSCode/Telegram'
                size_bytes=(Measure-Paths $apaths.ToArray()) }

    # 7b. Steam Cache
    $steamInstall = ''
    try { $steamInstall = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath } catch { }
    if (-not $steamInstall) { $steamInstall = 'C:\Program Files (x86)\Steam' }
    $steamPaths = @(
        "$env:LOCALAPPDATA\Steam\htmlcache",
        "$env:LOCALAPPDATA\Steam\logs",
        "$steamInstall\logs",
        "$steamInstall\dumps",
        "$steamInstall\shadercache"
    )
    $steamSz = Measure-Paths $steamPaths
    if ($steamSz -gt 0) {
        $cats += @{ id='steam_cache'; name='Steam Cache'; icon='S'; path='Steam logs/htmlcache/shadercache'
                    size_bytes=$steamSz }
    }

    # 7c. Browser History (separate from cache — shows history size)
    $bhpaths = [System.Collections.Generic.List[string]]::new()
    $histFiles = @('History','Visited Links','Top Sites','Favicons','Media History','Session Storage')
    foreach ($base in @("$env:LOCALAPPDATA\Google\Chrome\User Data","$env:LOCALAPPDATA\Microsoft\Edge\User Data","$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data")) {
        if (-not (Test-Path $base)) { continue }
        $profs = @("$base\Default") + @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Profile \d+$' } | ForEach-Object { $_.FullName })
        foreach ($prof in $profs) {
            foreach ($hf in $histFiles) {
                $fp = Join-Path $prof $hf
                if (Test-Path $fp) { $bhpaths.Add($fp) }
            }
        }
    }
    $bhSz = [int64]0
    foreach ($fp in $bhpaths) {
        try { $bhSz += [System.IO.FileInfo]::new($fp).Length } catch { }
    }
    if ($bhSz -gt 0) {
        $cats += @{ id='browser_history'; name='Browser History'; icon='H'; path='Chrome/Edge/Brave history files'
                    size_bytes=$bhSz }
    }

    # 8. Dev Tools Cache (npm + pip + NuGet + Yarn)
    $cats += @{ id='dev_cache'; name='Dev Tools Cache'; icon='D'; path='npm/pip/NuGet/Yarn'
                size_bytes=(Measure-Paths @(
                    "$env:LOCALAPPDATA\npm-cache",
                    "$env:APPDATA\npm-cache",
                    "$env:LOCALAPPDATA\pip\Cache",
                    "$env:LOCALAPPDATA\NuGet\Cache",
                    "$env:LOCALAPPDATA\NuGet\v3-cache",
                    "$env:LOCALAPPDATA\Yarn\Cache")) }

    # 9b. Extended areas (CCleaner / Advanced SystemCare best practices)
    $extPaths = [System.Collections.Generic.List[string]]::new()
    $extPaths.Add("$env:APPDATA\Microsoft\Windows\Recent")
    $extPaths.Add("$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations")
    $extPaths.Add("$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations")
    $extPaths.Add("$env:USERPROFILE\AppData\LocalLow\Sun\Java\Deployment\cache")
    $extPaths.Add("$env:APPDATA\Microsoft\Windows Media Player")
    $extPaths.Add("$env:TEMP\chocolatey")
    # MS Store app temp
    if (Test-Path "$env:LOCALAPPDATA\Packages") {
        Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Packages" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Join-Path $_.FullName 'AC\Temp'
            if (Test-Path $p) { $extPaths.Add($p) }
        }
    }
    $cats += @{ id='extended'; name='Extended Areas'; icon='X'; path='Recent/JumpLists/Java/StoreTemp'
                size_bytes=(Measure-Paths $extPaths.ToArray()) }

    # 9. Prefetch
    $cats += @{ id='prefetch'; name='Prefetch'; icon='P'; path="$env:WINDIR\Prefetch"
                size_bytes=(Measure-Paths @("$env:WINDIR\Prefetch")) }

    # 10. System Junk (CBS + PatchCache + Minidump + FontCache + memory.dmp)
    $cats += @{ id='system_junk'; name='System Junk'; icon='S'; path='CBS/PatchCache/Minidump/Font'
                size_bytes=(Measure-Paths @(
                    "$env:WINDIR\Logs\CBS",
                    "$env:WINDIR\Installer\`$PatchCache`$",
                    "$env:WINDIR\Minidump",
                    "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache",
                    "$env:WINDIR\memory.dmp")) }

    # 11. Windows Update (Download + WU Logs)
    $cats += @{ id='windows_update'; name='Windows Update'; icon='U'; path='SoftwareDistribution'
                size_bytes=(Measure-Paths @(
                    "$env:WINDIR\SoftwareDistribution\Download",
                    "$env:WINDIR\Logs\WindowsUpdate")) }

    # 12. System Logs
    $cats += @{ id='system_logs'; name='System Logs'; icon='L'; path='System32\LogFiles'
                size_bytes=(Measure-Paths @(
                    "$env:WINDIR\System32\LogFiles",
                    "$env:WINDIR\debug")) }

    # 13. Event Logs (fast: read FileSize property, no recursion)
    $evtSz = [int64]0
    try {
        Get-WinEvent -ListLog Application,System,Security,Setup -ErrorAction SilentlyContinue |
            ForEach-Object { try { $evtSz += [int64]$_.FileSize } catch { } }
    } catch { }
    $cats += @{ id='event_logs'; name='Event Logs'; icon='E'; path='Windows Event Logs'; size_bytes=$evtSz }

    # 14. VSS Shadow Copies (count copies; use SVI folder size as proxy)
    try {
        $vssItems = @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)
        if ($vssItems.Count -gt 1) {
            $sviSz = [int64]0
            try { $sviSz = Get-FolderSize "$env:SystemDrive\System Volume Information" } catch { }
            $cats += @{ id='vss'; name="VSS Shadows ($($vssItems.Count) copies)"; icon='V'
                        path='System Volume Information'; size_bytes=$sviSz }
        }
    } catch { }

    # 15. Windows.old (only if exists)
    $winOldSz = Get-FolderSize 'C:\Windows.old'
    if ($winOldSz -gt 0) {
        $cats += @{ id='windows_old'; name='Windows.old'; icon='X'; path='C:\Windows.old'; size_bytes=$winOldSz }
    }

    # 16. Recycle Bin
    $cats += @{ id='recycle_bin'; name='Recycle Bin'; icon='R'; path='$Recycle.Bin'
                size_bytes=(Get-RecycleBinSize) }

    # 17. Empty Folders (search in user dirs + temp with 6-second timeout)
    $emptyCount = 0
    $emptyRoots = @(
        $env:TEMP,
        "$env:LOCALAPPDATA\Temp",
        "$env:USERPROFILE\Documents",
        "$env:USERPROFILE\Downloads",
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Pictures",
        "$env:USERPROFILE\Videos"
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($root in $emptyRoots) {
        if (-not (Test-Path $root)) { continue }
        try {
            Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if ($sw.Elapsed.TotalSeconds -gt 6) { return }
                try {
                    $hasItems = [bool]([System.IO.Directory]::EnumerateFileSystemEntries($_.FullName) | Select-Object -First 1)
                    if (-not $hasItems) { $emptyCount++ }
                } catch { }
            }
        } catch { }
        if ($sw.Elapsed.TotalSeconds -gt 6) { break }
    }
    $sw.Stop()
    if ($emptyCount -gt 0) {
        $cats += @{ id='empty_folders'; name="Empty Folders ($emptyCount)"; icon='∅'
                    path='Documents/Downloads/Desktop/Temp'; size_bytes=[int64]0 }
    }

    $total = [int64]0
    foreach ($c in $cats) {
        try { $total += [int64]($c.size_bytes) } catch { }
    }
    $totalCount = ($cats | Where-Object { $_.size_bytes -gt 0 }).Count

    $lastCleanLog = $null
    $logFile = Join-Path $script:RootDir 'data\last-cleanup.json'
    if (Test-Path $logFile) {
        try { $lastCleanLog = Get-Content -Raw -Path $logFile | ConvertFrom-Json } catch { }
    }

    $script:lastJunkData = @{
        scanned_at       = $now.ToString('yyyy-MM-dd HH:mm:ss')
        total_bytes      = $total
        total_categories = $totalCount
        categories       = ,$cats
        last_cleanup     = $lastCleanLog
    }
    $script:lastJunkCheck = $now
    return $script:lastJunkData
}

# ----------------------------------------------------------------------------
# СБОР: SYNOLOGY (через SSH)
# ----------------------------------------------------------------------------
function Ensure-PoshSSH {
    if (Get-Module -ListAvailable -Name Posh-SSH) { return $true }
    Write-Host "[i] Установка модуля Posh-SSH (только для текущего пользователя)..." -ForegroundColor Yellow
    try {
        # NuGet провайдер
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Where-Object Version -ge '2.8.5.201')) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
        }
        # Trust PSGallery
        if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
        Install-Module -Name Posh-SSH -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "Не удалось установить Posh-SSH: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-NasSsh {
    param(
        [string]$User,
        [string]$NasHost,
        [int]$Port = 22,
        [string]$Command,
        [string]$Pass = '',
        [string]$KeyPath = ''
    )

    # Если есть пароль — используем Posh-SSH (поддерживает password auth)
    if ($Pass) {
        if (-not (Ensure-PoshSSH)) {
            return @{ ok = $false; output = "Posh-SSH module not available" }
        }
        try {
            Import-Module Posh-SSH -ErrorAction Stop
            $secure = ConvertTo-SecureString $Pass -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($User, $secure)
            $session = New-SSHSession -ComputerName $NasHost -Port $Port -Credential $cred -AcceptKey -ConnectionTimeout 8 -ErrorAction Stop
            try {
                # PowerShell here-strings on Windows use \r\n — strip \r so BusyBox sh doesn't choke
                $cleanCmd = $Command -replace "`r", ''
                $r = Invoke-SSHCommand -SSHSession $session -Command $cleanCmd -TimeOut 25 -ErrorAction Stop
                $out = $r.Output -join "`n"
                $ok = ($out -match '===END===') -or ($r.ExitStatus -eq 0)
                return @{ ok = $ok; output = $out }
            } finally {
                Remove-SSHSession -SSHSession $session -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            return @{ ok = $false; output = "Posh-SSH error: $($_.Exception.Message)" }
        }
    }

    # Иначе — ssh.exe в BatchMode (только по ключу)
    $sshArgs = @(
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=5',
        '-p', $Port
    )
    if ($KeyPath -and (Test-Path $KeyPath)) { $sshArgs += @('-i', $KeyPath) }
    $sshArgs += "$User@$NasHost"
    $sshArgs += $Command
    try {
        $out = & ssh.exe @sshArgs 2>&1
        return @{ ok = ($LASTEXITCODE -eq 0); output = ($out -join "`n") }
    } catch {
        return @{ ok = $false; output = $_.Exception.Message }
    }
}

function Get-SynologyInfo {
    param([pscustomobject]$Cfg)

    if (-not $Cfg.enabled) {
        return @{ enabled = $false }
    }

    $result = @{
        enabled    = $true
        host       = $Cfg.host
        reachable  = $false
        info       = @{}
    }

    # Сначала пинг
    try {
        $ping = Test-Connection -ComputerName $Cfg.host -Count 2 -Quiet -ErrorAction SilentlyContinue
        $result.reachable = [bool]$ping
    } catch {
        $result.reachable = $false
    }

    if (-not $result.reachable) {
        $result.error = "NAS не отвечает на ping ($($Cfg.host))"
        return $result
    }

    # Один SSH-вызов с пакетной командой — экономим коннекты
    $sshScript = @'
echo "===HOSTNAME==="; hostname
echo "===UNAME==="; uname -a
echo "===UPTIME==="; uptime
echo "===UPTIMESEC==="; cat /proc/uptime 2>/dev/null
echo "===LOADAVG==="; cat /proc/loadavg
echo "===MEMINFO==="; head -5 /proc/meminfo
echo "===CPUINFO==="; grep -m1 "model name" /proc/cpuinfo
echo "===CPUCORES==="; grep -c "^processor" /proc/cpuinfo
echo "===TEMP==="; for f in /sys/class/thermal/thermal_zone0/temp /sys/class/hwmon/hwmon0/temp1_input /sys/class/hwmon/hwmon1/temp1_input /sys/class/hwmon/hwmon2/temp1_input /sys/class/hwmon/hwmon3/temp1_input; do if [ -f "$f" ]; then v=$(cat "$f" 2>/dev/null); if [ -n "$v" ]; then echo "$v"; break; fi; fi; done
echo "===DISKS==="; df -h | grep -E "volume|md|/$" | head -10
echo "===PROCESSES==="; ps -ef 2>/dev/null | wc -l
echo "===NET==="; cat /proc/net/dev | grep -E "eth|bond" | head -5
echo "===PORTS==="; (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | awk 'NR>1 && /LISTEN/ {print $4}' | head -50
echo "===END==="
'@

    $sshPass = ''
    if ($Cfg.PSObject.Properties['pass']) { $sshPass = [string]$Cfg.pass }
    $ssh = Invoke-NasSsh -User $Cfg.user -NasHost $Cfg.host -Port $Cfg.port `
        -KeyPath $Cfg.sshKeyPath -Pass $sshPass -Command $sshScript

    if (-not $ssh.ok) {
        $result.error = "SSH failed: $($ssh.output)"
        return $result
    }

    # Парсим вывод по маркерам
    $sections = @{}
    $current = $null; $buf = @()
    $normalizedSsh = $ssh.output -replace '(===\w+===)', "`n`$1`n"
    foreach ($line in ($normalizedSsh -split "`n")) {
        if ($line -match '^===(.+?)===\r?$') {
            if ($current) { $sections[$current] = ($buf -join "`n").Trim() }
            $current = $matches[1]; $buf = @()
        } else {
            $buf += $line
        }
    }
    if ($current -and $current -ne 'END') { $sections[$current] = ($buf -join "`n").Trim() }

    $info = @{}
    $info.hostname = $sections['HOSTNAME']
    $info.kernel   = $sections['UNAME']
    $info.uptime_raw = $sections['UPTIME']
    if ($sections['UPTIMESEC'] -match '^([\d.]+)\s') {
        $info.uptime_sec = [int][double]$matches[1]
    }

    # Loadavg
    if ($sections['LOADAVG'] -match '^([\d.]+)\s+([\d.]+)\s+([\d.]+)') {
        $info.load_1m  = [double]$matches[1]
        $info.load_5m  = [double]$matches[2]
        $info.load_15m = [double]$matches[3]
    }

    # Meminfo
    $mem = @{}
    foreach ($l in ($sections['MEMINFO'] -split "`n")) {
        if ($l -match '^(\w+):\s+(\d+)\s+kB') {
            $mem[$matches[1]] = [int64]$matches[2]
        }
    }
    if ($mem.Count -gt 0) {
        $totKB = $mem['MemTotal']
        $freeKB = $mem['MemAvailable']
        if (-not $freeKB) { $freeKB = $mem['MemFree'] }
        $info.mem_total_gb = [math]::Round($totKB / 1MB, 2)
        $info.mem_free_gb  = [math]::Round($freeKB / 1MB, 2)
        $info.mem_used_gb  = [math]::Round(($totKB - $freeKB) / 1MB, 2)
        $info.mem_used_percent = if ($totKB -gt 0) { [math]::Round((($totKB - $freeKB) / $totKB) * 100, 1) } else { 0 }
    }

    # CPU
    if ($sections['CPUINFO'] -match 'model name\s*:\s*(.+)') {
        $info.cpu_model = $matches[1].Trim()
    }
    if ($sections['CPUCORES']) {
        $info.cpu_cores = [int]$sections['CPUCORES']
    }

    # Temperature: значение бывает в милли-Цельсиях (например 45000 = 45°C)
    # или в обычных Цельсиях. Берём первую числовую строку и нормализуем.
    if ($sections['TEMP']) {
        $tempLine = ($sections['TEMP'] -split "`n" | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
        if ($tempLine) {
            $tempVal = [int]$tempLine
            if ($tempVal -gt 1000) { $tempVal = [int]($tempVal / 1000) }
            # отсечь явно мусорные значения
            if ($tempVal -ge 5 -and $tempVal -le 150) {
                $info.cpu_temp_c = $tempVal
            }
        }
    }

    # Disks
    $disks = @()
    foreach ($l in ($sections['DISKS'] -split "`n")) {
        if ($l -match '^(\S+)\s+([\d.]+\w?)\s+([\d.]+\w?)\s+([\d.]+\w?)\s+(\d+)%\s+(.+)$') {
            $disks += @{
                device       = $matches[1]
                size         = $matches[2]
                used         = $matches[3]
                avail        = $matches[4]
                used_percent = [int]$matches[5]
                mount        = $matches[6].Trim()
            }
        }
    }
    $info.disks = $disks

    # Process count
    if ($sections['PROCESSES'] -match '^\d+$') {
        $info.process_count = [int]$sections['PROCESSES']
    }

    # NET totals (для трафик-индикатора)
    $totalRx = [int64]0; $totalTx = [int64]0
    foreach ($l in ($sections['NET'] -split "`n")) {
        $l = $l.Trim()
        if ($l -match '^\S+:\s+(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)') {
            $totalRx += [int64]$matches[1]
            $totalTx += [int64]$matches[2]
        }
    }
    $info.net_total = @{ rx_bytes = $totalRx; tx_bytes = $totalTx }

    # Ports — парсим вывод ss/netstat. Строки вида "0.0.0.0:5000" или "[::]:22"
    $portMap = @{
        '22'='SSH'; '21'='FTP'; '80'='HTTP'; '443'='HTTPS'
        '139'='SMB'; '445'='SMB'; '111'='RPC'; '2049'='NFS'
        '5000'='DSM'; '5001'='DSM/SSL'; '5005'='DSM-Cluster'; '5006'='DSM-Cluster'
        '5357'='WSDAPI'; '5432'='PostgreSQL'; '3306'='MariaDB'
        '32400'='Plex'; '8096'='Jellyfin'; '8920'='Emby/SSL'
        '6690'='CloudStation'; '873'='rsync'; '548'='AFP'; '631'='IPP'
        '8200'='DLNA'; '1900'='SSDP'; '5353'='mDNS'; '161'='SNMP'
        '5061'='SIP/SSL'; '49152'='UPnP'
    }
    $ports = @()
    $seen = @{}
    foreach ($l in ($sections['PORTS'] -split "`n")) {
        $l = $l.Trim()
        if (-not $l) { continue }
        $portStr = $null
        $bind = $null
        if ($l -match '^\[?([0-9a-f:.\*]+)\]?:(\d+)$') {
            $bind = $matches[1]; $portStr = $matches[2]
        }
        if (-not $portStr) { continue }
        $portNum = [int]$portStr
        if ($seen.ContainsKey($portNum)) { continue }
        $seen[$portNum] = $true
        $isPublic = ($bind -eq '0.0.0.0' -or $bind -eq '::' -or $bind -eq '*')
        $ports += @{
            port    = $portNum
            bind    = $bind
            service = if ($portMap.ContainsKey($portStr)) { $portMap[$portStr] } else { '' }
            public  = $isPublic
        }
    }
    $info.ports = ,($ports | Sort-Object { $_.port })

    $result.info = $info
    return $result
}

# ----------------------------------------------------------------------------
# ОСНОВНОЙ ЦИКЛ
# ----------------------------------------------------------------------------
function Build-DataSnapshot {
    param([pscustomobject]$Cfg)

    # Статичные данные (меняются редко) — берём из кэша.
    # Get-CachedOrFetch перезапрашивает только когда TTL истёк.
    $os  = Get-CachedOrFetch 'os'          60  { Get-OSInfo }
    $mb  = Get-CachedOrFetch 'motherboard' 300 { Get-MotherboardInfo }
    $disk= Get-CachedOrFetch 'disk'        30  { Get-DiskInfo }

    # Динамические данные — обновляем каждый цикл (CPU load, RAM, GPU util, Net bytes)
    Write-Host "[+] CPU/RAM/GPU/Net..." -ForegroundColor Cyan
    $cpu = Get-CPUInfo
    $mem = Get-MemoryInfo
    $gpu = Get-GPUInfo
    $net = Get-NetworkInfo

    # Router и Synology: тяжёлые сетевые вызовы, кэшируем на 30 сек.
    # На ПЕРВОМ снепшоте пропускаем — чтобы не блокировать старт на 5-30 сек.
    # Реальные данные появятся со второго цикла (через 3 сек), кэш уже будет тёплый.
    $router = $null
    if ($Cfg.router.enabled) {
        $rEntry = $script:slowCache['router']
        if ($rEntry -and $rEntry.expiresAt -gt [DateTime]::Now) {
            $router = $rEntry.data
        } elseif ($script:firstSnapshot) {
            $router = @{ status='loading'; reachable=$false }
        } else {
            $router = Get-RouterInfo -Cfg $Cfg.router -AutoGateway $net.gateway
            $script:slowCache['router'] = @{ data=$router; expiresAt=[DateTime]::Now.AddSeconds(30) }
        }
    }

    $synology = $null
    if ($Cfg.synology.enabled) {
        $sEntry = $script:slowCache['synology']
        if ($sEntry -and $sEntry.expiresAt -gt [DateTime]::Now) {
            $synology = $sEntry.data
        } elseif ($script:firstSnapshot) {
            $synology = @{ status='loading'; enabled=$true; reachable=$false }
        } else {
            $synology = Get-SynologyInfo -Cfg $Cfg.synology
            $script:slowCache['synology'] = @{ data=$synology; expiresAt=[DateTime]::Now.AddSeconds(30) }
        }
    }

    # Тяжёлые данные читаем из фонового кэша — никакой блокировки основного цикла.
    # В режиме одиночного запуска (без -Watch) bgCache ещё не наполнен,
    # поэтому запускаем их синхронно для обратной совместимости.
    if ($script:bgRunspace) {
        $junk      = $script:bgCache['junk']
        $releases  = $script:bgCache['releases']
        $updates   = $script:bgCache['updates']
        $sysErrors = $script:bgCache['sysErrors']
    } else {
        Write-Host "[+] Junk scan..." -ForegroundColor Cyan
        $junk = Get-JunkInfo
        Write-Host "[+] GitHub releases..." -ForegroundColor Cyan
        $token = ''; if ($Cfg.PSObject.Properties['github_token']) { $token = [string]$Cfg.github_token }
        $releases = Get-ReleasesInfo -Token $token
        Write-Host "[+] Windows Updates..." -ForegroundColor Cyan
        $updates = Get-WindowsUpdatesInfo
        Write-Host "[+] System errors..." -ForegroundColor Cyan
        $sysErrors = Get-SystemErrors
    }

    $rigaUrl = ''
    $amsUrl  = ''
    if ($Cfg.PSObject.Properties['proxy_riga_url'])      { $rigaUrl = [string]$Cfg.proxy_riga_url }
    if ($Cfg.PSObject.Properties['proxy_amsterdam_url']) { $amsUrl  = [string]$Cfg.proxy_amsterdam_url }

    return @{
        meta = @{
            generated_at  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            generated_iso = (Get-Date).ToString('o')
            generator     = 'Get-SystemInfo.ps1'
            version       = '2.2'
            title         = $Cfg.dashboard.title
            operator      = $Cfg.dashboard.operator
            proxy_links   = @{
                riga      = $rigaUrl
                amsterdam = $amsUrl
            }
        }
        os          = $os
        cpu         = $cpu
        memory      = $mem
        gpu         = $gpu
        disk        = $disk
        motherboard = $mb
        network     = $net
        router      = $router
        synology    = $synology
        junk        = $junk
        releases    = $releases
        updates     = $updates
        sys_errors  = $sysErrors
    }
}

# ----------------------------------------------------------------------------
# HTTP API (localhost:7779) — выделенный blocking-runspace, отвечает мгновенно
# независимо от того, чем занят основной цикл. Читает json из httpShared,
# пишет сигналы обратно через bgCache / httpShared.
# ----------------------------------------------------------------------------
function Start-HttpServer {
    param([int]$Port = 7779)

    $shared  = $script:httpShared
    $bgCache = $script:bgCache

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('shared',  $shared)
    $rs.SessionStateProxy.SetVariable('bgCache', $bgCache)
    $rs.SessionStateProxy.SetVariable('port',    $Port)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $httpScript = {
        $ErrorActionPreference = 'Continue'
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$port/")
        try { $listener.Start() } catch { return }

        while ($listener.IsListening) {
            try {
                $ctx = $listener.GetContext()   # blocking — zero CPU spin
                $req = $ctx.Request
                $res = $ctx.Response
                try {
                    $res.AddHeader('Access-Control-Allow-Origin',          '*')
                    $res.AddHeader('Access-Control-Allow-Methods',         'POST,GET,OPTIONS')
                    $res.AddHeader('Access-Control-Allow-Headers',         'Content-Type')
                    $res.AddHeader('Access-Control-Allow-Private-Network', 'true')

                    $path   = $req.Url.AbsolutePath.ToLower()
                    $method = $req.HttpMethod.ToUpper()
                    $body   = $null
                    if ($req.HasEntityBody) {
                        try {
                            $reader = [System.IO.StreamReader]::new($req.InputStream)
                            $raw    = $reader.ReadToEnd()
                            $reader.Close()
                            if ($raw) { $body = $raw | ConvertFrom-Json }
                        } catch { }
                    }

                    $statusCode   = 200
                    $responseText = '{"ok":true}'

                    if ($method -eq 'OPTIONS') {
                        # CORS preflight
                    } elseif ($path -eq '/api/data' -and $method -eq 'GET') {
                        $j = $shared['json']
                        if ($j) {
                            $responseText = $j
                            $res.AddHeader('Cache-Control', 'no-cache, no-store')
                        } else {
                            $statusCode   = 503
                            $responseText = '{"error":"not ready yet"}'
                        }
                    } elseif ($path -eq '/api/scan') {
                        $bgCache['forceJunk'] = $true
                    } elseif ($path -eq '/api/cleanup') {
                        $shared['cleanupPayload'] = $body
                        $shared['cleanupPending'] = $true
                    } else {
                        $statusCode   = 404
                        $responseText = '{"ok":false,"error":"not found"}'
                    }

                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($responseText)
                    $res.StatusCode      = $statusCode
                    $res.ContentType     = 'application/json'
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                } catch { }
                try { $res.OutputStream.Close() } catch { }
            } catch {
                if (-not $listener.IsListening) { break }
                Start-Sleep -Milliseconds 100
            }
        }
    }

    $ps.AddScript($httpScript) | Out-Null
    $ps.BeginInvoke() | Out-Null

    $script:httpRunspace   = $rs
    $script:httpPowerShell = $ps
    Write-Host "[HTTP] Dedicated server started on :$Port (blocking runspace)" -ForegroundColor Cyan
}

# Shared cleanup launcher — used by file-signal fallback.
function Invoke-CleanupFromPayload {
    param($Payload)
    $cleanScript = Join-Path $script:HereDir 'Clean-Junk.ps1'
    if (-not (Test-Path $cleanScript)) { Write-Warning "Clean-Junk.ps1 not found"; return }

    # Always run elevated — ensures full access to all system and user folders.
    $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$cleanScript`""
    if ($Payload -and $Payload.cats -and $Payload.cats.Count -gt 0) {
        $argStr += " -CategoriesStr `"$($Payload.cats -join ',')`""
    }
    if ($Payload -and $Payload.browsers) { $argStr += ' -CloseBrowsers' }

    Write-Host ""
    Write-Host "[!] Cleanup triggered (elevated)" -ForegroundColor Yellow

    try {
        $psi             = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName    = 'powershell.exe'
        $psi.Arguments   = $argStr
        $psi.Verb        = 'RunAs'
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        Write-Host "[OK] Elevated cleanup started" -ForegroundColor Green
    } catch {
        Write-Host "[!] UAC denied — running without elevation" -ForegroundColor Yellow
        Start-Process powershell.exe -ArgumentList $argStr -WindowStyle Normal
    }
    $script:bgCache['forceJunk'] = $true
    $script:lastJunkCheck = [DateTime]::MinValue
}

# ----------------------------------------------------------------------------
# Проверка signal-файла от UI: если HTML-кнопка "Очистить мусор" сбросила
# в Downloads файл — он забирается, удаляется и запускается Clean-Junk.ps1.
# ----------------------------------------------------------------------------
function Test-ScanSignal {
    $signalPaths = @(
        (Join-Path $env:USERPROFILE 'Downloads\cybfortress_scan.signal'),
        (Join-Path $script:HereDir 'cybfortress_scan.signal')
    )
    foreach ($p in $signalPaths) {
        if (Test-Path $p) {
            try { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch { }
            Write-Host "[i] Scan signal received — forcing fresh junk scan..." -ForegroundColor Cyan
            $script:bgCache['forceJunk'] = $true
            $script:lastJunkCheck = [DateTime]::MinValue
            return $true
        }
    }
    return $false
}

function Test-CleanupSignal {
    # File-based fallback (kept for compatibility; HTTP API is the primary path now)
    $signalPaths = @(
        (Join-Path $env:USERPROFILE 'Downloads\cybfortress_cleanup.signal'),
        (Join-Path $script:HereDir  'cybfortress_cleanup.signal')
    )
    foreach ($p in $signalPaths) {
        if (Test-Path $p) {
            $sigJson = $null
            try {
                $raw = Get-Content -Raw -LiteralPath $p -ErrorAction SilentlyContinue
                if ($raw) { $sigJson = $raw | ConvertFrom-Json }
            } catch { }
            try { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch { }
            Write-Host "[FILE-SIGNAL] Cleanup signal received" -ForegroundColor Yellow
            Invoke-CleanupFromPayload -Payload $sigJson
            return $true
        }
    }
    return $false
}

# ----------------------------------------------------------------------------
# Кэш медленных функций: Get-CachedOrFetch 'key' <ttl_sec> { ... }
# ----------------------------------------------------------------------------
function Get-CachedOrFetch {
    param([string]$Key, [int]$TtlSeconds, [scriptblock]$Fetch)
    $now = [DateTime]::Now
    $entry = $script:slowCache[$Key]
    if ($entry -and $entry.expiresAt -gt $now) { return $entry.data }
    $data = & $Fetch
    $script:slowCache[$Key] = @{ data = $data; expiresAt = $now.AddSeconds($TtlSeconds) }
    return $data
}

function Write-Snapshot {
    param($Snapshot, [string]$Path)

    # -Compress убирает пробелы: JSON меньше на 40-60%, быстрее сериализация и передача
    $json = $Snapshot | ConvertTo-Json -Depth 10 -Compress
    # Держим актуальный JSON в памяти; HTTP runspace читает его через httpShared
    $script:currentSnapshotJson = $json
    $script:httpShared['json']  = $json

    # Файл пишем только при первом запуске и раз в 60 секунд.
    # Это нужно для initial load браузера; основным транспортом служит HTTP.
    $now = [DateTime]::Now
    if ($script:lastFileWrite -eq [DateTime]::MinValue -or ($now - $script:lastFileWrite).TotalSeconds -ge 60) {
        try {
            $js = "// Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by Get-SystemInfo.ps1`r`nwindow.SYSTEM_DATA = $json;"
            Set-Content -Path $Path -Value $js -Encoding UTF8
            $script:lastFileWrite = $now
        } catch { }
    }
}

# =============================================================================
# ФОНОВЫЙ WORKER — запускает тяжёлые сканы в отдельном Runspace,
# чтобы основной цикл никогда не блокировался.
# =============================================================================
function Start-BackgroundWorker {
    param([pscustomobject]$Cfg)

    $token = ''
    if ($Cfg.PSObject.Properties['github_token']) { $token = [string]$Cfg.github_token }
    $script:bgCache['githubToken'] = $token
    $script:bgCache['rootDir']     = $script:RootDir

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('bgCache', $script:bgCache)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $bgScript = {
        $ErrorActionPreference = 'Continue'
        $ProgressPreference    = 'SilentlyContinue'

        # ------------------------------------------------------------------
        # Вспомогательные функции (копии из основного скрипта)
        # ------------------------------------------------------------------
        function Get-FolderSize {
            param([string]$Path, [int]$TimeoutSec = 8)
            if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return [int64]0 }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $sum = [int64]0
                $files = [System.IO.Directory]::EnumerateFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)
                foreach ($f in $files) {
                    if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { break }
                    try { $sum += [System.IO.FileInfo]::new($f).Length } catch { }
                }
                return [int64]$sum
            } catch { return [int64]0 }
            finally { $sw.Stop() }
        }

        function Get-RecycleBinSize {
            $total = [int64]0
            try {
                $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $drives = [System.IO.DriveInfo]::GetDrives() |
                    Where-Object { $_.IsReady -and $_.DriveType -eq [System.IO.DriveType]::Fixed }
                foreach ($drv in $drives) {
                    $binPath = Join-Path $drv.RootDirectory.FullName "`$Recycle.Bin\$sid"
                    if (Test-Path -LiteralPath $binPath) { $total += Get-FolderSize $binPath }
                }
            } catch { }
            return $total
        }

        # ------------------------------------------------------------------
        # Сбор данных о мусоре (без кэширования — им управляет loop)
        # ------------------------------------------------------------------
        function Collect-JunkData {
            param([string]$RootDir)

            function Measure-Paths {
                param([string[]]$Paths)
                $sz = [int64]0
                foreach ($p in $Paths) {
                    try { if (Test-Path -LiteralPath $p) { $sz += Get-FolderSize $p } } catch { }
                }
                return $sz
            }

            $cats = @()

            $tempPaths = @($env:TEMP)
            $la = "$env:LOCALAPPDATA\Temp"
            if ($la -ne $env:TEMP) { $tempPaths += $la }
            $cats += @{ id='user_temp'; name='User Temp'; icon='T'; path=$env:TEMP; size_bytes=(Measure-Paths $tempPaths) }
            $cats += @{ id='windows_temp'; name='Windows Temp'; icon='W'; path="$env:WINDIR\Temp"; size_bytes=(Measure-Paths @("$env:WINDIR\Temp")) }
            $cats += @{ id='error_reports'; name='Error Reports'; icon='!'; path='WER + CrashDumps'
                        size_bytes=(Measure-Paths @("$env:LOCALAPPDATA\Microsoft\Windows\WER","$env:LOCALAPPDATA\CrashDumps","$env:ProgramData\Microsoft\Windows\WER\ReportQueue")) }

            $bpaths = [System.Collections.Generic.List[string]]::new()
            $bpaths.Add("$env:LOCALAPPDATA\Microsoft\Windows\INetCache")
            foreach ($sub in @('Default\Cache','Default\Code Cache','Default\GPUCache')) {
                $bpaths.Add("$env:LOCALAPPDATA\Google\Chrome\User Data\$sub")
                $bpaths.Add("$env:LOCALAPPDATA\Microsoft\Edge\User Data\$sub")
            }
            $ffBase = "$env:APPDATA\Mozilla\Firefox\Profiles"
            if (Test-Path $ffBase) {
                Get-ChildItem $ffBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $c = Join-Path $_.FullName 'cache2'; if (Test-Path $c) { $bpaths.Add($c) }
                }
            }
            $cats += @{ id='browser_cache'; name='Browser Cache'; icon='B'; path='Chrome/Edge/Firefox'; size_bytes=(Measure-Paths $bpaths.ToArray()) }
            $cats += @{ id='gpu_cache'; name='GPU Cache'; icon='G'; path='D3DS/NVIDIA/AMD/Intel'
                        size_bytes=(Measure-Paths @("$env:LOCALAPPDATA\D3DSCache","$env:LOCALAPPDATA\NVIDIA\DXCache","$env:LOCALAPPDATA\NVIDIA\GLCache","$env:LOCALAPPDATA\AMD\DxCache","$env:LOCALAPPDATA\AMD\GLCache","$env:LOCALAPPDATA\Intel\ShaderCache")) }

            $thumbSz = [int64]0
            $thumbDir = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
            if (Test-Path $thumbDir) { Get-ChildItem $thumbDir -Filter '*.db' -Force -ErrorAction SilentlyContinue | ForEach-Object { $thumbSz += $_.Length } }
            $cats += @{ id='thumbnails'; name='Thumbnails'; icon='I'; path=$thumbDir; size_bytes=$thumbSz }

            $apaths = [System.Collections.Generic.List[string]]::new()
            foreach ($sub in @('Cache','blob_storage','databases','gpucache','logs')) { $apaths.Add("$env:LOCALAPPDATA\Microsoft\Teams\$sub") }
            foreach ($sub in @('Cache','Code Cache','GPUCache')) { $apaths.Add("$env:APPDATA\discord\$sub") }
            $apaths.Add("$env:LOCALAPPDATA\Spotify\Storage"); $apaths.Add("$env:LOCALAPPDATA\Spotify\Data")
            foreach ($sub in @('Cache','Code Cache','GPUCache','logs')) { $apaths.Add("$env:APPDATA\Code\$sub") }
            $tdataPath = "$env:APPDATA\Telegram Desktop\tdata"
            if (Test-Path $tdataPath) {
                Get-ChildItem -LiteralPath $tdataPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    foreach ($cs in @('cache','media_cache','cache2')) { $cp = Join-Path $_.FullName $cs; if (Test-Path $cp) { $apaths.Add($cp) } }
                }
            }
            Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office" -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { $p = Join-Path $_.FullName 'OfficeFileCache'; if (Test-Path $p) { $apaths.Add($p) } }
            $cats += @{ id='app_cache'; name='App Cache'; icon='A'; path='Teams/Discord/Spotify/VSCode/Telegram'; size_bytes=(Measure-Paths $apaths.ToArray()) }

            $steamInstall = ''
            try { $steamInstall = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath } catch { }
            if (-not $steamInstall) { $steamInstall = 'C:\Program Files (x86)\Steam' }
            $steamSz = Measure-Paths @("$env:LOCALAPPDATA\Steam\htmlcache","$env:LOCALAPPDATA\Steam\logs","$steamInstall\logs","$steamInstall\dumps","$steamInstall\shadercache")
            if ($steamSz -gt 0) { $cats += @{ id='steam_cache'; name='Steam Cache'; icon='S'; path='Steam logs/htmlcache/shadercache'; size_bytes=$steamSz } }

            $bhpaths = [System.Collections.Generic.List[string]]::new()
            $histFiles = @('History','Visited Links','Top Sites','Favicons','Media History','Session Storage')
            foreach ($base in @("$env:LOCALAPPDATA\Google\Chrome\User Data","$env:LOCALAPPDATA\Microsoft\Edge\User Data","$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data")) {
                if (-not (Test-Path $base)) { continue }
                $profs = @("$base\Default") + @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Profile \d+$' } | ForEach-Object { $_.FullName })
                foreach ($prof in $profs) { foreach ($hf in $histFiles) { $fp = Join-Path $prof $hf; if (Test-Path $fp) { $bhpaths.Add($fp) } } }
            }
            $bhSz = [int64]0; foreach ($fp in $bhpaths) { try { $bhSz += [System.IO.FileInfo]::new($fp).Length } catch { } }
            if ($bhSz -gt 0) { $cats += @{ id='browser_history'; name='Browser History'; icon='H'; path='Chrome/Edge/Brave history files'; size_bytes=$bhSz } }

            $cats += @{ id='dev_cache'; name='Dev Tools Cache'; icon='D'; path='npm/pip/NuGet/Yarn'
                        size_bytes=(Measure-Paths @("$env:LOCALAPPDATA\npm-cache","$env:APPDATA\npm-cache","$env:LOCALAPPDATA\pip\Cache","$env:LOCALAPPDATA\NuGet\Cache","$env:LOCALAPPDATA\NuGet\v3-cache","$env:LOCALAPPDATA\Yarn\Cache")) }

            $extPaths = [System.Collections.Generic.List[string]]::new()
            foreach ($ep in @("$env:APPDATA\Microsoft\Windows\Recent","$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations","$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations","$env:USERPROFILE\AppData\LocalLow\Sun\Java\Deployment\cache","$env:APPDATA\Microsoft\Windows Media Player","$env:TEMP\chocolatey")) { $extPaths.Add($ep) }
            if (Test-Path "$env:LOCALAPPDATA\Packages") {
                Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Packages" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $p = Join-Path $_.FullName 'AC\Temp'; if (Test-Path $p) { $extPaths.Add($p) } }
            }
            $cats += @{ id='extended'; name='Extended Areas'; icon='X'; path='Recent/JumpLists/Java/StoreTemp'; size_bytes=(Measure-Paths $extPaths.ToArray()) }
            $cats += @{ id='prefetch'; name='Prefetch'; icon='P'; path="$env:WINDIR\Prefetch"; size_bytes=(Measure-Paths @("$env:WINDIR\Prefetch")) }
            $cats += @{ id='system_junk'; name='System Junk'; icon='S'; path='CBS/PatchCache/Minidump/Font'
                        size_bytes=(Measure-Paths @("$env:WINDIR\Logs\CBS","$env:WINDIR\Installer\`$PatchCache`$","$env:WINDIR\Minidump","$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache","$env:WINDIR\memory.dmp")) }
            $cats += @{ id='windows_update'; name='Windows Update'; icon='U'; path='SoftwareDistribution'
                        size_bytes=(Measure-Paths @("$env:WINDIR\SoftwareDistribution\Download","$env:WINDIR\Logs\WindowsUpdate")) }
            $cats += @{ id='system_logs'; name='System Logs'; icon='L'; path='System32\LogFiles'
                        size_bytes=(Measure-Paths @("$env:WINDIR\System32\LogFiles","$env:WINDIR\debug")) }

            $evtSz = [int64]0
            try { Get-WinEvent -ListLog Application,System,Security,Setup -ErrorAction SilentlyContinue | ForEach-Object { try { $evtSz += [int64]$_.FileSize } catch { } } } catch { }
            $cats += @{ id='event_logs'; name='Event Logs'; icon='E'; path='Windows Event Logs'; size_bytes=$evtSz }

            try {
                $vssItems = @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)
                if ($vssItems.Count -gt 1) {
                    $sviSz = [int64]0; try { $sviSz = Get-FolderSize "$env:SystemDrive\System Volume Information" } catch { }
                    $cats += @{ id='vss'; name="VSS Shadows ($($vssItems.Count) copies)"; icon='V'; path='System Volume Information'; size_bytes=$sviSz }
                }
            } catch { }

            $winOldSz = Get-FolderSize 'C:\Windows.old'
            if ($winOldSz -gt 0) { $cats += @{ id='windows_old'; name='Windows.old'; icon='X'; path='C:\Windows.old'; size_bytes=$winOldSz } }
            $cats += @{ id='recycle_bin'; name='Recycle Bin'; icon='R'; path='$Recycle.Bin'; size_bytes=(Get-RecycleBinSize) }

            $emptyCount = 0
            $emptyRoots = @($env:TEMP,"$env:LOCALAPPDATA\Temp","$env:USERPROFILE\Documents","$env:USERPROFILE\Downloads","$env:USERPROFILE\Desktop","$env:USERPROFILE\Pictures","$env:USERPROFILE\Videos")
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            foreach ($root in $emptyRoots) {
                if (-not (Test-Path $root)) { continue }
                try {
                    Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        if ($sw.Elapsed.TotalSeconds -gt 6) { return }
                        try { if (-not [bool]([System.IO.Directory]::EnumerateFileSystemEntries($_.FullName) | Select-Object -First 1)) { $emptyCount++ } } catch { }
                    }
                } catch { }
                if ($sw.Elapsed.TotalSeconds -gt 6) { break }
            }
            $sw.Stop()
            if ($emptyCount -gt 0) { $cats += @{ id='empty_folders'; name="Empty Folders ($emptyCount)"; icon='∅'; path='Documents/Downloads/Desktop/Temp'; size_bytes=[int64]0 } }

            $total = [int64]0; foreach ($c in $cats) { try { $total += [int64]($c.size_bytes) } catch { } }
            $totalCount = ($cats | Where-Object { $_.size_bytes -gt 0 }).Count

            $lastCleanLog = $null
            $logFile = Join-Path $RootDir 'data\last-cleanup.json'
            if (Test-Path $logFile) { try { $lastCleanLog = Get-Content -Raw -Path $logFile | ConvertFrom-Json } catch { } }

            return @{
                scanned_at       = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
                total_bytes      = $total
                total_categories = $totalCount
                categories       = ,$cats
                last_cleanup     = $lastCleanLog
            }
        }

        # ------------------------------------------------------------------
        # GitHub releases (параллельные HTTP запросы, таймаут 7 сек)
        # ------------------------------------------------------------------
        function Collect-ReleasesData {
            param([string]$Token)
            $repos = @('MHSanaei/3x-ui','XTLS/Xray-core','amnezia-vpn/amneziawg-go','apernet/hysteria')
            $client = [System.Net.Http.HttpClient]::new()
            $client.Timeout = [System.TimeSpan]::FromSeconds(7)
            $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'CYBERFORTRESS-dashboard') | Out-Null
            $client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'application/vnd.github+json') | Out-Null
            if ($Token) { $client.DefaultRequestHeaders.TryAddWithoutValidation('Authorization', "Bearer $Token") | Out-Null }
            $taskArr = [System.Threading.Tasks.Task[]]($repos | ForEach-Object {
                $client.GetStringAsync("https://api.github.com/repos/$_/releases?per_page=5")
            })
            try { [System.Threading.Tasks.Task]::WaitAll($taskArr, 8000) } catch { }
            $items = for ($i = 0; $i -lt $repos.Count; $i++) {
                if ($taskArr[$i].Status -eq 'RanToCompletion') {
                    try {
                        $resp   = $taskArr[$i].Result | ConvertFrom-Json
                        $stable = $resp | Where-Object { -not $_.prerelease -and -not $_.draft } | Select-Object -First 1
                        $pre    = $resp | Where-Object {     $_.prerelease -and -not $_.draft } | Select-Object -First 1
                        @{ repo=$repos[$i]
                           stable     = if ($stable) { @{ tag=$stable.tag_name; name=$stable.name; published=$stable.published_at; url=$stable.html_url } } else { $null }
                           prerelease = if ($pre)    { @{ tag=$pre.tag_name;    name=$pre.name;    published=$pre.published_at;    url=$pre.html_url    } } else { $null }
                           error=$null }
                    } catch { @{ repo=$repos[$i]; stable=$null; prerelease=$null; error=$_.Exception.Message } }
                } else {
                    $errMsg = if ($taskArr[$i].Exception) { $taskArr[$i].Exception.GetBaseException().Message } else { 'timeout' }
                    @{ repo=$repos[$i]; stable=$null; prerelease=$null; error=$errMsg }
                }
            }
            $client.Dispose()
            return @{ scanned_at=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); items=,$items }
        }

        # ------------------------------------------------------------------
        # Windows Updates (COM, нужен MTA — работает в большинстве систем)
        # ------------------------------------------------------------------
        function Collect-UpdatesData {
            $result = @{ scanned_at=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); available=0; critical=0; items=,@(); error=$null }
            try {
                $session  = New-Object -ComObject Microsoft.Update.Session
                $searcher = $session.CreateUpdateSearcher()
                $sr = $searcher.Search('IsInstalled=0 and IsHidden=0')
                $items = @(); $crit = 0
                foreach ($u in $sr.Updates) {
                    $isCrit = $false
                    try { foreach ($cat in $u.Categories) { if ($cat.Name -match 'Critical|Security') { $isCrit = $true; break } } } catch { }
                    if ($isCrit) { $crit++ }
                    $items += @{ title=$u.Title; size_mb=if ($u.MaxDownloadSize) { [math]::Round([int64]$u.MaxDownloadSize/1MB,1) } else { 0 }; critical=$isCrit }
                    if ($items.Count -ge 15) { break }
                }
                $result.available = $sr.Updates.Count; $result.critical = $crit; $result.items = ,$items
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($session) | Out-Null
            } catch { $result.error = $_.Exception.Message }
            return $result
        }

        # ------------------------------------------------------------------
        # Системные ошибки (Event Log, кэш 300 сек)
        # ------------------------------------------------------------------
        function Collect-ErrorsData {
            $errors = @()
            try {
                $cutoff = [DateTime]::Now.AddDays(-2)
                $events = Get-WinEvent -FilterHashtable @{ LogName='System','Application'; Level=1,2; StartTime=$cutoff } -MaxEvents 25 -ErrorAction SilentlyContinue
                foreach ($e in $events) {
                    $msg = $e.Message; if ($msg.Length -gt 240) { $msg = $msg.Substring(0,240) + '...' }
                    $errors += @{ time=$e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); source=$e.ProviderName; log=$e.LogName; level=if ($e.Level -eq 1) { 'CRITICAL' } else { 'ERROR' }; event_id=$e.Id; message=$msg }
                }
            } catch { }
            return @{ scanned_at=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); count=$errors.Count; items=,$errors }
        }

        # ------------------------------------------------------------------
        # Основной фоновый цикл
        # ------------------------------------------------------------------
        $junkCheckedAt = [DateTime]::MinValue
        $relCheckedAt  = [DateTime]::MinValue
        $updCheckedAt  = [DateTime]::MinValue
        $errCheckedAt  = [DateTime]::MinValue

        while ($true) {
            $loopStart = [DateTime]::Now
            $now       = $loopStart

            # Системные ошибки (быстро ~1s, каждые 5 мин)
            if (($now - $errCheckedAt).TotalSeconds -ge 300) {
                try { $bgCache['sysErrors'] = Collect-ErrorsData } catch { }
                $errCheckedAt = [DateTime]::Now
            }

            # GitHub releases (~7-8s параллельно, каждые 30 мин)
            if (($now - $relCheckedAt).TotalSeconds -ge 1800) {
                try { $bgCache['releases'] = Collect-ReleasesData -Token $bgCache['githubToken'] } catch { }
                $relCheckedAt = [DateTime]::Now
            }

            # Junk scan (~20-30s, каждые 2 мин или по требованию)
            if ($bgCache['forceJunk'] -or ($now - $junkCheckedAt).TotalSeconds -ge 120) {
                $bgCache['forceJunk'] = $false
                try { $bgCache['junk'] = Collect-JunkData -RootDir $bgCache['rootDir'] } catch { }
                $junkCheckedAt = [DateTime]::Now
            }

            # Windows Updates (COM ~5-10s, каждые 30 мин)
            if (($now - $updCheckedAt).TotalSeconds -ge 1800) {
                try { $bgCache['updates'] = Collect-UpdatesData } catch { }
                $updCheckedAt = [DateTime]::Now
            }

            # Спим ровно столько, чтобы цикл занимал ~10 сек независимо от длительности операций
            $elapsed = ([DateTime]::Now - $loopStart).TotalSeconds
            $sleep   = [math]::Max(1, [math]::Min(10, 10 - [int]$elapsed))
            Start-Sleep -Seconds $sleep
        }
    }

    $ps.AddScript($bgScript) | Out-Null
    $ps.BeginInvoke() | Out-Null

    $script:bgRunspace   = $rs
    $script:bgPowerShell = $ps
    Write-Host "[BG] Background worker started — junk/releases/updates/errors run async" -ForegroundColor Cyan
}

# =============================================================================
# ENTRY POINT
# =============================================================================
$envVars = Load-Env -Path $EnvPath
$cfg = Load-Config -Path $ConfigPath -EnvVars $envVars

Write-Host ""
Write-Host "==================================================" -ForegroundColor Magenta
Write-Host "  CYBERFORTRESS // Telemetry Collector" -ForegroundColor Magenta
Write-Host "==================================================" -ForegroundColor Magenta
Write-Host ""

if ($Watch) {
    Write-Host "Режим: WATCH (интервал $Interval сек). Ctrl+C — остановка." -ForegroundColor Yellow
    Write-Host ""
    # HTTP server runs in its own blocking runspace — responds instantly at any time
    Start-HttpServer
    # Background runspace handles heavy ops (junk scan, GitHub, WU, errors)
    Start-BackgroundWorker -Cfg $cfg
    while ($true) {
        # Cleanup requested by HTTP runspace
        if ($script:httpShared['cleanupPending']) {
            $payload = $script:httpShared['cleanupPayload']
            $script:httpShared['cleanupPending'] = $false
            $script:httpShared['cleanupPayload'] = $null
            Write-Host "[HTTP] /api/cleanup received" -ForegroundColor Yellow
            Invoke-CleanupFromPayload -Payload $payload
        }

        Test-ScanSignal    | Out-Null
        Test-CleanupSignal | Out-Null

        $snap = Build-DataSnapshot -Cfg $cfg
        Write-Snapshot -Snapshot $snap -Path $OutputPath
        $script:firstSnapshot = $false   # со следующего цикла роутер/синолоджи загружаются
        Write-Host "[OK] $(Get-Date -Format 'HH:mm:ss') -> $OutputPath" -ForegroundColor Green
        Start-Sleep -Seconds $Interval
    }
} else {
    $snap = Build-DataSnapshot -Cfg $cfg
    Write-Snapshot -Snapshot $snap -Path $OutputPath
    Write-Host ""
    Write-Host "[OK] Снепшот сохранён: $OutputPath" -ForegroundColor Green

    if ($Open) {
        $html = Join-Path $script:RootDir 'frontend\index.html'
        if (Test-Path $html) {
            Write-Host "[+] Открытие dashboard..." -ForegroundColor Cyan
            Start-Process $html
        }
    }
}
