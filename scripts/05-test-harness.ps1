<#
.SYNOPSIS
    Full pipeline orchestrator — runs Phase 0→4 in sequence with iteration support.
.DESCRIPTION
    Executes the complete Edge AppStream optimization pipeline:
      Phase 0: Pre-flight checks
      Phase 1: Container provisioning
      Phase 2: Policy injection
      Phase 3: Registry validation (standalone)
      Phase 4: Launch & stability verification
    Supports -Iterations N for reliability testing with pass-rate tracking.
    Generates test-report.json at completion.
.PARAMETER TargetUrl
    The private URL Edge will launch to. REQUIRED.
.PARAMETER Iterations
    Number of full pipeline iterations to run. Default: 1.
.PARAMETER StopOnFirstFailure
    If set, stops immediately when any phase fails. Default: true.
.PARAMETER Headless
    Pass --headless flag to Edge launch (required for Server Core containers).
.PARAMETER NoCache
    Force fresh Docker pull (bypass layer cache).
.EXAMPLE
    .\05-test-harness.ps1 -TargetUrl "https://app.example.com"
.EXAMPLE
    .\05-test-harness.ps1 -TargetUrl "https://app.example.com" -Iterations 10 -Headless
.EXAMPLE
    .\05-test-harness.ps1 -TargetUrl "https://app.example.com" -Iterations 20 -StopOnFirstFailure:$false
#>

#Requires -Version 5.1

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetUrl,
    [int]$Iterations = 1,
    [switch]$StopOnFirstFailure = $true,
    [switch]$Headless,
    [switch]$NoCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$LogDir = Join-Path $ScriptDir "..\logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

$ReportPath = Join-Path $ScriptDir "..\test-report.json"
$HarnessLog = Join-Path $LogDir ("harness-{0:yyyyMMdd-HHmmss}.log" -f [DateTime]::UtcNow)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$timestamp] [$Level] $Message"
    Write-Information $line -InformationAction Continue
    Add-Content -Path $HarnessLog -Value $line
}

