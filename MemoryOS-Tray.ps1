param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$HostName = "127.0.0.1",
    [int]$Port = 8787,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path $RepoRoot).Path
$_startLog = Join-Path $repo "logs\memoryos-tray-startup.log"
try { New-Item -ItemType Directory -Path (Split-Path $_startLog) -Force | Out-Null; Add-Content -Path $_startLog -Value ("{0} TRAY START pid={1}" -f (Get-Date -Format o), $PID) } catch {}
$python = Join-Path $repo ".venv\Scripts\python.exe"
$serverScript = Join-Path $repo "scripts\run_server.py"
$logs = Join-Path $repo "logs"
$healthUrl = "http://${HostName}:${Port}/health"
$localDashboardUrl = "http://${HostName}:${Port}/admin/system"
$dashboardUrl = $localDashboardUrl

function Get-ConfiguredDashboardUrl {
    $railwayEnvFile = Join-Path $repo ".env.railway.local"
    if (-not (Test-Path $railwayEnvFile)) {
        return $localDashboardUrl
    }
    $apiBaseLine = Get-Content -Path $railwayEnvFile | Where-Object {
        $_ -match '^\s*MEMORYOS_API_BASE\s*='
    } | Select-Object -First 1
    if ($apiBaseLine -notmatch '^\s*MEMORYOS_API_BASE\s*=\s*(.+?)\s*$') {
        return $localDashboardUrl
    }
    $cloudBase = $matches[1].Trim().Trim('"').Trim("'").TrimEnd("/")
    if (-not $cloudBase) {
        return $localDashboardUrl
    }
    return "$cloudBase/admin/system"
}

$dashboardUrl = Get-ConfiguredDashboardUrl

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class MemoryOSTrayNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@

$trayErrorLog = Join-Path $logs "memoryos-tray.err.log"
trap {
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    Add-Content -Path $trayErrorLog -Value "$(Get-Date -Format o) $($_.Exception.Message)"
    exit 1
}

function Test-MemoryOSHealth {
    try {
        $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    } catch {
        return $false
    }
}

function Get-MemoryOSServerProcess {
    try {
        $connection = Get-NetTCPConnection -LocalAddress $HostName -LocalPort $Port -State Listen -ErrorAction Stop |
            Select-Object -First 1
    } catch {
        $connection = $null
    }
    if ($null -eq $connection) {
        return $null
    }
    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)"
    } catch {
        return $null
    }
    if ($null -eq $process) {
        return $null
    }
    $commandLine = [string]$process.CommandLine
    if ($commandLine -match "run_server\.py|src\.memoryos_api|uvicorn") {
        return $process
    }
    return $null
}

function Start-MemoryOSServer {
    if (Test-MemoryOSHealth) {
        return
    }
    if (-not (Test-Path $python)) {
        [System.Windows.Forms.MessageBox]::Show("Missing Python environment:`n$python", "MemoryOS") | Out-Null
        return
    }
    if (-not (Test-Path $serverScript)) {
        [System.Windows.Forms.MessageBox]::Show("Missing server script:`n$serverScript", "MemoryOS") | Out-Null
        return
    }
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $env:PYTHONUTF8 = "1"
    $env:MEMORYOS_HOST = $HostName
    $env:MEMORYOS_PORT = [string]$Port
    $env:MEMORYOS_API_KEY = " "
    $outLog = Join-Path $logs "memoryos-tray-server.out.log"
    $errLog = Join-Path $logs "memoryos-tray-server.err.log"
    Start-Process -FilePath $python -ArgumentList @($serverScript) -WorkingDirectory $repo -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-MemoryOSHealth) {
            return
        }
    }
}

function Stop-MemoryOSServer {
    $process = Get-MemoryOSServerProcess
    if ($null -eq $process) {
        return
    }
    Stop-Process -Id $process.ProcessId -Force
}

function Open-Dashboard {
    Start-MemoryOSServer
    Start-Process $dashboardUrl
}

function Open-LocalDashboard {
    Start-MemoryOSServer
    Start-Process $localDashboardUrl
}

function Open-Logs {
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    Start-Process $logs
}

function Install-StartupShortcut {
    $startup = [Environment]::GetFolderPath("Startup")
    New-Item -ItemType Directory -Path $startup -Force | Out-Null
    $shortcutPath = Join-Path $startup "MemoryOS Tray.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $vbsPath = Join-Path $repo "scripts\MemoryOS-Tray.vbs"
    $shortcut.TargetPath = "$env:SystemRoot\System32\wscript.exe"
    $shortcut.Arguments = "`"$vbsPath`" `"$HostName`" $Port"
    $shortcut.WorkingDirectory = $repo
    $shortcut.Description = "MemoryOS tray app"
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
    $shortcut.Save()
    [System.Windows.Forms.MessageBox]::Show("Installed startup shortcut:`n$shortcutPath", "MemoryOS") | Out-Null
}

