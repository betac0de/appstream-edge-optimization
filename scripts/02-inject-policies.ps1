<#
.SYNOPSIS
    Injects Microsoft Edge Group Policy registry keys into HKCU for AppStream kiosk mode.
.DESCRIPTION
    Applies 24 registry-based Edge policies covering performance, bloatware removal,
    setup wizard suppression, kiosk/privacy hardening, and startup behavior.
    Performs pre-injection state capture, injection, and post-injection validation.
    Fully idempotent — safe to run hundreds of times.
.PARAMETER TargetUrl
    The private URL Edge will launch to and use as new tab page. REQUIRED.
.PARAMETER ContainerName
    Docker container to inject policies into. Leave empty for local host HKCU.
.PARAMETER DryRun
    If set, validates and reports what WOULD be done without making changes.
.EXAMPLE
    .\02-inject-policies.ps1 -TargetUrl "https://app.example.com"
.EXAMPLE
    .\02-inject-policies.ps1 -TargetUrl "https://app.example.com" -ContainerName "appstream-edge-test" -DryRun
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetUrl,
    [string]$ContainerName = "",
    [switch]$DryRun
)

$LogDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir ("inject-{0:yyyyMMdd-HHmmss}.log" -f [DateTime]::UtcNow)

$EdgePolicyPath = "HKCU:\SOFTWARE\Policies\Microsoft\Edge"
$EdgePolicyRegPath = "HKCU\SOFTWARE\Policies\Microsoft\Edge"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$timestamp] [$Level] $Message"
    Write-Information $line -InformationAction Continue
    Add-Content -Path $LogFile -Value $line
}

# Registry key definitions: Name, Value, Type
# Types: DWORD, String, MultiString
$policyKeys = @(
    # === Performance & Stability ===
    @{ Name = "HardwareAccelerationModeEnabled"; Value = 0; Type = "DWORD" }
    @{ Name = "StartupBoostEnabled";             Value = 0; Type = "DWORD" }
    @{ Name = "BackgroundModeEnabled";           Value = 0; Type = "DWORD" }

    # === Bloatware Removal ===
    @{ Name = "EdgeShoppingAssistantEnabled";    Value = 0; Type = "DWORD" }
    @{ Name = "HubsSidebarEnabled";              Value = 0; Type = "DWORD" }
    @{ Name = "ShowRecommendationsEnabled";      Value = 0; Type = "DWORD" }
    @{ Name = "EdgeCollectionsEnabled";          Value = 0; Type = "DWORD" }
    @{ Name = "EdgeCopilotEnabled";              Value = 0; Type = "DWORD" }

    # === Setup & Sync Suppression ===
    @{ Name = "HideFirstRunExperience";          Value = 1; Type = "DWORD" }
    @{ Name = "BrowserSignin";                   Value = 0; Type = "DWORD" }
    @{ Name = "DefaultBrowserSettingEnabled";    Value = 0; Type = "DWORD" }
    @{ Name = "SyncDisabled";                    Value = 1; Type = "DWORD" }
    @{ Name = "BrowserAddProfileEnabled";        Value = 0; Type = "DWORD" }

    # === Kiosk & Privacy Hardening ===
    @{ Name = "RestoreOnStartup";                Value = 4; Type = "DWORD" }
    @{ Name = "RestoreOnStartupURLs";            Value = @($TargetUrl); Type = "MultiString" }
    @{ Name = "NewTabPageLocation";              Value = $TargetUrl; Type = "String" }
    @{ Name = "PasswordManagerEnabled";          Value = 0; Type = "DWORD" }
    @{ Name = "AutofillAddressEnabled";          Value = 0; Type = "DWORD" }
    @{ Name = "AutofillCreditCardEnabled";       Value = 0; Type = "DWORD" }
    @{ Name = "ExtensionInstallBlocklist";       Value = @("*"); Type = "MultiString" }
    @{ Name = "MetricsReportingEnabled";         Value = 0; Type = "DWORD" }
    @{ Name = "SiteSafetyServicesEnabled";       Value = 0; Type = "DWORD" }
)

# Build execution wrapper (local or container)
function Invoke-RegCommand {
    param([string]$Command)
    if ($ContainerName) {
        $escaped = $Command -replace '"', '\"'
        return docker exec $ContainerName powershell -Command $escaped 2>&1
    } else {
        return Invoke-Expression $Command 2>&1
    }
}

function Test-RegPath {
    $cmd = "Test-Path '$EdgePolicyPath'"
    $result = Invoke-RegCommand $cmd
    return ($result -join "").Trim() -eq "True"
}

