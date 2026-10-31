<#
    mergerino-spikecatch.ps1

    Polls Mergerino's thread count at high frequency. When it spikes above a
    threshold, captures every thread's stack via cdb (local symbols only, so
    attach takes <1s and does not freeze the target).

    Designed to reveal WHAT creates hundreds of threads at once.

    Usage:
        .\mergerino-spikecatch.ps1 -ProcessName mergerino
#>

[CmdletBinding()]
param(
    [string]$ProcessName = 'mergerino',
    [string]$OutDir      = "$env:USERPROFILE\Desktop\mergerino-dumps",
    [int]$Threshold     = 200,
    [int]$MaxCaptures   = 6,
    [string]$SymbolDir  = "$env:LOCALAPPDATA\Temp\opencode\symcache"
)

$ErrorActionPreference = 'Continue'

$cdb = @(
    'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe',
    'C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$env:_NT_SYMBOL_PATH = $SymbolDir
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $SymbolDir | Out-Null

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
while (-not $proc) {
    Start-Sleep -Milliseconds 500
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
}
$pid0 = $proc.Id
Write-Host "Spike-catcher on PID $pid0 (threshold $Threshold threads)" -ForegroundColor Cyan

$captures = 0
$lastThreads = 0
$cooldown = 0

while ($captures -lt $MaxCaptures) {
    Start-Sleep -Milliseconds 250
    $p = Get-Process -Id $pid0 -ErrorAction SilentlyContinue
    if (-not $p) { Write-Host "Process exited." -ForegroundColor Yellow; break }

    $t = $p.Threads.Count
    if ($t -gt $Threshold -and $cooldown -le 0) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss.fff'
        $out = Join-Path $OutDir "spike-$stamp-threads$t.txt"
        Write-Host "[$stamp] THREAD SPIKE: $t threads - capturing" -ForegroundColor Red
        try {
            & $cdb -p $pid0 -y $SymbolDir -c "~*k; qd" 2>&1 | Out-File -FilePath $out -Encoding utf8
            Write-Host "  -> $out" -ForegroundColor Green
            $captures++
            $cooldown = 20   # 20 * 250ms = 5s between captures
        } catch {
            Write-Warning "cdb failed: $_"
            $cooldown = 8
        }
    } else {
        if ($cooldown -gt 0) { $cooldown-- }
    }
    $lastThreads = $t
}

Write-Host "Done ($captures captures)." -ForegroundColor Cyan
