$ErrorActionPreference = "Stop"

$repo    = "C:\Users\taeji\AppData\Local\MemoryOS\memoryos_ai_memory_server"
$script  = Join-Path $repo "scripts\memoryos_observer.py"
$envFile = Join-Path $repo ".env.railway.local"
$logDir  = Join-Path $repo "logs"
$outLog  = Join-Path $logDir "memoryos-observer-service.out.log"
$errLog  = Join-Path $logDir "memoryos-observer-service.err.log"

# Single-instance guard: if an observer is already running, do nothing.
# This is the fix for the duplicate-observer flood -- no matter how many
# times the Startup shortcut (or a manual start) fires, only one observer
# process can ever exist, so observations are POSTed exactly once.
$already = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*memoryos_observer.py*" }
if ($already) { exit 0 }

# Prefer the repo venv python; fall back to whatever python is on PATH.
$python = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    $python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
}
if (-not $python)              { throw "No python found" }
if (-not (Test-Path $script))  { throw "Missing observer script: $script" }
if (-not (Test-Path $envFile)) { throw "Missing env file: $envFile" }

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Set-Location $repo
$env:PYTHONUTF8 = "1"

& $python $script run --env-file $envFile --interval 30 1>> $outLog 2>> $errLog
exit $LASTEXITCODE
