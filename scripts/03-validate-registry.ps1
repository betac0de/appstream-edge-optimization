<#
.SYNOPSIS
    Standalone registry validation — reads all expected Edge policy keys and compares.
.DESCRIPTION
    Validates that all 24 Microsoft Edge Group Policy registry keys exist at
    HKCU:\SOFTWARE\Policies\Microsoft\Edge with correct values and types.
    Can run independently of 02-inject-policies.ps1 for drift detection.
    Exit code 0 = all keys valid. Exit code 1 = one or more keys invalid/missing.
.PARAMETER TargetUrl
    The expected URL value for RestoreOnStartupURLs and NewTabPageLocation.
.PARAMETER ContainerName
    Docker container to validate inside. Leave empty for local host HKCU.
.EXAMPLE
    .\03-validate-registry.ps1 -TargetUrl "https://app.example.com"
.EXAMPLE
    .\03-validate-registry.ps1 -TargetUrl "https://app.example.com" -ContainerName "appstream-edge-test"
#>

#Requires -Version 5.1

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetUrl,
    [string]$ContainerName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LogDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir ("validate-{0:yyyyMMdd-HHmmss}.log" -f [DateTime]::UtcNow)

$EdgePolicyPath = "HKCU:\SOFTWARE\Policies\Microsoft\Edge"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$timestamp] [$Level] $Message"
    Write-Information $line -InformationAction Continue
    Add-Content -Path $LogFile -Value $line
}

# Expected key reference dictionary
$expected = @{
    "HardwareAccelerationModeEnabled"  = @{ Value = 0;         Type = "DWORD" }
    "StartupBoostEnabled"              = @{ Value = 0;         Type = "DWORD" }
    "BackgroundModeEnabled"            = @{ Value = 0;         Type = "DWORD" }
    "EdgeShoppingAssistantEnabled"     = @{ Value = 0;         Type = "DWORD" }
    "HubsSidebarEnabled"               = @{ Value = 0;         Type = "DWORD" }
    "ShowRecommendationsEnabled"       = @{ Value = 0;         Type = "DWORD" }
    "EdgeCollectionsEnabled"           = @{ Value = 0;         Type = "DWORD" }
    "EdgeCopilotEnabled"               = @{ Value = 0;         Type = "DWORD" }
    "HideFirstRunExperience"           = @{ Value = 1;         Type = "DWORD" }
    "BrowserSignin"                    = @{ Value = 0;         Type = "DWORD" }
    "DefaultBrowserSettingEnabled"     = @{ Value = 0;         Type = "DWORD" }
    "SyncDisabled"                     = @{ Value = 1;         Type = "DWORD" }
    "BrowserAddProfileEnabled"         = @{ Value = 0;         Type = "DWORD" }
    "RestoreOnStartup"                 = @{ Value = 4;         Type = "DWORD" }
    "RestoreOnStartupURLs"             = @{ Value = @($TargetUrl); Type = "MultiString" }
    "NewTabPageLocation"               = @{ Value = $TargetUrl; Type = "String" }
    "PasswordManagerEnabled"           = @{ Value = 0;         Type = "DWORD" }
    "AutofillAddressEnabled"           = @{ Value = 0;         Type = "DWORD" }
    "AutofillCreditCardEnabled"        = @{ Value = 0;         Type = "DWORD" }
    "ExtensionInstallBlocklist"        = @{ Value = @("*");    Type = "MultiString" }
    "MetricsReportingEnabled"          = @{ Value = 0;         Type = "DWORD" }
    "SiteSafetyServicesEnabled"        = @{ Value = 0;         Type = "DWORD" }
}

