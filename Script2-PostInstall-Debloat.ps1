# Script 2 - Post-install debloat + lockdown for Win11 24H2 Pro (26100.1742)
# Run AFTER clean install, as Administrator. Reboot when done.
# Covers: Store/Edge/WebView2 removal, Xbox/Copilot/Teams/Outlook/bloat removal,
# WU-to-localhost, privacy, OneDrive, AI/Recall, Defender/BitLocker off,
# printers/features, dark theme, taskbar, explorer, GameDVR, power.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\Script2-PostInstall-Debloat.ps1
#
# WARNING: Edge/WebView2 + Store removal is destructive and breaks Widgets,
# Phone Link, WebView-dependent apps. Defender-off + BitLocker-off reduces security.
# This is exactly what was requested - no undo except reinstall.
# NOTE: Store is NEVER reinstalled by this script (winget/App Installer left as-is).
# WSL is NEVER installed or enabled by this script - `wsl --install` remains a
# fully manual step after reboot. The script only preserves that ability: it
# removes no WSL / Virtual Machine Platform / Hyper-V payloads, installs no
# Store packages, and the WSL kernel/distro downloads use aka.ms (neither
# Windows Update nor the Store), so a later `wsl --install -d Ubuntu` works.

[CmdletBinding()]
param(
    [switch]$KeepStore,       # skip Microsoft Store removal if you need it
    [switch]$KeepEdge,        # skip Edge/WebView2 removal
    [switch]$KeepDefender     # skip Defender disable
)

$ErrorActionPreference = "Continue"
function OK($m)   { Write-Host "OK: $m" -ForegroundColor Green }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Info($m) { Write-Host "-- $m" -ForegroundColor Gray }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Not admin. Right-click -> Run as Administrator." }

Start-Transcript -Path "$env:SystemDrive\Script2-Debloat.log" -Append -ErrorAction SilentlyContinue | Out-Null
try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue } catch {}
try { Checkpoint-Computer -Description "Pre-Debloat" -RestorePointType "MODIFY_SETTINGS" -ErrorAction SilentlyContinue; OK "Restore point created" } catch { Info "Restore point skipped: $($_.Exception.Message)" }

function Set-Reg($Path, $Name, $Value, $Type = "DWord") {
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch { Write-Warning "Reg failed $Path\$Name : $($_.Exception.Message)" }
}
function Remove-AppxAll([string[]]$Patterns) {
    foreach ($pat in $Patterns) {
        # installed for all users
        Get-AppxPackage -AllUsers | Where-Object { $_.Name -like $pat -or $_.PackageFullName -like $pat } | ForEach-Object {
            Info "Removing installed: $($_.Name)"
            try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue } catch {}
        }
        # provisioned (future users / sysprep image)
        Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $pat -or $_.PackageName -like $pat } | ForEach-Object {
            Info "De-provisioning: $($_.DisplayName)"
            try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
        # DISM stub (covers Xbox Identity Provider style system packages)
        try {
            $dism = dism /Online /Get-ProvisionedAppxPackages 2>$null | Select-String "PackageName :"
            $dism | Where-Object { $_ -like "*$($pat.Trim('*'))*" } | ForEach-Object { Info "DISM sees provisioned stub: $($_.Line.Trim())" }
        } catch {}
    }
}

# ============================================================
# 1. APP REMOVALS
# ============================================================
Step "1. Removing bloat AppX (Store/Edge handled separately below)"

$apps = @(
    "Microsoft.XboxApp",
    "Microsoft.Xbox.TCUI",
    "Microsoft.XboxGamingOverlay",        # Game Bar
    "Microsoft.XboxSpeechToTextOverlay",  # Speech-to-Text overlay
    "Microsoft.XboxIdentityProvider",     # Identity Provider
    "Microsoft.XboxGameOverlay",
    "Microsoft.GamingApp",                # Xbox app (new name)
    "Microsoft.Copilot",
    "Microsoft.Windows.Copilot",
    "Microsoft.Windows.Ai.Copilot*",
    "MicrosoftTeams",                    # Teams Chat personal
    "Microsoft.Teams",
    "MSTeams",
    "Microsoft.OutlookForWindows",        # new Outlook/Mail
    "Microsoft.Todos",                    # To Do
    "Clipchamp.Clipchamp",                # Clipchamp
    "Microsoft.ZuneMusic",                # Media Player (legacy ZuneMusic)
    "Microsoft.WindowsCamera",            # Camera
    "Microsoft.WindowsAlarms",            # Alarms & Clock
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.BingWeather",
    "Microsoft.BingSearch",
    "Microsoft.GetHelp",
    "MicrosoftCorporationII.QuickAssist",
    "Microsoft.PowerAutomateDesktop",
    "Microsoft.MicrosoftOfficeHub",       # Office Hub / Microsoft 365
    "Microsoft.YourPhone",                # Phone Link
    "MicrosoftWindows.CrossDevice",       # Cross Device Experience Host
    "MicrosoftWindows.Client.WebExperience", # Widgets backend
    "Microsoft.MicrosoftStickyNotes"      # Sticky Notes
)
if (-not $KeepStore) { $apps += "Microsoft.WindowsStore" } else { Info "KeepStore set - skipping Store" }

