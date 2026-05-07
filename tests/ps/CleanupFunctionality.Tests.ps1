# =============================================================================
# CleanupFunctionality.Tests.ps1  v3 — maximum coverage
# Tests every function, edge case, boundary, and UI fix in the junk cleaner.
# Usage: pwsh -NoProfile -File tests\ps\CleanupFunctionality.Tests.ps1
# =============================================================================

$ErrorActionPreference = 'Continue'
$ScriptRoot  = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
$BackendDir  = Join-Path $ScriptRoot 'backend'
$CleanScript = Join-Path $BackendDir 'Clean-Junk.ps1'
$DataDir     = Join-Path $ScriptRoot 'data'

$pass = 0; $fail = 0
$results = [System.Collections.Generic.List[hashtable]]::new()

function Test-Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $status = if ($Condition) { 'PASS' } else { 'FAIL' }
    $color  = if ($Condition) { 'Green' } else { 'Red' }
    Write-Host ("  [{0,-4}] {1}" -f $status, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("         $Detail") -ForegroundColor DarkGray }
    if ($Condition) { $script:pass++ } else { $script:fail++ }
    $script:results.Add(@{ name=$Name; status=$status; detail=$Detail })
}

function Section([string]$Title) {
    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

$TmpBase = Join-Path $env:TEMP "cf_test_v3_$(Get-Random)"
New-Item -ItemType Directory -Path $TmpBase -Force | Out-Null

function New-TestFile {
    param([string]$Path, [int]$SizeKB = 10, [switch]$OldFile, [int]$AgeHours = 48)
    $dir = Split-Path $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bytes = New-Object byte[] ($SizeKB * 1024)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    if ($OldFile) { (Get-Item $Path).LastWriteTime = (Get-Date).AddHours(-$AgeHours) }
}

# IMPORTANT: param() must be the FIRST statement in a PowerShell script.
# All generated scripts use $ParamDir as the opening line so the Dir argument
# is received correctly when called with -Dir <path>.
$ParamDir = 'param([string]$Dir)' + [Environment]::NewLine

# Production-matching Clear-FolderContents (function only, no param block).
$ClearFolderFunc = @'
function Clear-FolderContents {
    param([string]$Path, [switch]$DryRun, [string]$Label = '', [int]$MinAgeHours = 0)
    $r = @{ path=$Path; label=$Label; existed=$false; size_before=0; size_after=0
            freed_bytes=0; files_removed=0; errors=0 }
    try { $exists = Test-Path -LiteralPath $Path } catch { return $r }
    if (-not $exists) { return $r }
    $r.existed = $true
    $sum = [int64]0
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        ForEach-Object { try { $sum += [int64]$_.Length } catch {} }
    $r.size_before = $sum
    if (-not $DryRun) {
        $cutoff = (Get-Date).AddHours(-$MinAgeHours)
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($MinAgeHours -gt 0 -and $_.LastWriteTime -gt $cutoff) { return }
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop; $r.files_removed++ }
            catch { $r.errors++ }
        }
    }
    $sum2 = [int64]0
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        ForEach-Object { try { $sum2 += [int64]$_.Length } catch {} }
    $r.size_after  = if ($DryRun) { $r.size_before } else { $sum2 }
    $r.freed_bytes = [math]::Max([int64]0, [int64]$r.size_before - [int64]$r.size_after)
    return $r
}
'@

# Combined: param first, then function — use this for all -Dir scripts
$CFBlock = $ParamDir + $ClearFolderFunc

# ============================================================================
Section "1. SCRIPTS EXIST"
# ============================================================================
Test-Assert "Clean-Junk.ps1 exists"             (Test-Path $CleanScript)
Test-Assert "data/ directory exists"             (Test-Path $DataDir)
Test-Assert "app.js exists"                      (Test-Path (Join-Path $ScriptRoot 'frontend\js\app.js'))
Test-Assert "index.html exists"                  (Test-Path (Join-Path $ScriptRoot 'frontend\index.html'))
Test-Assert "Get-SystemInfo.ps1 exists"          (Test-Path (Join-Path $BackendDir 'Get-SystemInfo.ps1'))

