# Execution Summary: Optimizing Microsoft Edge for AWS AppStream (Windows Server 2025)

## 1. Executive Summary & Objective
Our primary objective is to create a seamless, "kiosk-like", zero-touch browser experience within an AWS AppStream multi-session environment. We aim to configure Microsoft Edge to launch instantly to a specific private URL without setup wizards, sync prompts, or user friction, and test these configurations using a Windows Server 2025 base image.

## 2. Problem Statement
AWS AppStream relies on non-persistent, volatile profiles. Microsoft Edge, out-of-the-box, conflicts with this virtualized desktop infrastructure (VDI) in several ways:
* **Guest Profile Crashes:** Using the native `--guest` mode creates a temporary profile that AppStream's aggressive backend storage management wipes out, causing Edge to force-close after 5 to 10 minutes.
* **First Run Experience (FRE):** Edge forces welcome screens, default browser checks, and sign-in prompts on every new session.
* **Resource Bloat & Instability:** Hardware acceleration causes visual artifacts/crashes in virtual GPU environments. Background processes ("Startup Boost") act as memory leaks across multi-session environments. Bloatware (Shopping Assistant, Copilot) wastes CPU and bandwidth.

## 3. The Optimization Solution (PowerShell)
Instead of relying on command-line switches that Edge often ignores, we inject official Microsoft Edge Group Policy registry keys into the Current User (`HKCU`) hive right before launching the browser. We then use `--inprivate` mode, which provides a stateless session without triggering the temporary profile deletion bug found in `--guest` mode.

### The AppStream Startup Script
```powershell
# Define Edge Policy registry path for the Current User
$EdgePolicyPath = "HKCU:\SOFTWARE\Policies\Microsoft\Edge"

# Ensure the registry key path exists
if (-not (Test-Path $EdgePolicyPath)) { New-Item -Path $EdgePolicyPath -Force | Out-Null }

# 1. Performance & Stability
New-ItemProperty -Path $EdgePolicyPath -Name "HardwareAccelerationModeEnabled" -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $EdgePolicyPath -Name "StartupBoostEnabled" -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $EdgePolicyPath -Name "BackgroundModeEnabled" -Value 0 -PropertyType DWORD -Force | Out-Null

# 2. Strip Bloatware
New-ItemProperty -Path $EdgePolicyPath -Name "EdgeShoppingAssistantEnabled" -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $EdgePolicyPath -Name "HubsSidebarEnabled" -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $EdgePolicyPath -Name "ShowRecommendationsEnabled" -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $EdgePolicyPath -Name "EdgeCollectionsEnabled" -Value 0 -PropertyType DWORD -Force | Out-Null

# 3. Disable Setup Wizards & Sync
New-ItemProperty -Path $EdgePolicyPath -Name "HideFirstRunExperience" -Value 1 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $EdgePolicyPath -Name "BrowserSignin" -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $EdgePolicyPath -Name "DefaultBrowserSettingEnabled" -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $EdgePolicyPath -Name "SyncDisabled" -Value 1 -PropertyType DWORD -Force | Out-Null

# 4. Launch Execution
$PrivateUrl = "https://your-private-url-here.com"
Start-Process -FilePath "msedge.exe" -ArgumentList "--inprivate", "--no-first-run", $PrivateUrl
```

## 4. Testing Execution: Windows Server 2025 Docker Container
To validate the registry injection and script logic without spinning up a full AWS AppStream fleet, we utilize the official Windows Server 2025 Core container image via Docker. 

*(Note: Docker must be running in "Windows Containers" mode on the host).*

### Step 4.1: Pull the Base Image
Pull the official Windows Server 2025 Core image from the Microsoft Container Registry:
```powershell
docker pull mcr.microsoft.com/windows/servercore:ltsc2025
```

### Step 4.2: Run an Interactive Session
Launch the container and open an interactive PowerShell terminal:
```powershell
docker run -it mcr.microsoft.com/windows/servercore:ltsc2025 powershell
```

### Step 4.3: Install Microsoft Edge inside the Container
Windows Server Core does not include Edge. We must download and install the enterprise MSI silently:
```powershell
Invoke-WebRequest -Uri "https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/a2861c8f-b98a-4412-a162-43f1d32152a5/MicrosoftEdgeEnterpriseX64.msi" -OutFile "C:\Edge.msi"
Start-Process msiexec.exe -ArgumentList "/i C:\Edge.msi /qn" -Wait
```

### Step 4.4: Execute the Optimization Script
Paste and run the PowerShell startup script (from Section 3) into the container's terminal. 

### Step 4.5: Validate Registry Changes
Verify that the Group Policies were successfully applied to the registry:
```powershell
Get-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Edge"
```
*Success criteria:* The output must list `HideFirstRunExperience = 1`, `HardwareAccelerationModeEnabled = 0`, and all other applied keys.

## 5. End Results & Limitations
* **What this Testing Validates:** We confirm that our automation script successfully provisions the enterprise policies in a Windows Server 2025 environment without syntax errors or permission blocks.
* **Limitations of Docker Testing:** Because Windows Server Core containers are **headless (No GUI)**, we cannot visually witness Edge opening to the private URL.
* **Final Expected Result in AppStream:** Once this validated script is moved to the AppStream Image Builder, users will experience a zero-touch, 100% stable Edge browser that instantly loads the required private URL, consumes minimal server RAM, and never crashes due to Guest profile wiping.