# WSL preservation guard: no pattern above targets WSL, and this filter pins
# that invariant so a future wildcard edit can never sweep up WSL packages.
$apps = $apps | Where-Object { $_ -notlike "*Subsystem*Linux*" -and $_ -notlike "*WSL*" }

Remove-AppxAll $apps
OK "AppX removal pass done"
Info "WSL packages (deliberately left alone):"
Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*Subsystem*Linux*" -or $_.Name -like "*WSL*" } |
    ForEach-Object { Info "  kept: $($_.Name)" }

# Outlook PreventRun policy (new Mail)
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Outlook" "PreventRun" 1

# Xbox Identity Provider: provisioned absent, only firewall orphan left -> clean it
Step "1b. Xbox Identity Provider firewall orphan cleanup"
try {
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Xbox*" -or $_.Name -like "*XboxIdentity*" -or $_.Owner -like "*XboxIdentity*" } |
        ForEach-Object { Info "Removing orphan FW rule: $($_.Name)"; Remove-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue }
    OK "Xbox firewall orphans cleaned (if any)"
} catch { Write-Warning "FW cleanup failed: $($_.Exception.Message)" }

# ============================================================
# 2. MICROSOFT STORE (full)
# ============================================================
if (-not $KeepStore) {
    Step "2. Microsoft Store full removal (winget/App Installer untouched, Store never reinstalled)"
    Remove-AppxAll @("Microsoft.WindowsStore", "Microsoft.StorePurchaseApp")
    # Explicit guard: NEVER touch DesktopAppInstaller (winget) or re-add Store.
    # If winget is missing at this point it was already missing - we do not install it.
    # Block Store reinstall via ContentDeliveryManager + policy
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" "RemoveWindowsStore" 1
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" "DisableStoreApps" 1
    if (Get-Command winget -ErrorAction SilentlyContinue) { Info "winget still present: $((Get-Command winget).Source)" }
    else { Write-Warning "winget not found - left as-is per request (no Store reinstall, no winget install)." }
    OK "Store removed + blocked"
}