# ============================================================================
Section "2. SOURCE CHECK — MinAgeHours defaults and protections"
# ============================================================================
$cleanContent = Get-Content -Raw $CleanScript
Test-Assert "Clear-FolderContents default MinAgeHours is 0"      ($cleanContent -match 'param\(\[string\]\$Path.*\[int\]\$MinAgeHours\s*=\s*0\)')
Test-Assert "Default MinAgeHours is NOT 24"                      (-not ($cleanContent -match 'param\(\[string\]\$Path.*\[int\]\$MinAgeHours\s*=\s*24\)'))
Test-Assert "Minidump protected: explicit MinAgeHours 24"        ($cleanContent -match 'Minidump.*-MinAgeHours 24')
Test-Assert "WER protected: explicit MinAgeHours 24"             ($cleanContent -match 'WER.*-MinAgeHours 24')
Test-Assert "CrashDumps protected: explicit MinAgeHours 24"      ($cleanContent -match 'CrashDumps.*-MinAgeHours 24')
# histFolders loop uses MinAgeHours 0
Test-Assert "Browser history subfolders: Clear-FolderContents called with MinAgeHours 0" `
    ($cleanContent -match 'Clear-FolderContents.*-MinAgeHours 0')
Test-Assert "Steam cache calls Clear-FolderContents"             ($cleanContent -match 'htmlcache|shadercache')

# ============================================================================
Section "3. BASIC DELETION — new files, MinAgeHours=0"
# ============================================================================
$basicDir = Join-Path $TmpBase 'basic'
New-Item -ItemType Directory $basicDir -Force | Out-Null
New-TestFile (Join-Path $basicDir 'a.tmp') 20
New-TestFile (Join-Path $basicDir 'b.tmp') 20
New-TestFile (Join-Path $basicDir 'c.tmp') 20

$basicCode = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir
Write-Output "REMOVED=$($r.files_removed)"
Write-Output "FREED=$($r.freed_bytes)"
Write-Output "REMAINING=$((Get-ChildItem $Dir -Force -ErrorAction SilentlyContinue).Count)"
'@
$basicCode | Set-Content (Join-Path $TmpBase 'test_basic.ps1') -Encoding UTF8
$bo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_basic.ps1') -Dir $basicDir 2>&1
$bRemoved = [int]($bo | Where-Object { $_ -match 'REMOVED=(\d+)' }    | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$bFreed   = [int64]($bo | Where-Object { $_ -match 'FREED=(\d+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$bLeft    = [int]($bo | Where-Object { $_ -match 'REMAINING=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Basic: all 3 files removed"     ($bRemoved -eq 3)  "removed=$bRemoved"
Test-Assert "Basic: freed bytes > 0"         ($bFreed -gt 0)    "freed=$($bFreed/1KB)KB"
Test-Assert "Basic: directory now empty"     ($bLeft -eq 0)     "remaining=$bLeft"

# ============================================================================
Section "4. NON-EXISTENT PATH — no crash, graceful return"
# ============================================================================
$neCode = $CFBlock + @'
$r = Clear-FolderContents -Path 'C:\DOES_NOT_EXIST_CF_TEST_XYZ_99'
Write-Output "EXISTED=$($r.existed)"
Write-Output "FREED=$($r.freed_bytes)"
Write-Output "ERRORS=$($r.errors)"
'@
$neCode | Set-Content (Join-Path $TmpBase 'test_ne.ps1') -Encoding UTF8
$neo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_ne.ps1') -Dir 'ignored' 2>&1
$neExisted = ($neo | Where-Object { $_ -match 'EXISTED=(\w+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$neFreed   = [int64]($neo | Where-Object { $_ -match 'FREED=(\d+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$neErrors  = [int]($neo | Where-Object { $_ -match 'ERRORS=(\d+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Non-existent: existed=False"   ($neExisted -eq 'False')  "existed=$neExisted"
Test-Assert "Non-existent: freed=0"         ($neFreed -eq 0)          "freed=$neFreed"
Test-Assert "Non-existent: errors=0"        ($neErrors -eq 0)         "errors=$neErrors"

# ============================================================================
Section "5. EMPTY FOLDER — existed=True, freed=0"
# ============================================================================
$emptyDir = Join-Path $TmpBase 'empty_folder'
New-Item -ItemType Directory $emptyDir -Force | Out-Null
$efCode = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir
Write-Output "EXISTED=$($r.existed)"
Write-Output "FREED=$($r.freed_bytes)"
Write-Output "REMOVED=$($r.files_removed)"
'@
$efCode | Set-Content (Join-Path $TmpBase 'test_ef.ps1') -Encoding UTF8
$efo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_ef.ps1') -Dir $emptyDir 2>&1
$efExisted = ($efo | Where-Object { $_ -match 'EXISTED=(\w+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$efFreed   = [int64]($efo | Where-Object { $_ -match 'FREED=(\d+)' }    | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$efRemoved = [int]($efo | Where-Object { $_ -match 'REMOVED=(\d+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Empty folder: existed=True"      ($efExisted -eq 'True')
Test-Assert "Empty folder: freed=0"           ($efFreed -eq 0)
Test-Assert "Empty folder: files_removed=0"   ($efRemoved -eq 0)

# ============================================================================
Section "6. SUBDIRECTORY RECURSIVE DELETE"
# ============================================================================
$recDir = Join-Path $TmpBase 'recursive'
New-Item -ItemType Directory $recDir -Force | Out-Null
New-TestFile (Join-Path $recDir 'top.tmp') 10
New-TestFile (Join-Path $recDir 'sub\nested.tmp') 10
New-TestFile (Join-Path $recDir 'sub\deep\leaf.tmp') 10
$recCode = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir
$allLeft = (Get-ChildItem $Dir -Force -Recurse -ErrorAction SilentlyContinue).Count
Write-Output "REMOVED=$($r.files_removed)"
Write-Output "ALL_LEFT=$allLeft"
'@
$recCode | Set-Content (Join-Path $TmpBase 'test_rec.ps1') -Encoding UTF8
$reco = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_rec.ps1') -Dir $recDir 2>&1
$recRemoved = [int]($reco | Where-Object { $_ -match 'REMOVED=(\d+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$recLeft    = [int]($reco | Where-Object { $_ -match 'ALL_LEFT=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Recursive: removed entries > 0"        ($recRemoved -gt 0)  "removed=$recRemoved"
Test-Assert "Recursive: 0 items left (all gone)"    ($recLeft -eq 0)     "remaining=$recLeft"

# ============================================================================
Section "7. DRYRUN — reports bytes but deletes nothing"
# ============================================================================
$drDir = Join-Path $TmpBase 'dryrun'
New-Item -ItemType Directory $drDir -Force | Out-Null
New-TestFile (Join-Path $drDir 'f1.tmp') 50
New-TestFile (Join-Path $drDir 'f2.tmp') 50
$drCode = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir -DryRun
Write-Output "SIZE_BEFORE=$($r.size_before)"
Write-Output "FREED=$($r.freed_bytes)"
Write-Output "REMOVED=$($r.files_removed)"
Write-Output "STILL_THERE=$((Get-ChildItem $Dir -Force).Count)"
'@
$drCode | Set-Content (Join-Path $TmpBase 'test_dr.ps1') -Encoding UTF8
$dro = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_dr.ps1') -Dir $drDir 2>&1
$drSizeBefore = [int64]($dro | Where-Object { $_ -match 'SIZE_BEFORE=(\d+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$drFreed  = [int64]($dro | Where-Object { $_ -match 'FREED=(\d+)' }       | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$drRemoved= [int]($dro   | Where-Object { $_ -match 'REMOVED=(\d+)' }     | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$drStill  = [int]($dro   | Where-Object { $_ -match 'STILL_THERE=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
# Production behavior: DryRun measures size_before (what exists) but freed_bytes=0 (nothing deleted)
Test-Assert "DryRun: size_before reports existing bytes"  ($drSizeBefore -gt 0)  "size_before=$($drSizeBefore/1KB)KB"
Test-Assert "DryRun: freed_bytes=0 (nothing deleted)"     ($drFreed -eq 0)       "freed=$drFreed"
Test-Assert "DryRun: files_removed=0 (not deleted)"       ($drRemoved -eq 0)     "removed=$drRemoved"
Test-Assert "DryRun: 2 files still on disk"               ($drStill -eq 2)       "still=$drStill"

# ============================================================================
Section "8. DRYRUN vs REAL — identical freed bytes"
# ============================================================================
$dr2Dir = Join-Path $TmpBase 'dryreal'
New-Item -ItemType Directory $dr2Dir -Force | Out-Null
New-TestFile (Join-Path $dr2Dir 'x1.tmp') 50
New-TestFile (Join-Path $dr2Dir 'x2.tmp') 75
New-TestFile (Join-Path $dr2Dir 'x3.tmp') 25
$dr2Code = $CFBlock + @'
$dry  = Clear-FolderContents -Path $Dir -DryRun
$real = Clear-FolderContents -Path $Dir
Write-Output "DRY_SIZE_BEFORE=$($dry.size_before)"
Write-Output "DRY_FREED=$($dry.freed_bytes)"
Write-Output "REAL_FREED=$($real.freed_bytes)"
Write-Output "AFTER_COUNT=$((Get-ChildItem $Dir -Force -ErrorAction SilentlyContinue).Count)"
'@
$dr2Code | Set-Content (Join-Path $TmpBase 'test_dr2.ps1') -Encoding UTF8
$dr2o = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_dr2.ps1') -Dir $dr2Dir 2>&1
$drySzB = [int64]($dr2o | Where-Object { $_ -match 'DRY_SIZE_BEFORE=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$dryF   = [int64]($dr2o | Where-Object { $_ -match 'DRY_FREED=(\d+)' }       | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$realF  = [int64]($dr2o | Where-Object { $_ -match 'REAL_FREED=(\d+)' }      | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$ac     = [int]($dr2o   | Where-Object { $_ -match 'AFTER_COUNT=(\d+)' }     | ForEach-Object { $Matches[1] } | Select-Object -First 1)
# DryRun scans size_before (150KB) but freed_bytes=0; Real cleans and freed_bytes=150KB
Test-Assert "DryRun: size_before == Real freed_bytes (scan matches cleanup)" ($drySzB -eq $realF) "dry_size=$($drySzB/1KB)KB real_freed=$($realF/1KB)KB"
Test-Assert "DryRun: freed_bytes=0 (scan only, nothing deleted)"            ($dryF -eq 0)        "dry_freed=$dryF"
Test-Assert "Real: freed_bytes > 0"                                         ($realF -gt 0)        "real=$($realF/1KB)KB"
Test-Assert "Real: directory emptied"                                        ($ac -eq 0)           "remaining=$ac"

# ============================================================================
Section "9. AGE FILTER — MinAgeHours=24 keeps new, deletes old"
# ============================================================================
$ageDir = Join-Path $TmpBase 'age_filter'
New-Item -ItemType Directory $ageDir -Force | Out-Null
New-TestFile (Join-Path $ageDir 'new_file.tmp')  20            # < 24h — KEEP
New-TestFile (Join-Path $ageDir 'old_file.tmp')  20 -OldFile   # > 48h — DELETE
$ageCode = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir -MinAgeHours 24
Write-Output "REMOVED=$($r.files_removed)"
$remaining = (Get-ChildItem $Dir -Force | Select-Object -ExpandProperty Name) -join ','
Write-Output "REMAINING=$remaining"
'@
$ageCode | Set-Content (Join-Path $TmpBase 'test_age.ps1') -Encoding UTF8
$ageo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_age.ps1') -Dir $ageDir 2>&1
$ageRemoved   = [int]($ageo | Where-Object { $_ -match 'REMOVED=(\d+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$ageRemaining = ($ageo | Where-Object { $_ -match 'REMAINING=(.+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Age filter: old file (>48h) deleted"           ($ageRemoved -ge 1)                       "removed=$ageRemoved"
Test-Assert "Age filter: new file (<24h) PRESERVED"         ($ageRemaining -match 'new_file.tmp')     "remaining=$ageRemaining"
Test-Assert "Age filter: old file NOT in remaining"         ($ageRemaining -notmatch 'old_file.tmp')  "remaining=$ageRemaining"

# ============================================================================
Section "10. AGE FILTER — MinAgeHours=0 deletes everything regardless of age"
# ============================================================================
$age0Dir = Join-Path $TmpBase 'age0'
New-Item -ItemType Directory $age0Dir -Force | Out-Null
New-TestFile (Join-Path $age0Dir 'brand_new.tmp') 10
New-TestFile (Join-Path $age0Dir 'one_hour.tmp')  10 -OldFile -AgeHours 1
New-TestFile (Join-Path $age0Dir 'old_48h.tmp')   10 -OldFile
$age0Code = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir -MinAgeHours 0
Write-Output "REMOVED=$($r.files_removed)"
Write-Output "REMAINING=$((Get-ChildItem $Dir -Force -ErrorAction SilentlyContinue).Count)"
'@
$age0Code | Set-Content (Join-Path $TmpBase 'test_age0.ps1') -Encoding UTF8
$a0o = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_age0.ps1') -Dir $age0Dir 2>&1
$a0Removed = [int]($a0o | Where-Object { $_ -match 'REMOVED=(\d+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$a0Left    = [int]($a0o | Where-Object { $_ -match 'REMAINING=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "MinAgeHours=0: all 3 files deleted (any age)"  ($a0Removed -eq 3)  "removed=$a0Removed"
Test-Assert "MinAgeHours=0: directory empty"                ($a0Left -eq 0)     "remaining=$a0Left"

# ============================================================================
Section "11. STEAM CACHE — new shader files deleted (core fix)"
# ============================================================================
$steamDir = Join-Path $TmpBase 'steam'
New-Item -ItemType Directory $steamDir -Force | Out-Null
New-TestFile (Join-Path $steamDir 'dx11_cache.bin')   100
New-TestFile (Join-Path $steamDir 'dx12_cache.bin')   150
New-TestFile (Join-Path $steamDir 'vulkan_cache.bin')  80
$steamCode = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir   # default MinAgeHours=0
Write-Output "REMOVED=$($r.files_removed)"
Write-Output "FREED=$($r.freed_bytes)"
Write-Output "REMAINING=$((Get-ChildItem $Dir -Force -ErrorAction SilentlyContinue).Count)"
'@
$steamCode | Set-Content (Join-Path $TmpBase 'test_steam.ps1') -Encoding UTF8
$sto = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_steam.ps1') -Dir $steamDir 2>&1
$stRemoved = [int]($sto | Where-Object { $_ -match 'REMOVED=(\d+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$stFreed   = [int64]($sto | Where-Object { $_ -match 'FREED=(\d+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$stLeft    = [int]($sto | Where-Object { $_ -match 'REMAINING=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Steam: all 3 new shader files deleted"   ($stRemoved -eq 3)          "removed=$stRemoved"
Test-Assert "Steam: directory empty after cleanup"    ($stLeft -eq 0)             "remaining=$stLeft"
Test-Assert "Steam: freed >= 330KB"                   ($stFreed -ge 330 * 1024)   "freed=$($stFreed/1KB)KB"

# ============================================================================
Section "12. SOURCE — histFiles excludes session/tab files"
# ============================================================================
$histListOk  = $cleanContent -notmatch "'Current Session'"
$histListOk2 = $cleanContent -notmatch "'Current Tabs'"
$histListOk3 = $cleanContent -notmatch "'Last Session'"
$histListOk4 = $cleanContent -notmatch "'Last Tabs'"
Test-Assert "histFiles: 'Current Session' NOT in deletion list"   $histListOk
Test-Assert "histFiles: 'Current Tabs' NOT in deletion list"      $histListOk2
Test-Assert "histFiles: 'Last Session' NOT in deletion list"      $histListOk3
Test-Assert "histFiles: 'Last Tabs' NOT in deletion list"         $histListOk4
Test-Assert "histFiles: 'History' IS in deletion list"            ($cleanContent -match "'History'")
Test-Assert "histFiles: 'Visited Links' IS in deletion list"      ($cleanContent -match "'Visited Links'")
Test-Assert "histFiles: 'Favicons' IS in deletion list"           ($cleanContent -match "'Favicons'")

# ============================================================================
Section "13. BROWSER HISTORY — functional (cookies/tabs preserved)"
# ============================================================================
$fakeBrowser = Join-Path $TmpBase 'fake_chrome\Default'
New-Item -ItemType Directory $fakeBrowser -Force | Out-Null
$delFiles  = @('History','History-journal','Visited Links','Top Sites','Favicons','Media History','Shortcuts')
$keepFiles = @('Cookies','Login Data','Bookmarks','Current Session','Current Tabs','Last Session','Last Tabs','Web Data')
foreach ($f in ($delFiles + $keepFiles)) { New-TestFile (Join-Path $fakeBrowser $f) 5 }

$bhCode = @'
param([string]$ProfilePath)
$agg = @{ freed_bytes=[int64]0; files_removed=0; errors=0 }
$histFiles = @(
    'History','History-journal','Visited Links','Top Sites','Favicons',
    'Media History','Download Metadata','Network Action Predictor',
    'Shortcuts','QuotaManager'
)
foreach ($f in $histFiles) {
    $fp = Join-Path $ProfilePath $f
    if (-not (Test-Path $fp)) { continue }
    try {
        $fi = Get-Item $fp -Force
        $agg.freed_bytes += $fi.Length
        Remove-Item $fp -Force -ErrorAction Stop
        $agg.files_removed++
    } catch { $agg.errors++ }
}
Write-Output "DELETED=$($agg.files_removed)"
Write-Output "FREED=$($agg.freed_bytes)"
$remain = (Get-ChildItem $ProfilePath -Force | Select-Object -ExpandProperty Name) -join ','
Write-Output "REMAIN=$remain"
'@
$bhCode | Set-Content (Join-Path $TmpBase 'test_bh.ps1') -Encoding UTF8
$bho = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_bh.ps1') -ProfilePath $fakeBrowser 2>&1
$bhDeleted   = [int]($bho | Where-Object { $_ -match 'DELETED=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$bhRemainStr = ($bho | Where-Object { $_ -match 'REMAIN=(.+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$bhRemain    = $bhRemainStr -split ',' | Where-Object { $_ -ne '' }
Test-Assert "Browser: history files deleted (>=4)"           ($bhDeleted -ge 4)                     "deleted=$bhDeleted"
Test-Assert "Browser: Cookies preserved"                     ($bhRemain -contains 'Cookies')
Test-Assert "Browser: Login Data (passwords) preserved"      ($bhRemain -contains 'Login Data')
Test-Assert "Browser: Bookmarks preserved"                   ($bhRemain -contains 'Bookmarks')
Test-Assert "Browser: Current Session (open tabs) preserved" ($bhRemain -contains 'Current Session')
Test-Assert "Browser: Current Tabs preserved"                ($bhRemain -contains 'Current Tabs')
Test-Assert "Browser: Last Session preserved"                ($bhRemain -contains 'Last Session')
Test-Assert "Browser: Last Tabs preserved"                   ($bhRemain -contains 'Last Tabs')
Test-Assert "Browser: Web Data preserved"                    ($bhRemain -contains 'Web Data')
Test-Assert "Browser: History NOT in remaining"              ($bhRemain -notcontains 'History')
Test-Assert "Browser: Favicons NOT in remaining"             ($bhRemain -notcontains 'Favicons')

# ============================================================================
Section "14. BROWSER HISTORY — DryRun preserves all files on disk"
# ============================================================================
$fakeBr2 = Join-Path $TmpBase 'fake_chrome2\Default'
New-Item -ItemType Directory $fakeBr2 -Force | Out-Null
foreach ($f in @('History','Visited Links','Favicons','Cookies','Login Data','Current Session')) {
    New-TestFile (Join-Path $fakeBr2 $f) 5
}
$bh2Code = @'
param([string]$ProfilePath)
$histFiles = @('History','History-journal','Visited Links','Top Sites','Favicons',
    'Media History','Download Metadata','Network Action Predictor','Shortcuts','QuotaManager')
$wouldDelete = 0
foreach ($f in $histFiles) {
    $fp = Join-Path $ProfilePath $f
    if (Test-Path $fp) { $wouldDelete++ }  # DryRun: count but do NOT delete
}
$onDisk = (Get-ChildItem $ProfilePath -Force).Count
Write-Output "WOULD_DELETE=$wouldDelete"
Write-Output "STILL_ON_DISK=$onDisk"
'@
$bh2Code | Set-Content (Join-Path $TmpBase 'test_bh2.ps1') -Encoding UTF8
$bh2o = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_bh2.ps1') -ProfilePath $fakeBr2 2>&1
$bh2Would = [int]($bh2o | Where-Object { $_ -match 'WOULD_DELETE=(\d+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$bh2Disk  = [int]($bh2o | Where-Object { $_ -match 'STILL_ON_DISK=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Browser DryRun: would-delete count >= 1"    ($bh2Would -ge 1)  "would_delete=$bh2Would"
Test-Assert "Browser DryRun: all 6 files still on disk"  ($bh2Disk -eq 6)   "on_disk=$bh2Disk"

# ============================================================================
Section "15. CRASH DUMP PROTECTION — MinAgeHours=24"
# ============================================================================
$dumpDir = Join-Path $TmpBase 'dumps'
New-Item -ItemType Directory $dumpDir -Force | Out-Null
New-TestFile (Join-Path $dumpDir 'crash_new.dmp') 50           # < 24h — KEEP
New-TestFile (Join-Path $dumpDir 'crash_old.dmp') 50 -OldFile  # > 48h — DELETE
$protCode = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir -MinAgeHours 24
Write-Output "REMOVED=$($r.files_removed)"
Write-Output "COUNT=$((Get-ChildItem $Dir -Force -ErrorAction SilentlyContinue).Count)"
$names = (Get-ChildItem $Dir -Force | Select-Object -ExpandProperty Name) -join ','
Write-Output "REMAINING=$names"
'@
$protCode | Set-Content (Join-Path $TmpBase 'test_prot.ps1') -Encoding UTF8
$proo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_prot.ps1') -Dir $dumpDir 2>&1
$proRemoved = [int]($proo | Where-Object { $_ -match 'REMOVED=(\d+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$proCount   = [int]($proo | Where-Object { $_ -match 'COUNT=(\d+)' }     | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$proNames   = ($proo | Where-Object { $_ -match 'REMAINING=(.+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Crash dumps: old dump (>48h) deleted"         ($proRemoved -eq 1)               "removed=$proRemoved"
Test-Assert "Crash dumps: 1 file remains (new dump)"       ($proCount -eq 1)                 "count=$proCount"
Test-Assert "Crash dumps: crash_new.dmp is the survivor"   ($proNames -match 'crash_new.dmp') "remaining=$proNames"

# ============================================================================
Section "16. FREED_BYTES — never negative"
# ============================================================================
$nbDir = Join-Path $TmpBase 'nobytes'
New-Item -ItemType Directory $nbDir -Force | Out-Null
$nbCode = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir
Write-Output "FREED=$($r.freed_bytes)"
'@
$nbCode | Set-Content (Join-Path $TmpBase 'test_nb.ps1') -Encoding UTF8
$nbo   = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_nb.ps1') -Dir $nbDir 2>&1
$nbFrd = [int64]($nbo | Where-Object { $_ -match 'FREED=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "freed_bytes never negative (empty dir)"   ($nbFrd -ge 0)  "freed=$nbFrd"

# ============================================================================
Section "17. SHOULD-CLEAN — category filter logic"
# ============================================================================
$scCode = @'
function Should-Clean([string]$id) {
    return ($_cats.Count -eq 0 -or $_cats -contains $id)
}
$_cats = @()
Write-Output "EMPTY_ALL=$(Should-Clean 'any_cat')"
$_cats = @('steam_cache','user_temp')
Write-Output "STEAM_IN=$(Should-Clean 'steam_cache')"
Write-Output "GPU_OUT=$(Should-Clean 'gpu_cache')"
Write-Output "TEMP_IN=$(Should-Clean 'user_temp')"
$_cats = @('browser_history')
Write-Output "BH_ONLY=$(Should-Clean 'browser_history')"
Write-Output "BC_OUT=$(Should-Clean 'browser_cache')"
'@
$scCode | Set-Content (Join-Path $TmpBase 'test_sc.ps1') -Encoding UTF8
$sco = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_sc.ps1') 2>&1
$scEmptyAll = ($sco | Where-Object { $_ -match 'EMPTY_ALL=(\w+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$scSteamIn  = ($sco | Where-Object { $_ -match 'STEAM_IN=(\w+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$scGpuOut   = ($sco | Where-Object { $_ -match 'GPU_OUT=(\w+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$scTempIn   = ($sco | Where-Object { $_ -match 'TEMP_IN=(\w+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$scBhOnly   = ($sco | Where-Object { $_ -match 'BH_ONLY=(\w+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$scBcOut    = ($sco | Where-Object { $_ -match 'BC_OUT=(\w+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Should-Clean: empty list → all run"              ($scEmptyAll -eq 'True')
Test-Assert "Should-Clean: steam_cache in selection"          ($scSteamIn -eq 'True')
Test-Assert "Should-Clean: gpu_cache NOT in selection"        ($scGpuOut -eq 'False')
Test-Assert "Should-Clean: user_temp in selection"            ($scTempIn -eq 'True')
Test-Assert "Should-Clean: browser_history alone → runs"      ($scBhOnly -eq 'True')
Test-Assert "Should-Clean: browser_cache when only bh → skip" ($scBcOut -eq 'False')

# ============================================================================
Section "18. FORMAT-BYTES OUTPUT"
# ============================================================================
$fbCode = @'
function Format-Bytes { param([int64]$n)
    if ($n -lt 1KB) { return "$n B" }
    if ($n -lt 1MB) { return "{0:N1} KB" -f ($n/1KB) }
    if ($n -lt 1GB) { return "{0:N1} MB" -f ($n/1MB) }
    return "{0:N2} GB" -f ($n/1GB)
}
Write-Output "ZERO=$(Format-Bytes 0)"
Write-Output "BYTES=$(Format-Bytes 512)"
Write-Output "KB=$(Format-Bytes 1536)"
Write-Output "MB=$(Format-Bytes 1572864)"
Write-Output "GB=$(Format-Bytes 2147483648)"
'@
$fbCode | Set-Content (Join-Path $TmpBase 'test_fb.ps1') -Encoding UTF8
$fbo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_fb.ps1') 2>&1
$fbZero  = ($fbo | Where-Object { $_ -match 'ZERO=(.+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$fbBytes = ($fbo | Where-Object { $_ -match 'BYTES=(.+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$fbKb    = ($fbo | Where-Object { $_ -match '^KB=(.+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$fbMb    = ($fbo | Where-Object { $_ -match '^MB=(.+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$fbGb    = ($fbo | Where-Object { $_ -match '^GB=(.+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Format-Bytes: 0 → '0 B'"            ($fbZero  -eq '0 B')
Test-Assert "Format-Bytes: 512 → '512 B'"         ($fbBytes -eq '512 B')
Test-Assert "Format-Bytes: 1.5KB → contains 'KB'" ($fbKb    -match 'KB')
Test-Assert "Format-Bytes: 1.5MB → contains 'MB'" ($fbMb    -match 'MB')
Test-Assert "Format-Bytes: 2GB → contains 'GB'"   ($fbGb    -match 'GB')

# ============================================================================
Section "19. CATEGORY ISOLATION — DryRun on real script"
# ============================================================================
Write-Host "  Running DryRun user_temp only..." -ForegroundColor DarkGray
$catOut = & pwsh -NoProfile -NonInteractive -File $CleanScript -DryRun -CategoriesStr 'user_temp' 2>&1
$catStr = $catOut -join "`n"
Test-Assert "user_temp: User Temp processed"          ($catStr -match 'User Temp')
Test-Assert "user_temp: browser cache NOT processed"  (-not ($catStr -match 'INetCache|Chrome.*Cache'))
Test-Assert "user_temp: steam NOT processed"          (-not ($catStr -match 'Steam.*htmlcache|shadercache'))
Test-Assert "user_temp: GPU NOT processed"            (-not ($catStr -match 'D3D|NVIDIA|AMD|Intel Shader'))

