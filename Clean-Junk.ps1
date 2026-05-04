# =============================================================================
# Clean-Junk.ps1  -  CYBERFORTRESS // System Junk Cleaner
# All string literals are ASCII/English to avoid PS5 encoding issues.
# Usage:
#   .\Clean-Junk.ps1           -- real cleanup
#   .\Clean-Junk.ps1 -DryRun   -- scan only, nothing deleted
# =============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun,
    # Remove hiberfil.sys (= RAM size, e.g. 16-32 GB). Disables hibernate + fast-startup.
    # Re-enable anytime: powercfg /h on
    [switch]$DisableHibernate
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function Get-FolderSize {
    param([string]$Path, [int]$TimeoutSec = 5)
    if (-not $Path) { return [int64]0 }
    try { if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return [int64]0 } } catch { return [int64]0 }

    $sw    = [System.Diagnostics.Stopwatch]::StartNew()
    $sum   = [int64]0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { break }
        $dir = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $stack.Clear(); break }
                try { $sum += [System.IO.FileInfo]::new($f).Length } catch { }
            }
        } catch { }
        try {
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $stack.Clear(); break }
                try {
                    $attr = [System.IO.File]::GetAttributes($sub)
                    if (-not ($attr -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($sub) }
                } catch { }
            }
        } catch { }
    }
    $sw.Stop()
    return [int64]$sum
}

function Format-Bytes {
    param([int64]$n)
    if ($n -lt 1KB) { return "$n B" }
    if ($n -lt 1MB) { return "{0:N1} KB" -f ($n / 1KB) }
    if ($n -lt 1GB) { return "{0:N1} MB" -f ($n / 1MB) }
    return "{0:N2} GB" -f ($n / 1GB)
}

# Clean a folder's CONTENTS (not the folder itself).
# Returns result hashtable.
function Clear-FolderContents {
    param([string]$Path, [switch]$DryRun, [string]$Label = '')
    $r = @{
        path          = $Path
        label         = $Label
        existed       = $false
        size_before   = 0
        size_after    = 0
        freed_bytes   = 0
        files_removed = 0
        errors        = 0
    }
    try { $exists = Test-Path -LiteralPath $Path } catch { return $r }
    if (-not $exists) { return $r }
    $r.existed     = $true
    $r.size_before = Get-FolderSize $Path

    if (-not $DryRun) {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                $r.files_removed++
            } catch { $r.errors++ }
        }
    }

    # After deletion, measure remaining size (2s timeout — folder is nearly empty, so instant)
    $r.size_after  = if ($DryRun) { $r.size_before } else { Get-FolderSize $Path 2 }
    $r.freed_bytes = [math]::Max([int64]0, [int64]$r.size_before - [int64]$r.size_after)
    return $r
}

# Enumerate all Chrome/Edge/Firefox user profiles and return their cache paths.
function Get-BrowserCachePaths {
    param([string]$BrowserBase, [string]$CacheSubPath)
    $paths = @()
    if (-not (Test-Path $BrowserBase)) { return $paths }
    # Default profile
    $def = Join-Path $BrowserBase $CacheSubPath
    if (Test-Path $def) { $paths += $def }
    # Numbered profiles (Profile 1, Profile 2 ...)
    Get-ChildItem -LiteralPath $BrowserBase -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Profile \d+$' } |
        ForEach-Object {
            $p = Join-Path $_.FullName ($CacheSubPath -replace '^Default.', '')
            if (Test-Path $p) { $paths += $p }
        }
    return $paths
}

# Clean single file (e.g. memory.dmp)
function Clear-SingleFile {
    param([string]$Path, [switch]$DryRun, [string]$Label = '')
    $r = @{
        path          = $Path
        label         = $Label
        existed       = $false
        size_before   = 0
        size_after    = 0
        freed_bytes   = 0
        files_removed = 0
        errors        = 0
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    try {
        $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $r.existed     = $true
        $r.size_before = $fi.Length
        if (-not $DryRun) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            $r.files_removed = 1
        }
    } catch { $r.errors++ }
    $r.size_after  = 0
    $r.freed_bytes = $r.size_before
    return $r
}

# Stop a service safely with timeout — Stop-Service blocks indefinitely if service is busy
function Stop-ServiceSafe {
    param([string]$Name, [int]$TimeoutSec = 10)
    try {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') { return $svc?.Status.ToString() }
        $svc.Stop()   # initiates stop without blocking
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            Start-Sleep -Milliseconds 400
            $svc.Refresh()
            if ($svc.Status -eq 'Stopped') { break }
        }
        return 'Running'
    } catch { return 'Unknown' }
}
function Start-ServiceSafe {
    param([string]$Name, [string]$PrevState)
    if ($PrevState -eq 'Running') {
        try { Start-Service -Name $Name -ErrorAction SilentlyContinue } catch { }
    }
}

# Recycle Bin via Shell.Application COM
function Clear-RecycleBinSafe {
    param([switch]$DryRun)
    $r = @{ path='Recycle Bin'; label='Recycle Bin'; existed=$true
            size_before=0; size_after=0; freed_bytes=0; files_removed=0; errors=0 }
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin   = $shell.Namespace(0xA)
        if ($bin -and $bin.Items()) {
            foreach ($it in $bin.Items()) { $r.size_before += [int64]$it.Size; $r.files_removed++ }
        }
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    } catch { $r.errors++ }

    if (-not $DryRun) {
        try { Clear-RecycleBin -Force -ErrorAction Stop }
        catch { $r.errors++ }
    }
    $r.freed_bytes = $r.size_before
    return $r
}