$script:notificationsApiBase = "http://${HostName}:${Port}"
$script:knownCandidateIds = New-Object 'System.Collections.Generic.HashSet[string]'
$script:candidatesBootstrapped = $false
# Re-entrancy guard for Update-Candidates. The Forms.Timer that drives the
# candidate poll keeps ticking even while a notification is being shown; if
# any call in the poll path pumps the Windows message loop, the timer can
# re-enter Update-Candidates before the previous run finished. This flag
# makes the second entry bail. (The old blocking MessageBox.Show notifier
# triggered exactly this — its modal loop pumped WM_TIMER and stacked one
# dialog every 5s without bound. The notifier is now a non-blocking balloon,
# but the guard stays as defense in depth.)
$script:candidatesBusy = $false

function Get-PendingCandidates {
    try {
        $url = "$script:notificationsApiBase/v1/candidates?tenant_id=local&owner_id=user&limit=50&include_hints=false"
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 3 -ErrorAction Stop
        if ($null -eq $response) { return @() }
        return ,@($response)
    } catch {
        return @()
    }
}

function Get-CandidateToastTitle {
    param($candidate)
    if ($candidate.sensitivity -eq 'secret') { return 'MemoryOS: secret needs approval' }
    if ($candidate.tags -contains 'credential') { return 'MemoryOS: credential needs approval' }
    if ($candidate.tags -contains 'pii') { return 'MemoryOS: PII needs approval' }
    return 'MemoryOS: candidate awaiting review'
}

function Show-CandidateBalloon {
    param(
        [string]$title,
        [string]$text
    )
    if (-not $script:notify) { return }
    # Non-blocking tray balloon. CRITICAL: this must never be a
    # [MessageBox]::Show() — a MessageBox runs its own modal message loop
    # which pumps WM_TIMER for the still-running candidate-poll timer,
    # re-entering Update-Candidates and stacking one dialog every tick
    # without bound. ShowBalloonTip returns immediately and pumps nothing,
    # so the timer cannot re-enter. A click on the balloon is routed to
    # the candidates dashboard by the $notify.add_BalloonTipClicked handler.
    $tipText = [string]$text
    if ($tipText.Length -gt 240) { $tipText = $tipText.Substring(0, 237) + '...' }
    Write-TrayDebug "ShowBalloonTip: $title"
    try {
        $script:notify.ShowBalloonTip(
            10000,
            $title,
            $tipText,
            [System.Windows.Forms.ToolTipIcon]::Warning
        )
    } catch {
        Write-TrayDebug "ShowBalloonTip ERROR: $($_.Exception.Message)"
    }
}

$script:debugLog = Join-Path $logs "memoryos-tray-debug.log"
function Write-TrayDebug { param([string]$msg) Add-Content -Path $script:debugLog -Value ("{0} {1}" -f (Get-Date -Format o), $msg) }

function Update-Candidates {
    # Re-entrancy guard: if a prior poll is still in progress, skip this
    # tick entirely. Defense in depth against any future message-loop pump.
    if ($script:candidatesBusy) {
        Write-TrayDebug "poll skipped: previous Update-Candidates still running"
        return
    }
    $script:candidatesBusy = $true
    try {
        $pending = Get-PendingCandidates
        Write-TrayDebug "poll: count=$($pending.Count) bootstrapped=$script:candidatesBootstrapped knownCount=$($script:knownCandidateIds.Count)"
        if (-not $script:candidatesBootstrapped) {
            foreach ($c in $pending) {
                if ($c.id) { [void]$script:knownCandidateIds.Add([string]$c.id) }
            }
            $script:candidatesBootstrapped = $true
            Write-TrayDebug "bootstrap complete, knownCount=$($script:knownCandidateIds.Count)"
            return
        }
        # Collect EVERY new candidate this poll, mark them all known, then
        # emit ONE batched balloon. The old code popped one blocking modal
        # per new candidate — 8 new candidates meant 8 stacked dialogs.
        # One non-blocking balloon for the whole batch is the correct UX.
        $fresh = New-Object 'System.Collections.Generic.List[object]'
        foreach ($c in $pending) {
            if (-not $c.id) { continue }
            $id = [string]$c.id
            if (-not $script:knownCandidateIds.Contains($id)) {
                [void]$script:knownCandidateIds.Add($id)
                $fresh.Add($c)
            }
        }
        if ($fresh.Count -eq 0) { return }
        Write-TrayDebug "NEW candidates this poll: $($fresh.Count)"
        if ($fresh.Count -eq 1) {
            $c = $fresh[0]
            $claim = [string]$c.claim
            if ($claim.Length -gt 200) { $claim = $claim.Substring(0, 197) + '...' }
            Show-CandidateBalloon -title (Get-CandidateToastTitle -candidate $c) `
                -text "$claim`n`nClick to review in the dashboard."
        } else {
            $sensitive = @($fresh | Where-Object {
                $_.sensitivity -eq 'secret' -or ($_.tags -contains 'credential') -or ($_.tags -contains 'pii')
            })
            $title = if ($sensitive.Count -gt 0) {
                "MemoryOS: $($fresh.Count) candidates need review (incl. sensitive)"
            } else {
                "MemoryOS: $($fresh.Count) candidates awaiting review"
            }
            Show-CandidateBalloon -title $title `
                -text "Click to open the candidates dashboard and review them."
        }
    } catch {
        Write-TrayDebug "Update-Candidates ERROR: $($_.Exception.Message)"
    } finally {
        $script:candidatesBusy = $false
    }
}