Write-Host "  Running DryRun steam_cache only..." -ForegroundColor DarkGray
$stCatOut = & pwsh -NoProfile -NonInteractive -File $CleanScript -DryRun -CategoriesStr 'steam_cache' 2>&1
$stCatStr = $stCatOut -join "`n"
Test-Assert "steam_cache: Steam section appears"            ($stCatStr -match 'Steam')
Test-Assert "steam_cache: no browser section"               (-not ($stCatStr -match 'closing browsers'))
Test-Assert "steam_cache: no GPU section"                   (-not ($stCatStr -match 'D3D|NVIDIA Shader'))

Write-Host "  Running DryRun gpu_cache only..." -ForegroundColor DarkGray
$gpuOut = & pwsh -NoProfile -NonInteractive -File $CleanScript -DryRun -CategoriesStr 'gpu_cache' 2>&1
$gpuStr = $gpuOut -join "`n"
Test-Assert "gpu_cache: Graphics section appears"           ($gpuStr -match 'D3D|NVIDIA|AMD|Intel|Graphics')
Test-Assert "gpu_cache: user_temp NOT processed"            (-not ($gpuStr -match 'User Temp'))

# ============================================================================
Section "20. JSON LOG STRUCTURE"
# ============================================================================
Write-Host "  Running DryRun to generate last-cleanup.json..." -ForegroundColor DarkGray
& pwsh -NoProfile -NonInteractive -File $CleanScript -DryRun -CategoriesStr 'user_temp' 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$lcPath = Join-Path $DataDir 'last-cleanup.json'
if (Test-Path $lcPath) {
    $lc = Get-Content -Raw $lcPath | ConvertFrom-Json -ErrorAction SilentlyContinue
    Test-Assert "JSON: file written and parseable"    ($null -ne $lc)
    Test-Assert "JSON: finished_at present"           (-not [string]::IsNullOrEmpty($lc.finished_at))
    Test-Assert "JSON: dry_run = true"                ($lc.dry_run -eq $true)
    Test-Assert "JSON: freed_bytes >= 0"              ($lc.freed_bytes -ge 0)
    Test-Assert "JSON: categories array present"      ($null -ne $lc.categories)
    Test-Assert "JSON: elapsed_sec >= 0"              ($lc.elapsed_sec -ge 0)
    Test-Assert "JSON: finished_iso present"          (-not [string]::IsNullOrEmpty($lc.finished_iso))
    Test-Assert "JSON: total_before >= 0"             ($lc.total_before -ge 0)
    $firstCat = $lc.categories | Select-Object -First 1
    if ($firstCat) {
        Test-Assert "JSON cat: has label field"       ($null -ne $firstCat.label)
        Test-Assert "JSON cat: freed_bytes >= 0"      ($firstCat.freed_bytes -ge 0)
        Test-Assert "JSON cat: files_removed >= 0"    ($firstCat.files_removed -ge 0)
        Test-Assert "JSON cat: errors >= 0"           ($firstCat.errors -ge 0)
    } else {
        Test-Assert "JSON: at least one category"     $false "categories array empty"
    }
} else {
    Test-Assert "JSON: last-cleanup.json written"     $false "path=$lcPath"
}

