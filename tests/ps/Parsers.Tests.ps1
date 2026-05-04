# Parsers.Tests.ps1 - pure ASCII strings, no Cyrillic in literals

$script:passed = 0
$script:failed = 0
$script:results = [System.Collections.Generic.List[hashtable]]::new()

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:passed++
        $script:results.Add(@{ ok = $true; name = $Name })
    } catch {
        $script:failed++
        $script:results.Add(@{ ok = $false; name = $Name; error = $_.Exception.Message })
    }
}
function Assert-Eq     { param($A, $E) if ($A -ne $E)  { throw "Expected: $E`nGot: $A" } }
function Assert-Null   { param($V)     if ($null -ne $V){ throw "Expected null, got: $V" } }
function Assert-True   { param($V)     if (-not $V)     { throw "Expected true, got: $V" } }
function Assert-False  { param($V)     if ($V)          { throw "Expected false, got: $V" } }

# SSH section parser (copy from Get-SystemInfo.ps1)
function Invoke-SshParser {
    param([string]$Output)
    $sections = @{}
    $current = $null; $buf = @()
    foreach ($line in ($Output -split "`n")) {
        if ($line -match '^===(.+?)===\r?$') {
            if ($current) { $sections[$current] = ($buf -join "`n").Trim() }
            $current = $matches[1]; $buf = @()
        } else { $buf += $line }
    }
    if ($current -and $current -ne 'END') { $sections[$current] = ($buf -join "`n").Trim() }
    return $sections
}

# Env file parser (copy from Get-SystemInfo.ps1)
function Invoke-EnvParser {
    param([string[]]$Lines)
    $env = @{}
    foreach ($line in $Lines) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $t.Substring(0, $eq).Trim()
        $v = $t.Substring($eq + 1).Trim()
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or
            ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $env[$k] = $v
    }
    return $env
}

# Ping latency helper (copy from Get-SystemInfo.ps1)
function Get-PingLatency {
    param($PingObj)
    if ($PingObj.PSObject.Properties['Latency'])          { return [int]$PingObj.Latency }
    elseif ($PingObj.PSObject.Properties['ResponseTime']) { return [int]$PingObj.ResponseTime }
    else { return 0 }
}

# =============================================================================
# SSH Parser tests
# =============================================================================
Test-Case 'SSH parser: single section' {
    $s = Invoke-SshParser "===HOSTNAME===`nrouter-1`n===END==="
    Assert-Eq $s['HOSTNAME'] 'router-1'
}
Test-Case 'SSH parser: multiple sections' {
    $s = Invoke-SshParser "===HOSTNAME===`nnas`n===UPTIME===`n123.45 678.90`n===END==="
    Assert-Eq $s['HOSTNAME'] 'nas'
    Assert-Eq $s['UPTIME']   '123.45 678.90'
}
Test-Case 'SSH parser: multiline section value' {
    $s = Invoke-SshParser "===MEMINFO===`nMemTotal: 4096 kB`nMemFree: 1024 kB`n===END==="
    Assert-True ($s['MEMINFO'] -match 'MemTotal')
    Assert-True ($s['MEMINFO'] -match 'MemFree')
}
Test-Case 'SSH parser: empty section' {
    $s = Invoke-SshParser "===HOSTNAME===`n===UNAME===`nLinux router`n===END==="
    Assert-Eq $s['HOSTNAME'] ''
    Assert-Eq $s['UNAME']    'Linux router'
}
Test-Case 'SSH parser: END section not in result' {
    $s = Invoke-SshParser "===HOSTNAME===`ntest`n===END==="
    Assert-False ($s.ContainsKey('END'))
}
Test-Case 'SSH parser: empty output returns empty hash' {
    $s = Invoke-SshParser ''
    Assert-Eq $s.Count 0
}
Test-Case 'SSH parser: whitespace is trimmed' {
    $s = Invoke-SshParser "===MODEL===`n  RT-AX89X  `n===END==="
    Assert-Eq $s['MODEL'] 'RT-AX89X'
}
Test-Case 'SSH parser: real ASUS output' {
    $out = "===HOSTNAME===`nRT-AX89X-7A70`n===UNAME===`nLinux RT-AX89X-7A70 4.4.60 #1 SMP armv7l ASUSWRT`n===LOADAVG===`n2.50 2.30 2.22 3/456 789`n===END==="
    $s = Invoke-SshParser $out
    Assert-Eq  $s['HOSTNAME'] 'RT-AX89X-7A70'
    Assert-True ($s['UNAME'] -match 'ASUSWRT')
    Assert-True ($s['LOADAVG'] -match '^2\.50')
}
Test-Case 'SSH parser: CRLF line endings handled' {
    $s = Invoke-SshParser "===HOSTNAME===`r`nrouter`r`n===END==="
    Assert-True ($s['HOSTNAME'] -match 'router')
}
Test-Case 'SSH parser: END marker presence = success detection' {
    $out = "===HOSTNAME===`ntest`n===END==="
    $ok = ($out -match '===END===')
    Assert-True $ok
}
Test-Case 'SSH parser: no END marker = failure detected' {
    $out = "===HOSTNAME===`ntest"
    $ok = ($out -match '===END===')
    Assert-False $ok
}

