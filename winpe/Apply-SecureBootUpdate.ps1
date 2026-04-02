[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$PayloadPath = "$PSScriptRoot\payload",

    [Parameter(Mandatory = $false)]
    [string]$LogRoot = 'X:\SecureBootUpdate\logs',

    [Parameter(Mandatory = $false)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [string[]]$SupportedModels = @('X500 G2', 'X500 G3'),

    [Parameter(Mandatory = $false)]
    [hashtable]$MinimumFirmwareByModel = @{ 'X500 G2' = '1.00'; 'X500 G3' = '1.00' },

    [Parameter(Mandatory = $false)]
    [switch]$AllowUnsupported
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExitCodes = @{
    Success = 0
    InvalidEnvironment = 10
    PayloadMissing = 20
    UpdateFailed = 30
    VerificationFailed = 40
    UnsupportedPlatform = 45
    UnexpectedError = 99
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = "{0:u} [{1}] {2}" -f (Get-Date), $Level, $Message
    $line | Tee-Object -FilePath $script:LocalLogFile -Append | Out-Null
}

function Get-FirmwareMode {
    if ($env:firmware_type) {
        return $env:firmware_type
    }

    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control'
    try {
        $value = (Get-ItemProperty -Path $path -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
        switch ($value) {
            1 { return 'BIOS' }
            2 { return 'UEFI' }
            default { return "Unknown($value)" }
        }
    }
    catch {
        return 'Unknown'
    }
}

function Get-VariableHash {
    param([Parameter(Mandatory = $true)][string]$Name)

    $var = Get-SecureBootUEFI -Name $Name
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($var.Bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-PayloadManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Manifest file not found: $Path"
    }

    $manifest = @{}
    $lines = Get-Content -Path $Path
    foreach ($rawLine in $lines) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        if ($line -match '^([A-Fa-f0-9]{64})\s+\*?(.+)$') {
            $manifest[$matches[2].Trim().ToLowerInvariant()] = $matches[1].ToUpperInvariant()
            continue
        }

        throw "Invalid manifest line format: $line"
    }

    return $manifest
}

function Test-ManifestEntry {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Manifest,
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][string]$FilePath
    )

    $relativePath = [System.IO.Path]::GetRelativePath($PayloadRoot, $FilePath).Replace('\\', '/').ToLowerInvariant()
    if (-not $Manifest.ContainsKey($relativePath)) {
        throw "Manifest entry missing for payload file: $relativePath"
    }

    $expected = $Manifest[$relativePath]
    $actual = Get-FileSha256 -Path $FilePath
    if ($expected -ne $actual) {
        throw "SHA-256 mismatch for $relativePath. expected=$expected actual=$actual"
    }

    return [ordered]@{
        RelativePath = $relativePath
        ExpectedSha256 = $expected
        ActualSha256 = $actual
        Validated = $true
    }
}

function Get-PlatformInfo {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS

    return [ordered]@{
        Model = ($cs.Model).Trim()
        Manufacturer = ($cs.Manufacturer).Trim()
        SerialNumber = ($bios.SerialNumber).Trim()
        FirmwareVersion = ($bios.SMBIOSBIOSVersion).Trim()
        BiosReleaseDate = ([Management.ManagementDateTimeConverter]::ToDateTime($bios.ReleaseDate)).ToUniversalTime().ToString('o')
    }
}

function Test-SupportedPlatform {
    param(
        [Parameter(Mandatory = $true)]$Platform,
        [Parameter(Mandatory = $true)][string[]]$Supported,
        [Parameter(Mandatory = $true)][hashtable]$MinimumFirmware,
        [Parameter(Mandatory = $true)][switch]$Override
    )

    $result = [ordered]@{
        IsSupported = $true
        ModelSupported = $true
        FirmwareSupported = $true
        Notes = @()
    }

    if ($Supported -and ($Platform.Model -notin $Supported)) {
        $result.IsSupported = $false
        $result.ModelSupported = $false
        $result.Notes += "Model '$($Platform.Model)' is not in supported list: $($Supported -join ', ')."
    }

    if ($MinimumFirmware.ContainsKey($Platform.Model)) {
        $minimum = $MinimumFirmware[$Platform.Model]
        try {
            $currentVersion = [version]$Platform.FirmwareVersion
            $minimumVersion = [version]$minimum
            if ($currentVersion -lt $minimumVersion) {
                $result.IsSupported = $false
                $result.FirmwareSupported = $false
                $result.Notes += "Firmware '$($Platform.FirmwareVersion)' is below required minimum '$minimum' for model '$($Platform.Model)'."
            }
        }
        catch {
            $result.IsSupported = $false
            $result.FirmwareSupported = $false
            $result.Notes += "Unable to compare firmware version '$($Platform.FirmwareVersion)' to minimum '$minimum'."
        }
    }

    if (-not $result.IsSupported -and -not $Override) {
        throw ($result.Notes -join ' ')
    }

    if (-not $result.IsSupported -and $Override) {
        $result.Notes += 'Unsupported platform override accepted via -AllowUnsupported.'
    }

    return $result
}

