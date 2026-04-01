# Getac X500 G2 / G3 Secure Boot Certificate Update Playbook

## Purpose

This playbook standardizes Secure Boot certificate and variable updates on Getac **X500 G2** and **X500 G3** systems, including both:

- systems that still boot installed Windows, and
- systems that require an offline WinPE path.

Use this document together with the WinPE package in `winpe/` (`Apply-SecureBootUpdate.ps1` and `Verify-SecureBootUpdate.ps1`).

---

## 1) Preconditions

## 1.1 BIOS / firmware baseline checks

Before any change:

1. Record:
   - Model (X500 G2 or X500 G3)
   - BIOS version
   - BIOS date
   - Current Secure Boot mode (Enabled/Disabled)
   - Boot mode (UEFI required)
2. Confirm the platform is in **UEFI mode** (not Legacy/CSM).
3. Confirm Secure Boot variables are readable (PK/KEK/db/dbx present in firmware UI or via PowerShell tooling).
4. If BIOS is below your organization’s approved minimum for Secure Boot updates, update BIOS first per enterprise firmware policy.

> Do not proceed with Secure Boot variable updates on unapproved BIOS revisions.

## 1.2 Power and stability requirements

- Connect **AC adapter** before starting.
- Battery should be present and charged (recommended: at least 30%).
- Disable planned sleep/hibernate for the maintenance window.
- Do not dock/undock, hot-unplug storage, or force power-off during variable writes.

## 1.3 BitLocker handling requirements

If OS volume is BitLocker-protected:

1. Capture BitLocker recovery keys in your approved escrow system.
2. **Suspend BitLocker** before Secure Boot variable changes and reboot(s):
   - Typical command (run elevated):
     ```powershell
     Suspend-BitLocker -MountPoint "C:" -RebootCount 2
     ```
3. Document protector state before and after.
4. After successful verification, **resume BitLocker**:
   ```powershell
   Resume-BitLocker -MountPoint "C:"
   ```

> If BitLocker was not suspended and platform measurements change, the next boot may require recovery key entry.

---

## 2) Branching procedure

Choose one path per device.

## Path A — System still boots Windows

Use this when Windows is bootable and admin access is available.

1. Complete preconditions above.
2. If remediating devices impacted by the 2026 Secure Boot certificate rollout sequencing, run the Microsoft-trigger workflow from an elevated prompt:
   ```powershell
   reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Secureboot /v AvailableUpdates /t REG_DWORD /d 0x5944 /f
   Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update"
   ```
3. Confirm the registry value transitions to `0x4100`, then perform a **manual reboot**.
4. After reboot, trigger the scheduled task again:
   ```powershell
   Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update"
   ```
5. Stage approved Secure Boot payloads (`db.auth`, `dbx.auth`, `kek.auth`, optional `pk.auth`) from your controlled source.
6. Reboot and run validation in Windows (see Verification section).
7. If online apply fails, move to **Path B (offline WinPE)**.

Microsoft references for this workflow:

- Registry key updates for Secure Boot Windows devices: <https://support.microsoft.com/en-us/topic/registry-key-updates-for-secure-boot-windows-devices-with-it-managed-updates-a7be69c9-4634-42e1-9ca1-df06f43f360d>
- Secure Boot playbook for certificates expiring in 2026: <https://techcommunity.microsoft.com/blog/windows-itpro-blog/secure-boot-playbook-for-certificates-expiring-in-2026/4469235>

## Path B — Offline WinPE boot required

Use this when:

- Windows does not boot,
- boot chain trust errors block startup, or
- online apply is disallowed by policy.

