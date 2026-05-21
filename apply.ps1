# MemoryOS laptop fix installer -- run this ON THE LAPTOP (XPG).
# It clears the running MemoryOS processes and installs three fixed files:
#   * MemoryOS-Tray.ps1        -> stops the dialog cascade
#   * memoryos-observer-run.ps1 -> single-instance guard, stops the duplicate flood
#   * memoryos-observer-run.cmd -> wrapper the Startup shortcut calls
$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
if (-not $src) { throw "Run this as a file (powershell -File apply.ps1), not by pasting." }

$trayDst = "C:\Users\taeji\AppData\Local\MemoryOS\memoryos_ai_memory_server\scripts\MemoryOS-Tray.ps1"
$obsPs1  = "C:\Users\taeji\bin\memoryos-observer-run.ps1"
$obsCmd  = "C:\Users\taeji\bin\memoryos-observer-run.cmd"

foreach ($f in "MemoryOS-Tray.ps1","memoryos-observer-run.ps1","memoryos-observer-run.cmd") {
    if (-not (Test-Path (Join-Path $src $f))) { throw "Missing staged file: $f -- run apply.ps1 from inside the xpg-fix folder." }
}
if (-not (Test-Path (Split-Path $trayDst))) { throw "Tray folder not found: $(Split-Path $trayDst)" }
if (-not (Test-Path (Split-Path $obsPs1)))  { throw "bin folder not found: $(Split-Path $obsPs1)" }

# 1. Kill every running MemoryOS process (clean slate).
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -match 'memoryos' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host "1/2  running MemoryOS processes cleared"

# 2. Install the three fixed files.
Copy-Item (Join-Path $src "MemoryOS-Tray.ps1")         $trayDst -Force
Copy-Item (Join-Path $src "memoryos-observer-run.ps1") $obsPs1  -Force
Copy-Item (Join-Path $src "memoryos-observer-run.cmd") $obsCmd  -Force
Write-Host "2/2  fixed tray + guarded observer launcher installed"

Write-Host ""
Write-Host "Fix applied. Reboot the laptop now."