function Get-CertState {
    $state = [ordered]@{}
    foreach ($name in @('db', 'dbx', 'KEK', 'PK')) {
        try {
            $state[$name] = @{ Sha256 = (Get-VariableHash -Name $name) }
        }
        catch {
            $state[$name] = @{ Error = $_.Exception.Message }
        }
    }

    return $state
}

function Invoke-ApplySecureBootUpdate {
$operationResults = New-Object System.Collections.Generic.List[object]
$isDryRun = [bool]($DryRun -or $WhatIfPreference)
$runTimestamp = Get-Date

try {
    if (-not (Test-Path $LogRoot)) {
        New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
    }

    $script:LocalLogFile = Join-Path $LogRoot 'Apply-SecureBootUpdate.log'
    "" | Out-File -FilePath $script:LocalLogFile -Encoding utf8

    $manifestFile = if ($ManifestPath) { $ManifestPath } else { Join-Path $PayloadPath 'manifest.sha256' }

    Write-Log "Starting Secure Boot remediation. DryRun=$isDryRun"
    Write-Log "Payload path: $PayloadPath"
    Write-Log "Manifest path: $manifestFile"
    Write-Log "Log root: $LogRoot"

    if (-not (Test-Path $PayloadPath)) {
        Write-Log "Payload folder not found: $PayloadPath" 'ERROR'
        return $ExitCodes.PayloadMissing
    }

    $platformInfo = Get-PlatformInfo
    Write-Log "Platform model: $($platformInfo.Model); serial: $($platformInfo.SerialNumber); firmware: $($platformInfo.FirmwareVersion)"

    try {
        $platformSupport = Test-SupportedPlatform -Platform $platformInfo -Supported $SupportedModels -MinimumFirmware $MinimumFirmwareByModel -Override:$AllowUnsupported
        if ($platformSupport.Notes.Count -gt 0) {
            foreach ($note in $platformSupport.Notes) {
                Write-Log $note $(if ($platformSupport.IsSupported) { 'INFO' } else { 'WARN' })
            }
        }
    }
    catch {
        Write-Log "Unsupported platform: $($_.Exception.Message)" 'ERROR'
        return $ExitCodes.UnsupportedPlatform
    }

    $firmwareMode = Get-FirmwareMode
    Write-Log "Detected firmware mode: $firmwareMode"
    if ($firmwareMode -ne 'UEFI') {
        Write-Log 'System is not running in UEFI mode; cannot apply Secure Boot variable updates.' 'ERROR'
        return $ExitCodes.InvalidEnvironment
    }

    try {
        $secureBootEnabled = Confirm-SecureBootUEFI
        Write-Log "Secure Boot enabled: $secureBootEnabled"
    }
    catch {
        Write-Log "Unable to query Secure Boot state: $($_.Exception.Message)" 'ERROR'
        return $ExitCodes.InvalidEnvironment
    }

    $preState = Get-CertState
    $manifest = Get-PayloadManifest -Path $manifestFile
    Write-Log "Loaded payload manifest entries: $($manifest.Keys.Count)"

    $plan = @(
        @{ Name = 'db';  File = 'db.auth' },
        @{ Name = 'dbx'; File = 'dbx.auth' },
        @{ Name = 'KEK'; File = 'kek.auth' },
        @{ Name = 'PK';  File = 'pk.auth'; Optional = $true }
    )

    foreach ($item in $plan) {
        $filePath = Join-Path $PayloadPath $item.File
        if (-not (Test-Path $filePath)) {
            if ($item.Optional) {
                Write-Log "Optional payload missing; skipping $($item.Name): $filePath" 'WARN'
                $operationResults.Add([ordered]@{ Step = $item.Name; Action = 'SkipOptional'; Result = 'Skipped'; File = $item.File })
                continue
            }

            Write-Log "Required payload missing for $($item.Name): $filePath" 'ERROR'
            return $ExitCodes.PayloadMissing
        }

        try {
            $validation = Test-ManifestEntry -Manifest $manifest -PayloadRoot $PayloadPath -FilePath $filePath
            Write-Log "Validated SHA-256 for $($validation.RelativePath)."
            $operationResults.Add([ordered]@{ Step = $item.Name; Action = 'ManifestValidate'; Result = 'Success'; File = $item.File; Sha256 = $validation.ActualSha256 })
        }
        catch {
            Write-Log "Manifest validation failed for $($item.Name): $($_.Exception.Message)" 'ERROR'
            $operationResults.Add([ordered]@{ Step = $item.Name; Action = 'ManifestValidate'; Result = 'Failed'; File = $item.File; Error = $_.Exception.Message })
            return $ExitCodes.VerificationFailed
        }

        if ($isDryRun) {
            Write-Log "Dry-run active; skipping firmware variable write for $($item.Name)." 'WARN'
            $operationResults.Add([ordered]@{ Step = $item.Name; Action = 'Set-SecureBootUEFI'; Result = 'DryRunSkipped'; File = $item.File })
            continue
        }

        Write-Log "Applying signed update file for $($item.Name): $filePath"
        try {
            Set-SecureBootUEFI -Name $item.Name -ContentFilePath $filePath -ErrorAction Stop
            Write-Log "Update command completed for $($item.Name)."
            $operationResults.Add([ordered]@{ Step = $item.Name; Action = 'Set-SecureBootUEFI'; Result = 'Success'; File = $item.File })
        }
        catch {
            Write-Log "Failed to apply $($item.Name) from $filePath. Error: $($_.Exception.Message)" 'ERROR'
            $operationResults.Add([ordered]@{ Step = $item.Name; Action = 'Set-SecureBootUEFI'; Result = 'Failed'; File = $item.File; Error = $_.Exception.Message })
            return $ExitCodes.UpdateFailed
        }
    }

    $certDir = Join-Path $PayloadPath 'certs'
    if (Test-Path $certDir) {
        $certFiles = Get-ChildItem -Path $certDir -File -Include *.cer,*.crt -ErrorAction SilentlyContinue
        foreach ($certFile in $certFiles) {
            try {
                $validation = Test-ManifestEntry -Manifest $manifest -PayloadRoot $PayloadPath -FilePath $certFile.FullName
                Write-Log "Validated SHA-256 for $($validation.RelativePath)."
                $operationResults.Add([ordered]@{ Step = 'TrustedPublisherCert'; Action = 'ManifestValidate'; Result = 'Success'; File = $validation.RelativePath; Sha256 = $validation.ActualSha256 })
            }
            catch {
                Write-Log "Manifest validation failed for certificate $($certFile.FullName): $($_.Exception.Message)" 'ERROR'
                $operationResults.Add([ordered]@{ Step = 'TrustedPublisherCert'; Action = 'ManifestValidate'; Result = 'Failed'; File = $certFile.Name; Error = $_.Exception.Message })
                return $ExitCodes.VerificationFailed
            }

            if ($isDryRun) {
                Write-Log "Dry-run active; skipping certificate import for $($certFile.FullName)." 'WARN'
                $operationResults.Add([ordered]@{ Step = 'TrustedPublisherCert'; Action = 'certutil -addstore'; Result = 'DryRunSkipped'; File = $certFile.Name })
                continue
            }

            Write-Log "Importing vetted certificate to LocalMachine\\TrustedPublisher: $($certFile.FullName)"
            try {
                certutil -f -addstore TrustedPublisher $certFile.FullName | Out-Null
                $operationResults.Add([ordered]@{ Step = 'TrustedPublisherCert'; Action = 'certutil -addstore'; Result = 'Success'; File = $certFile.Name })
            }
            catch {
                Write-Log "Certificate import failed for $($certFile.FullName): $($_.Exception.Message)" 'ERROR'
                $operationResults.Add([ordered]@{ Step = 'TrustedPublisherCert'; Action = 'certutil -addstore'; Result = 'Failed'; File = $certFile.Name; Error = $_.Exception.Message })
                return $ExitCodes.UpdateFailed
            }
        }
    }

    $postState = if ($isDryRun) { $preState } else { Get-CertState }

    $state = [ordered]@{
        TimestampUtc = $runTimestamp.ToUniversalTime().ToString('o')
        DryRun = $isDryRun
        FirmwareMode = $firmwareMode
        SecureBootEnabled = $secureBootEnabled
        Platform = $platformInfo
        PlatformSupport = $platformSupport
        CurrentCertStateBefore = $preState
        CurrentCertStateAfter = $postState
        OperationResults = $operationResults
    }

    $statePath = Join-Path $LogRoot 'SecureBootUpdateState.json'
    $state | ConvertTo-Json -Depth 8 | Out-File -FilePath $statePath -Encoding utf8
    Write-Log "Wrote post-update state file: $statePath"

    $summaryPath = Join-Path $LogRoot 'Apply-OperationSummary.json'
    $operationResults | ConvertTo-Json -Depth 5 | Out-File -FilePath $summaryPath -Encoding utf8
    Write-Log "Wrote operation summary: $summaryPath"

    Write-Log 'Secure Boot remediation completed successfully.'
    return $ExitCodes.Success
}
catch {
    if ($script:LocalLogFile) {
        Write-Log "Unexpected error: $($_.Exception.Message)" 'ERROR'
    }

    return $ExitCodes.UnexpectedError
}

}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-ApplySecureBootUpdate)
}
