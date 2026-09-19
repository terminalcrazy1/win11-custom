# Win11 24H2 Pro (26100.1742) — UUP ISO + Post-Install Debloat

Original-release Windows 11 24H2 Pro workflow: build the ISO via UUP Dump, then debloat after install.

## Contents

- `Script1-Build-Win11-24H2-ISO.ps1` — downloads the official UUP Dump package for
  `26100.1742 amd64` (`e1d5e11a-7054-49cf-b9c9-ba54258d5cc6`, Pro, default `en-us`)
  and builds the ISO. Run as Admin on Win10/11 with ~25 GB free.
- `Script2-PostInstall-Debloat.ps1` — run after clean install as Admin. Removes Store,
  Edge + WebView2, Xbox, Copilot, Teams, new Outlook, bloat AppX, then applies
  WU-to-localhost, privacy, OneDrive, AI/Recall, Defender/BitLocker-off,
  dark theme, taskbar, Explorer, GameDVR, power tweaks. Reboot after.
  Installs nothing; `wsl --install` stays a manual step and keeps working.
- `Script3-Maintenance.ps1` — Admin toggle for the Script2 WU lockdown:
  `-Status` (default), `-UnblockWU` (allow capability/FoD downloads),
  `-ReblockWU` (restore exact Script2 values). No Store changes.
- `Script4-Install-Apps.ps1` — Admin app installer, no Store needed:
  Firefox, Git, Discord, Spotify, Steam, Intel DSA via winget community
  source; NVIDIA App + HyperX NGENUITY via vendor direct downloads;
  aw-screentime-tagger via git clone + its installer.

## Quick start

```powershell
# 1. Build ISO
powershell -ExecutionPolicy Bypass -File .\Script1-Build-Win11-24H2-ISO.ps1
# with options: -Lang en-us -Edition professional -OutDir C:\UUP-24H2

# Burn with Rufus (GPT/UEFI), install, then:

# 2. Debloat (Admin)
powershell -ExecutionPolicy Bypass -File .\Script2-PostInstall-Debloat.ps1
# keep bits: -KeepStore -KeepEdge -KeepDefender

# 3. Reboot, then WSL manually + apps (Admin)
wsl --install -d Ubuntu
powershell -ExecutionPolicy Bypass -File .\Script4-Install-Apps.ps1

# Anytime: toggle the WU lockdown for on-demand features (Admin)
powershell -ExecutionPolicy Bypass -File .\Script3-Maintenance.ps1 -UnblockWU
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
powershell -ExecutionPolicy Bypass -File .\Script3-Maintenance.ps1 -ReblockWU
```

## WSL / winget

- Script2 installs neither WSL nor the Store. After reboot, install WSL
  manually: `wsl --install -d Ubuntu`. The script removes no WSL /
  Virtual Machine Platform payloads, and kernel/distro downloads come from
  aka.ms, so install works with no Store and no Windows Update.
- winget (`Microsoft.DesktopAppInstaller`) is left exactly as found.

See the header comments in each script for full details and warnings
(Edge/Store removal is destructive; Defender-off reduces security — as requested).