if ($ContainerName) {
    Write-Log "Container mode: validating inside $ContainerName"

    $expectedJson = $expected | ConvertTo-Json -Depth 4 -Compress
    $escapedJson = $expectedJson -replace '"', '\"'

    $validationScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$EdgePolicyPath = '$EdgePolicyPath'
`$TargetUrl = '$TargetUrl'

`$expected = @{}
$(
    foreach ($key in $expected.Keys) {
        $val = $expected[$key].Value
        $valStr = if ($val -is [array]) {
            "@('$($val -join "','")')"
        } elseif ($val -is [string]) {
            "'$val'"
        } else {
            $val
        }
        "`$expected['$key'] = @{ Value = $valStr; Type = '$($expected[$key].Type)' }"
    }
)

`$results = @()

if (-not (Test-Path `$EdgePolicyPath)) {
    foreach (`$key in `$expected.Keys) {
        `$results += @{
            name = `$key
            expected_type = `$expected[`$key].Type
            expected_value = `$expected[`$key].Value
            actual_type = "MISSING"
            actual_value = `$null
            status = "MISSING"
        }
    }
    `$output = @{ all_keys_valid = `$false; keys_total = `$results.Count; keys_passed = 0; results = `$results }
    Write-Output (`$output | ConvertTo-Json -Depth 4)
    exit 1
}

foreach (`$key in `$expected.Keys) {
    try {
        `$prop = Get-ItemProperty -Path `$EdgePolicyPath -Name `$key -ErrorAction Stop
        `$actualValue = `$prop.`$key

        `$expectedValue = `$expected[`$key].Value
        `$expectedType = `$expected[`$key].Type

        # Determine actual type
        if (`$actualValue -is [array] -and `$actualValue.Count -gt 1) {
            `$actualType = "MultiString"
        } elseif (`$actualValue -is [string]) {
            `$actualType = "String"
        } elseif (`$actualValue -is [int] -or `$actualValue -is [long]) {
            `$actualType = "DWORD"
        } else {
            `$actualType = `$actualValue.GetType().Name
        }

        `$typeMatch = `$actualType -eq `$expectedType
        `$valueMatch = `$false
        if (`$expectedType -eq "MultiString") {
            `$diff = Compare-Object @(`$actualValue) @(`$expectedValue)
            `$valueMatch = (`$null -eq `$diff) -or (`$diff.Count -eq 0)
        } else {
            `$valueMatch = `$actualValue -eq `$expectedValue
        }

        `$status = if (`$typeMatch -and `$valueMatch) { "PASS" } elseif (-not `$typeMatch) { "TYPE_MISMATCH" } else { "VALUE_MISMATCH" }

        `$results += @{
            name = `$key
            expected_type = `$expectedType
            expected_value = `$expectedValue
            actual_type = `$actualType
            actual_value = `$actualValue
            status = `$status
        }
    } catch [System.Management.Automation.PropertyNotFoundException] {
        `$results += @{
            name = `$key
            expected_type = `$expected[`$key].Type
            expected_value = `$expected[`$key].Value
            actual_type = "MISSING"
            actual_value = `$null
            status = "MISSING"
        }
    } catch {
        `$results += @{
            name = `$key
            expected_type = `$expected[`$key].Type
            expected_value = `$expected[`$key].Value
            actual_type = "ERROR"
            actual_value = `$null
            status = "ERROR"
            error = `$_.Exception.Message
        }
    }
}

