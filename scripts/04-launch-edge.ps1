<#
.SYNOPSIS
    Launches Microsoft Edge in kiosk/inprivate mode and verifies process stability.
.DESCRIPTION
    Starts Edge with --inprivate --no-first-run --no-default-browser-check, monitors for 15 seconds,
    checks if the process survived (no crash), captures stderr, and reports.
    Designed for both local host and Docker container execution.
.PARAMETER TargetUrl
    The URL Edge should launch to. REQUIRED.
.PARAMETER ContainerName
    Docker container to launch Edge inside. Leave empty for local host.
.PARAMETER WaitSeconds
    How long to wait before checking process survival. Default: 15.
.PARAMETER Headless
    Use --headless flag for Server Core (no GUI) environments.
.EXAMPLE
    .\04-launch-edge.ps1 -TargetUrl "https://app.example.com"
.EXAMPLE
    .\04-launch-edge.ps1 -TargetUrl "https://app.example.com" -ContainerName "appstream-edge-test" -Headless
#>

#Requires -Version 5.1

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetUrl,
    [string]$ContainerName = "",
    [int]$WaitSeconds = 15,
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LogDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir ("launch-{0:yyyyMMdd-HHmmss}.log" -f [DateTime]::UtcNow)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$timestamp] [$Level] $Message"
    Write-Information $line -InformationAction Continue
    Add-Content -Path $LogFile -Value $line
}

if ($ContainerName) {
    Write-Log "=== Phase 3: Container Launch Verification ==="
    Write-Log "Container: $ContainerName | URL: $TargetUrl | Headless: $Headless"

    $launchScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$WaitSeconds = $WaitSeconds
`$TargetUrl = '$TargetUrl'
`$Headless = `$$Headless
`$StderrFile = "C:\edge-stderr-{0:yyyyMMdd-HHmmss}.txt" -f [DateTime]::UtcNow

# Kill any existing msedge processes
Get-Process -Name "msedge" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# Build launch arguments
`$args = @("--inprivate", "--no-first-run", "--no-default-browser-check")
if (`$Headless) { `$args += "--headless" }
`$args += `$TargetUrl

Write-Output "Launching Edge with args: `$(`$args -join ' ')"
`$proc = Start-Process -FilePath "msedge.exe" -ArgumentList `$args -PassThru -NoNewWindow -RedirectStandardError `$StderrFile
`$pid = `$proc.Id
Write-Output "Edge PID: `$pid"

Start-Sleep -Seconds `$WaitSeconds

# Check if still alive
`$alive = Get-Process -Id `$pid -ErrorAction SilentlyContinue
`$survived = `$null -ne `$alive

# Collect stderr
`$stderr = if (Test-Path `$StderrFile) { Get-Content `$StderrFile -Raw } else { "" }

# Kill process cleanly
if (`$survived) {
    Stop-Process -Id `$pid -Force -ErrorAction SilentlyContinue
    Write-Output "Edge survived `$WaitSeconds seconds - killed cleanly"
} else {
    Write-Output "Edge died before `$WaitSeconds seconds"
}

`$output = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    pid = `$pid
    survived_seconds = if (`$survived) { `$WaitSeconds } else { "DIED" }
    survived = `$survived
    headless = `$Headless
    target_url = `$TargetUrl
    stderr_snippet = if (`$stderr.Length -gt 500) { `$stderr.Substring(0, 500) + "..." } else { `$stderr }
    stderr_file = `$StderrFile
}

Write-Output (`$output | ConvertTo-Json -Depth 3)
exit if (`$survived) { 0 } else { 1 }
"@

    $scriptPath = Join-Path $LogDir "launch-container-script.ps1"
    $launchScript | Set-Content -Path $scriptPath -Encoding UTF8
    docker cp $scriptPath "${ContainerName}:C:\launch.ps1" 2>&1 | Out-Null

    try {
        $output = docker exec $ContainerName powershell -ExecutionPolicy Bypass -File "C:\launch.ps1" 2>&1
        Write-Output $output
        Write-Log "Container launch completed"
    } catch {
        Write-Log "Container launch failed: $($_.Exception.Message)" "ERROR"
        $output = @{
            timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            pid = $null
            survived = $false
            error = $_.Exception.Message
        }
        Write-Output ($output | ConvertTo-Json)
        exit 1
    }
    exit $LASTEXITCODE
}

# === Local host execution ===
Write-Log "=== Phase 3: Local Launch Verification ==="
Write-Log "URL: $TargetUrl | WaitSeconds: $WaitSeconds | Headless: $Headless"

# Kill any existing msedge processes
$existing = Get-Process -Name "msedge" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Log "Killing $($existing.Count) existing msedge processes..."
    $existing | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$stderrFile = Join-Path $LogDir ("edge-stderr-{0:yyyyMMdd-HHmmss}.txt" -f [DateTime]::UtcNow)
Write-Log "Stderr redirected to: $stderrFile"

# Build launch arguments
$edgeArgs = @("--inprivate", "--no-first-run", "--no-default-browser-check")
if ($Headless) { $edgeArgs += "--headless" }
$edgeArgs += $TargetUrl

Write-Log "Launching Edge: msedge.exe $($edgeArgs -join ' ')"

try {
    $proc = Start-Process -FilePath "msedge.exe" -ArgumentList $edgeArgs -PassThru -NoNewWindow -RedirectStandardError $stderrFile
    $pid = $proc.Id
    Write-Log "Edge PID: $pid"
} catch {
    Write-Log "Failed to start Edge: $($_.Exception.Message)" "ERROR"
    $output = @{
        timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        pid = $null
        survived = $false
        headless = $Headless
        target_url = $TargetUrl
        error = $_.Exception.Message
    }
    Write-Output ($output | ConvertTo-Json -Depth 3)
    exit 1
}

Write-Log "Waiting $WaitSeconds seconds..."
Start-Sleep -Seconds $WaitSeconds

# Check if still alive
$alive = Get-Process -Id $pid -ErrorAction SilentlyContinue
$survived = $null -ne $alive
Write-Log "Process survived: $survived"

# Collect stderr
$stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue } else { "" }
if ($stderr) { Write-Log "Stderr captured: $($stderr.Length) chars" }

# Kill process cleanly
if ($survived) {
    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    Write-Log "Edge survived ${WaitSeconds}s — killed cleanly"
} else {
    Write-Log "Edge died before ${WaitSeconds}s — check event log" "WARN"
}

$output = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    pid = $pid
    survived_seconds = if ($survived) { $WaitSeconds } else { "DIED" }
    survived = $survived
    headless = $Headless
    target_url = $TargetUrl
    stderr_snippet = if ($stderr -and $stderr.Length -gt 500) { $stderr.Substring(0, [math]::Min(500, $stderr.Length)) + "..." } else { $stderr }
    stderr_file = $stderrFile
    log_file = $LogFile
}

$json = $output | ConvertTo-Json -Depth 3
Write-Output $json

if (-not $survived) {
    Write-Log "=== Phase 3: FAILED ==="
    exit 1
}

Write-Log "=== Phase 3: PASSED ==="
exit 0
