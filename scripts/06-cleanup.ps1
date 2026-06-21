<#
.SYNOPSIS
    Cleans up Docker container, MSI files, and optionally the servercore image.
.DESCRIPTION
    Stops and removes the AppStream Edge test container, cleans downloaded MSI
    files from the container and logs directory, and optionally prunes the
    Docker image and build cache.
.PARAMETER ContainerName
    Name of the container to remove. Default: appstream-edge-test.
.PARAMETER Full
    If set, also removes the Windows Server Core image and prunes Docker cache.
.PARAMETER ImageName
    Docker image to remove when -Full is set. Default: mcr.microsoft.com/windows/servercore:ltsc2025.
.EXAMPLE
    .\06-cleanup.ps1
.EXAMPLE
    .\06-cleanup.ps1 -Full
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

param(
    [string]$ContainerName = "appstream-edge-test",
    [switch]$Full,
    [string]$ImageName = "mcr.microsoft.com/windows/servercore:ltsc2025"
)

$LogDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir ("cleanup-{0:yyyyMMdd-HHmmss}.log" -f [DateTime]::UtcNow)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$timestamp] [$Level] $Message"
    Write-Information $line -InformationAction Continue
    Add-Content -Path $LogFile -Value $line
}

Write-Log "=== Cleanup Started ==="
Write-Log "Container: $ContainerName | Full: $Full"

$results = @()

# Step 1: Stop container
Write-Log "Step 1: Stopping container $ContainerName"
try {
    $running = docker inspect --format '{{.State.Running}}' $ContainerName 2>&1
    if ($running -eq "true") {
        docker stop $ContainerName 2>&1 | Out-Null
        Write-Log "Container stopped: $ContainerName"
        $results += @{ action = "stop_container"; status = "OK" }
    } else {
        Write-Log "Container not running or not found"
        $results += @{ action = "stop_container"; status = "SKIPPED"; reason = "Not running" }
    }
} catch {
    Write-Log "Container stop failed (may already be stopped): $($_.Exception.Message)" "WARN"
    $results += @{ action = "stop_container"; status = "WARN"; error = $_.Exception.Message }
}

# Step 2: Remove container
Write-Log "Step 2: Removing container $ContainerName"
try {
    $exists = docker ps -a --filter "name=$ContainerName" --format '{{.Names}}' 2>&1
    if ($exists -eq $ContainerName) {
        docker rm $ContainerName 2>&1 | Out-Null
        Write-Log "Container removed: $ContainerName"
        $results += @{ action = "remove_container"; status = "OK" }
    } else {
        Write-Log "Container does not exist"
        $results += @{ action = "remove_container"; status = "SKIPPED"; reason = "Not found" }
    }
} catch {
    Write-Log "Container removal failed: $($_.Exception.Message)" "WARN"
    $results += @{ action = "remove_container"; status = "WARN"; error = $_.Exception.Message }
}

# Step 3: Clean downloaded MSI files from logs dir
Write-Log "Step 3: Cleaning MSI/script artifacts from logs"
try {
    $tempFiles = Get-ChildItem -Path $LogDir -Filter "inject-container-script.ps1" -ErrorAction SilentlyContinue
    $tempFiles += Get-ChildItem -Path $LogDir -Filter "launch-container-script.ps1" -ErrorAction SilentlyContinue
    $tempFiles += Get-ChildItem -Path $LogDir -Filter "validate-container-script.ps1" -ErrorAction SilentlyContinue
    $count = 0
    foreach ($f in $tempFiles) {
        Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
        $count++
    }
    Write-Log "Removed $count temp script files from logs"
    $results += @{ action = "clean_logs"; status = "OK"; files_removed = $count }
} catch {
    Write-Log "Log cleanup failed: $($_.Exception.Message)" "WARN"
    $results += @{ action = "clean_logs"; status = "WARN" }
}

# Step 4: Docker system prune (optional)
if ($Full) {
    Write-Log "Step 4: Full cleanup — removing image $ImageName"
    try {
        $hasImage = docker images --format '{{.Repository}}:{{.Tag}}' 2>&1 | Select-String -Pattern [regex]::Escape($ImageName)
        if ($hasImage) {
            docker rmi $ImageName 2>&1 | Out-Null
            Write-Log "Image removed: $ImageName"
            $results += @{ action = "remove_image"; status = "OK" }
        } else {
            Write-Log "Image not found: $ImageName"
            $results += @{ action = "remove_image"; status = "SKIPPED"; reason = "Image not found" }
        }
    } catch {
        Write-Log "Image removal failed: $($_.Exception.Message)" "WARN"
        $results += @{ action = "remove_image"; status = "WARN"; error = $_.Exception.Message }
    }

    Write-Log "Step 5: Docker system prune"
    try {
        docker system prune -f 2>&1 | Out-Null
        Write-Log "Docker system pruned"
        $results += @{ action = "docker_prune"; status = "OK" }
    } catch {
        Write-Log "Docker prune failed: $($_.Exception.Message)" "WARN"
        $results += @{ action = "docker_prune"; status = "WARN" }
    }
} else {
    Write-Log "Skipping full cleanup (-Full not set). Use -Full to remove image and prune."
}

$output = @{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    container_name = $ContainerName
    full_cleanup = $Full
    results = $results
    log_file = $LogFile
}

$json = $output | ConvertTo-Json -Depth 3
Write-Output $json

Write-Log "=== Cleanup Completed ==="
exit 0