# =============================================================================
# Load-Env parser tests
# =============================================================================
Test-Case 'Load-Env: basic KEY=VALUE' {
    $e = Invoke-EnvParser @('SYNOLOGY_HOST=192.168.50.124')
    Assert-Eq $e['SYNOLOGY_HOST'] '192.168.50.124'
}
Test-Case 'Load-Env: comment line ignored' {
    $e = Invoke-EnvParser @('# comment', 'KEY=val')
    Assert-False ($e.ContainsKey('# comment'))
    Assert-Eq $e['KEY'] 'val'
}
Test-Case 'Load-Env: blank lines ignored' {
    $e = Invoke-EnvParser @('', '   ', 'KEY=val')
    Assert-Eq $e.Count 1
}
Test-Case 'Load-Env: double quotes stripped' {
    $e = Invoke-EnvParser @('PASS="secret123"')
    Assert-Eq $e['PASS'] 'secret123'
}
Test-Case 'Load-Env: single quotes stripped' {
    $e = Invoke-EnvParser @("PASS='secret123'")
    Assert-Eq $e['PASS'] 'secret123'
}
Test-Case 'Load-Env: equals sign inside value preserved' {
    $e = Invoke-EnvParser @('TOKEN=abc=def=ghi')
    Assert-Eq $e['TOKEN'] 'abc=def=ghi'
}
Test-Case 'Load-Env: spaces around = trimmed' {
    $e = Invoke-EnvParser @('KEY = value ')
    Assert-Eq $e['KEY'] 'value'
}
Test-Case 'Load-Env: multiple keys parsed' {
    $e = Invoke-EnvParser @('SYNOLOGY_HOST=192.168.50.124','SYNOLOGY_USER=admin','SYNOLOGY_PORT=22')
    Assert-Eq $e.Count 3
    Assert-Eq $e['SYNOLOGY_PORT'] '22'
}

# =============================================================================
# CR strip tests
# =============================================================================
Test-Case 'CR strip: removes \r from command' {
    $cmd   = "echo hello`r`necho world`r`n"
    $clean = $cmd -replace "`r", ''
    Assert-False ($clean -match "`r")
    Assert-True  ($clean -match 'hello')
}
Test-Case 'CR strip: clean command unchanged' {
    $cmd   = "echo hello`necho world`n"
    $clean = $cmd -replace "`r", ''
    Assert-Eq $cmd $clean
}

# =============================================================================
# Ping latency PS5 vs PS7 tests
# =============================================================================
Test-Case 'Ping: PS7 .Latency property used' {
    Assert-Eq (Get-PingLatency ([PSCustomObject]@{ Latency = 42 })) 42
}
Test-Case 'Ping: PS5 .ResponseTime property used' {
    Assert-Eq (Get-PingLatency ([PSCustomObject]@{ ResponseTime = 15 })) 15
}
Test-Case 'Ping: unknown object returns 0' {
    Assert-Eq (Get-PingLatency ([PSCustomObject]@{ Other = 99 })) 0
}
Test-Case 'Ping: Latency takes priority over ResponseTime' {
    Assert-Eq (Get-PingLatency ([PSCustomObject]@{ Latency = 10; ResponseTime = 999 })) 10
}

# =============================================================================
return @{ passed = $script:passed; failed = $script:failed; results = $script:results }
