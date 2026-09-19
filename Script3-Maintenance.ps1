# Script 3 - Maintenance toggle for the Script2 Windows Update lockdown.
# Run as Administrator on the Script2-treated machine.
#
# Script2 section 4 points Windows Update at localhost and blocks internet
# update traffic. That breaks anything that downloads payloads on demand:
# Add-WindowsCapability / Features on Demand, Hyper-V or WSL feature payloads
# not present locally, etc. This script toggles that block WITHOUT touching
# the Store (which stays removed).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\Script3-Maintenance.ps1 -Status      # report (default)
#   powershell -ExecutionPolicy Bypass -File .\Script3-Maintenance.ps1 -UnblockWU   # allow downloads, then install your capability
#   powershell -ExecutionPolicy Bypass -File .\Script3-Maintenance.ps1 -ReblockWU   # restore the exact Script2 lockdown
#
# Typical flow: -UnblockWU -> Add-WindowsCapability ... -> -ReblockWU -> reboot.

[CmdletBinding(DefaultParameterSetName = "Status")]
param(
    [Parameter(ParameterSetName = "Unblock", Mandatory = $true)][switch]$UnblockWU,
    [Parameter(ParameterSetName = "Reblock", Mandatory = $true)][switch]$ReblockWU,
    [Parameter(ParameterSetName = "Status")][switch]$Status
)

$ErrorActionPreference = "Stop"
function OK($m)   { Write-Host "OK: $m" -ForegroundColor Green }
function Info($m) { Write-Host "-- $m" -ForegroundColor Gray }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Not admin. Right-click -> Run as Administrator." }

$auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
$wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

function Set-Reg($Path, $Name, $Value, $Type = "DWord") {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Get-Reg($Path, $Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}
function Restart-WUStack {
    foreach ($s in @("wuauserv", "BITS")) {
        try { Restart-Service -Name $s -ErrorAction SilentlyContinue; Info "$s restarted" } catch {}
    }
}

# Exact Script2 section 4 values - single source of truth for re-blocking.
$script:BlockValues = @{
    AU = @{
        UseWUServer               = @{ Value = 1; Type = "DWord" }
        WUServer                  = @{ Value = "http://localhost:8530"; Type = "String" }
        WUStatusServer            = @{ Value = "http://localhost:8530"; Type = "String" }
        UpdateServiceUrlAlternate = @{ Value = "http://localhost:8530"; Type = "String" }
        NoAutoUpdate              = @{ Value = 0; Type = "DWord" }
        AUOptions                 = @{ Value = 2; Type = "DWord" }
        AutoInstallMinorUpdates   = @{ Value = 0; Type = "DWord" }
        NoAutoRebootWithLoggedOnUsers = @{ Value = 1; Type = "DWord" }
    }
    WU = @{
        DoNotConnectToWindowsUpdateInternetLocations = @{ Value = 1; Type = "DWord" }
        DisableWindowsUpdateAccess                   = @{ Value = 1; Type = "DWord" }
    }
}

if ($UnblockWU) {
    Write-Host "`n=== Unblocking Windows Update (Script2 lockdown off) ===" -ForegroundColor Cyan
    foreach ($n in @("WUServer", "WUStatusServer", "UpdateServiceUrlAlternate")) {
        try { Remove-ItemProperty -Path $auPath -Name $n -ErrorAction SilentlyContinue; Info "removed AU\$n" } catch {}
    }
    Set-Reg $auPath "UseWUServer" 0
    Set-Reg $wuPath "DoNotConnectToWindowsUpdateInternetLocations" 0
    Set-Reg $wuPath "DisableWindowsUpdateAccess" 0
    # NoAutoRebootWithLoggedOnUsers is deliberately KEPT so an unblocked
    # update download can never force a reboot while you are logged in.
    Restart-WUStack
    OK "WU unblocked. Install what you need (e.g. Add-WindowsCapability), then re-run with -ReblockWU."
    return
}

if ($ReblockWU) {
    Write-Host "`n=== Restoring Script2 Windows Update lockdown ===" -ForegroundColor Cyan
    foreach ($n in $script:BlockValues.AU.Keys) {
        Set-Reg $auPath $n $script:BlockValues.AU[$n].Value $script:BlockValues.AU[$n].Type
    }
    foreach ($n in $script:BlockValues.WU.Keys) {
        Set-Reg $wuPath $n $script:BlockValues.WU[$n].Value $script:BlockValues.WU[$n].Type
    }
    Restart-WUStack
    OK "Lockdown restored (localhost WUServer, internet updates blocked, no forced reboot)."
    return
}

# --- Status (default) ---
Write-Host "`n=== Windows Update lockdown status ===" -ForegroundColor Cyan
$blocked = $true
foreach ($n in @("WUServer", "WUStatusServer", "UpdateServiceUrlAlternate")) {
    $v = Get-Reg $auPath $n
    Write-Host ("AU\{0} = {1}" -f $n, $(if ($null -eq $v) { "(absent)" } else { $v }))
    if ($v -ne "http://localhost:8530") { $blocked = $false }
}
foreach ($n in @("UseWUServer")) {
    $v = Get-Reg $auPath $n
    Write-Host ("AU\{0} = {1}" -f $n, $(if ($null -eq $v) { "(absent)" } else { $v }))
    if ($v -ne 1) { $blocked = $false }
}
foreach ($n in @("DoNotConnectToWindowsUpdateInternetLocations", "DisableWindowsUpdateAccess")) {
    $v = Get-Reg $wuPath $n
    Write-Host ("WU\{0} = {1}" -f $n, $(if ($null -eq $v) { "(absent)" } else { $v }))
    if ($v -ne 1) { $blocked = $false }
}
if ($blocked) { Write-Host "STATE: BLOCKED (Script2 lockdown active)" -ForegroundColor Yellow }
else { Write-Host "STATE: UNBLOCKED (downloads allowed)" -ForegroundColor Green }
