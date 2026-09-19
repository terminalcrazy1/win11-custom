# Script 4 - Install everyday apps on the Script2-treated machine.
# Run as Administrator AFTER Script2 + reboot. No Store needed: everything
# comes from winget's community source (pinned via --source winget), vendor
# direct downloads, or your own GitHub repo.
#
# Installs: Firefox (first - Intel DSA opens a browser tab), Git (needed for
# the tagger clone), Discord, Spotify, Steam, Intel Driver & Support Assistant,
# NVIDIA App (direct download - NOT in winget), HyperX NGENUITY (direct EXE -
# Store version unusable with Store removed), aw-screentime-tagger (git clone
# + run its installer).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\Script4-Install-Apps.ps1
#   powershell -ExecutionPolicy Bypass -File .\Script4-Install-Apps.ps1 -Interactive   # click through NVIDIA/HyperX setup manually
#
# If a vendor URL 404s (they version their links), grab the fresh one from
# nvidia.com/en-us/software/nvidia-app / hyperx.com/pages/ngenuity and pass:
#   .\Script4-Install-Apps.ps1 -NvidiaAppUrl <url> -HyperXUrl <url>

[CmdletBinding()]
param(
    [string]$NvidiaAppUrl = "https://us.download.nvidia.com/nvapp/client/11.0.8.299/NVIDIA_app_v11.0.8.299.exe",
    [string]$HyperXUrl = "https://files.hyperx.com/software-installers/Ngenuity_Installer/HyperX_NGENUITY_Installer_2.35.0.0.exe",
    [string]$TaggerRepo = "https://github.com/terminalcrazy1/aw-screentime-tagger.git",
    [string]$TaggerDir = "C:\Tools\aw-screentime-tagger",
    [string]$TaggerInstaller = "",   # auto-detect if empty (install.ps1 > setup.ps1 > install/setup .bat/.cmd > setup.py)
    [string]$DownloadDir = (Join-Path $env:TEMP "Script4-Downloads"),
    [switch]$Interactive
)

$ErrorActionPreference = "Continue"
function OK($m)   { Write-Host "OK: $m" -ForegroundColor Green }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Info($m) { Write-Host "-- $m" -ForegroundColor Gray }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Not admin. Right-click -> Run as Administrator." }

Start-Transcript -Path "C:\Script4-Apps.log" -Append -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget not found. It ships as Microsoft.DesktopAppInstaller (left in place by Script2) - repair App Installer first; there is no Store to reinstall it from."
}

function Install-Winget($Id, $Name) {
    $listed = winget list --id $Id -e --source winget 2>$null | Select-String $Id
    if ($listed) { Info "$Name already installed - skipping"; return }
    Info "Installing $Name ($Id)..."
    winget install --id $Id -e --source winget --silent `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) { OK "$Name installed" }
    else { Write-Warning "$Name failed (exit $LASTEXITCODE)" }
}

function Get-File($Url, $OutFile) {
    Info "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    OK "Saved $([math]::Round((Get-Item $OutFile).Length / 1MB, 1)) MB -> $OutFile"
}

# --- 1. winget packages (community source only - msstore source is dead by design) ---
Step "1. winget packages"
Install-Winget "Mozilla.Firefox" "Firefox"                        # first: Intel DSA opens a browser tab
Install-Winget "Git.Git" "Git"                                    # needed for the tagger clone below
Install-Winget "Discord.Discord" "Discord"
Install-Winget "Spotify.Spotify" "Spotify"
Install-Winget "Valve.Steam" "Steam"
Install-Winget "Intel.IntelDriverAndSupportAssistant" "Intel DSA"

# --- 2. NVIDIA App (direct download: blocked from winget upstream on hardware validation) ---
Step "2. NVIDIA App"
$hasNvidia = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*NVIDIA*" }
if (-not $hasNvidia) { Write-Warning "No NVIDIA GPU detected - skipping NVIDIA App." }
else {
    $nvExe = Join-Path $DownloadDir "NVIDIA_app_setup.exe"
    try {
        Get-File $NvidiaAppUrl $nvExe
        if ($Interactive) { Start-Process -FilePath $nvExe -Wait }
        else { Start-Process -FilePath $nvExe -ArgumentList "-s" -Wait }  # NVIDIA silent flag
        OK "NVIDIA App installer finished (exit $LASTEXITCODE)"
    } catch { Write-Warning "NVIDIA App failed: $($_.Exception.Message). URL may have rotted - pass a fresh -NvidiaAppUrl." }
}

# --- 3. HyperX NGENUITY (direct EXE: Store-distributed, Store is gone) ---
Step "3. HyperX NGENUITY"
$hxExe = Join-Path $DownloadDir "HyperX_NGENUITY_Installer.exe"
try {
    Get-File $HyperXUrl $hxExe
    if ($Interactive) { Start-Process -FilePath $hxExe -Wait }
    else { Start-Process -FilePath $hxExe -ArgumentList "/SILENT" -Wait }
    OK "HyperX NGENUITY installer finished. Restart recommended for USB driver registration."
} catch { Write-Warning "HyperX failed: $($_.Exception.Message). Pass a fresh -HyperXUrl from hyperx.com/pages/ngenuity." }

# --- 4. aw-screentime-tagger (clone + run its installer) ---
Step "4. aw-screentime-tagger"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git not found even after install step - cannot clone tagger." }
if ((Test-Path (Join-Path $TaggerDir ".git")) -and -not $Interactive) {
    Info "Updating existing clone..."
    git -C $TaggerDir pull --ff-only
} elseif (-not (Test-Path $TaggerDir)) {
    git clone $TaggerRepo $TaggerDir
} else { Info "Tagger dir exists without .git - using as-is: $TaggerDir" }
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) { Write-Warning "git operation exited $LASTEXITCODE - continuing with local copy if present." }

$installer = $TaggerInstaller
if (-not $installer) {
    foreach ($cand in @("install.ps1", "setup.ps1", "install.cmd", "install.bat", "setup.cmd", "setup.bat", "setup.py")) {
        if (Test-Path (Join-Path $TaggerDir $cand)) { $installer = $cand; break }
    }
}
if (-not $installer) {
    Write-Warning "No installer found in $TaggerDir. Contents:"
    Get-ChildItem $TaggerDir | Format-Table Name -AutoSize | Out-String | Write-Host
    throw "Cannot install tagger - pass -TaggerInstaller <filename>."
}
Info "Running tagger installer: $installer"
Push-Location $TaggerDir
try {
    switch -Wildcard ($installer) {
        "*.ps1" { powershell -NoProfile -ExecutionPolicy Bypass -File $installer }
        "*.cmd" { cmd /c $installer }
        "*.bat" { cmd /c $installer }
        "*.py"  {
            if (Get-Command py -ErrorAction SilentlyContinue) { py $installer }
            elseif (Get-Command python -ErrorAction SilentlyContinue) { python $installer }
            else { throw "setup.py found but no Python on PATH." }
        }
        default { throw "Unknown installer type: $installer" }
    }
    OK "aw-screentime-tagger installer finished"
} finally { Pop-Location }

Step "DONE"
Write-Host "Log: C:\Script4-Apps.log" -ForegroundColor Cyan
Write-Host "Reboot if NVIDIA/HyperX prompt for it." -ForegroundColor Yellow
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