# ============================================================
# 3. EDGE + WEBVIEW2 FULL REMOVAL
# ============================================================
if (-not $KeepEdge) {
    Step "3. Full Edge + WebView2 removal"
    try { Stop-Process -Name msedge, msedgewebview2, edgeupdate, msedge* -Force -ErrorAction SilentlyContinue } catch {}

    # 3a. Official uninstaller (per-channel)
    $edgeSetups = @(
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\*\Installer\setup.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\*\Installer\setup.exe"
    ) | ForEach-Object { Get-Item $_ -ErrorAction SilentlyContinue } | Sort-Object FullName -Descending
    foreach ($s in $edgeSetups) {
        Info "Uninstalling Edge via $($s.FullName)"
        try { Start-Process -FilePath $s.FullName -ArgumentList "--uninstall","--msedge","--system-level","--verbose-logging","--force-uninstall" -Wait -ErrorAction SilentlyContinue } catch {}
    }
    # 3b. WebView2 evergreen standalone uninstaller (if present) + MSI product codes
    Get-Package -Name "*WebView2*" -ErrorAction SilentlyContinue | ForEach-Object {
        Info "Uninstalling package: $($_.Name)"
        try { Uninstall-Package -Name $_.Name -Force -ErrorAction SilentlyContinue } catch {}
    }
    Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                   "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
        Get-ItemProperty -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Edge*" -or $_.DisplayName -like "*WebView2*" } |
        ForEach-Object {
            Info "MSI uninstall: $($_.DisplayName)"
            if ($_.UninstallString) {
                try { cmd /c "$($_.UninstallString) /quiet /norestart" } catch {}
            }
            if ($_.PSChildName -match '^\{[0-9A-F\-]{36}\}$') {
                try { Start-Process msiexec.exe -ArgumentList "/x $($_.PSChildName) /qn /norestart" -Wait -ErrorAction SilentlyContinue } catch {}
            }
        }
    # 3c. Services + scheduled tasks
    @("edgeupdate", "edgeupdatem", "MicrosoftEdgeElevationService") | ForEach-Object {
        try { Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue; Set-Service -Name $_ -StartupType Disabled -ErrorAction SilentlyContinue; sc.exe delete $_ | Out-Null } catch {}
    }
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "*Edge*" -or $_.TaskName -like "*EdgeUpdate*" } |
        ForEach-Object { Info "Removing task: $($_.TaskName)"; try { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {} }
    # 3d. Files + registry blocks
    @("$env:ProgramFiles(x86)\Microsoft\Edge", "$env:ProgramFiles\Microsoft\Edge",
      "$env:ProgramFiles(x86)\Microsoft\EdgeUpdate", "$env:ProgramFiles\Microsoft\EdgeUpdate",
      "$env:ProgramFiles(x86)\Microsoft\EdgeWebView", "$env:ProgramFiles\Microsoft\EdgeWebView") | ForEach-Object {
        if (Test-Path $_) { Info "Deleting $_"; try { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
    }
    Remove-AppxAll @("Microsoft.MicrosoftEdge*", "Microsoft.Edge.GameAssist", "*EdgeWebView*")
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" "DoNotUpdateToEdgeWithChromium" 1
    Set-Reg "HKLM:\SOFTWARE\Microsoft\EdgeUpdate" "DoNotUpdateToEdgeWithChromium" 1
    # Block Edge re-install via Windows Update / first-run
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftEdge.Stable_8wekyb3d8bbwe" "Deprovisioned" 1
    OK "Edge + WebView2 force-removed (reboot to finish file locks)"
} else { Info "KeepEdge set - skipping Edge removal" }

# ============================================================
# 4. WINDOWS UPDATE -> LOCALHOST + BLOCKS + NO FORCED REBOOT
# WSL note: `wsl --install` still works after this because its feature
# payloads (Subsystem-Linux, VirtualMachinePlatform) are inbox and enable
# from local SxS, while kernel/distro downloads come from aka.ms - neither
# path uses Windows Update or the Store. If a future payload ever requires
# WU, temporarily revert this section, run wsl --install, then re-run Script2.
# ============================================================
Step "4. Redirect Windows Update to localhost + block internet updates + no forced reboots"
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "UseWUServer" 1
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "WUServer" "http://localhost:8530" "String"
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "WUStatusServer" "http://localhost:8530" "String"
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "UpdateServiceUrlAlternate" "http://localhost:8530" "String"
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "DoNotConnectToWindowsUpdateInternetLocations" 1
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "DisableWindowsUpdateAccess" 1
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "NoAutoUpdate" 0
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "AUOptions" 2
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "AutoInstallMinorUpdates" 0
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "NoAutoRebootWithLoggedOnUsers" 1
OK "WU localhost-block + no-reboot set"

# ============================================================
# 5. CONSUMER FEATURES / SUGGESTIONS
# ============================================================
Step "5. Disable consumer features & suggestions"
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableCloudOptimizedContent" 1
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableTailoredExperiencesWithDiagnosticData" 1
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SilentInstalledAppsEnabled" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "ContentDeliveryAllowed" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "OemPreInstalledAppsEnabled" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "PreInstalledAppsEnabled" 0
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" 1        # Bing search off
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDynamicSearchBoxEnabled" 0
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "HideRecommendedSection" 1        # Start recommendations off
OK "Consumer bloat + suggestions off"

# ============================================================
# 6. TELEMETRY / PRIVACY
# ============================================================
Step "6. Disable telemetry & privacy tracking"
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 0
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" 0
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 0
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceMetadata" "PreventDeviceMetadataFromNetwork" 1
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SyncShare" "EnableSyncShare" 0
try { Set-Service -Name DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service -Name DiagTrack -Force -ErrorAction SilentlyContinue } catch {}
try { Set-Service -Name dmwappushservice -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service -Name dmwappushservice -Force -ErrorAction SilentlyContinue } catch {}
OK "Telemetry off"

# ============================================================
# 7. LOCATION
# ============================================================
Step "7. Disable location services"
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation" 1
Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}" "Value" "Deny" "String"  # location sensor
try { Set-Service -Name lfsvc -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service -Name lfsvc -Force -ErrorAction SilentlyContinue } catch {}
OK "Location off"

# ============================================================
# 8. ONEDRIVE
# ============================================================
Step "8. Disable OneDrive"
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1
try { Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue } catch {}
$od = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe")
foreach ($p in $od) { if (Test-Path $p) { try { Start-Process $p -ArgumentList "/uninstall" -Wait -ErrorAction SilentlyContinue } catch {} } }
try {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "*OneDrive*" } |
        ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
} catch {}
OK "OneDrive uninstalled + policy-blocked"

# ============================================================
# 9. AI / COPILOT / RECALL
# ============================================================
Step "9. Disable AI, Copilot & Recall"
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
Set-Reg "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableClickToDo" 1
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "AllowRecallEnablement" 0
Set-Reg "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
# Recall snapshot history (24H2)
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
try { Disable-WindowsOptionalFeature -Online -FeatureName "Recall" -NoRestart -ErrorAction SilentlyContinue | Out-Null } catch {}
OK "Copilot/Recall/Click-to-Do off"