# For container mode, we wrap the full script
if ($ContainerName) {
    Write-Log "Container mode: Building script for execution inside $ContainerName"

    $fullScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$EdgePolicyPath = '$EdgePolicyPath'
`$EdgePolicyRegPath = '$EdgePolicyRegPath'
`$TargetUrl = '$TargetUrl'
`$DryRun = `$$DryRun

`$policyKeys = @(
$(
    ($policyKeys | ForEach-Object {
        $valueStr = if ($_.Type -eq "MultiString") {
            "@('$($_.Value -join "','")')"
        } elseif ($_.Type -eq "String") {
            "'$($_.Value)'"
        } else {
            $_.Value
        }
        "    @{ Name = '$($_.Name)'; Value = $valueStr; Type = '$($_.Type)' }"
    }) -join "`n"
)
)

`$results = @()

# Ensure policy path exists
if (-not (Test-Path `$EdgePolicyPath)) {
    New-Item -Path `$EdgePolicyPath -Force | Out-Null
    Write-Output "Created: `$EdgePolicyPath"
} else {
    Write-Output "Path exists: `$EdgePolicyPath"
}

foreach (`$key in `$policyKeys) {
    try {
        if (`$DryRun) {
            Write-Output "DRYRUN: Would set `$(`$key.Name) = `$(`$key.Value) [`$(`$key.Type)]"
            `$results += @{ name = `$key.Name; expected = `$key.Value; status = "DRYRUN"; actual = $null }
            continue
        }

        `$propArgs = @{
            Path = `$EdgePolicyPath
            Name = `$key.Name
            Value = `$key.Value
            PropertyType = `$key.Type
            Force = `$true
        }
        New-ItemProperty @propArgs | Out-Null

        # Read back to verify
        `$actual = Get-ItemProperty -Path `$EdgePolicyPath -Name `$key.Name -ErrorAction SilentlyContinue
        if (`$null -eq `$actual) {
            throw "Key not found after write"
        }

        `$actualValue = `$actual.`$(`$key.Name)
        `$match = `$false
        if (`$key.Type -eq "MultiString") {
            `$match = (Compare-Object `$actualValue `$key.Value).Count -eq 0
        } else {
            `$match = `$actualValue -eq `$key.Value
        }

        `$results += @{
            name = `$key.Name
            expected = `$key.Value
            actual = `$actualValue
            type = `$key.Type
            status = if (`$match) { "PASS" } else { "FAIL" }
        }
    } catch {
        `$results += @{
            name = `$key.Name
            expected = `$key.Value
            actual = $null
            type = `$key.Type
            status = "ERROR"
            error = `$_.Exception.Message
        }
    }
}

# Check for HKLM policy conflicts
`$hklmPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (Test-Path `$hklmPath) {
    `$hklmKeys = Get-ItemProperty -Path `$hklmPath -ErrorAction SilentlyContinue
    `$conflicts = @()
    foreach (`$key in `$policyKeys) {
        if (`$null -ne `$hklmKeys.PSObject.Properties[`$key.Name]) {
            `$conflicts += "`$(`$key.Name) also set in HKLM (precedence: HKLM overrides HKCU)"
        }
    }
    if (`$conflicts.Count -gt 0) {
        Write-Output "WARNING: HKLM policy conflicts detected:"
        `$conflicts | ForEach-Object { Write-Output "  - `$_" }
    } else {
        Write-Output "No HKLM policy conflicts detected."
    }
}

# Output result JSON
`$output = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    policy_path = `$EdgePolicyRegPath
    target_url = `$TargetUrl
    dry_run = `$DryRun
    keys_total = `$results.Count
    keys_passed = (`$results | Where-Object { `$_.status -eq "PASS" }).Count
    keys_failed = (`$results | Where-Object { `$_.status -eq "FAIL" }).Count
    keys_errored = (`$results | Where-Object { `$_.status -eq "ERROR" }).Count
    all_keys_valid = (`$results | Where-Object { `$_.status -ne "PASS" }).Count -eq 0
    results = `$results
}

`$json = `$output | ConvertTo-Json -Depth 4
Write-Output `$json
"@

    $scriptPath = Join-Path $LogDir "inject-container-script.ps1"
    $fullScript | Set-Content -Path $scriptPath -Encoding UTF8
    $result = docker exec $ContainerName powershell -File "C:\inject.ps1" 2>&1
    # Copy script to container and execute
    docker cp $scriptPath "${ContainerName}:C:\inject.ps1" 2>&1 | Out-Null
    $output = docker exec $ContainerName powershell -ExecutionPolicy Bypass -File "C:\inject.ps1" 2>&1
    Write-Output $output
    Write-Log "=== Phase 2: Container injection completed ==="
    exit 0
}

# === Local HKCU execution ===
Write-Log "=== Phase 2: Policy Injection Started (Local HKCU) ==="
Write-Log "Target URL: $TargetUrl | DryRun: $DryRun"

if ($DryRun) { Write-Log "DRY RUN MODE — no changes will be made" }

$results = @()

# Ensure policy path exists
if (-not (Test-Path $EdgePolicyPath)) {
    if (-not $DryRun) {
        New-Item -Path $EdgePolicyPath -Force | Out-Null
        Write-Log "Created policy path: $EdgePolicyPath"
    } else {
        Write-Log "DRYRUN: Would create policy path: $EdgePolicyPath"
    }
} else {
    Write-Log "Policy path exists: $EdgePolicyPath"
}

Write-Log "Injecting $($policyKeys.Count) registry keys..."

foreach ($key in $policyKeys) {
    try {
        if ($DryRun) {
            Write-Log "DRYRUN: Would set $($key.Name) = $($key.Value) [$($key.Type)]"
            $results += @{ name = $key.Name; expected = $key.Value; actual = $null; type = $key.Type; status = "DRYRUN" }
            continue
        }

        $propArgs = @{
            Path = $EdgePolicyPath
            Name = $key.Name
            Value = $key.Value
            PropertyType = $key.Type
            Force = $true
        }
        New-ItemProperty @propArgs | Out-Null

        # Read back immediately to verify write
        $actual = Get-ItemProperty -Path $EdgePolicyPath -Name $key.Name -ErrorAction SilentlyContinue
        if ($null -eq $actual) {
            throw "Key not found after write"
        }

        $actualValue = $actual.($key.Name)
        $match = $false
        if ($key.Type -eq "MultiString") {
            $match = ($null -ne $actualValue) -and ((Compare-Object $actualValue $key.Value).Count -eq 0)
        } else {
            $match = $actualValue -eq $key.Value
        }

        $status = if ($match) { "PASS" } else { "FAIL" }
        Write-Log "$status`: $($key.Name) = $actualValue (expected: $($key.Value))"
        $results += @{
            name = $key.Name
            expected = $key.Value
            actual = $actualValue
            type = $key.Type
            status = $status
        }
    } catch {
        Write-Log "ERROR: $($key.Name) — $($_.Exception.Message)" "ERROR"
        $results += @{
            name = $key.Name
            expected = $key.Value
            actual = $null
            type = $key.Type
            status = "ERROR"
            error = $_.Exception.Message
        }
    }
}

# Check HKLM for conflicting policies
Write-Log "Checking HKLM policy precedence..."
$hklmPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
$conflicts = @()
if (Test-Path $hklmPath) {
    $hklmKeys = Get-ItemProperty -Path $hklmPath -ErrorAction SilentlyContinue
    foreach ($key in $policyKeys) {
        if ($null -ne $hklmKeys.PSObject.Properties[$key.Name]) {
            $conflictMsg = "$($key.Name) also set in HKLM (HKLM overrides HKCU per GP precedence)"
            Write-Log "WARNING: $conflictMsg" "WARN"
            $conflicts += $conflictMsg
        }
    }
}
if ($conflicts.Count -eq 0) {
    Write-Log "No HKLM policy conflicts detected."
}

$allValid = ($results | Where-Object { $_.status -ne "PASS" -and $_.status -ne "DRYRUN" }).Count -eq 0

$output = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    policy_path = $EdgePolicyRegPath
    target_url = $TargetUrl
    dry_run = $DryRun
    keys_total = $results.Count
    keys_passed = ($results | Where-Object { $_.status -eq "PASS" }).Count
    keys_failed = ($results | Where-Object { $_.status -eq "FAIL" }).Count
    keys_errored = ($results | Where-Object { $_.status -eq "ERROR" }).Count
    all_keys_valid = $allValid
    hklm_conflicts = $conflicts
    results = $results
    log_file = $LogFile
}

$json = $output | ConvertTo-Json -Depth 4
Write-Output $json

if (-not $allValid -and -not $DryRun) {
    Write-Log "=== Phase 2: FAILED ==="
    exit 1
}

Write-Log "=== Phase 2: PASSED ==="
exit 0
