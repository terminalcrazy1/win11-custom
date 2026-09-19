# Script 1 - Build Win11 24H2 Pro ORIGINAL RELEASE ISO via UUP Dump
# Target: Windows 11, version 24H2 (26100.1742) amd64 - original 2024-09-10 release
# Edition: Professional | Default lang: en-us
# Run on: Windows 10/11 x64 host with ~25 GB free, Admin required for ISO conversion phase.
#
# What it does:
#  1. Downloads the official UUP Dump package (uup_download_windows.cmd + files/)
#     for ID e1d5e11a-7054-49cf-b9c9-ba54258d5cc6 directly from uupdump.net
#  2. Extracts it and launches the download + convert (aria2 from MS servers -> wimlib ISO)
#  3. Copies resulting ISO to output dir with verified name.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\Script1-Build-Win11-24H2-ISO.ps1
#   powershell -ExecutionPolicy Bypass -File .\Script1-Build-Win11-24H2-ISO.ps1 -Lang en-us -OutDir C:\UUP-24H2 -Edition professional
#   powershell -ExecutionPolicy Bypass -File .\Script1-Build-Win11-24H2-ISO.ps1 -SkipConvert   # download only

[CmdletBinding()]
param(
    [string]$Lang = "en-us",
    [string]$Edition = "professional",
    [string]$OutDir = (Join-Path (Get-Location).Path "UUP-24H2-26100.1742"),
    [string]$BuildId = "e1d5e11a-7054-49cf-b9c9-ba54258d5cc6",
    [string]$BuildNumber = "26100.1742",
    [switch]$SkipConvert,
    [switch]$SkipElevationCheck
)

$ErrorActionPreference = "Stop"

function Write-Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function OK($m) { Write-Host "OK: $m" -ForegroundColor Green }
function Warn($m) { Write-Warning $m }

# --- 0. Admin check (converter needs admin for DISM/wimlib mount) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SkipConvert -and -not $SkipElevationCheck) {
    throw "Not admin. Right-click PowerShell -> Run as Administrator. Or re-run with -SkipElevationCheck (convert will fail without admin)."
}

# --- 1. Prep dirs ---
Write-Step "Prepare output dir: $OutDir"
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$zipPath = Join-Path $OutDir "uupdump-24H2-$BuildNumber-$Lang-$Edition.zip"
$workDir = Join-Path $OutDir "uup-package"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# --- 2. Build UUP Dump URL ---
# Verified ID for "Windows 11, version 24H2 (26100.1742) amd64" (added 2024-09-10):
#   https://uupdump.net/selectlang.php?id=e1d5e11a-7054-49cf-b9c9-ba54258d5cc6
$downloadUrl = "https://uupdump.net/get.php?id=$BuildId&pack=$Lang&edition=$Edition"
Write-Step "UUP Dump package URL"
Write-Host $downloadUrl
Write-Host "Build: $BuildNumber amd64 | Edition: $Edition | Lang: $Lang"

# --- 3. Download package ---
# NOTE: this endpoint requires POST. A plain GET returns the "List of files"
# HTML page (not a zip) - Expand-Archive then dies with "End of Central
# Directory record could not be found."
# autodl=2 = Windows package (uup_download_windows.cmd). No `updates` flag =
# base original-release build (no CU integration). No virtualEditions = Pro-only.
Write-Step "Downloading UUP Dump package"
$form = @{ autodl = "2" }
$retries = 3
for ($i = 1; $i -le $retries; $i++) {
    try {
        Invoke-WebRequest -Uri $downloadUrl -Method Post -Body $form -OutFile $zipPath -UseBasicParsing
        break
    } catch {
        Warn "Attempt $i/$retries failed: $($_.Exception.Message)"
        if ($i -eq $retries) { throw }
        Start-Sleep -Seconds 10
    }
}
# Validate: must be a ZIP (PK magic), not an HTML error/file-list page
$magic = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($zipPath)[0..3])
if (-not $magic.StartsWith("PK")) {
    $peek = [IO.File]::ReadAllText($zipPath)
    if ($peek.Length -gt 1500) { $peek = $peek.Substring(0, 1500) }
    $title = ([regex]::Match($peek, "<title>(.*?)</title>").Groups[1].Value)
    throw "UUP Dump did not return a zip (server page title: '$title'). Build may be pulled or rate-limited - retry later or pick the package manually via the download.php page."
}
$zipSize = (Get-Item $zipPath).Length
OK "Downloaded $([math]::Round($zipSize/1KB)) KB -> $zipPath"

# --- 4. Extract ---
Write-Step "Extracting package to $workDir"
Expand-Archive -LiteralPath $zipPath -DestinationPath $workDir -Force
OK "Extracted. Contents:"
Get-ChildItem $workDir | Format-Table Name, Length -AutoSize | Out-String | Write-Host

$cmdPath = Join-Path $workDir "uup_download_windows.cmd"
if (-not (Test-Path $cmdPath)) { throw "uup_download_windows.cmd not found in package. UUP Dump format changed - inspect $workDir manually." }

# --- 5. Sanity check ConvertConfig (force Pro-only, no extra editions) ---
$convertIni = Join-Path $workDir "ConvertConfig.ini"
if (Test-Path $convertIni) {
    Write-Host "ConvertConfig.ini found - leaving defaults (UUP package already scoped to $Edition)."
}

# --- 6. Free-space check ---
$drive = (Get-Item $OutDir).PSDrive.Name
$freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB, 1)
Write-Host "Free space on ${drive}: : $freeGB GB (need ~25 GB)"
if ($freeGB -lt 20) { Warn "Low disk space - download/convert will likely fail." }

# --- 7. Launch download + convert ---
if ($SkipConvert) {
    OK "SkipConvert set. Package ready at $workDir. Run uup_download_windows.cmd as Admin when ready."
    return
}

Write-Step "Launching UUP download + ISO build (this takes 30-90 min)"
Write-Host "Running: $cmdPath"
Write-Host "It downloads UUPs from Microsoft servers via aria2, then builds ISO with wimlib."
Write-Host "Do NOT close the new window. Log: $workDir\aria2_download.log"

# uup_download_windows.cmd self-elevates and pauses; run it synchronously so we can copy ISO after.
Push-Location $workDir
try {
    cmd /c uup_download_windows.cmd
    if ($LASTEXITCODE -ne 0) { Warn "uup_download_windows.cmd exited with code $LASTEXITCODE - check logs." }
} finally {
    Pop-Location
}

# --- 8. Find resulting ISO ---
Write-Step "Locating built ISO"
$isos = Get-ChildItem -Path $workDir -Filter *.iso -Recurse -ErrorAction SilentlyContinue | Sort-Object Length -Descending
if (-not $isos) {
    Warn "No ISO found in $workDir. Check aria2_download.log / errors above."
    Write-Host "Manual step: re-run $cmdPath as Admin."
    return
}
$iso = $isos[0]
OK "Built ISO: $($iso.FullName) ($([math]::Round($iso.Length/1GB,2)) GB)"

$finalIso = Join-Path $OutDir ("Win11-24H2-Original-26100.1742-Pro-" + $Lang + "-x64.iso")
Copy-Item -LiteralPath $iso.FullName -Destination $finalIso -Force
OK "Copied to: $finalIso"
Get-FileHash -Path $finalIso -Algorithm SHA256 | Format-List | Out-String | Write-Host

Write-Host "`nDONE. Burn with Rufus (GPT/UEFI, NTFS) or mount for in-place install." -ForegroundColor Cyan
Write-Host "Next: after install, run Script 2 (post-install debloat) as Admin." -ForegroundColor Cyan
