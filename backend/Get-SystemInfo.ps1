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
        $bankIndex = 0
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
            $bankIndex++
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
                speed_mbps  = [math]::Round($if.LinkSpeed.Replace(' Gbps','000').Replace(' Mbps','') -as [double], 0) # простое преобразование
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

    # DNS resolve test
    try {
        $dnsTest = Test-NetConnection -ComputerName 8.8.8.8 -Port 53 -InformationLevel Quiet -ErrorAction SilentlyContinue
        $result.internet_dns_ok = [bool]$dnsTest
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
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(0xA)
        $sum = 0
        if ($bin -and $bin.Items()) {
            foreach ($item in $bin.Items()) { $sum += [int64]$item.Size }
        }
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        return [int64]$sum
    } catch { return 0 }
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
    $apaths.Add("$env:APPDATA\Telegram Desktop\tdata\user_data\cache")
    $apaths.Add("$env:APPDATA\Telegram Desktop\tdata\user_data\media_cache")
    Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $p = Join-Path $_.FullName 'OfficeFileCache'; if (Test-Path $p) { $apaths.Add($p) } }
    $cats += @{ id='app_cache'; name='App Cache'; icon='A'; path='Teams/Discord/Spotify/VSCode/Telegram'
                size_bytes=(Measure-Paths $apaths.ToArray()) }

    # 8. Dev Tools Cache (npm + pip + NuGet + Yarn)
    $cats += @{ id='dev_cache'; name='Dev Tools Cache'; icon='D'; path='npm/pip/NuGet/Yarn'
                size_bytes=(Measure-Paths @(
                    "$env:LOCALAPPDATA\npm-cache",
                    "$env:APPDATA\npm-cache",
                    "$env:LOCALAPPDATA\pip\Cache",
                    "$env:LOCALAPPDATA\NuGet\Cache",
                    "$env:LOCALAPPDATA\NuGet\v3-cache",
                    "$env:LOCALAPPDATA\Yarn\Cache")) }

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

    $total = [int64]0
    foreach ($c in $cats) { $total += [int64]$c.size_bytes }
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

    Write-Host "[+] Сбор данных ОС..." -ForegroundColor Cyan
    $os  = Get-OSInfo

    Write-Host "[+] CPU..." -ForegroundColor Cyan
    $cpu = Get-CPUInfo

    Write-Host "[+] RAM..." -ForegroundColor Cyan
    $mem = Get-MemoryInfo

    Write-Host "[+] GPU..." -ForegroundColor Cyan
    $gpu = Get-GPUInfo

    Write-Host "[+] Диски..." -ForegroundColor Cyan
    $disk = Get-DiskInfo

    Write-Host "[+] Материнская плата..." -ForegroundColor Cyan
    $mb = Get-MotherboardInfo

    Write-Host "[+] Сеть..." -ForegroundColor Cyan
    $net = Get-NetworkInfo

    $router = $null
    if ($Cfg.router.enabled) {
        Write-Host "[+] Роутер..." -ForegroundColor Cyan
        $router = Get-RouterInfo -Cfg $Cfg.router -AutoGateway $net.gateway
    }

    $synology = $null
    if ($Cfg.synology.enabled) {
        Write-Host "[+] Synology NAS ($($Cfg.synology.host))..." -ForegroundColor Cyan
        $synology = Get-SynologyInfo -Cfg $Cfg.synology
    }

    # Тяжёлые сканы — на первом цикле пропускаем, snapshot появляется быстро.
    if ($script:firstSnapshotDone) {
        Write-Host "[+] Junk scan..." -ForegroundColor Cyan
        $junk = Get-JunkInfo

        Write-Host "[+] GitHub releases..." -ForegroundColor Cyan
        $token = ''
        if ($Cfg.PSObject.Properties['github_token']) { $token = [string]$Cfg.github_token }
        $releases = Get-ReleasesInfo -Token $token

        Write-Host "[+] Windows Updates..." -ForegroundColor Cyan
        $updates = Get-WindowsUpdatesInfo

        Write-Host "[+] System errors..." -ForegroundColor Cyan
        $sysErrors = Get-SystemErrors
    } else {
        $junk     = @{ scanned_at=''; total_bytes=0; total_categories=0; categories=,@(); status='scanning' }
        $releases = @{ scanned_at=''; items=,@(); status='scanning' }
        $updates  = @{ scanned_at=''; available=$null; critical=0; items=,@(); status='scanning' }
        $sysErrors= @{ scanned_at=''; count=0; items=,@(); status='scanning' }
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
# Проверка signal-файла от UI: если HTML-кнопка "Очистить мусор" сбросила
# в Downloads файл — он забирается, удаляется и запускается Clean-Junk.ps1.
# ----------------------------------------------------------------------------
function Test-CleanupSignal {
    $signalPaths = @(
        (Join-Path $env:USERPROFILE 'Downloads\cybfortress_cleanup.signal'),
        (Join-Path $script:HereDir 'cybfortress_cleanup.signal')
    )
    foreach ($p in $signalPaths) {
        if (Test-Path $p) {
            try { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch { }
            $cleanScript = Join-Path $script:HereDir 'Clean-Junk.ps1'
            if (Test-Path $cleanScript) {
                Write-Host ""
                Write-Host "[!] Cleanup signal received — launching elevated cleaner..." -ForegroundColor Yellow
                Write-Host "    UAC prompt will appear. Click YES to allow." -ForegroundColor Cyan
                try {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName  = 'powershell.exe'
                    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$cleanScript`""
                    $psi.Verb      = 'RunAs'
                    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
                    $proc = [System.Diagnostics.Process]::Start($psi)
                    $proc.WaitForExit()
                    Write-Host "[OK] Cleanup finished (exit code: $($proc.ExitCode))" -ForegroundColor Green
                } catch {
                    # UAC declined or error — fall back to same-process run
                    Write-Host "[!] Elevation denied or failed, running without admin..." -ForegroundColor Yellow
                    & $cleanScript
                }
                # форсируем пересбор junk-данных
                $script:lastJunkCheck = [DateTime]::MinValue
            } else {
                Write-Warning "Clean-Junk.ps1 not found next to Get-SystemInfo.ps1"
            }
            return $true
        }
    }
    return $false
}

function Write-Snapshot {
    param($Snapshot, [string]$Path)

    $json = $Snapshot | ConvertTo-Json -Depth 10 -Compress:$false
    $js = "// Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by Get-SystemInfo.ps1`r`nwindow.SYSTEM_DATA = $json;"
    Set-Content -Path $Path -Value $js -Encoding UTF8
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
    $script:firstSnapshotDone = $false
    while ($true) {
        # Проверка signal-файла от кнопки "Очистить мусор"
        Test-CleanupSignal | Out-Null

        $snap = Build-DataSnapshot -Cfg $cfg
        Write-Snapshot -Snapshot $snap -Path $OutputPath
        $script:firstSnapshotDone = $true
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
