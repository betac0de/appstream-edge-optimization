<#
.SYNOPSIS
    Pre-flight environment validation for AppStream Edge Optimization Pipeline.
.DESCRIPTION
    Validates that the execution environment meets all prerequisites:
    - Windows Server 2025 (Build >= 26100)
    - Docker running in Windows Containers mode
    - MSI URL reachable
    - Sufficient disk space
    - PowerShell version >= 5.1
    Outputs JSON with pass/fail status per check. Exit code 0 = all passed.
.PARAMETER MsiUrl
    URL of the Microsoft Edge Enterprise MSI to validate reachability.
    Default: Known Microsoft CDN URL.
.PARAMETER MinDiskGB
    Minimum free disk space in GB on C:\. Default: 20.
.EXAMPLE
    .\00-preflight.ps1
.EXAMPLE
    .\00-preflight.ps1 -MsiUrl "https://custom-cdn.example.com/Edge.msi" -MinDiskGB 30
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
    [string]$MsiUrl = "",
    [int]$MinDiskGB = 20
)

# Default MSI URL if not provided (param default with long strings breaks in some shells)
if (-not $MsiUrl) {
    $MsiUrl = "https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/a2861c8f-b98a-4412-a162-43f1d32152a5/MicrosoftEdgeEnterpriseX64.msi"
}

$LogDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir ("preflight-{0:yyyyMMdd-HHmmss}.log" -f [DateTime]::UtcNow)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$timestamp] [$Level] $Message"
    Write-Information $line -InformationAction Continue
    Add-Content -Path $LogFile -Value $line
}

function Test-Check {
    param([string]$Name, [scriptblock]$Test, [string]$PassMessage, [string]$FailMessage)
    try {
        $result = & $Test
        if ($result) {
            Write-Log "PASS: $Name — $PassMessage"
            return @{ name = $Name; passed = $true; message = $PassMessage }
        } else {
            Write-Log "FAIL: $Name — $FailMessage"
            return @{ name = $Name; passed = $false; message = $FailMessage; severity = "HIGH" }
        }
    } catch {
        Write-Log "FAIL: $Name — Exception: $($_.Exception.Message)"
        return @{ name = $Name; passed = $false; message = $_.Exception.Message; severity = "HIGH" }
    }
}

Write-Log "=== Phase 0: Pre-flight Checks Started ==="
Write-Log "MSI URL: $MsiUrl"
Write-Log "Minimum Disk GB: $MinDiskGB"

$results = @()

# Check 1: OS Version
$results += Test-Check -Name "OS Version" -Test {
    $os = [Environment]::OSVersion
    $build = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    Write-Log "OS: $($os.VersionString), Build: $build"
    [int]$build -ge 26100
} -PassMessage "Windows Server 2025 (Build $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber))" `
  -FailMessage "Requires Windows Server 2025 (Build >= 26100). Current build: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber)"

# Check 2: Docker Installed
$results += Test-Check -Name "Docker Installed" -Test {
    $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
} -PassMessage "Docker CLI available" `
  -FailMessage "Docker is not installed or not in PATH"

# Check 3: Docker Running
$results += Test-Check -Name "Docker Running" -Test {
    docker ps 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -PassMessage "Docker daemon is running" `
  -FailMessage "Docker daemon is not running. Start Docker Desktop."

# Check 4: Docker Windows Containers Mode
$results += Test-Check -Name "Docker Windows Containers Mode" -Test {
    $osType = docker info --format '{{.OSType}}' 2>&1
    Write-Log "Docker OSType: $osType"
    $osType -eq "windows"
} -PassMessage "Docker is in Windows Containers mode" `
  -FailMessage "Docker is in Linux container mode. Switch to Windows Containers: '& `"C:\Program Files\Docker\DockerCli.exe`" -SwitchDaemon'"

# Check 5: PowerShell Version
$results += Test-Check -Name "PowerShell Version" -Test {
    $PSVersionTable.PSVersion.Major -ge 5
} -PassMessage "PowerShell $($PSVersionTable.PSVersion)" `
  -FailMessage "Requires PowerShell 5.1 or later. Current: $($PSVersionTable.PSVersion)"

# Check 6: MSI URL Reachable
$results += Test-Check -Name "MSI URL Reachable" -Test {
    $response = Invoke-WebRequest -Uri $MsiUrl -Method Head -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
    Write-Log "MSI URL HTTP Status: $($response.StatusCode)"
    $response.StatusCode -eq 200
} -PassMessage "MSI URL returned HTTP 200" `
  -FailMessage "MSI URL is not reachable. Check network, proxy, or use -MsiUrl parameter."

# Check 7: Disk Space
$results += Test-Check -Name "Disk Space" -Test {
    $drive = Get-PSDrive C -ErrorAction Stop
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    Write-Log "Free disk space: ${freeGB}GB"
    $freeGB -ge $MinDiskGB
} -PassMessage "Free disk space: $([math]::Round((Get-PSDrive C).Free / 1GB, 1))GB >= ${MinDiskGB}GB" `
  -FailMessage "Insufficient disk space. Free: $([math]::Round((Get-PSDrive C).Free / 1GB, 1))GB, Required: ${MinDiskGB}GB"

# Check 8: Network Connectivity
$results += Test-Check -Name "Network Connectivity" -Test {
    Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet
} -PassMessage "Network connectivity confirmed" `
  -FailMessage "No network connectivity to 8.8.8.8"

$allPassed = ($results | Where-Object { -not $_.passed }).Count -eq 0

$output = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    all_passed = $allPassed
    checks_total = $results.Count
    checks_passed = ($results | Where-Object { $_.passed }).Count
    checks_failed = ($results | Where-Object { -not $_.passed }).Count
    results = $results
    log_file = $LogFile
}

$json = $output | ConvertTo-Json -Depth 3
Write-Output $json

if (-not $allPassed) {
    $failed = ($results | Where-Object { -not $_.passed } | ForEach-Object { $_.name }) -join ", "
    Write-Log "=== Phase 0: FAILED — $failed ==="
    exit 2
}

Write-Log "=== Phase 0: PASSED ==="
exit 0