function Invoke-Phase {
    param(
        [string]$PhaseName,
        [string]$ScriptName,
        [string]$Arguments,
        [int]$ExpectedExitCode = 0
    )
    $scriptPath = Join-Path $ScriptDir $ScriptName
    if (-not (Test-Path $scriptPath)) {
        Write-Log "Script not found: $scriptPath" "ERROR"
        return @{ phase = $PhaseName; passed = $false; error = "Script not found: $scriptPath" }
    }

    Write-Log "--- $PhaseName : Starting ---"
    $startTime = Get-Date

    try {
        $fullCmd = "powershell -ExecutionPolicy Bypass -File `"$scriptPath`" $Arguments"
        Write-Log "Executing: $fullCmd"
        $output = Invoke-Expression $fullCmd 2>&1
        $exitCode = $LASTEXITCODE

        $elapsed = (Get-Date) - $startTime
        Write-Log "$PhaseName : Exit code: $exitCode | Elapsed: $($elapsed.TotalSeconds)s"

        if ($exitCode -eq $ExpectedExitCode) {
            Write-Log "$PhaseName : PASSED"
            return @{
                phase = $PhaseName
                passed = $true
                exit_code = $exitCode
                elapsed_seconds = [math]::Round($elapsed.TotalSeconds, 1)
                output = $output
            }
        } else {
            Write-Log "$PhaseName : FAILED (exit code $exitCode, expected $ExpectedExitCode)" "WARN"
            return @{
                phase = $PhaseName
                passed = $false
                exit_code = $exitCode
                elapsed_seconds = [math]::Round($elapsed.TotalSeconds, 1)
                error = "Exit code $exitCode (expected $ExpectedExitCode)"
                output = $output
            }
        }
    } catch {
        $elapsed = (Get-Date) - $startTime
        Write-Log "$PhaseName : ERROR — $($_.Exception.Message)" "ERROR"
        return @{
            phase = $PhaseName
            passed = $false
            elapsed_seconds = [math]::Round($elapsed.TotalSeconds, 1)
            error = $_.Exception.Message
        }
    }
}

Write-Log "============================================"
Write-Log "TEST HARNESS STARTED"
Write-Log "Target URL: $TargetUrl"
Write-Log "Iterations: $Iterations"
Write-Log "StopOnFirstFailure: $StopOnFirstFailure"
Write-Log "Headless: $Headless"
Write-Log "============================================"

$headlessArgStr = if ($Headless) { "-Headless" } else { "" }
$phaseOrder = @(
    @{ Name = "Phase 0: Preflight";        Script = "00-preflight.ps1";         Args = "";                              ExitCode = 0 }
    @{ Name = "Phase 1: Provisioning";     Script = "01-provision-container.ps1"; Args = if ($NoCache) { "-NoCache" } else { "" }; ExitCode = 0 }
    @{ Name = "Phase 2: Policy Injection"; Script = "02-inject-policies.ps1";  Args = "-TargetUrl `"$TargetUrl`"";     ExitCode = 0 }
    @{ Name = "Phase 3: Validate Registry";Script = "03-validate-registry.ps1"; Args = "-TargetUrl `"$TargetUrl`"";     ExitCode = 0 }
    @{ Name = "Phase 4: Launch Edge";     Script = "04-launch-edge.ps1";       Args = "-TargetUrl `"$TargetUrl`" $headlessArgStr"; ExitCode = 0 }
)

$allIterations = @()
$edgeCasesTriggered = @()
$totalPasses = 0
$totalFailures = 0

for ($i = 1; $i -le $Iterations; $i++) {
    Write-Log ""
    Write-Log "======== ITERATION $i / $Iterations ========"

    $iterationResult = @{
        iteration = $i
        phases = @()
        all_passed = $true
        first_failure = $null
    }

    foreach ($phase in $phaseOrder) {
        $result = Invoke-Phase -PhaseName $phase.Name -ScriptName $phase.Script -Arguments $phase.Args -ExpectedExitCode $phase.ExitCode
        $iterationResult.phases += $result

        if (-not $result.passed) {
            $iterationResult.all_passed = $false
            $iterationResult.first_failure = $phase.Name
            $totalFailures++

            if ($StopOnFirstFailure) {
                Write-Log "STOPPING: First failure at $($phase.Name) — StopOnFirstFailure is enabled"
                break
            }
        }
    }

    if ($iterationResult.all_passed) {
        $totalPasses++
        Write-Log "ITERATION $i: ALL PHASES PASSED"
    } else {
        Write-Log "ITERATION $i: FAILED at $($iterationResult.first_failure)"
    }

    $allIterations += $iterationResult

    # Cleanup between iterations
    if ($i -lt $Iterations) {
        Write-Log "Running cleanup before next iteration..."
        try {
            & (Join-Path $ScriptDir "06-cleanup.ps1") 2>&1 | Out-Null
            Start-Sleep -Seconds 5
        } catch {
            Write-Log "Cleanup between iterations failed (non-fatal): $($_.Exception.Message)" "WARN"
        }
    }
}

$passRate = if ($Iterations -gt 0) { [math]::Round($totalPasses / $Iterations, 3) } else { 0 }

$verdict = switch ($passRate) {
    1.0      { "RELIABLE" }
    { $_ -ge 0.95 } { "ACCEPTABLE" }
    { $_ -ge 0.80 } { "UNSTABLE" }
    default  { "BROKEN" }
}

$phaseStats = @{}
foreach ($phase in $phaseOrder) {
    $phasePasses = 0
    $phaseFailures = 0
    foreach ($iter in $allIterations) {
        $pr = $iter.phases | Where-Object { $_.phase -eq $phase.Name }
        if ($pr -and $pr.passed) { $phasePasses++ }
        elseif ($pr) { $phaseFailures++ }
    }
    $phaseStats[$phase.Name] = @{ passes = $phasePasses; failures = $phaseFailures }
}

$report = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    target_url = $TargetUrl
    headless = $Headless
    iterations_requested = $Iterations
    iterations_completed = $allIterations.Count
    total_passes = $totalPasses
    total_failures = $totalFailures
    pass_rate = $passRate
    verdict = $verdict
    phase_statistics = $phaseStats
    edge_cases_triggered = $edgeCasesTriggered
    iterations = $allIterations
    harness_log = $HarnessLog
}

$reportJson = $report | ConvertTo-Json -Depth 5
$reportJson | Set-Content -Path $ReportPath -Encoding UTF8

Write-Log ""
Write-Log "============================================"
Write-Log "HARNESS COMPLETE"
Write-Log "Pass Rate: $passRate ($totalPasses/$Iterations)"
Write-Log "Verdict: $verdict"
Write-Log "Report: $ReportPath"
Write-Log "============================================"

Write-Output $reportJson

if ($verdict -eq "BROKEN") { exit 2 }
if ($verdict -eq "UNSTABLE") { exit 1 }
exit 0