`$allValid = (`$results | Where-Object { `$_.status -ne "PASS" }).Count -eq 0

`$output = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    all_keys_valid = `$allValid
    keys_total = `$results.Count
    keys_passed = (`$results | Where-Object { `$_.status -eq "PASS" }).Count
    keys_type_mismatch = (`$results | Where-Object { `$_.status -eq "TYPE_MISMATCH" }).Count
    keys_value_mismatch = (`$results | Where-Object { `$_.status -eq "VALUE_MISMATCH" }).Count
    keys_missing = (`$results | Where-Object { `$_.status -eq "MISSING" }).Count
    keys_errored = (`$results | Where-Object { `$_.status -eq "ERROR" }).Count
    results = `$results
}

Write-Output (`$output | ConvertTo-Json -Depth 4)
exit if (`$allValid) { 0 } else { 1 }
"@

    $scriptPath = Join-Path $LogDir "validate-container-script.ps1"
    $validationScript | Set-Content -Path $scriptPath -Encoding UTF8
    docker cp $scriptPath "${ContainerName}:C:\validate.ps1" 2>&1 | Out-Null
    $output = docker exec $ContainerName powershell -ExecutionPolicy Bypass -File "C:\validate.ps1" 2>&1
    Write-Output $output
    Write-Log "=== Phase 2 Validate: Container validation completed (exit: $LASTEXITCODE) ==="
    exit $LASTEXITCODE
}

# === Local HKCU execution ===
Write-Log "=== Phase 2 Validate: Registry Validation Started ==="
Write-Log "Target URL: $TargetUrl"

$results = @()

if (-not (Test-Path $EdgePolicyPath)) {
    Write-Log "Policy path does not exist: $EdgePolicyPath" "ERROR"
    foreach ($key in $expected.Keys) {
        $results += @{
            name = $key
            expected_type = $expected[$key].Type
            expected_value = $expected[$key].Value
            actual_type = "MISSING"
            actual_value = $null
            status = "MISSING"
        }
    }
    $output = @{
        timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        all_keys_valid = $false
        keys_total = $results.Count
        keys_passed = 0
        keys_missing = $results.Count
        results = $results
    }
    Write-Output ($output | ConvertTo-Json -Depth 4)
    exit 1
}

foreach ($key in $expected.Keys) {
    try {
        $prop = Get-ItemProperty -Path $EdgePolicyPath -Name $key -ErrorAction Stop
        $actualValue = $prop.$key

        $expectedValue = $expected[$key].Value
        $expectedType = $expected[$key].Type

        # Determine actual type
        if ($actualValue -is [array] -and $actualValue.Count -gt 1) {
            $actualType = "MultiString"
        } elseif ($actualValue -is [string]) {
            $actualType = "String"
        } elseif ($actualValue -is [int] -or $actualValue -is [long]) {
            $actualType = "DWORD"
        } else {
            $actualType = $actualValue.GetType().Name
        }

        $typeMatch = $actualType -eq $expectedType
        $valueMatch = $false
        if ($expectedType -eq "MultiString") {
            $diff = Compare-Object @($actualValue) @($expectedValue)
            $valueMatch = ($null -eq $diff) -or ($diff.Count -eq 0)
        } else {
            $valueMatch = $actualValue -eq $expectedValue
        }

        if ($typeMatch -and $valueMatch) {
            $status = "PASS"
            Write-Log "PASS: $key = $actualValue [$actualType]"
        } elseif (-not $typeMatch) {
            $status = "TYPE_MISMATCH"
            Write-Log "TYPE_MISMATCH: $key — expected $expectedType, got $actualType" "WARN"
        } else {
            $status = "VALUE_MISMATCH"
            Write-Log "VALUE_MISMATCH: $key — expected $expectedValue, got $actualValue" "WARN"
        }

        $results += @{
            name = $key
            expected_type = $expectedType
            expected_value = $expectedValue
            actual_type = $actualType
            actual_value = $actualValue
            status = $status
        }
    } catch [System.Management.Automation.PropertyNotFoundException] {
        Write-Log "MISSING: $key" "WARN"
        $results += @{
            name = $key
            expected_type = $expected[$key].Type
            expected_value = $expected[$key].Value
            actual_type = "MISSING"
            actual_value = $null
            status = "MISSING"
        }
    } catch {
        Write-Log "ERROR: $key — $($_.Exception.Message)" "ERROR"
        $results += @{
            name = $key
            expected_type = $expected[$key].Type
            expected_value = $expected[$key].Value
            actual_type = "ERROR"
            actual_value = $null
            status = "ERROR"
            error = $_.Exception.Message
        }
    }
}

$allValid = ($results | Where-Object { $_.status -ne "PASS" }).Count -eq 0

$output = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    all_keys_valid = $allValid
    keys_total = $results.Count
    keys_passed = ($results | Where-Object { $_.status -eq "PASS" }).Count
    keys_type_mismatch = ($results | Where-Object { $_.status -eq "TYPE_MISMATCH" }).Count
    keys_value_mismatch = ($results | Where-Object { $_.status -eq "VALUE_MISMATCH" }).Count
    keys_missing = ($results | Where-Object { $_.status -eq "MISSING" }).Count
    keys_errored = ($results | Where-Object { $_.status -eq "ERROR" }).Count
    results = $results
    log_file = $LogFile
}

$json = $output | ConvertTo-Json -Depth 4
Write-Output $json

if (-not $allValid) {
    Write-Log "=== Phase 2 Validate: FAILED — $($output.keys_type_mismatch + $output.keys_value_mismatch + $output.keys_missing) issues ==="
    exit 1
}

Write-Log "=== Phase 2 Validate: PASSED — all $($output.keys_passed) keys valid ==="
exit 0
