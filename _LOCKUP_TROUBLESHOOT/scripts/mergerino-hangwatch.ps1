<#
    mergerino-hangwatch.ps1  (v2 - crash-proof)

    Monitors Mergerino and captures evidence of a GUI lockup:
      - all thread stacks via cdb (~*k)        [LOCAL symbols only -> attaches in <1s]
      - a full memory dump via comsvcs MiniDump
      - a continuous health CSV

    Design notes:
      * $ErrorActionPreference is deliberately NOT 'Stop'. A single failed
        property access (e.g. .MainWindowHandle on a process whose window is
        being destroyed) must never kill the monitor.
      * Every risky access is individually guarded.
      * The script is designed to run forever and never exit on error.

    Usage (elevated):
        powershell -File mergerino-hangwatch.ps1 -ProcessName mergerino
#>

[CmdletBinding()]
param(
    [string]$ProcessName = 'mergerino',
    [string]$OutDir      = "$env:USERPROFILE\Desktop\mergerino-dumps",
    [int]$IntervalSec    = 2,
    [int]$StrikesToFire  = 3,
    [int]$WarmupSec      = 30,
    [string]$SymbolDir   = "$env:LOCALAPPDATA\Temp\opencode\symcache"
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$cdb = @(
    'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe',
    'C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

# LOCAL ONLY symbols. Never let cdb hit the network: downloading Qt symbols
# takes ~80s and FREEZES the target the whole time, which mimics a hang.
$env:_NT_SYMBOL_PATH = $SymbolDir
try { New-Item -ItemType Directory -Force -Path $SymbolDir | Out-Null } catch { }
try { New-Item -ItemType Directory -Force -Path $OutDir   | Out-Null } catch { }

$errLog = Join-Path $OutDir 'hangwatch-errors.log'
function Log-Err($m) {
    try { Add-Content -Path $errLog -Value ("{0} {1}" -f (Get-Date).ToString('HH:mm:ss'), $m) } catch { }
}

function Get-Prop($obj, $name, $default) {
    try {
        $v = $obj.$name
        if ($null -eq $v) { return $default }
        return $v
    } catch {
        return $default
    }
}

# ---------------------------------------------------------------- find target
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] waiting for '$ProcessName'..." -ForegroundColor Cyan
$proc = $null
while (-not $proc) {
    try { $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { }
    if (-not $proc) { Start-Sleep -Seconds 2 }
}
$targetPid = $proc.Id
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$base   = Join-Path $OutDir "mergerino-hang-$stamp"
$csvFile = "$base-samples.csv"
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] watching PID $targetPid -> $csvFile" -ForegroundColor Green

try {
    'timestamp,responding,cpu_pct,working_set_mb,private_mb,threads,handles' |
        Out-File -FilePath $csvFile -Encoding utf8
} catch { Log-Err "csv header write failed: $_" }

$lastCpu = 0.0
try { $lastCpu = [double](Get-Prop $proc 'CPU' 0) } catch { }
$lastSample = Get-Date
$armedAt = (Get-Date).AddSeconds($WarmupSec)
$strikes = 0

# ---------------------------------------------------------------- main loop
while ($true) {
    try {
        Start-Sleep -Seconds $IntervalSec

        $p = $null
        try { $p = Get-Process -Id $targetPid -ErrorAction SilentlyContinue } catch { }
        if (-not $p) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] target exited - monitor stopping." -ForegroundColor Yellow
            break
        }

        $mainWin = Get-Prop $p 'MainWindowHandle' 0
        if ($mainWin -eq 0) { continue }

        # ---- sample health ----
        $now  = Get-Date
        $cpu  = [double](Get-Prop $p 'CPU' $lastCpu)
        $dt   = ($now - $lastSample).TotalSeconds
        $pct  = 0
        if ($dt -gt 0) { $pct = [math]::Round((($cpu - $lastCpu) / $dt) * 100, 1) }
        $lastCpu = $cpu
        $lastSample = $now

        $responding = Get-Prop $p 'Responding' '?'
        $threads    = Get-Prop $p 'Threads' '?'
        if ($threads -isnot [string]) { $threads = $threads.Count }
        $handles    = Get-Prop $p 'HandleCount' '?'
        $ws         = Get-Prop $p 'WorkingSet64' 0
        $priv       = Get-Prop $p 'PrivateMemorySize64' 0

        try {
            "{0},{1},{2},{3},{4},{5},{6}" -f $now.ToString('HH:mm:ss'), $responding, $pct,
                [math]::Round($ws / 1MB, 1), [math]::Round($priv / 1MB, 1), $threads, $handles |
                Out-File -FilePath $csvFile -Append -Encoding utf8
        } catch { Log-Err "csv append failed: $_" }

        if ($responding -eq $true) {
            $strikes = 0
            continue
        }

        if ($now -lt $armedAt) {
            Write-Host "[$($now.ToString('HH:mm:ss'))] unresponsive during warmup - ignored." -ForegroundColor DarkGray
            continue
        }

        $strikes++
        Write-Host "[$($now.ToString('HH:mm:ss'))] UNRESPONSIVE $strikes/$StrikesToFire  cpu=$pct% ws=$([math]::Round($ws/1MB,1))MB thr=$threads" -ForegroundColor Yellow
        if ($strikes -lt $StrikesToFire) { continue }

        # ---------------- capture ----------------
        Write-Host "[$($now.ToString('HH:mm:ss'))] CAPTURING..." -ForegroundColor Red

        if ($cdb) {
            $stackFile = "$base-stacks.txt"
            try {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                & $cdb -p $targetPid -y $SymbolDir -c "~*k; qd" 2>&1 |
                    Out-File -FilePath $stackFile -Encoding utf8
                $sw.Stop()
                Write-Host ("  stacks -> {0} ({1} s)" -f $stackFile, [math]::Round($sw.Elapsed.TotalSeconds,1)) -ForegroundColor Green
            } catch { Log-Err "cdb failed: $_"; Write-Warning "cdb failed: $_" }
        } else {
            Write-Warning "cdb.exe not found"
        }

        $dmpFile = "$base.dmp"
        try {
            $script = "C:\Windows\System32\comsvcs.dll, MiniDump $targetPid $dmpFile full"
            Start-Process -FilePath "$env:SystemRoot\System32\rundll32.exe" `
                          -ArgumentList $script -Wait -NoNewWindow -ErrorAction SilentlyContinue
            if (Test-Path $dmpFile) {
                Write-Host "  dump   -> $dmpFile ($([math]::Round((Get-Item $dmpFile).Length/1MB,1)) MB)" -ForegroundColor Green
                try { & icacls.exe $dmpFile /grant "${env:USERNAME}:(R)" | Out-Null } catch { }
            } else {
                Write-Warning "MiniDump produced no file"
            }
        } catch { Log-Err "MiniDump failed: $_"; Write-Warning "MiniDump failed: $_" }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] captured - app left running." -ForegroundColor Cyan
        break
    }
    catch {
        # NEVER die on a transient error.
        Log-Err "loop error: $_"
        Start-Sleep -Seconds 2
    }
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] monitor finished." -ForegroundColor Cyan