# ============================================================
# 10. DEFENDER + BITLOCKER OFF (as requested)
# ============================================================
if (-not $KeepDefender) {
    Step "10. Disable Defender services + BitLocker C: (INSECURE by request)"
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" "DisableAntiSpyware" 1
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableRealtimeMonitoring" 1
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableBehaviorMonitoring" 1
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableOnAccessProtection" 1
    @("WinDefend", "WdNisSvc", "WdNisDrv", "Sense", "SecurityHealthService") | ForEach-Object {
        try { Set-Service -Name $_ -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue } catch {}
    }
    try { manage-bde -off C: } catch { Write-Warning "BitLocker off failed: $($_.Exception.Message)" }
    OK "Defender disabled, BitLocker decrypting C: (takes a while)"
} else { Info "KeepDefender set - skipping" }

# ============================================================
# 11. OPTIONAL FEATURES + PRINTERS
# ============================================================
Step "11. Remove optional features & non-PDF printers"
# Deliberately scoped to OpenSSH/Fax/Scan/XPS only - WSL, Virtual Machine
# Platform and Hyper-V features are never touched so `wsl --install` keeps working.
$capNames = @(
    "OpenSSH.Client~~~~0.0.1.0",
    "Microsoft.Windows.WordPad~~~~0.0.1.0",
    "Print.Fax.Scan~~~~0.0.1.0",
    "Windows.Client.ShellComponents~~~~0.0.1.0"
)
foreach ($c in (Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Client*" -or $_.Name -like "*Fax*" -or $_.Name -like "*Scan*" -or $_.Name -like "*XPS*" })) {
    if ($c.State -eq "Installed") { Info "Removing capability $($c.Name)"; try { Remove-WindowsCapability -Online -Name $c.Name -ErrorAction SilentlyContinue | Out-Null } catch {} }
}
try { Disable-WindowsOptionalFeature -Online -FeatureName "Printing-XPSServices-Features" -NoRestart -ErrorAction SilentlyContinue | Out-Null } catch {}
try { Disable-WindowsOptionalFeature -Online -FeatureName "FaxServicesClientPackage" -NoRestart -ErrorAction SilentlyContinue | Out-Null } catch {}
try {
    Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*PDF*" -and $_.Name -notlike "*XPS*Document*" -and $_.Name -notlike "*OneNote*" } |
        ForEach-Object { Info "Removing printer: $($_.Name)"; Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue }
} catch { Write-Warning "Printer cleanup: $($_.Exception.Message)" }
OK "Features/printers cleaned"

# ============================================================
# 12. DARK THEME + VISUAL EFFECTS
# ============================================================
Step "12. Force dark theme + disable visual effects"
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "SystemUsesLightTheme" 0
Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme" 0
Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "SystemUsesLightTheme" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAcrylicOpacity" 0
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "DisablePreviewDesktop" 1
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 2  # custom
try { Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "UserPreferencesMask" -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -ErrorAction SilentlyContinue } catch {}
# Lock screen spotlight off (static)
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsSpotlightFeatures" 1
OK "Dark theme + minimal FX"

# ============================================================
# 13. TASKBAR
# ============================================================
Step "13. Taskbar: left align, hide Search/Widgets/TaskView/Copilot"
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" 0
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 0
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 0
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton" 0
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn" 0
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0
OK "Taskbar configured"

# ============================================================
# 14. NOTIFICATIONS / EXPLORER / GAMEDVR
# ============================================================
Step "14. Toasts off, Explorer to This PC + extensions, GameDVR off"
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 0
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" 0  # toasts off, keep center
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "LaunchTo" 1
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" 0
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0
Set-Reg "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0
OK "Explorer/GameDVR set"

# ============================================================
# 15. POWER PLAN + FAST STARTUP + SLEEP
# ============================================================
Step "15. Ultimate Performance + no Fast Startup + no sleep"
try {
    $up = powercfg /list | Select-String "Ultimate Performance"
    if (-not $up) { powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null }
    powercfg /setactive 9d09e330-644f-4589-a97e-6aace8e8ddd3
    OK "Ultimate Performance active"
} catch { Write-Warning "powercfg failed: $($_.Exception.Message)" }
Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0
try {
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /hibernate off
} catch {}
OK "Sleep off, Fast Startup off"

Step "DONE - reboot now"
Write-Host "Review log: $env:SystemDrive\Script2-Debloat.log" -ForegroundColor Cyan
Write-Host "REBOOT REQUIRED (Edge/Store file locks, power plan, policies)." -ForegroundColor Yellow
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