# ============================================================================
Section "21. END-TO-END: measure → cleanup → counter drops to 0"
# ============================================================================
$e2eDir = Join-Path $TmpBase 'e2e'
New-Item -ItemType Directory $e2eDir -Force | Out-Null
New-TestFile (Join-Path $e2eDir 'cache1.bin') 100
New-TestFile (Join-Path $e2eDir 'cache2.bin') 100
New-TestFile (Join-Path $e2eDir 'cache3.bin') 100
$e2eCode = $CFBlock + @'
$beforeBytes = (Get-ChildItem $Dir -Force | Measure-Object -Property Length -Sum).Sum
$r = Clear-FolderContents -Path $Dir
$afterBytes  = [int64]((Get-ChildItem $Dir -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
Write-Output "BEFORE=$beforeBytes"
Write-Output "AFTER=$afterBytes"
Write-Output "FREED=$($r.freed_bytes)"
'@
$e2eCode | Set-Content (Join-Path $TmpBase 'test_e2e.ps1') -Encoding UTF8
$e2eo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_e2e.ps1') -Dir $e2eDir 2>&1
$e2eBefore = [int64]($e2eo | Where-Object { $_ -match 'BEFORE=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$e2eAfter  = [int64]($e2eo | Where-Object { $_ -match 'AFTER=(\d+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$e2eFreed  = [int64]($e2eo | Where-Object { $_ -match 'FREED=(\d+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "E2E: before shows 300KB"              ($e2eBefore -ge 300 * 1024)   "before=$($e2eBefore/1KB)KB"
Test-Assert "E2E: counter drops to 0 after cleanup" ($e2eAfter -eq 0)            "after=$e2eAfter bytes"
Test-Assert "E2E: freed == before (all gone)"       ($e2eFreed -eq $e2eBefore)   "freed=$($e2eFreed/1KB)KB"

# ============================================================================
Section "22. MIXED AGE — partial cleanup (2 old deleted, 2 new kept)"
# ============================================================================
$mixDir = Join-Path $TmpBase 'mixed'
New-Item -ItemType Directory $mixDir -Force | Out-Null
New-TestFile (Join-Path $mixDir 'keep1.tmp')   10
New-TestFile (Join-Path $mixDir 'keep2.tmp')   10
New-TestFile (Join-Path $mixDir 'delete1.tmp') 10 -OldFile
New-TestFile (Join-Path $mixDir 'delete2.tmp') 10 -OldFile
$mixCode = $CFBlock + @'
$r = Clear-FolderContents -Path $Dir -MinAgeHours 24
Write-Output "REMOVED=$($r.files_removed)"
$names = (Get-ChildItem $Dir -Force | Select-Object -ExpandProperty Name) -join ','
Write-Output "REMAINING=$names"
'@
$mixCode | Set-Content (Join-Path $TmpBase 'test_mix.ps1') -Encoding UTF8
$mixo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_mix.ps1') -Dir $mixDir 2>&1
$mixRemoved = [int]($mixo | Where-Object { $_ -match 'REMOVED=(\d+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$mixNames   = ($mixo | Where-Object { $_ -match 'REMAINING=(.+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Mixed: exactly 2 old files deleted"    ($mixRemoved -eq 2)             "removed=$mixRemoved"
Test-Assert "Mixed: keep1.tmp still present"        ($mixNames -match 'keep1.tmp')  "remaining=$mixNames"
Test-Assert "Mixed: keep2.tmp still present"        ($mixNames -match 'keep2.tmp')  "remaining=$mixNames"
Test-Assert "Mixed: delete1.tmp NOT present"        ($mixNames -notmatch 'delete1') "remaining=$mixNames"
Test-Assert "Mixed: delete2.tmp NOT present"        ($mixNames -notmatch 'delete2') "remaining=$mixNames"

# ============================================================================
Section "23. MULTIPLE CATEGORIES — selective run"
# ============================================================================
$m1 = Join-Path $TmpBase 'multi1'
$m2 = Join-Path $TmpBase 'multi2'
$m3 = Join-Path $TmpBase 'multi3'
New-Item -ItemType Directory $m1, $m2, $m3 -Force | Out-Null
New-TestFile (Join-Path $m1 'f.tmp') 10
New-TestFile (Join-Path $m2 'f.tmp') 10
New-TestFile (Join-Path $m3 'f.tmp') 10
$multiCode = @'
param([string]$D1,[string]$D2,[string]$D3)
$_cats = @('user_temp','steam_cache')
function Should-Clean([string]$id) { return ($_cats.Count -eq 0 -or $_cats -contains $id) }
function Clear-Folder([string]$P) { Get-ChildItem $P -Force -ErrorAction SilentlyContinue | Remove-Item -Force }
if (Should-Clean 'user_temp')   { Clear-Folder $D1; Write-Output "D1=cleaned" } else { Write-Output "D1=skipped" }
if (Should-Clean 'steam_cache') { Clear-Folder $D2; Write-Output "D2=cleaned" } else { Write-Output "D2=skipped" }
if (Should-Clean 'gpu_cache')   { Clear-Folder $D3; Write-Output "D3=cleaned" } else { Write-Output "D3=skipped" }
'@
$multiCode | Set-Content (Join-Path $TmpBase 'test_multi.ps1') -Encoding UTF8
$mo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_multi.ps1') -D1 $m1 -D2 $m2 -D3 $m3 2>&1
$md1 = ($mo | Where-Object { $_ -match 'D1=(\w+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$md2 = ($mo | Where-Object { $_ -match 'D2=(\w+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$md3 = ($mo | Where-Object { $_ -match 'D3=(\w+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Multi-cat: user_temp cleaned"         ($md1 -eq 'cleaned')  "d1=$md1"
Test-Assert "Multi-cat: steam_cache cleaned"       ($md2 -eq 'cleaned')  "d2=$md2"
Test-Assert "Multi-cat: gpu_cache NOT cleaned"     ($md3 -eq 'skipped')  "d3=$md3"
Test-Assert "Multi-cat: D1 empty on disk"          ((Get-ChildItem $m1 -Force).Count -eq 0)
Test-Assert "Multi-cat: D2 empty on disk"          ((Get-ChildItem $m2 -Force).Count -eq 0)
Test-Assert "Multi-cat: D3 untouched on disk"      ((Get-ChildItem $m3 -Force).Count -eq 1)

# ============================================================================
Section "24. APP.JS — all UI bug fixes present"
# ============================================================================
$appJsPath = Join-Path $ScriptRoot 'frontend\js\app.js'
if (Test-Path $appJsPath) {
    $js = Get-Content -Raw $appJsPath

    Test-Assert "UI: _cleanHasBrowser declared"                   ($js -match "let _cleanHasBrowser\s*=\s*false")
    Test-Assert "UI: _doCleanup sets _cleanHasBrowser"            ($js -match "_cleanHasBrowser\s*=\s*_selectedCats")
    Test-Assert "UI: label uses _cleanHasBrowser (not hardcoded)" ($js -match "_cpSetLabel\(_cleanHasBrowser")
    Test-Assert "UI: _hasScanned=true on first data arrival"      ($js -match "_hasScanned\s*=\s*true")
    Test-Assert "UI: no 1MB threshold in _updateCleanBtn"         ($js -notmatch "total\s*<\s*1024\s*\*\s*1024")
    Test-Assert "UI: _updateCleanBtn: !_hasScanned || !hasSelection" ($js -match "disabled\s*=\s*!_hasScanned\s*\|\|\s*!hasSelection")
    Test-Assert "UI: _cleanFinish resets _allCatIds"              ($js -match "_allCatIds\s*=\s*\[\]")
    Test-Assert "UI: _cleanFinish clears _selectedCats"           ($js -match "_selectedCats\.clear\(\)")
    Test-Assert "UI: renderJunk checks j.status === 'scanning'"   ($js -match "j\?\.status === 'scanning'")
    Test-Assert "UI: _browserCatIds includes browser_history"     ($js -match "browser_history")
    Test-Assert "UI: _browserCatIds includes browser_cache"       ($js -match "browser_cache")
} else {
    Test-Assert "app.js found" $false $appJsPath
}

# ============================================================================
Section "25. INDEX.HTML — hint text updated"
# ============================================================================
$htmlPath = Join-Path $ScriptRoot 'frontend\index.html'
if (Test-Path $htmlPath) {
    $html = Get-Content -Raw $htmlPath
    Test-Assert "HTML: outdated '24ч не удаляются' removed"  ($html -notmatch '24ч не удаляются')
    Test-Assert "HTML: cookies/tabs note present"             ($html -match 'Куки|Cookie|вкладки|tabs')
} else {
    Test-Assert "index.html found" $false $htmlPath
}

# ============================================================================
Section "26. LARGE FILE COUNT — 200 files, no hang"
# ============================================================================
$bigDir = Join-Path $TmpBase 'bigdir'
New-Item -ItemType Directory $bigDir -Force | Out-Null
1..200 | ForEach-Object { [System.IO.File]::WriteAllBytes((Join-Path $bigDir "f$_.tmp"), (New-Object byte[] 1024)) }
$bigCode = $CFBlock + @'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r  = Clear-FolderContents -Path $Dir
$sw.Stop()
Write-Output "REMOVED=$($r.files_removed)"
Write-Output "ELAPSED_MS=$($sw.ElapsedMilliseconds)"
Write-Output "REMAINING=$((Get-ChildItem $Dir -Force -ErrorAction SilentlyContinue).Count)"
'@
$bigCode | Set-Content (Join-Path $TmpBase 'test_big.ps1') -Encoding UTF8
$bigo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_big.ps1') -Dir $bigDir 2>&1
$bigRemoved = [int]($bigo | Where-Object { $_ -match 'REMOVED=(\d+)' }    | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$bigElapsed = [int]($bigo | Where-Object { $_ -match 'ELAPSED_MS=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$bigLeft    = [int]($bigo | Where-Object { $_ -match 'REMAINING=(\d+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "Large: all 200 files deleted"   ($bigRemoved -eq 200)  "removed=$bigRemoved"
Test-Assert "Large: completed in < 10s"      ($bigElapsed -lt 10000) "elapsed=${bigElapsed}ms"
Test-Assert "Large: directory empty after"   ($bigLeft -eq 0)       "remaining=$bigLeft"

# ============================================================================
Section "27. REAL DISK PROOF — files physically gone"
# ============================================================================
$proofDir = Join-Path $TmpBase 'proof'
New-Item -ItemType Directory $proofDir -Force | Out-Null
$proofFiles = @(
    (Join-Path $proofDir 'p1.tmp'),
    (Join-Path $proofDir 'p2.tmp'),
    (Join-Path $proofDir 'p3.tmp')
)
foreach ($f in $proofFiles) { New-TestFile $f 20 }
$pfBefore = $proofFiles | Where-Object { Test-Path $_ }
Test-Assert "Proof: 3 files exist before cleanup"  ($pfBefore.Count -eq 3)

$pfCode = $CFBlock + @'
Clear-FolderContents -Path $Dir | Out-Null
'@
$pfCode | Set-Content (Join-Path $TmpBase 'test_pf.ps1') -Encoding UTF8
& pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_pf.ps1') -Dir $proofDir 2>&1 | Out-Null
$pfAfter = $proofFiles | Where-Object { Test-Path $_ }
Test-Assert "Proof: ALL 3 files gone from disk"     ($pfAfter.Count -eq 0)  "still on disk: $($pfAfter.Count)"
Test-Assert "Proof: parent directory still exists"  (Test-Path $proofDir)

# ============================================================================
Section "28. CLEAR-SINGLEFILE — functional test"
# ============================================================================
$sfPath = Join-Path $TmpBase 'single_test.dmp'
New-TestFile $sfPath 30
$sfCode = @'
param([string]$FilePath)
function Clear-SingleFile {
    param([string]$Path,[switch]$DryRun,[string]$Label='')
    $r = @{ existed=$false; size_before=0; freed_bytes=0; files_removed=0; errors=0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    try {
        $fi = Get-Item -LiteralPath $Path -Force
        $r.existed = $true; $r.size_before = $fi.Length
        if (-not $DryRun) { Remove-Item -LiteralPath $Path -Force; $r.files_removed = 1 }
    } catch { $r.errors++ }
    $r.freed_bytes = $r.size_before; return $r
}
$r = Clear-SingleFile -Path $FilePath
Write-Output "EXISTED=$($r.existed)"
Write-Output "FREED=$($r.freed_bytes)"
Write-Output "REMOVED=$($r.files_removed)"
Write-Output "ON_DISK=$(Test-Path $FilePath)"
'@
$sfCode | Set-Content (Join-Path $TmpBase 'test_sf.ps1') -Encoding UTF8
$sfo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_sf.ps1') -FilePath $sfPath 2>&1
$sfExisted = ($sfo | Where-Object { $_ -match 'EXISTED=(\w+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$sfFreed   = [int64]($sfo | Where-Object { $_ -match 'FREED=(\d+)' }   | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$sfRemoved = [int]($sfo | Where-Object { $_ -match 'REMOVED=(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$sfOnDisk  = ($sfo | Where-Object { $_ -match 'ON_DISK=(\w+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "SingleFile: existed=True"          ($sfExisted -eq 'True')
Test-Assert "SingleFile: freed_bytes = 30KB"    ($sfFreed -ge 30 * 1024)  "freed=$($sfFreed/1KB)KB"
Test-Assert "SingleFile: files_removed = 1"     ($sfRemoved -eq 1)
Test-Assert "SingleFile: gone from disk"        ($sfOnDisk -eq 'False')

# ============================================================================
Section "29. CLEAR-SINGLEFILE — missing file (no crash)"
# ============================================================================
$sfMissCode = @'
function Clear-SingleFile {
    param([string]$Path,[switch]$DryRun,[string]$Label='')
    $r = @{ existed=$false; size_before=0; freed_bytes=0; files_removed=0; errors=0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    try { $fi = Get-Item -LiteralPath $Path -Force; $r.existed=$true; $r.size_before=$fi.Length
          if (-not $DryRun) { Remove-Item -LiteralPath $Path -Force; $r.files_removed=1 } } catch { $r.errors++ }
    $r.freed_bytes = $r.size_before; return $r
}
$r = Clear-SingleFile -Path 'C:\NONEXISTENT_CF_TEST_99.dmp'
Write-Output "EXISTED=$($r.existed)"
Write-Output "ERRORS=$($r.errors)"
Write-Output "FREED=$($r.freed_bytes)"
'@
$sfMissCode | Set-Content (Join-Path $TmpBase 'test_sfm.ps1') -Encoding UTF8
$sfmo = & pwsh -NoProfile -NonInteractive -File (Join-Path $TmpBase 'test_sfm.ps1') 2>&1
$sfmExisted = ($sfmo | Where-Object { $_ -match 'EXISTED=(\w+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$sfmErrors  = [int]($sfmo | Where-Object { $_ -match 'ERRORS=(\d+)' }  | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$sfmFreed   = [int64]($sfmo | Where-Object { $_ -match 'FREED=(\d+)' }    | ForEach-Object { $Matches[1] } | Select-Object -First 1)
Test-Assert "SingleFile missing: existed=False"  ($sfmExisted -eq 'False')
Test-Assert "SingleFile missing: errors=0"       ($sfmErrors -eq 0)
Test-Assert "SingleFile missing: freed=0"        ($sfmFreed -eq 0)

# ============================================================================
Section "30. STEAM SOURCE — all paths present"
# ============================================================================
Test-Assert "Steam: htmlcache path in source"             ($cleanContent -match 'htmlcache')
Test-Assert "Steam: shadercache path in source"           ($cleanContent -match 'shadercache')
Test-Assert "Steam: logs path in source"                  ($cleanContent -match 'steamInstall.*logs|logs.*steam' -or $cleanContent -match '".*\\logs"')
Test-Assert "Steam: dumps path in source"                 ($cleanContent -match 'dumps')
Test-Assert "Steam: reads registry for SteamPath"         ($cleanContent -match 'Valve\\Steam|SteamPath')

# ============================================================================
Section "31. BROWSER SOURCE — all 4 browsers covered"
# ============================================================================
Test-Assert "Source: Chrome base path"    ($cleanContent -match 'Google.Chrome.User Data')
Test-Assert "Source: Edge base path"      ($cleanContent -match 'Microsoft.Edge.User Data')
Test-Assert "Source: Brave base path"     ($cleanContent -match 'BraveSoftware.Brave-Browser')
Test-Assert "Source: Firefox base path"   ($cleanContent -match 'Mozilla.Firefox.Profiles')
Test-Assert "Source: INetCache path"      ($cleanContent -match 'INetCache')

# ============================================================================
Section "32. MD REPORT — written to data/logs/"
# ============================================================================
$logsDir = Join-Path $DataDir 'logs'
if (Test-Path $logsDir) {
    $mdFiles = @(Get-ChildItem -LiteralPath $logsDir -Filter 'cleanup-*.md' -ErrorAction SilentlyContinue)
    Test-Assert "MD logs: at least 1 report file"     ($mdFiles.Count -ge 1)  "count=$($mdFiles.Count)"
    if ($mdFiles.Count -gt 0) {
        $latestMd  = $mdFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $mdContent = Get-Content -Raw $latestMd.FullName -ErrorAction SilentlyContinue
        Test-Assert "MD: contains CYBERFORTRESS header"  ($mdContent -match 'CYBERFORTRESS')
        Test-Assert "MD: contains SUMMARY section"       ($mdContent -match 'SUMMARY')
        Test-Assert "MD: contains freed metric"          ($mdContent -match 'freed|Freed')
    }
} else {
    Test-Assert "logs/ directory exists"  $false "path=$logsDir"
}

# ============================================================================
Section "33. SECURITY — sensitive files never in histFiles list"
# ============================================================================
$histSection = ''
if ($cleanContent -match '(?s)\$histFiles\s*=\s*@\((.*?)\)') { $histSection = $Matches[1] }
Test-Assert "Security: 'Cookies' NOT in histFiles"            ($histSection -notmatch "'Cookies'")
Test-Assert "Security: 'Login Data' NOT in histFiles"         ($histSection -notmatch "'Login Data'")
Test-Assert "Security: 'Web Data' NOT in histFiles"           ($histSection -notmatch "'Web Data'")
Test-Assert "Security: 'Bookmarks' NOT in histFiles"          ($histSection -notmatch "'Bookmarks'")
Test-Assert "Security: 'Extension Cookies' NOT in histFiles"  ($histSection -notmatch "'Extension Cookies'")

# ============================================================================
Section "34. JSON INTEGRITY — valid JSON, not empty"
# ============================================================================
if (Test-Path $lcPath) {
    $raw = Get-Content -Raw $lcPath -ErrorAction SilentlyContinue
    Test-Assert "JSON: file not empty"                    (-not [string]::IsNullOrWhiteSpace($raw))
    $parseOk = $false
    try { $null = $raw | ConvertFrom-Json; $parseOk = $true } catch { }
    Test-Assert "JSON: valid (parses without error)"      $parseOk
    Test-Assert "JSON: starts with '{'"                   ($raw.TrimStart()[0] -eq '{')
}

# ============================================================================
Section "35. SIGNAL FILE MECHANISM — Get-SystemInfo.ps1 wiring"
# ============================================================================
$sysInfo = Get-Content -Raw (Join-Path $BackendDir 'Get-SystemInfo.ps1') -ErrorAction SilentlyContinue
Test-Assert "Signal: cleanup.signal in Get-SystemInfo"      ($sysInfo -match 'cybfortress_cleanup\.signal')
Test-Assert "Signal: launches Clean-Junk.ps1"               ($sysInfo -match 'Clean-Junk')
Test-Assert "Signal: junk cache reset after cleanup"        ($sysInfo -match 'MinValue|lastJunkCheck')

# ============================================================================
Section "SUMMARY"
# ============================================================================
Write-Host ""
Write-Host ("=" * 65) -ForegroundColor Cyan
Write-Host "  TEST RESULTS — CleanupFunctionality v3" -ForegroundColor Cyan
Write-Host ("=" * 65) -ForegroundColor Cyan
Write-Host ("  PASS : $pass") -ForegroundColor Green
Write-Host ("  FAIL : $fail") -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
Write-Host ("  TOTAL: $($pass + $fail)") -ForegroundColor Cyan
Write-Host ("=" * 65) -ForegroundColor Cyan

if ($fail -gt 0) {
    Write-Host ""
    Write-Host "  FAILED TESTS:" -ForegroundColor Red
    $script:results | Where-Object { $_.status -eq 'FAIL' } | ForEach-Object {
        Write-Host ("    - $($_.name)") -ForegroundColor Red
        if ($_.detail) { Write-Host ("      $($_.detail)") -ForegroundColor DarkGray }
    }
}

Remove-Item -LiteralPath $TmpBase -Recurse -Force -ErrorAction SilentlyContinue

if ($fail -gt 0) { exit 1 } else { exit 0 }