function Open-CandidatesDashboard {
    Start-MemoryOSServer
    $candidatesUrl = "http://${HostName}:${Port}/admin/candidates"
    Start-Process $candidatesUrl
}

function New-MemoryOSIcon {
    param([bool]$Online)
    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $color = if ($Online) { [System.Drawing.Color]::FromArgb(124, 232, 164) } else { [System.Drawing.Color]::FromArgb(255, 204, 102) }
    $brush = [System.Drawing.SolidBrush]::new($color)
    $graphics.FillEllipse($brush, 2, 2, 28, 28)
    $font = [System.Drawing.Font]::new("Segoe UI", 14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $format = [System.Drawing.StringFormat]::new()
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $graphics.DrawString("M", $font, [System.Drawing.Brushes]::Black, [System.Drawing.RectangleF]::new(0, 0, 32, 32), $format)
    $handle = $bitmap.GetHicon()
    $handleIcon = [System.Drawing.Icon]::FromHandle($handle)
    $icon = $handleIcon.Clone()
    $handleIcon.Dispose()
    [MemoryOSTrayNative]::DestroyIcon($handle) | Out-Null
    $graphics.Dispose()
    $brush.Dispose()
    $font.Dispose()
    $format.Dispose()
    return @{ Icon = $icon; Bitmap = $bitmap }
}

if ($ValidateOnly) {
    Write-Host "MemoryOS tray app is valid."
    Write-Host "Repo: $repo"
    Write-Host "Dashboard: $dashboardUrl"
    exit 0
}

$mutexSuffix = "$HostName-$Port" -replace '[^A-Za-z0-9_-]', '_'
$script:trayMutex = [System.Threading.Mutex]::new($false, "Local\MemoryOS-Tray-$mutexSuffix")
if (-not $script:trayMutex.WaitOne(0)) {
    exit 0
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$notify = New-Object System.Windows.Forms.NotifyIcon
$context = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$statusItem.Enabled = $false
$context.Items.Add($statusItem) | Out-Null
$context.Items.Add("-") | Out-Null

$openItem = $context.Items.Add("Open Dashboard")
$openItem.add_Click({ Open-Dashboard; Update-Status })

$openLocalItem = $context.Items.Add("Open Local Dashboard")
$openLocalItem.add_Click({ Open-LocalDashboard; Update-Status })

$startItem = $context.Items.Add("Start MemoryOS")
$startItem.add_Click({ Start-MemoryOSServer; Update-Status })

$stopItem = $context.Items.Add("Stop MemoryOS")
$stopItem.add_Click({ Stop-MemoryOSServer; Start-Sleep -Milliseconds 500; Update-Status })

$restartItem = $context.Items.Add("Restart MemoryOS")
$restartItem.add_Click({ Stop-MemoryOSServer; Start-Sleep -Milliseconds 800; Start-MemoryOSServer; Update-Status })

$logsItem = $context.Items.Add("Open Logs Folder")
$logsItem.add_Click({ Open-Logs })

$startupItem = $context.Items.Add("Install at Startup")
$startupItem.add_Click({ Install-StartupShortcut })

$context.Items.Add("-") | Out-Null
$quitItem = $context.Items.Add("Quit Tray App")
$quitItem.add_Click({
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$notify.ContextMenuStrip = $context
$notify.Visible = $true
$script:iconState = $null

function Update-Status {
    $online = Test-MemoryOSHealth
    $statusItem.Text = if ($online) { "Status: MemoryOS online" } else { "Status: MemoryOS offline" }
    $notify.Text = if ($online) { "MemoryOS online - $HostName`:$Port" } else { "MemoryOS offline - $HostName`:$Port" }
    if ($script:iconState) {
        $script:iconState.Icon.Dispose()
        $script:iconState.Bitmap.Dispose()
    }
    $script:iconState = New-MemoryOSIcon -Online $online
    $notify.Icon = $script:iconState.Icon
}

$notify.add_DoubleClick({ Open-Dashboard; Update-Status })
$notify.add_BalloonTipClicked({ Open-CandidatesDashboard })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick({ Update-Status; Update-Candidates })
$timer.Start()

Start-MemoryOSServer
Update-Status
Update-Candidates
[System.Windows.Forms.Application]::Run()

$timer.Stop()
$notify.Dispose()
if ($script:iconState) {
    $script:iconState.Icon.Dispose()
    $script:iconState.Bitmap.Dispose()
}
if ($script:trayMutex) {
    $script:trayMutex.ReleaseMutex()
    $script:trayMutex.Dispose()
}
