# WinPE Secure Boot Remediation Package

This folder contains WinPE startup and remediation scripts for applying Secure Boot variable updates and verifying resulting state.

## Contents

- `StartNet.cmd` - Initializes WinPE and launches remediation automatically.
- `Apply-SecureBootUpdate.ps1` - Detects firmware/Secure Boot state, applies signed update payloads, and writes detailed logs + state file.
- `Verify-SecureBootUpdate.ps1` - Verifies post-apply Secure Boot state and UEFI variable hashes.

## Payload layout expected by `Apply-SecureBootUpdate.ps1`

Place update files under `winpe\\payload\\`:

- `db.auth` (required)
- `dbx.auth` (required)
- `kek.auth` (required)
- `pk.auth` (optional)
- `certs\\*.cer|*.crt` (optional vetted certificate imports)

> The `.auth` files must be signed, authenticated Secure Boot variable update binaries created and approved by your PK/KEK trust chain process.

## Exit codes

`Apply-SecureBootUpdate.ps1`:

- `0` success
- `10` invalid environment (not UEFI / Secure Boot state unavailable)
- `20` required payload missing
- `30` update command failed
- `40` post-update state creation failed
- `99` unexpected error

`Verify-SecureBootUpdate.ps1`:

- `0` success
- `50` state file missing
- `60` verification mismatch (Secure Boot off / variable hash mismatch)
- `70` invalid environment
- `99` unexpected error

## WinPE ADK prerequisites

Install the following on the build workstation:

1. **Windows Assessment and Deployment Kit (ADK)** for your target Windows release.
2. **Windows PE add-on for the ADK** (same ADK version).

Run all commands below from **Deployment and Imaging Tools Environment (x64) as Administrator**.

## Build WinPE media with these scripts

```cmd
:: 1) Create amd64 WinPE working directory
copype amd64 C:\WinPE_UEFI

:: 2) Mount boot.wim so optional components can be added
Dism /Mount-Image /ImageFile:C:\WinPE_UEFI\media\sources\boot.wim /index:1 /MountDir:C:\WinPE_UEFI\mount

:: 3) Add PowerShell-related WinPE optional components
Dism /Add-Package /Image:C:\WinPE_UEFI\mount /PackagePath:"%ProgramFiles(x86)%\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-WMI.cab"
Dism /Add-Package /Image:C:\WinPE_UEFI\mount /PackagePath:"%ProgramFiles(x86)%\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-NetFX.cab"
Dism /Add-Package /Image:C:\WinPE_UEFI\mount /PackagePath:"%ProgramFiles(x86)%\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-Scripting.cab"
Dism /Add-Package /Image:C:\WinPE_UEFI\mount /PackagePath:"%ProgramFiles(x86)%\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-PowerShell.cab"

:: 4) Commit and unmount
Dism /Unmount-Image /MountDir:C:\WinPE_UEFI\mount /Commit

:: 5) Copy this repo's winpe content into media root
xcopy /E /I /Y C:\path\to\Update-UEFI\winpe C:\WinPE_UEFI\media\

:: 6) Create bootable ISO
MakeWinPEMedia /ISO C:\WinPE_UEFI C:\WinPE_UEFI\SecureBootRemediation.iso

:: 7) (Optional) Create bootable USB directly
MakeWinPEMedia /UFD C:\WinPE_UEFI F:
```