1. Boot the device to a prepared UEFI WinPE USB.
2. Ensure WinPE media includes this repo’s `winpe/` content and payload files under `winpe\payload\`.
3. Let `StartNet.cmd` launch the remediation sequence automatically, or run scripts manually.
4. Collect logs and state artifacts from `X:\SecureBootUpdate\` before rebooting.
5. Reboot to firmware/OS for verification.

---

## 3) Step-by-step certificate update process

The sequence below is the standard order for controlled updates.

1. **Prepare payloads**
   - Required: `db.auth`, `dbx.auth`, `kek.auth`
   - Optional: `pk.auth`
   - Optional certificates: `certs\*.cer` / `certs\*.crt`
2. **Verify payload integrity and provenance**
   - Confirm files are from approved release package.
   - Validate hash/signature against internal release manifest.
3. **Apply updates**
   - In WinPE, run:
     ```powershell
     powershell -ExecutionPolicy Bypass -File X:\Apply-SecureBootUpdate.ps1
     ```
   - Script exit code expectations:
     - `0` success
     - `10` invalid environment
     - `20` payload missing
     - `30` update command failed
     - `40` state creation failed
     - `99` unexpected error
4. **Reboot once after apply**
   - Reboot is required so firmware fully re-reads updated variables.
5. **Run post-update verification script**
   - In WinPE:
     ```powershell
     powershell -ExecutionPolicy Bypass -File X:\Verify-SecureBootUpdate.ps1
     ```
   - Verification exit code expectations:
     - `0` success
     - `50` state file missing
     - `60` verification mismatch
     - `70` invalid environment
     - `99` unexpected error
6. **Capture evidence**
   - Save script logs, exit codes, and resulting variable hash outputs in ticket/change record.

---

## 4) Verification steps (firmware + OS)

## 4.1 Firmware verification

In BIOS/UEFI setup:

1. Confirm **Boot Mode = UEFI**.
2. Confirm **Secure Boot = Enabled** (if enabled by policy).
3. Confirm Secure Boot key state is populated (PK/KEK/db/dbx not empty unless intentionally cleared).
4. If firmware UI provides key/certificate metadata, confirm expected update timestamp/version identifiers.

## 4.2 OS verification (Windows)

After successful boot to Windows:

1. Check Secure Boot state:
   ```powershell
   Confirm-SecureBootUEFI
   ```
   Expected output: `True`.
2. Check BitLocker protector status:
   ```powershell
   Get-BitLockerVolume -MountPoint "C:"
   ```
3. Verify no repeated BitLocker recovery prompts on two warm reboots.
4. Confirm event logs do not show new recurring Secure Boot or TPM measurement failures after update window.

---

## 5) Exporting certificates from a known-good Windows machine

Use a known-good endpoint that has already completed the Microsoft Secure Boot update flow successfully.

1. Open elevated PowerShell and create an export folder:
   ```powershell
   New-Item -Path C:\SecureBoot-Cert-Export -ItemType Directory -Force | Out-Null
   ```
2. Export candidate certificates from `LocalMachine\CA`, `LocalMachine\Root`, and `LocalMachine\TrustedPublisher`:
   ```powershell
   $dest = 'C:\SecureBoot-Cert-Export'
   $stores = @(
     'Cert:\LocalMachine\CA',
     'Cert:\LocalMachine\Root',
     'Cert:\LocalMachine\TrustedPublisher'
   )

   foreach ($store in $stores) {
     $storeName = $store.Split('\')[-1]
     Get-ChildItem -Path $store | ForEach-Object {
       $safeThumbprint = $_.Thumbprint -replace '[^A-Fa-f0-9]', ''
       $outFile = Join-Path $dest ("{0}_{1}.cer" -f $storeName, $safeThumbprint)
       Export-Certificate -Cert $_ -FilePath $outFile -Type CERT | Out-Null
     }
   }
   ```
3. Optionally export active UEFI variable payload bytes for engineering comparison:
   ```powershell
   $uefiDir = 'C:\SecureBoot-Cert-Export\UEFI-Variables'
   New-Item -Path $uefiDir -ItemType Directory -Force | Out-Null
   foreach ($name in 'PK','KEK','db','dbx') {
     $var = Get-SecureBootUEFI -Name $name
     [System.IO.File]::WriteAllBytes((Join-Path $uefiDir "$name.bin"), $var.Bytes)
   }
   ```
4. Curate only approved `.cer` files into this repo under `winpe\payload\certs\`.
5. Generate/update `winpe\payload\manifest.sha256` so every `.auth` and `.cer/.crt` file is represented.
6. Run `Apply-SecureBootUpdate.ps1 -WhatIf` first to confirm manifest validation before production use.

---

## 6) Failure handling, rollback, and escalation

## 6.1 Immediate failure actions

If apply/verify fails:

1. Do **not** repeatedly retry with unknown payloads.
2. Preserve logs/state files from WinPE session.
3. Record exact exit code and failing step.
4. Reboot to firmware and check whether Secure Boot is left disabled or keys are partially updated.

## 6.2 Controlled rollback options

Use only organization-approved rollback package/process.

- If rollback `.auth` payload set exists, apply via same WinPE method.
- If platform is unbootable after key update, recover using:
  - known-good firmware defaults (if policy permits), and/or
  - approved key re-provisioning package.

> Avoid ad hoc key clearing or manual key enrollment unless specifically authorized by platform security engineering.

## 6.3 Escalation criteria

Escalate to endpoint engineering / platform security when any of the following occur:

- verification exit code `60` persists after one clean re-apply,
- repeated BitLocker recovery loop after proper suspend/resume handling,
- Secure Boot keys appear blank/corrupt in firmware,
- system cannot boot WinPE or Windows after update attempt,
- mismatch between expected and observed variable hashes.

Include in escalation bundle:

- device model + serial,
- BIOS version/date,
- payload package version + hashes,
- full script logs and exit codes,
- photos/screens of firmware Secure Boot pages (if allowed by policy).

---

## 7) Model-specific checklist (X500G2 vs X500G3)

Use this checklist during change execution.

| Checkpoint | X500 G2 | X500 G3 |
|---|---|---|
| Device identified and recorded | ☐ | ☐ |
| BIOS meets approved minimum for this model | ☐ | ☐ |
| Boot mode confirmed UEFI (no Legacy/CSM) | ☐ | ☐ |
| AC connected + battery health acceptable | ☐ | ☐ |
| BitLocker recovery key escrow verified | ☐ | ☐ |
| BitLocker suspended pre-change | ☐ | ☐ |
| Correct model-approved payload package staged | ☐ | ☐ |
| Update path selected (Windows or WinPE) | ☐ | ☐ |
| `Apply-SecureBootUpdate.ps1` exit code = 0 | ☐ | ☐ |
| `Verify-SecureBootUpdate.ps1` exit code = 0 | ☐ | ☐ |
| Firmware Secure Boot status rechecked post-update | ☐ | ☐ |
| Windows boot + `Confirm-SecureBootUEFI` validated | ☐ | ☐ |
| BitLocker resumed and post-check completed | ☐ | ☐ |
| Logs/evidence attached to ticket | ☐ | ☐ |

## Model notes to verify during pilot

- Validate exact BIOS menu wording and navigation path differences between X500 G2 and X500 G3 in your environment documentation.
- Validate whether either model requires additional reboot count before verification due to firmware variable commit behavior.
- Keep per-model known-good BIOS + payload matrix in your change runbook appendix.