function Write-Row {
    param($r, [string]$name)
    $label = if ($r.label) { $r.label } else { $name }
    Write-Host ("[~] {0,-28}" -f $label) -NoNewline -ForegroundColor Cyan
    if ($r.existed) {
        $freed = Format-Bytes $r.freed_bytes
        $before = Format-Bytes $r.size_before
        Write-Host (" {0,9} -> {1,-9}  freed: {2}  errors:{3}" -f `
            $before, (Format-Bytes $r.size_after), $freed, $r.errors) -ForegroundColor Green
    } else {
        Write-Host " (not found)" -ForegroundColor DarkGray
    }
}

function Get-DiskFree {
    param([string]$Drive = 'C:')
    try {
        $d = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction SilentlyContinue
        if ($d) { return @{ free = [int64]$d.FreeSpace; total = [int64]$d.Size } }
    } catch {}
    return @{ free = [int64]0; total = [int64]0 }
}

function Get-OsInfo {
    try {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
        return "$($os.CSName) -- $($os.Caption) (Build $($os.BuildNumber))"
    } catch { return 'Unknown' }
}

function Write-MdReport {
    param($Results, $Summary, $DiskBefore, $DiskAfter, $OsInfo, $LogDir)

    $stamp  = $Summary.finished_at -replace '[:\s]', '-'
    $mdPath = Join-Path $LogDir "cleanup-$stamp.md"
    $sb     = [System.Text.StringBuilder]::new(8192)

    $null = $sb.AppendLine('# CYBERFORTRESS // CLEANUP REPORT')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("**Date:** $($Summary.finished_at)  ")
    $null = $sb.AppendLine("**Duration:** $($Summary.elapsed_sec) sec  ")
    $null = $sb.AppendLine("**Mode:** $(if ($Summary.dry_run) { 'DRY-RUN (nothing deleted)' } else { 'FULL CLEANUP (Administrator)' })  ")
    $null = $sb.AppendLine("**System:** $OsInfo")
    $null = $sb.AppendLine(''); $null = $sb.AppendLine('---'); $null = $sb.AppendLine('')

    # --- Disk space (ground truth) ---
    if ($DiskBefore.total -gt 0) {
        $pctB  = [math]::Round($DiskBefore.free / $DiskBefore.total * 100, 1)
        $pctA  = [math]::Round($DiskAfter.free  / $DiskAfter.total  * 100, 1)
        $delta = $DiskAfter.free - $DiskBefore.free
        $dAbs  = Format-Bytes ([math]::Abs($delta))
        $dStr  = if ($delta -ge 0) { "+ $dAbs" } else { "- $dAbs" }
        $null = $sb.AppendLine('## DISK C: -- VERIFIED RESULT (ground truth)')
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('| | Value |'); $null = $sb.AppendLine('|---|---|')
        $null = $sb.AppendLine("| Free before | $(Format-Bytes $DiskBefore.free) of $(Format-Bytes $DiskBefore.total) ($pctB%) |")
        $null = $sb.AppendLine("| Free after  | $(Format-Bytes $DiskAfter.free) of $(Format-Bytes $DiskAfter.total) ($pctA%) |")
        $null = $sb.AppendLine("| **Real disk change** | **$dStr** |")
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('> Note: GPU cache and thumbnails rebuild automatically seconds after cleanup.')
        $null = $sb.AppendLine('> The real disk delta may be less than the reported freed value.')
        $null = $sb.AppendLine(''); $null = $sb.AppendLine('---'); $null = $sb.AppendLine('')
    }

    # --- Summary ---
    $totalErr   = [int]($Results | ForEach-Object { [int]$_.errors }        | Measure-Object -Sum).Sum
    $totalFiles = [int]($Results | ForEach-Object { [int]$_.files_removed } | Measure-Object -Sum).Sum
    $null = $sb.AppendLine('## SUMMARY')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('| Metric | Value |'); $null = $sb.AppendLine('|--------|-------|')
    $null = $sb.AppendLine("| **Total freed (reported)** | **$(Format-Bytes $Summary.freed_bytes)** |")
    $null = $sb.AppendLine("| Scanned before cleanup | $(Format-Bytes $Summary.total_before) |")
    $null = $sb.AppendLine("| Duration | $($Summary.elapsed_sec) sec |")
    $null = $sb.AppendLine("| Files removed | $totalFiles |")
    $null = $sb.AppendLine("| Total errors (locked files) | $totalErr |")
    $null = $sb.AppendLine(''); $null = $sb.AppendLine('---'); $null = $sb.AppendLine('')

    # --- Cleaned categories ---
    $cleaned = @($Results |
        Where-Object { $_.existed -and ([int64]$_.freed_bytes -gt 0 -or [int]$_.files_removed -gt 0) } |
        Sort-Object { [int64]$_.freed_bytes } -Descending)
    if ($cleaned.Count -gt 0) {
        $null = $sb.AppendLine("## CLEANED ($($cleaned.Count) categories)")
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('| Category | Before | Freed | Files | Errors |')
        $null = $sb.AppendLine('|----------|--------|-------|-------|--------|')
        foreach ($r in $cleaned) {
            $flag = if ([int]$r.errors -gt 0) { ' !' } else { '' }
            $null = $sb.AppendLine("| $($r.label)$flag | $(Format-Bytes $r.size_before) | **$(Format-Bytes $r.freed_bytes)** | $($r.files_removed) | $($r.errors) |")
        }
        $null = $sb.AppendLine('')
    }

    # --- Not found ---
    $skipped = @($Results | Where-Object { -not $_.existed })
    if ($skipped.Count -gt 0) {
        $null = $sb.AppendLine('---'); $null = $sb.AppendLine('')
        $null = $sb.AppendLine("## NOT FOUND -- SKIPPED ($($skipped.Count))")
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('| Category | Path |'); $null = $sb.AppendLine('|----------|------|')
        foreach ($r in $skipped) { $null = $sb.AppendLine("| $($r.label) | $($r.path) |") }
        $null = $sb.AppendLine('')
    }

    # --- Errors ---
    $errItems = @($Results | Where-Object { $_.existed -and [int]$_.errors -gt 0 })
    if ($errItems.Count -gt 0) {
        $null = $sb.AppendLine('---'); $null = $sb.AppendLine('')
        $null = $sb.AppendLine('## ERRORS (locked files -- normal)')
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('| Category | Locked | Note |'); $null = $sb.AppendLine('|----------|--------|------|')
        foreach ($r in $errItems) {
            $null = $sb.AppendLine("| $($r.label) | $($r.errors) | Locked by running process -- close app or reboot to fully free |")
        }
        $null = $sb.AppendLine('')
    }

    $null = $sb.AppendLine('---'); $null = $sb.AppendLine('')
    $null = $sb.AppendLine('## BACKGROUND PROCESSES')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('- **DISM WinSxS:** started in background after window closed')
    $null = $sb.AppendLine('  (may take 5-30 min, can free 0-8 GB from Windows component store)')
    $null = $sb.AppendLine(''); $null = $sb.AppendLine('---'); $null = $sb.AppendLine('')
    $null = $sb.AppendLine('*CYBERFORTRESS // Clean-Junk.ps1*')

    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($mdPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
        return $mdPath
    } catch { return $null }
}

# ============================================================================
# Banner
# ============================================================================
Write-Host ""
Write-Host "================================================" -ForegroundColor Magenta
Write-Host "  CYBERFORTRESS // SYSTEM JUNK CLEANER" -ForegroundColor Magenta
if ($DryRun) { Write-Host "  >>> DRY-RUN: scan only, nothing deleted <<<" -ForegroundColor Yellow }
Write-Host "================================================" -ForegroundColor Magenta
Write-Host ""

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  [!] Not running as Administrator." -ForegroundColor Yellow
    Write-Host "      Some system folders (Windows\Temp, Prefetch, Minidump, SoftwareDistribution)" -ForegroundColor DarkGray
    Write-Host "      require elevation. User-level items will still be cleaned." -ForegroundColor DarkGray
    Write-Host ""
}

$startTime  = Get-Date
$results    = @()
$osInfo     = Get-OsInfo
$diskBefore = Get-DiskFree 'C:'
Write-Host ("  System: $osInfo") -ForegroundColor DarkGray
Write-Host ("  Disk C: free before: $(Format-Bytes $diskBefore.free) of $(Format-Bytes $diskBefore.total)") -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
# 1. USER TEMP
# ============================================================================
Write-Host "-- User-level items ----------------------------" -ForegroundColor DarkGray
$r = Clear-FolderContents -Path $env:TEMP -DryRun:$DryRun -Label 'User Temp (%TEMP%)'
$results += $r; Write-Row $r 'User Temp'

$localTemp = "$env:LOCALAPPDATA\Temp"
if ($localTemp -ne $env:TEMP) {
    $r = Clear-FolderContents -Path $localTemp -DryRun:$DryRun -Label 'LocalAppData\Temp'
    $results += $r; Write-Row $r 'LocalAppData Temp'
}

# ============================================================================
# 2. WINDOWS ERROR REPORTING
# ============================================================================
$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Microsoft\Windows\WER" -DryRun:$DryRun -Label 'Windows Error Reports'
$results += $r; Write-Row $r 'WER'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\CrashDumps" -DryRun:$DryRun -Label 'App Crash Dumps'
$results += $r; Write-Row $r 'CrashDumps'

# Global WER dumps
$r = Clear-FolderContents -Path "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" -DryRun:$DryRun -Label 'WER Report Queue'
$results += $r; Write-Row $r 'WER Queue'

$r = Clear-FolderContents -Path "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" -DryRun:$DryRun -Label 'WER Report Archive'
$results += $r; Write-Row $r 'WER Archive'

# ============================================================================
# 3. BROWSER CACHES
# ============================================================================
Write-Host "-- Browser caches ------------------------------" -ForegroundColor DarkGray

$chromeBase = "$env:LOCALAPPDATA\Google\Chrome\User Data"
foreach ($p in (Get-BrowserCachePaths $chromeBase 'Default\Cache')) {
    $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label 'Chrome Cache'
    $results += $r; Write-Row $r 'Chrome Cache'
}
foreach ($p in (Get-BrowserCachePaths $chromeBase 'Default\Code Cache')) {
    $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label 'Chrome Code Cache'
    $results += $r; Write-Row $r 'Chrome Code Cache'
}
foreach ($p in (Get-BrowserCachePaths $chromeBase 'Default\GPUCache')) {
    $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label 'Chrome GPU Cache'
    $results += $r; Write-Row $r 'Chrome GPU Cache'
}

$edgeBase = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
foreach ($p in (Get-BrowserCachePaths $edgeBase 'Default\Cache')) {
    $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label 'Edge Cache'
    $results += $r; Write-Row $r 'Edge Cache'
}
foreach ($p in (Get-BrowserCachePaths $edgeBase 'Default\Code Cache')) {
    $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label 'Edge Code Cache'
    $results += $r; Write-Row $r 'Edge Code Cache'
}
foreach ($p in (Get-BrowserCachePaths $edgeBase 'Default\GPUCache')) {
    $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label 'Edge GPU Cache'
    $results += $r; Write-Row $r 'Edge GPU Cache'
}

# Firefox: profile in %APPDATA%\Mozilla\Firefox\Profiles\*\cache2
$ffBase = "$env:APPDATA\Mozilla\Firefox\Profiles"
if (Test-Path $ffBase) {
    Get-ChildItem -LiteralPath $ffBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $ffCache = Join-Path $_.FullName 'cache2'
        if (Test-Path $ffCache) {
            $r = Clear-FolderContents -Path $ffCache -DryRun:$DryRun -Label 'Firefox Cache'
            $results += $r; Write-Row $r 'Firefox Cache'
        }
    }
}

# IE / Edge Legacy WebCache
$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Microsoft\Windows\INetCache" -DryRun:$DryRun -Label 'INetCache (IE/Edge)'
$results += $r; Write-Row $r 'INetCache'

# ============================================================================
# 4. GRAPHICS / DIRECTX SHADER CACHE
# ============================================================================
Write-Host "-- Graphics caches -----------------------------" -ForegroundColor DarkGray

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\D3DSCache" -DryRun:$DryRun -Label 'D3D Shader Cache'
$results += $r; Write-Row $r 'D3DSCache'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\NVIDIA\DXCache" -DryRun:$DryRun -Label 'NVIDIA DX Cache'
$results += $r; Write-Row $r 'NVIDIA DXCache'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\NVIDIA\GLCache" -DryRun:$DryRun -Label 'NVIDIA GL Cache'
$results += $r; Write-Row $r 'NVIDIA GLCache'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\AMD\DxCache" -DryRun:$DryRun -Label 'AMD DX Cache'
$results += $r; Write-Row $r 'AMD DxCache'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\AMD\GLCache" -DryRun:$DryRun -Label 'AMD GL Cache'
$results += $r; Write-Row $r 'AMD GLCache'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Intel\ShaderCache" -DryRun:$DryRun -Label 'Intel Shader Cache'
$results += $r; Write-Row $r 'Intel ShaderCache'

# ============================================================================
# 5. THUMBNAIL CACHE
# ============================================================================
Write-Host "-- Thumbnail cache -----------------------------" -ForegroundColor DarkGray
$thumbDir = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
if (Test-Path $thumbDir) {
    $r = @{ path=$thumbDir; label='Thumbnail Cache'; existed=$true; size_before=0; size_after=0; freed_bytes=0; files_removed=0; errors=0 }
    if (-not $DryRun) {
        # Explorer must not be running its cache — just delete the db files
        Get-ChildItem -LiteralPath $thumbDir -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $r.size_before += $_.Length
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $r.files_removed++; $r.freed_bytes += $_.Length }
                catch { $r.errors++ }
            }
        Get-ChildItem -LiteralPath $thumbDir -Filter 'iconcache_*.db' -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $r.size_before += $_.Length
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $r.files_removed++; $r.freed_bytes += $_.Length }
                catch { $r.errors++ }
            }
    } else {
        Get-ChildItem -LiteralPath $thumbDir -Filter '*.db' -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $r.size_before += $_.Length; $r.files_removed++ }
        $r.freed_bytes = $r.size_before
    }
    $results += $r; Write-Row $r 'Thumbnails'
}

# ============================================================================
# 6. APP CACHES — Teams, Discord, Spotify, VS Code, Telegram, Office
# ============================================================================
Write-Host "-- App caches ----------------------------------" -ForegroundColor DarkGray

# Microsoft Teams (new Teams stores under WindowsApps, classic under LocalAppData)
foreach ($sub in @('Cache','blob_storage','databases','gpucache','logs','tmp','Service Worker\CacheStorage','Service Worker\ScriptCache')) {
    $p = "$env:LOCALAPPDATA\Microsoft\Teams\$sub"
    if (Test-Path $p) {
        $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label "Teams $sub"
        $results += $r; Write-Row $r "Teams $sub"
    }
}
# New Teams (packaged app)
Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'MSTeams_*' } |
    ForEach-Object {
        $p = Join-Path $_.FullName 'LocalCache\Microsoft\MSTeams'
        if (Test-Path $p) {
            $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label 'Teams (new) Cache'
            $results += $r; Write-Row $r 'Teams-new Cache'
        }
    }

# Discord
foreach ($sub in @('Cache','Code Cache','GPUCache')) {
    $p = "$env:APPDATA\discord\$sub"
    $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label "Discord $sub"
    $results += $r; Write-Row $r "Discord $sub"
}

# Spotify
$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Spotify\Storage" -DryRun:$DryRun -Label 'Spotify Storage'
$results += $r; Write-Row $r 'Spotify Storage'
$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Spotify\Data" -DryRun:$DryRun -Label 'Spotify Data'
$results += $r; Write-Row $r 'Spotify Data'

# VS Code
foreach ($sub in @('Cache','Code Cache','GPUCache','logs')) {
    $p = "$env:APPDATA\Code\$sub"
    $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label "VSCode $sub"
    $results += $r; Write-Row $r "VSCode $sub"
}

# Telegram Desktop — account folders have hash names (not literal "user_data")
# Enumerate all subfolders of tdata\ and clean cache/media_cache inside each
$tdataPath = "$env:APPDATA\Telegram Desktop\tdata"
if (Test-Path $tdataPath) {
    Get-ChildItem -LiteralPath $tdataPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($cacheSub in @('cache', 'media_cache', 'cache2')) {
            $cp = Join-Path $_.FullName $cacheSub
            if (Test-Path $cp) {
                $r = Clear-FolderContents -Path $cp -DryRun:$DryRun -Label "Telegram $cacheSub"
                $results += $r; Write-Row $r "Telegram $cacheSub"
            }
        }
    }
}

# Microsoft Office
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Join-Path $_.FullName 'OfficeFileCache'
    if (Test-Path $p) {
        $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label 'Office FileCache'
        $results += $r; Write-Row $r 'Office Cache'
    }
}

# Windows Search index logs (safe — index rebuilds automatically)
$r = Clear-FolderContents -Path "$env:PROGRAMDATA\Microsoft\Search\Data\Temp" -DryRun:$DryRun -Label 'Search Temp'
$results += $r; Write-Row $r 'Search Temp'

# OneDrive sync logs (safe — OneDrive recreates them)
$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Microsoft\OneDrive\logs" -DryRun:$DryRun -Label 'OneDrive Logs'
$results += $r; Write-Row $r 'OneDrive Logs'

# Adobe app caches (Photoshop, Premiere, etc.)
if (Test-Path "$env:LOCALAPPDATA\Adobe") {
    Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Adobe" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($sub in @('Cache', 'CT Font Cache', 'Media Cache Files', 'Media Cache')) {
            $p = Join-Path $_.FullName $sub
            if (Test-Path $p) {
                $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label "Adobe $($_.Name) Cache"
                $results += $r; Write-Row $r "Adobe $($_.Name)"
            }
        }
    }
}

# ============================================================================
# 6b. DEV TOOL CACHES — npm, pip, NuGet, Yarn, Maven
# ============================================================================
Write-Host "-- Dev tool caches -----------------------------" -ForegroundColor DarkGray

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\npm-cache" -DryRun:$DryRun -Label 'npm cache'
$results += $r; Write-Row $r 'npm cache'

$r = Clear-FolderContents -Path "$env:APPDATA\npm-cache" -DryRun:$DryRun -Label 'npm cache (Roaming)'
$results += $r; Write-Row $r 'npm cache (R)'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\pip\Cache" -DryRun:$DryRun -Label 'pip Cache'
$results += $r; Write-Row $r 'pip Cache'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\NuGet\Cache" -DryRun:$DryRun -Label 'NuGet Cache'
$results += $r; Write-Row $r 'NuGet Cache'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\NuGet\v3-cache" -DryRun:$DryRun -Label 'NuGet v3 Cache'
$results += $r; Write-Row $r 'NuGet v3'

$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Yarn\Cache" -DryRun:$DryRun -Label 'Yarn Cache'
$results += $r; Write-Row $r 'Yarn Cache'

# .NET SDK temp
$r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Temp\NuGetScratch" -DryRun:$DryRun -Label '.NET NuGet Scratch'
$results += $r; Write-Row $r 'NuGet Scratch'

# ============================================================================
# 7. SYSTEM-LEVEL (needs admin)
# ============================================================================
Write-Host "-- System-level --------------------------------" -ForegroundColor DarkGray

$r = Clear-FolderContents -Path "$env:WINDIR\Temp" -DryRun:$DryRun -Label 'Windows\Temp'
$results += $r; Write-Row $r 'Windows Temp'

$r = Clear-FolderContents -Path "$env:WINDIR\Prefetch" -DryRun:$DryRun -Label 'Prefetch'
$results += $r; Write-Row $r 'Prefetch'

$r = Clear-FolderContents -Path "$env:WINDIR\Minidump" -DryRun:$DryRun -Label 'Minidump files'
$results += $r; Write-Row $r 'Minidump'

$memDump = "$env:WINDIR\memory.dmp"
$r = Clear-SingleFile -Path $memDump -DryRun:$DryRun -Label 'Memory dump (memory.dmp)'
$results += $r; Write-Row $r 'memory.dmp'

# CBS archive logs — CbsPersist_*.log only (active CbsPersist.log is always locked by TrustedInstaller)
$cbsPath = "$env:WINDIR\Logs\CBS"
$cbsR = @{ path=$cbsPath; label='CBS Archive Logs'; existed=(Test-Path $cbsPath -ErrorAction SilentlyContinue)
           size_before=[int64]0; size_after=[int64]0; freed_bytes=[int64]0; files_removed=0; errors=0 }
if ($cbsR.existed) {
    Get-ChildItem -LiteralPath $cbsPath -Filter 'CbsPersist_*' -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $cbsR.size_before += [int64]$_.Length
        if (-not $DryRun) {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $cbsR.files_removed++; $cbsR.freed_bytes += [int64]$_.Length }
            catch { $cbsR.errors++ }
        } else { $cbsR.files_removed++ }
    }
    if ($DryRun) { $cbsR.freed_bytes = $cbsR.size_before }
}
$results += $cbsR; Write-Row $cbsR 'CBS Archive Logs'

# CBS Temp — servicing temp packages (separate from Logs, can be 0-2 GB)
$r = Clear-FolderContents -Path "$env:WINDIR\CbsTemp" -DryRun:$DryRun -Label 'CBS Temp'
$results += $r; Write-Row $r 'CBS Temp'

# Windows Setup/Upgrade logs — safe after successful upgrade
$r = Clear-FolderContents -Path "$env:WINDIR\Panther" -DryRun:$DryRun -Label 'Windows Setup Logs'
$results += $r; Write-Row $r 'Panther'

# Windows Defender scan history (Threat History in Security UI — safe, Defender recreates)
$r = Clear-FolderContents -Path "$env:ProgramData\Microsoft\Windows Defender\Scans\History" -DryRun:$DryRun -Label 'Defender Scan History'
$results += $r; Write-Row $r 'Defender History'

# Windows Installer patch cache — huge, safe (installers already applied)
$r = Clear-FolderContents -Path "$env:WINDIR\Installer\`$PatchCache`$" -DryRun:$DryRun -Label 'Installer PatchCache'
$results += $r; Write-Row $r 'Installer PatchCache'

# Windows.old — leftover from OS upgrade, can be 10-30 GB
$winOld = 'C:\Windows.old'
if (Test-Path $winOld) {
    $winOldSize = Get-FolderSize $winOld
    Write-Host ("[~] {0,-28}" -f 'Windows.old') -NoNewline -ForegroundColor Yellow
    Write-Host (" SIZE: {0}  -- removing old OS backup..." -f (Format-Bytes $winOldSize)) -ForegroundColor Yellow
    if (-not $DryRun -and $isAdmin) {
        try {
            # takeown/icacls with 2-minute timeout each — can be slow on large directories
            $p1 = Start-Process 'takeown.exe' -ArgumentList "/F `"$winOld`" /R /D Y" -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
            if ($p1) { $p1.WaitForExit(120000) | Out-Null; if (-not $p1.HasExited) { try { $p1.Kill() } catch {} } }
            $p2 = Start-Process 'icacls.exe'  -ArgumentList "`"$winOld`" /grant administrators:F /T" -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
            if ($p2) { $p2.WaitForExit(120000) | Out-Null; if (-not $p2.HasExited) { try { $p2.Kill() } catch {} } }
            Remove-Item -LiteralPath $winOld -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    $winOldAfter = Get-FolderSize $winOld
    $r = @{ path=$winOld; label='Windows.old'; existed=$true
            size_before=[int64]$winOldSize; size_after=[int64]$winOldAfter
            freed_bytes=[int64]([math]::Max([int64]0,[int64]$winOldSize-[int64]$winOldAfter))
            files_removed=0; errors=0 }
    $results += $r
}

# Font Cache — stop service, delete cache, restart
Write-Host "-- Font cache ----------------------------------" -ForegroundColor DarkGray
$fontCachePrev = Stop-ServiceSafe 'FontCache'
if (-not $DryRun -and $isAdmin) { Start-Sleep -Milliseconds 600 }
$r = Clear-FolderContents -Path "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache" -DryRun:$DryRun -Label 'Font Cache'
$results += $r; Write-Row $r 'FontCache'
# FontCache-S-1-5-18 subfolder
$r = Clear-FolderContents -Path "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache-S-1-5-18" -DryRun:$DryRun -Label 'FontCache-System'
$results += $r; Write-Row $r 'FontCache-System'
Start-ServiceSafe 'FontCache' $fontCachePrev

# ============================================================================
# 7. WINDOWS UPDATE DOWNLOAD CACHE
# Safely: stop wuauserv + bits, delete, restart.
# ============================================================================
Write-Host "-- Windows Update cache ------------------------" -ForegroundColor DarkGray
$wuPath = "$env:WINDIR\SoftwareDistribution\Download"
$wuPrev = ''; $bitsPrev = ''
if (-not $DryRun -and $isAdmin) {
    Write-Host "  Stopping Windows Update service..." -ForegroundColor DarkGray
    $wuPrev   = Stop-ServiceSafe 'wuauserv'
    $bitsPrev = Stop-ServiceSafe 'bits'
    Start-Sleep -Milliseconds 800
}
$r = Clear-FolderContents -Path $wuPath -DryRun:$DryRun -Label 'WU Download Cache'
$results += $r; Write-Row $r 'SoftwareDistribution'

# DataStore transaction logs — also safe while WU is stopped
$r = Clear-FolderContents -Path "$env:WINDIR\SoftwareDistribution\DataStore\Logs" -DryRun:$DryRun -Label 'WU DataStore Logs'
$results += $r; Write-Row $r 'WU DataStore Logs'

if (-not $DryRun -and $isAdmin) {
    Start-ServiceSafe 'wuauserv' $wuPrev
    Start-ServiceSafe 'bits'    $bitsPrev
}

# Delivery Optimization cache
$doPath = "$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
$r = Clear-FolderContents -Path $doPath -DryRun:$DryRun -Label 'Delivery Optimization'
$results += $r; Write-Row $r 'DeliveryOptimization'

# Windows Update log files
$r = Clear-FolderContents -Path "$env:WINDIR\Logs\WindowsUpdate" -DryRun:$DryRun -Label 'WU Log Files'
$results += $r; Write-Row $r 'WU Logs'

# ============================================================================
# 8. RECYCLE BIN
# ============================================================================
Write-Host "-- Recycle Bin ---------------------------------" -ForegroundColor DarkGray
$rb = Clear-RecycleBinSafe -DryRun:$DryRun
$results += $rb; Write-Row $rb 'Recycle Bin'

# ============================================================================
# 9. SYSTEM LOG FILES
# ============================================================================
Write-Host "-- System log files ----------------------------" -ForegroundColor DarkGray

# Windows system log files (IIS, HTTPERR, etc.)
$r = Clear-FolderContents -Path "$env:WINDIR\System32\LogFiles" -DryRun:$DryRun -Label 'System LogFiles'
$results += $r; Write-Row $r 'System LogFiles'

# Windows debug logs
$r = Clear-FolderContents -Path "$env:WINDIR\debug" -DryRun:$DryRun -Label 'Windows Debug Logs'
$results += $r; Write-Row $r 'Debug Logs'

# IIS logs (if IIS installed)
$r = Clear-FolderContents -Path "$env:SystemDrive\inetpub\logs\LogFiles" -DryRun:$DryRun -Label 'IIS Logs'
$results += $r; Write-Row $r 'IIS Logs'

# ============================================================================
# 10. WINDOWS EVENT LOGS
# Safe: logs are for diagnostics only, cleared automatically at size limit anyway.
# ============================================================================
Write-Host "-- Event logs ----------------------------------" -ForegroundColor DarkGray
# Only the 4 main logs — iterating all 500-1000 channels takes several minutes
$evtMainLogs = @('Application','System','Security','Setup')
if (-not $DryRun -and $isAdmin) {
    $evtBefore = [int64]0
    $evtCount  = 0
    Get-WinEvent -ListLog $evtMainLogs -ErrorAction SilentlyContinue | ForEach-Object {
        try { $evtBefore += [int64]$_.FileSize } catch { }
    }
    foreach ($logName in $evtMainLogs) {
        try {
            [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($logName)
            $evtCount++
        } catch { }
    }
    $evtAfter = [int64]0
    Get-WinEvent -ListLog $evtMainLogs -ErrorAction SilentlyContinue | ForEach-Object {
        try { $evtAfter += [int64]$_.FileSize } catch { }
    }
    $evtFreed = [math]::Max([int64]0, $evtBefore - $evtAfter)
    $evtR = @{ path='EventLogs'; label='Windows Event Logs'; existed=$true
               size_before=$evtBefore; size_after=$evtAfter; freed_bytes=$evtFreed
               files_removed=$evtCount; errors=0 }
    $results += $evtR; Write-Row $evtR 'EventLogs'
} elseif ($DryRun) {
    $evtSize = [int64]0
    Get-WinEvent -ListLog $evtMainLogs -ErrorAction SilentlyContinue | ForEach-Object {
        try { $evtSize += [int64]$_.FileSize } catch { }
    }
    $evtR = @{ path='EventLogs'; label='Windows Event Logs'; existed=$true
               size_before=$evtSize; size_after=0; freed_bytes=$evtSize
               files_removed=0; errors=0 }
    $results += $evtR; Write-Row $evtR 'EventLogs'
} else {
    Write-Host ("[~] {0,-28} (requires Administrator)" -f 'Windows Event Logs') -ForegroundColor DarkGray
}

# ============================================================================
# 11. VSS SHADOW COPIES — keep only the latest restore point, delete the rest.
# Frees 1-10 GB. Safe: you still have 1 restore point for emergency rollback.
# ============================================================================
Write-Host "-- VSS Shadow Copies ---------------------------" -ForegroundColor DarkGray

function Get-VssUsedBytes {
    # Win32_ShadowStorage is language-independent and accessible as admin
    $total = [int64]0
    try {
        Get-WmiObject -Query "SELECT UsedSpace FROM Win32_ShadowStorage" -ErrorAction SilentlyContinue |
            ForEach-Object { $total += [int64]$_.UsedSpace }
    } catch {}
    return $total
}

if ($isAdmin -and -not $DryRun) {
    try {
        $shadows = @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)
        if ($shadows.Count -gt 1) {
            $vssBefore = Get-VssUsedBytes
            $sorted   = $shadows | Sort-Object InstallDate -Descending
            $toDelete = $sorted | Select-Object -Skip 1
            $delCount = 0
            foreach ($s in $toDelete) {
                try { $s.Delete() | Out-Null; $delCount++ } catch { }
            }
            Start-Sleep -Seconds 3   # allow VSS to reclaim
            $vssAfter  = Get-VssUsedBytes
            $vssFreed  = [math]::Max([int64]0, $vssBefore - $vssAfter)
            $vssR = @{ path='VSS'; label="VSS (kept 1, removed $delCount)"; existed=$true
                       size_before=$vssBefore; size_after=$vssAfter; freed_bytes=$vssFreed
                       files_removed=$delCount; errors=0 }
            $results += $vssR; Write-Row $vssR 'VSS ShadowCopy'
        } elseif ($shadows.Count -eq 1) {
            Write-Host ("[~] {0,-28} only 1 restore point, keeping it." -f 'VSS ShadowCopy') -ForegroundColor DarkGray
        } else {
            Write-Host ("[~] {0,-28} no shadow copies found." -f 'VSS ShadowCopy') -ForegroundColor DarkGray
        }
    } catch {
        Write-Host ("[~] {0,-28} error: $_" -f 'VSS ShadowCopy') -ForegroundColor Yellow
    }
} else {
    Write-Host ("[~] {0,-28} $(if ($DryRun) { 'DryRun mode' } else { 'requires Administrator' })" -f 'VSS ShadowCopy') -ForegroundColor DarkGray
}

# ============================================================================
# 12. HIBERFIL.SYS — removes file equal to RAM size (16-32 GB on most systems).
# Disables Hibernate sleep mode and Windows Fast Startup.
# Re-enable: powercfg /h on
# Only runs if -DisableHibernate flag passed explicitly.
# ============================================================================
if ($DisableHibernate -and $isAdmin -and -not $DryRun) {
    Write-Host "-- Hibernate file ------------------------------" -ForegroundColor DarkGray
    $hibPath = "$env:SystemDrive\hiberfil.sys"
    $hibSize = [int64]0
    try { $hibSize = (Get-Item -LiteralPath $hibPath -Force -ErrorAction Stop).Length } catch { }
    if ($hibSize -gt 0) {
        Write-Host ("[~] {0,-28} {1}  -- disabling hibernate..." -f 'hiberfil.sys', (Format-Bytes $hibSize)) -ForegroundColor Yellow
        & powercfg /h off 2>&1 | Out-Null
        $hibAfter = [int64]0
        try { $hibAfter = (Get-Item -LiteralPath $hibPath -Force -ErrorAction SilentlyContinue).Length } catch { }
        $hibFreed = [math]::Max([int64]0, $hibSize - $hibAfter)
        $hibR = @{ path=$hibPath; label='hiberfil.sys (hibernate off)'; existed=$true
                   size_before=$hibSize; size_after=$hibAfter; freed_bytes=$hibFreed
                   files_removed=$(if ($hibFreed -gt 0) { 1 } else { 0 }); errors=0 }
        $results += $hibR; Write-Row $hibR 'hiberfil.sys'
        Write-Host "  [!] Hibernate + Fast Startup are now OFF. Run 'powercfg /h on' to restore." -ForegroundColor Yellow
    } else {
        Write-Host ("[~] {0,-28} hiberfil.sys not found or hibernate already off." -f 'hiberfil.sys') -ForegroundColor DarkGray
    }
} elseif ($DisableHibernate -and -not $isAdmin) {
    Write-Host "-- Hibernate file: requires Administrator ------" -ForegroundColor Yellow
}

# ============================================================================
# DISM — Windows Component Store cleanup (WinSxS).
# Can free 2-8 GB. Runs with a hard 8-minute timeout so the script never hangs.
# ============================================================================
if ($isAdmin -and -not $DryRun) {
    Write-Host "-- WinSxS component cleanup --------------------" -ForegroundColor DarkGray
    # Fire-and-forget: DISM takes 5-30 min, don't block the script
    try {
        Start-Process -FilePath 'dism.exe' `
            -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup /NoRestart' `
            -WindowStyle Hidden -ErrorAction SilentlyContinue
        Write-Host ("  [DISM] Started in background (runs after this window closes).") -ForegroundColor Green
    } catch {
        Write-Host ("  [DISM] Could not start.") -ForegroundColor Yellow
    }
} elseif ($DryRun) {
    Write-Host "-- WinSxS component cleanup --------------------" -ForegroundColor DarkGray
    Write-Host "  [DISM] Skipped in DryRun mode." -ForegroundColor DarkGray
} else {
    Write-Host "-- WinSxS component cleanup --------------------" -ForegroundColor DarkGray
    Write-Host "  [DISM] Skipped: requires Administrator." -ForegroundColor DarkGray
}

# ============================================================================
# SUMMARY
# ============================================================================
$totalBefore = ($results | ForEach-Object { [int64]$_.size_before } | Measure-Object -Sum).Sum
$totalAfter  = ($results | ForEach-Object { [int64]$_.size_after  } | Measure-Object -Sum).Sum
$freedBytes  = [math]::Max([int64]0, [int64]$totalBefore - [int64]$totalAfter)
$elapsed     = [int]((Get-Date) - $startTime).TotalSeconds

Write-Host ""
Write-Host "================================================" -ForegroundColor Magenta
Write-Host ("  FREED: {0}   ({1}s)" -f (Format-Bytes $freedBytes), $elapsed) -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Magenta
Write-Host ""

# ============================================================================
# WRITE JSON LOG FOR DASHBOARD
# ============================================================================
$summary = @{
    finished_at  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    finished_iso = (Get-Date).ToString('o')
    dry_run      = [bool]$DryRun
    total_before = [int64]$totalBefore
    total_after  = [int64]$totalAfter
    freed_bytes  = [int64]$freedBytes
    elapsed_sec  = $elapsed
    categories   = ,$results
}
$logPath = Join-Path $PSScriptRoot 'last-cleanup.json'
try {
    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $logPath -Encoding UTF8
} catch {
    Write-Host "  [!] Could not write JSON log: $_" -ForegroundColor Yellow
}

# Disk space after — compare with before for ground truth
$diskAfter = Get-DiskFree 'C:'
if ($diskBefore.total -gt 0) {
    $realDelta = $diskAfter.free - $diskBefore.free
    $sign      = if ($realDelta -ge 0) { '+' } else { '' }
    Write-Host ("  Disk C: free after:  $(Format-Bytes $diskAfter.free) of $(Format-Bytes $diskAfter.total)") -ForegroundColor DarkGray
    Write-Host ("  Real disk change:    $sign$(Format-Bytes $realDelta)") -ForegroundColor $(if ($realDelta -gt 0) { 'Green' } else { 'Yellow' })
}
Write-Host ""

# Write detailed Markdown report
$logsDir = Join-Path $PSScriptRoot 'logs'
$mdPath  = Write-MdReport -Results $results -Summary $summary `
               -DiskBefore $diskBefore -DiskAfter $diskAfter `
               -OsInfo $osInfo -LogDir $logsDir
if ($mdPath) {
    Write-Host "  Report: $mdPath" -ForegroundColor Cyan
    Write-Host ""
} else {
    Write-Host "  [!] Could not write MD report" -ForegroundColor Yellow
}

if (-not $DryRun) {
    Write-Host "  Window closes automatically in 8 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 8
}
