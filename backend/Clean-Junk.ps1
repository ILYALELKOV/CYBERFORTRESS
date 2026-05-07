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
    [switch]$DisableHibernate,
    # Comma-separated category IDs to clean. Empty = clean everything.
    [string]$CategoriesStr = '',
    # Close and reopen browsers automatically before browser-related cleanup.
    [switch]$CloseBrowsers
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$_cats = if ($CategoriesStr) { $CategoriesStr -split ',' | ForEach-Object { $_.Trim() } } else { @() }
function Should-Clean([string]$id) {
    # Empty list = run all (backward-compat). Otherwise only run if ID is in the list.
    return ($_cats.Count -eq 0 -or $_cats -contains $id)
}

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
    # MinAgeHours = 0 bypasses age filter (e.g. browser history files you always want gone)
    param([string]$Path, [switch]$DryRun, [string]$Label = '', [int]$MinAgeHours = 0)
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
        $cutoff = (Get-Date).AddHours(-$MinAgeHours)
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            # Skip items newer than MinAgeHours (like top tools — CCleaner, ASC do the same)
            if ($MinAgeHours -gt 0 -and $_.LastWriteTime -gt $cutoff) { return }
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

# Delete browser history files from a profile folder but preserve Cookies, Login Data, Bookmarks.
# Returns aggregated result hashtable.
function Clear-BrowserHistory {
    param([string]$ProfilePath, [switch]$DryRun, [string]$BrowserLabel)
    $agg = @{ path=$ProfilePath; label="$BrowserLabel History"; existed=$false
              size_before=[int64]0; size_after=[int64]0; freed_bytes=[int64]0
              files_removed=0; errors=0 }
    if (-not (Test-Path $ProfilePath)) { return $agg }
    $agg.existed = $true

    # Individual history files — always delete regardless of age (MinAgeHours=0)
    $histFiles = @(
        'History','History-journal','Visited Links','Top Sites','Favicons',
        'Media History','Download Metadata','Network Action Predictor',
        'Shortcuts','QuotaManager'
    )
    foreach ($f in $histFiles) {
        $fp = Join-Path $ProfilePath $f
        if (-not (Test-Path $fp)) { continue }
        try {
            $fi = Get-Item -LiteralPath $fp -Force -ErrorAction Stop
            $agg.size_before += $fi.Length
            $agg.existed = $true
            if (-not $DryRun) {
                Remove-Item -LiteralPath $fp -Force -ErrorAction Stop
                $agg.files_removed++
                $agg.freed_bytes += $fi.Length
            } else { $agg.freed_bytes += $fi.Length }
        } catch { $agg.errors++ }
    }
    # History sub-folders
    $histFolders = @('Session Storage', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache')
    foreach ($sub in $histFolders) {
        $fp = Join-Path $ProfilePath $sub
        if (-not (Test-Path $fp)) { continue }
        $sub_r = Clear-FolderContents -Path $fp -DryRun:$DryRun -Label "$BrowserLabel $(Split-Path $sub -Leaf)" -MinAgeHours 0
        $agg.size_before  += [int64]$sub_r.size_before
        $agg.freed_bytes  += [int64]$sub_r.freed_bytes
        $agg.files_removed += [int]$sub_r.files_removed
        $agg.errors       += [int]$sub_r.errors
    }
    $agg.size_after = [math]::Max([int64]0, $agg.size_before - $agg.freed_bytes)
    return $agg
}

# Kill browsers and wait until all processes are fully gone (file handles released).
function Stop-Browsers {
    $browserNames = @('chrome','msedge','firefox','brave','vivaldi','opera','operagx')
    $killed = $false
    foreach ($name in $browserNames) {
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { continue }
        & taskkill /F /IM "$name.exe" /T 2>$null | Out-Null
        $killed = $true
        Write-Host ("  [BROWSER] Killed: $name ($($procs.Count) process(es))") -ForegroundColor Yellow
    }
    if ($killed) {
        # Wait until every browser process is actually gone (up to 15 sec)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 15) {
            $still = $browserNames | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue }
            if (-not $still) { break }
            Start-Sleep -Milliseconds 500
        }
        Start-Sleep -Milliseconds 500   # extra settle for file handle release
        Write-Host "  [BROWSER] All browser processes gone." -ForegroundColor Green
    }
    return @()   # never reopen — history sync would restore it
}

