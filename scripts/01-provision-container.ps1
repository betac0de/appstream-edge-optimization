<#
.SYNOPSIS
    Provisions Windows Server 2025 Docker container with Microsoft Edge Enterprise.
.DESCRIPTION
    Pulls the official Windows Server 2025 Core image, starts a container,
    downloads and installs Microsoft Edge Enterprise MSI silently.
    All operations have 3-retry logic with exponential backoff.
.PARAMETER ContainerName
    Name for the Docker container. Default: appstream-edge-test.
.PARAMETER ImageName
    Docker image to pull. Default: mcr.microsoft.com/windows/servercore:ltsc2025.
.PARAMETER MsiUrl
    URL for Microsoft Edge Enterprise MSI. Default: Known Microsoft CDN URL.
.PARAMETER NoCache
    Force fresh image pull (bypass Docker layer cache).
.EXAMPLE
    .\01-provision-container.ps1
.EXAMPLE
    .\01-provision-container.ps1 -MsiUrl "https://custom-cdn.example.com/Edge.msi" -NoCache
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
    [string]$ContainerName = "appstream-edge-test",
    [string]$ImageName = "mcr.microsoft.com/windows/servercore:ltsc2025",
    [string]$MsiUrl = "",
    [switch]$NoCache
)

# Default MSI URL if not provided
if (-not $MsiUrl) {
    $MsiUrl = "https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/a2861c8f-b98a-4412-a162-43f1d32152a5/MicrosoftEdgeEnterpriseX64.msi"
}

$LogDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir ("provision-{0:yyyyMMdd-HHmmss}.log" -f [DateTime]::UtcNow)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$timestamp] [$Level] $Message"
    Write-Information $line -InformationAction Continue
    Add-Content -Path $LogFile -Value $line
}

function Invoke-Retry {
    param(
        [string]$OperationName,
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$BaseDelaySeconds = 10
    )
    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            Write-Log "$OperationName — Attempt $attempt/$MaxAttempts"
            $result = & $ScriptBlock
            Write-Log "$OperationName — Succeeded on attempt $attempt"
            return $result
        } catch {
            $delay = $BaseDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Log "$OperationName — Attempt $attempt failed: $($_.Exception.Message)" "WARN"
            if ($attempt -lt $MaxAttempts) {
                Write-Log "$OperationName — Retrying in ${delay}s..."
                Start-Sleep -Seconds $delay
            } else {
                throw "Operation '$OperationName' failed after $MaxAttempts attempts: $($_.Exception.Message)"
            }
        }
    }
}

Write-Log "=== Phase 1: Container Provisioning Started ==="
Write-Log "Container: $ContainerName | Image: $ImageName | MSI: $MsiUrl"

# Step 1: Clean up any existing container
Write-Log "Step 1: Cleaning up existing container (if any)"
$existing = docker ps -a --filter "name=$ContainerName" --format '{{.Names}}' 2>&1
if ($existing -eq $ContainerName) {
    docker rm -f $ContainerName 2>&1 | Out-Null
    Write-Log "Removed existing container: $ContainerName"
} else {
    Write-Log "No existing container named $ContainerName"
}

# Step 2: Pull image
Write-Log "Step 2: Pulling image $ImageName"
$pullArgs = @("pull")
if ($NoCache) { $pullArgs += "--no-cache" }
$pullArgs += $ImageName

Invoke-Retry -OperationName "Docker pull" -ScriptBlock {
    docker @pullArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker pull failed with exit code $LASTEXITCODE" }
} -MaxAttempts 3 -BaseDelaySeconds 30

# Step 3: Start container
Write-Log "Step 3: Starting container $ContainerName"
Invoke-Retry -OperationName "Docker run" -ScriptBlock {
    docker run -d --name $ContainerName $ImageName powershell -NoExit 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker run failed with exit code $LASTEXITCODE" }
} -MaxAttempts 3 -BaseDelaySeconds 10

# Step 4: Wait for container healthy
Write-Log "Step 4: Waiting for container health"
$maxWait = 60
$waited = 0
do {
    Start-Sleep -Seconds 2
    $waited += 2
    $running = docker inspect --format '{{.State.Running}}' $ContainerName 2>&1
    Write-Log "Container running: $running (waited ${waited}s)"
} while ($running -ne "true" -and $waited -lt $maxWait)

if ($running -ne "true") {
    throw "Container $ContainerName did not start within ${maxWait}s"
}
Write-Log "Container $ContainerName is running"

# Step 5: Download Edge MSI inside container
Write-Log "Step 5: Downloading Edge Enterprise MSI"
$msiContainerPath = "C:\Edge-{0:yyyyMMdd}.msi" -f [DateTime]::UtcNow

Invoke-Retry -OperationName "MSI Download" -ScriptBlock {
    $downloadCmd = "Invoke-WebRequest -Uri '$MsiUrl' -OutFile '$msiContainerPath' -UseBasicParsing"
    docker exec $ContainerName powershell -Command $downloadCmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "MSI download failed" }
} -MaxAttempts 3 -BaseDelaySeconds 15

# Verify MSI exists in container
$msiExists = docker exec $ContainerName powershell -Command "Test-Path '$msiContainerPath'" 2>&1
Write-Log "MSI exists in container: $msiExists"
if ($msiExists.Trim() -ne "True") {
    throw "MSI file not found in container at $msiContainerPath"
}

# Step 6: Install Edge silently
Write-Log "Step 6: Installing Microsoft Edge Enterprise"
Invoke-Retry -OperationName "MSI Install" -ScriptBlock {
    $installCmd = "Start-Process msiexec.exe -ArgumentList '/i `"$msiContainerPath`" /qn /norestart' -Wait -NoNewWindow; exit `$LASTEXITCODE"
    $result = docker exec $ContainerName powershell -Command $installCmd 2>&1
    Write-Log "MSI install output: $result"
} -MaxAttempts 3 -BaseDelaySeconds 20

# Step 7: Verify Edge binary exists
Write-Log "Step 7: Verifying Edge installation"
$edgePaths = @(
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
)

$edgeInstalled = $false
$edgeVersion = "unknown"
foreach ($edgePath in $edgePaths) {
    $exists = docker exec $ContainerName powershell -Command "Test-Path '$edgePath'" 2>&1
    if ($exists.Trim() -eq "True") {
        $edgeInstalled = $true
        $versionRaw = docker exec $ContainerName powershell -Command "(Get-Item '$edgePath').VersionInfo.ProductVersion" 2>&1
        $edgeVersion = $versionRaw.Trim()
        Write-Log "Edge found at: $edgePath (v$edgeVersion)"
        break
    }
}

if (-not $edgeInstalled) {
    throw "Microsoft Edge executable not found at any expected path"
}

$output = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    container_name = $ContainerName
    container_running = $true
    edge_installed = $true
    edge_version = $edgeVersion
    image = $ImageName
    msi_url = $MsiUrl
    log_file = $LogFile
}

$json = $output | ConvertTo-Json -Depth 3
Write-Output $json

Write-Log "=== Phase 1: PASSED ==="
exit 0
