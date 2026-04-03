# Update-UEFI

Secure Boot remediation automation for WinPE, with CI unit tests and ISO build automation.

## What is included

- WinPE remediation entrypoint (`winpe/StartNet.cmd`)
- Secure Boot apply + verify scripts (`winpe/*.ps1`)
- Pester unit tests (`tests/*.Tests.ps1`)
- GitHub Actions workflow to run tests and publish a bootable WinPE ISO artifact (`.github/workflows/ci-winpe.yml`)
- Certificate export helper for 2023-validity certs from Windows VMs (`tools/Export-2023Certificates.ps1`)

## Compatibility targets

Validation is designed for:

- Windows 11 LTSC 24H2
- Windows 10 LTSC 1809

Use the verification checklist in `docs/getac-x500g2-g3-secure-boot-playbook.md` plus `winpe/Verify-SecureBootUpdate.ps1` logs/state artifacts on each target OS.