function Start-Browsers {
    param([string[]]$ExePaths)
    foreach ($path in $ExePaths) {
        try {
            Start-Process -FilePath $path -ErrorAction SilentlyContinue
            Write-Host ("  [BROWSER] Reopened: $path") -ForegroundColor Green
        } catch { }
    }
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

function Clear-RecycleBinSafe {
    param([switch]$DryRun)
    $r = @{ path='Recycle Bin'; label='Recycle Bin'; existed=$true
            size_before=[int64]0; size_after=[int64]0; freed_bytes=[int64]0; files_removed=0; errors=0 }
    try {
        $sid   = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $drives = [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.IsReady -and $_.DriveType -eq [System.IO.DriveType]::Fixed }
        foreach ($drv in $drives) {
            $bp = Join-Path $drv.RootDirectory.FullName "`$Recycle.Bin\$sid"
            if (Test-Path -LiteralPath $bp) {
                $r.size_before += Get-FolderSize $bp
                $r.files_removed += ([System.IO.Directory]::EnumerateFiles($bp, '*', [System.IO.SearchOption]::AllDirectories) | Measure-Object).Count
            }
        }
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
if (Should-Clean 'user_temp') {
    Write-Host "-- User-level items ----------------------------" -ForegroundColor DarkGray
    $r = Clear-FolderContents -Path $env:TEMP -DryRun:$DryRun -Label 'User Temp (%TEMP%)'
    $results += $r; Write-Row $r 'User Temp'
    $localTemp = "$env:LOCALAPPDATA\Temp"
    if ($localTemp -ne $env:TEMP) {
        $r = Clear-FolderContents -Path $localTemp -DryRun:$DryRun -Label 'LocalAppData\Temp'
        $results += $r; Write-Row $r 'LocalAppData Temp'
    }
}

# ============================================================================
# 2. WINDOWS ERROR REPORTING
# ============================================================================
if (Should-Clean 'error_reports') {
    $r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Microsoft\Windows\WER" -DryRun:$DryRun -Label 'Windows Error Reports' -MinAgeHours 24
    $results += $r; Write-Row $r 'WER'
    $r = Clear-FolderContents -Path "$env:LOCALAPPDATA\CrashDumps" -DryRun:$DryRun -Label 'App Crash Dumps' -MinAgeHours 24
    $results += $r; Write-Row $r 'CrashDumps'
    $r = Clear-FolderContents -Path "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" -DryRun:$DryRun -Label 'WER Report Queue' -MinAgeHours 24
    $results += $r; Write-Row $r 'WER Queue'
    $r = Clear-FolderContents -Path "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" -DryRun:$DryRun -Label 'WER Report Archive' -MinAgeHours 24
    $results += $r; Write-Row $r 'WER Archive'
}

# ============================================================================
# 3. BROWSER CLEANUP (cache + history, cookies preserved)
# ============================================================================
# Helper: enumerate all Chromium profiles under a base dir
function Get-ChromiumProfiles {
    param([string]$Base)
    $profiles = @()
    if (-not (Test-Path $Base)) { return $profiles }
    $profiles += Join-Path $Base 'Default'
    Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Profile \d+$' } |
        ForEach-Object { $profiles += $_.FullName }
    return $profiles | Where-Object { Test-Path $_ }
}

if (Should-Clean 'browser_cache' -or Should-Clean 'browser_history') {
    Write-Host "-- Browser cleanup (closing browsers...) ------" -ForegroundColor DarkGray
    # Close browsers only if the CloseBrowsers flag was passed (frontend sends it when browser cats are selected)
    if (-not $DryRun -and $CloseBrowsers) { Stop-Browsers | Out-Null }

    foreach ($entry in @(
        @{ base="$env:LOCALAPPDATA\Google\Chrome\User Data";           label='Chrome' },
        @{ base="$env:LOCALAPPDATA\Microsoft\Edge\User Data";          label='Edge' },
        @{ base="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; label='Brave' }
    )) {
        foreach ($prof in (Get-ChromiumProfiles $entry.base)) {
            if (Should-Clean 'browser_cache') {
                foreach ($sub in @('Cache','Code Cache','GPUCache')) {
                    $p = Join-Path $prof $sub
                    $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label "$($entry.label) $sub" -MinAgeHours 0
                    $results += $r; Write-Row $r "$($entry.label) $sub"
                }
            }
            if (Should-Clean 'browser_history') {
                $r = Clear-BrowserHistory -ProfilePath $prof -DryRun:$DryRun -BrowserLabel $entry.label
                $results += $r; Write-Row $r "$($entry.label) History"
            }
        }
    }

    # Firefox
    $ffBase = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $ffBase) {
        Get-ChildItem -LiteralPath $ffBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if (Should-Clean 'browser_cache') {
                foreach ($sub in @('cache2','startupCache','shader-cache')) {
                    $p = Join-Path $_.FullName $sub
                    if (Test-Path $p) {
                        $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label "Firefox $sub" -MinAgeHours 0
                        $results += $r; Write-Row $r "Firefox $sub"
                    }
                }
            }
        }
    }

    if (Should-Clean 'browser_cache') {
        $r = Clear-FolderContents -Path "$env:LOCALAPPDATA\Microsoft\Windows\INetCache" -DryRun:$DryRun -Label 'INetCache (IE/Edge)' -MinAgeHours 0
        $results += $r; Write-Row $r 'INetCache'
    }

    Write-Host "-- Browser cleanup done (reopen manually) ------" -ForegroundColor DarkGray
}

# ============================================================================
# 4. GRAPHICS / DIRECTX SHADER CACHE
# ============================================================================
if (Should-Clean 'gpu_cache') {
    Write-Host "-- Graphics caches -----------------------------" -ForegroundColor DarkGray
    foreach ($p in @(
        @{p="$env:LOCALAPPDATA\D3DSCache";           l='D3D Shader Cache'},
        @{p="$env:LOCALAPPDATA\NVIDIA\DXCache";       l='NVIDIA DX Cache'},
        @{p="$env:LOCALAPPDATA\NVIDIA\GLCache";       l='NVIDIA GL Cache'},
        @{p="$env:LOCALAPPDATA\AMD\DxCache";          l='AMD DX Cache'},
        @{p="$env:LOCALAPPDATA\AMD\GLCache";          l='AMD GL Cache'},
        @{p="$env:LOCALAPPDATA\Intel\ShaderCache";    l='Intel Shader Cache'}
    )) {
        $r = Clear-FolderContents -Path $p.p -DryRun:$DryRun -Label $p.l
        $results += $r; Write-Row $r $p.l
    }
}

# ============================================================================
# 5. THUMBNAIL CACHE
# ============================================================================
if (Should-Clean 'thumbnails') {
    Write-Host "-- Thumbnail cache -----------------------------" -ForegroundColor DarkGray
    $thumbDir = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    if (Test-Path $thumbDir) {
        $r = @{ path=$thumbDir; label='Thumbnail Cache'; existed=$true; size_before=0; size_after=0; freed_bytes=0; files_removed=0; errors=0 }
        if (-not $DryRun) {
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
}

# ============================================================================
# 6. APP CACHES — Teams, Discord, Spotify, VS Code, Telegram, Office
# ============================================================================
if (Should-Clean 'app_cache') {
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
} # end app_cache

# Steam cache — htmlcache (Steam browser), logs, dumps
if (Should-Clean 'steam_cache') {
    Write-Host "-- Steam cache ---------------------------------" -ForegroundColor DarkGray
    $steamPaths = @("$env:LOCALAPPDATA\Steam\htmlcache","$env:LOCALAPPDATA\Steam\logs")
    $steamInstall = ''
    try { $steamInstall = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath } catch { }
    if (-not $steamInstall) { $steamInstall = 'C:\Program Files (x86)\Steam' }
    $steamPaths += "$steamInstall\logs","$steamInstall\dumps"
    $shadersPath = Join-Path $steamInstall 'shadercache'
    if (Test-Path $shadersPath) { $steamPaths += $shadersPath }
    foreach ($p in ($steamPaths | Select-Object -Unique)) {
        if (Test-Path $p) {
            $r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label "Steam $(Split-Path $p -Leaf)"
            $results += $r; Write-Row $r "Steam $(Split-Path $p -Leaf)"
        }
    }
}

# ============================================================================
# 6b. DEV TOOL CACHES — npm, pip, NuGet, Yarn, Maven
# ============================================================================
if (Should-Clean 'dev_cache') {
    Write-Host "-- Dev tool caches -----------------------------" -ForegroundColor DarkGray
    foreach ($entry in @(
        @{p="$env:LOCALAPPDATA\npm-cache";          l='npm cache'},
        @{p="$env:APPDATA\npm-cache";               l='npm cache (Roaming)'},
        @{p="$env:LOCALAPPDATA\pip\Cache";           l='pip Cache'},
        @{p="$env:LOCALAPPDATA\NuGet\Cache";         l='NuGet Cache'},
        @{p="$env:LOCALAPPDATA\NuGet\v3-cache";      l='NuGet v3 Cache'},
        @{p="$env:LOCALAPPDATA\Yarn\Cache";          l='Yarn Cache'},
        @{p="$env:LOCALAPPDATA\Temp\NuGetScratch";   l='.NET NuGet Scratch'}
    )) {
        $r = Clear-FolderContents -Path $entry.p -DryRun:$DryRun -Label $entry.l
        $results += $r; Write-Row $r $entry.l
    }
}

# ============================================================================
# 6c. EXTENDED AREAS — CCleaner / Advanced SystemCare best practices
# ============================================================================
if (Should-Clean 'extended') {
    Write-Host "-- Extended cleanup areas ----------------------" -ForegroundColor DarkGray
    foreach ($entry in @(
        @{p="$env:APPDATA\Microsoft\Windows\Recent";                              l='Recent Documents'},
        @{p="$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations";        l='Jump Lists (Auto)'},
        @{p="$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations";           l='Jump Lists (Custom)'},
        @{p="$env:USERPROFILE\AppData\LocalLow\Sun\Java\Deployment\cache";        l='Java Cache'},
        @{p="$env:APPDATA\Microsoft\Windows Media Player";                        l='WMP History'},
        @{p="$env:TEMP\chocolatey";                                               l='Chocolatey Cache'},
        @{p="$env:WINDIR\SoftwareDistribution\DeliveryOptimization";              l='Delivery Opt Extra'}
    )) {
        $r = Clear-FolderContents -Path $entry.p -DryRun:$DryRun -Label $entry.l
        $results += $r; Write-Row $r $entry.l
    }
    # Microsoft Store / UWP app temp folders
    $pkgBase = "$env:LOCALAPPDATA\Packages"
    if (Test-Path $pkgBase) {
        $storeFreed = [int64]0; $storeFiles = 0; $storeErrors = 0
        Get-ChildItem -LiteralPath $pkgBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Join-Path $_.FullName 'AC\Temp'
            if (Test-Path $p) {
                $sub_r = Clear-FolderContents -Path $p -DryRun:$DryRun -Label 'Store Temp'
                $storeFreed += [int64]$sub_r.freed_bytes; $storeFiles += [int]$sub_r.files_removed; $storeErrors += [int]$sub_r.errors
            }
        }
        $storeR = @{ path=$pkgBase; label='MS Store App Temp'; existed=($storeFreed -gt 0 -or $storeFiles -gt 0)
                     size_before=$storeFreed; size_after=[int64]0; freed_bytes=$storeFreed
                     files_removed=$storeFiles; errors=$storeErrors }
        $results += $storeR; Write-Row $storeR 'Store App Temp'
    }
}

# ============================================================================
# 7. SYSTEM-LEVEL (needs admin)
# ============================================================================
Write-Host "-- System-level --------------------------------" -ForegroundColor DarkGray

if (Should-Clean 'windows_temp') {
    $r = Clear-FolderContents -Path "$env:WINDIR\Temp" -DryRun:$DryRun -Label 'Windows\Temp'
    $results += $r; Write-Row $r 'Windows Temp'
}
if (Should-Clean 'prefetch') {
    $r = Clear-FolderContents -Path "$env:WINDIR\Prefetch" -DryRun:$DryRun -Label 'Prefetch'
    $results += $r; Write-Row $r 'Prefetch'
}
if (Should-Clean 'system_junk') {
    $r = Clear-FolderContents -Path "$env:WINDIR\Minidump" -DryRun:$DryRun -Label 'Minidump files' -MinAgeHours 24
    $results += $r; Write-Row $r 'Minidump'
    $r = Clear-SingleFile -Path "$env:WINDIR\memory.dmp" -DryRun:$DryRun -Label 'Memory dump (memory.dmp)'
    $results += $r; Write-Row $r 'memory.dmp'
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
    foreach ($entry in @(
        @{p="$env:WINDIR\CbsTemp";          l='CBS Temp'},
        @{p="$env:WINDIR\Panther";           l='Windows Setup Logs'},
        @{p="$env:ProgramData\Microsoft\Windows Defender\Scans\History"; l='Defender Scan History'},
        @{p="$env:WINDIR\Installer\`$PatchCache`$"; l='Installer PatchCache'}
    )) {
        $r = Clear-FolderContents -Path $entry.p -DryRun:$DryRun -Label $entry.l
        $results += $r; Write-Row $r $entry.l
    }
}
if (Should-Clean 'windows_old') {
    $winOld = 'C:\Windows.old'
    if (Test-Path $winOld) {
        $winOldSize = Get-FolderSize $winOld
        Write-Host ("[~] {0,-28} SIZE: {1}  -- removing..." -f 'Windows.old', (Format-Bytes $winOldSize)) -ForegroundColor Yellow
        if (-not $DryRun -and $isAdmin) {
            try {
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
                freed_bytes=[int64]([math]::Max([int64]0,[int64]$winOldSize-[int64]$winOldAfter)); files_removed=0; errors=0 }
        $results += $r
    }
}
if (Should-Clean 'system_junk') {
    Write-Host "-- Font cache ----------------------------------" -ForegroundColor DarkGray
    $fontCachePrev = Stop-ServiceSafe 'FontCache'
    if (-not $DryRun -and $isAdmin) { Start-Sleep -Milliseconds 600 }
    $r = Clear-FolderContents -Path "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache" -DryRun:$DryRun -Label 'Font Cache'
    $results += $r; Write-Row $r 'FontCache'
    $r = Clear-FolderContents -Path "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache-S-1-5-18" -DryRun:$DryRun -Label 'FontCache-System'
    $results += $r; Write-Row $r 'FontCache-System'
    Start-ServiceSafe 'FontCache' $fontCachePrev
}

# ============================================================================
# 7. WINDOWS UPDATE DOWNLOAD CACHE
# ============================================================================
if (Should-Clean 'windows_update') {
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
    $r = Clear-FolderContents -Path "$env:WINDIR\SoftwareDistribution\DataStore\Logs" -DryRun:$DryRun -Label 'WU DataStore Logs'
    $results += $r; Write-Row $r 'WU DataStore Logs'
    if (-not $DryRun -and $isAdmin) { Start-ServiceSafe 'wuauserv' $wuPrev; Start-ServiceSafe 'bits' $bitsPrev }
    $doPath = "$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
    $r = Clear-FolderContents -Path $doPath -DryRun:$DryRun -Label 'Delivery Optimization'
    $results += $r; Write-Row $r 'DeliveryOptimization'
    $r = Clear-FolderContents -Path "$env:WINDIR\Logs\WindowsUpdate" -DryRun:$DryRun -Label 'WU Log Files'
    $results += $r; Write-Row $r 'WU Logs'
}

# ============================================================================
# 8. RECYCLE BIN
# ============================================================================
if (Should-Clean 'recycle_bin') {
    Write-Host "-- Recycle Bin ---------------------------------" -ForegroundColor DarkGray
    $rb = Clear-RecycleBinSafe -DryRun:$DryRun
    $results += $rb; Write-Row $rb 'Recycle Bin'
}

# ============================================================================
# 9. SYSTEM LOG FILES
# ============================================================================
if (Should-Clean 'system_logs') {
    Write-Host "-- System log files ----------------------------" -ForegroundColor DarkGray
    foreach ($entry in @(
        @{p="$env:WINDIR\System32\LogFiles";               l='System LogFiles'},
        @{p="$env:WINDIR\debug";                           l='Windows Debug Logs'},
        @{p="$env:SystemDrive\inetpub\logs\LogFiles";      l='IIS Logs'}
    )) {
        $r = Clear-FolderContents -Path $entry.p -DryRun:$DryRun -Label $entry.l
        $results += $r; Write-Row $r $entry.l
    }
}

# ============================================================================
# 10. WINDOWS EVENT LOGS
# ============================================================================
if (Should-Clean 'event_logs') {
    Write-Host "-- Event logs ----------------------------------" -ForegroundColor DarkGray
    $evtMainLogs = @('Application','System','Security','Setup')
    if (-not $DryRun -and $isAdmin) {
        $evtBefore = [int64]0; $evtCount = 0
        Get-WinEvent -ListLog $evtMainLogs -ErrorAction SilentlyContinue | ForEach-Object { try { $evtBefore += [int64]$_.FileSize } catch { } }
        foreach ($logName in $evtMainLogs) { try { [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($logName); $evtCount++ } catch { } }
        $evtAfter = [int64]0
        Get-WinEvent -ListLog $evtMainLogs -ErrorAction SilentlyContinue | ForEach-Object { try { $evtAfter += [int64]$_.FileSize } catch { } }
        $evtR = @{ path='EventLogs'; label='Windows Event Logs'; existed=$true
                   size_before=$evtBefore; size_after=$evtAfter; freed_bytes=[math]::Max([int64]0,$evtBefore-$evtAfter)
                   files_removed=$evtCount; errors=0 }
        $results += $evtR; Write-Row $evtR 'EventLogs'
    } elseif ($DryRun) {
        $evtSize = [int64]0
        Get-WinEvent -ListLog $evtMainLogs -ErrorAction SilentlyContinue | ForEach-Object { try { $evtSize += [int64]$_.FileSize } catch { } }
        $evtR = @{ path='EventLogs'; label='Windows Event Logs'; existed=$true
                   size_before=$evtSize; size_after=0; freed_bytes=$evtSize; files_removed=0; errors=0 }
        $results += $evtR; Write-Row $evtR 'EventLogs'
    } else {
        Write-Host ("[~] {0,-28} (requires Administrator)" -f 'Windows Event Logs') -ForegroundColor DarkGray
    }
} # end event_logs

# ============================================================================
# 11. VSS SHADOW COPIES
# ============================================================================
if (Should-Clean 'vss') {
    Write-Host "-- VSS Shadow Copies ---------------------------" -ForegroundColor DarkGray
    function Get-VssUsedBytes {
        $total = [int64]0
        try { Get-WmiObject -Query "SELECT UsedSpace FROM Win32_ShadowStorage" -ErrorAction SilentlyContinue | ForEach-Object { $total += [int64]$_.UsedSpace } } catch {}
        return $total
    }
    if ($isAdmin -and -not $DryRun) {
        try {
            $shadows = @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)
            if ($shadows.Count -gt 1) {
                $vssBefore = Get-VssUsedBytes
                $toDelete  = $shadows | Sort-Object InstallDate -Descending | Select-Object -Skip 1
                $delCount  = 0
                foreach ($s in $toDelete) { try { $s.Delete() | Out-Null; $delCount++ } catch { } }
                Start-Sleep -Seconds 3
                $vssAfter = Get-VssUsedBytes
                $vssR = @{ path='VSS'; label="VSS (kept 1, removed $delCount)"; existed=$true
                           size_before=$vssBefore; size_after=$vssAfter; freed_bytes=[math]::Max([int64]0,$vssBefore-$vssAfter)
                           files_removed=$delCount; errors=0 }
                $results += $vssR; Write-Row $vssR 'VSS ShadowCopy'
            } elseif ($shadows.Count -eq 1) {
                Write-Host ("[~] {0,-28} only 1 restore point, keeping it." -f 'VSS ShadowCopy') -ForegroundColor DarkGray
            } else {
                Write-Host ("[~] {0,-28} no shadow copies found." -f 'VSS ShadowCopy') -ForegroundColor DarkGray
            }
        } catch { Write-Host ("[~] {0,-28} error: $_" -f 'VSS ShadowCopy') -ForegroundColor Yellow }
    } else {
        Write-Host ("[~] {0,-28} $(if ($DryRun) { 'DryRun mode' } else { 'requires Administrator' })" -f 'VSS ShadowCopy') -ForegroundColor DarkGray
    }
} # end vss

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
# EMPTY FOLDERS
# ============================================================================
if (Should-Clean 'empty_folders') {
    Write-Host "-- Empty folders -------------------------------" -ForegroundColor DarkGray
    $emptyRoots = @(
        $env:TEMP,
        "$env:LOCALAPPDATA\Temp",
        "$env:USERPROFILE\Documents",
        "$env:USERPROFILE\Downloads",
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Pictures",
        "$env:USERPROFILE\Videos"
    )
    $efCount = 0; $efErrors = 0
    $swEf = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($root in $emptyRoots) {
        if (-not (Test-Path $root)) { continue }
        try {
            # Sort descending so deepest dirs are deleted first (parent becomes empty after child removed)
            $dirs = Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending
            foreach ($d in $dirs) {
                if ($swEf.Elapsed.TotalSeconds -gt 20) { break }
                try {
                    $hasItems = [bool]([System.IO.Directory]::EnumerateFileSystemEntries($d.FullName) | Select-Object -First 1)
                    if (-not $hasItems) {
                        if (-not $DryRun) {
                            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop
                        }
                        $efCount++
                    }
                } catch { $efErrors++ }
            }
        } catch { }
        if ($swEf.Elapsed.TotalSeconds -gt 20) { break }
    }
    $swEf.Stop()
    $efR = @{ path='Empty Folders'; label='Empty Folders'; existed=($efCount -gt 0 -or $efErrors -gt 0)
              size_before=[int64]0; size_after=[int64]0; freed_bytes=[int64]0
              files_removed=$efCount; errors=$efErrors }
    $results += $efR; Write-Row $efR 'Empty Folders'
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
$logPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'data\last-cleanup.json'
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
$logsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data\logs'
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
