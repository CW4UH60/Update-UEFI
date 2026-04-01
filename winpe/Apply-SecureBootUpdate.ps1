[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PayloadPath = "$PSScriptRoot\payload",

    [Parameter(Mandatory = $false)]
    [string]$LogRoot = "$PSScriptRoot\logs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExitCodes = @{
    Success = 0
    InvalidEnvironment = 10
    PayloadMissing = 20
    UpdateFailed = 30
    VerificationFailed = 40
    UnexpectedError = 99
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = "{0:u} [{1}] {2}" -f (Get-Date), $Level, $Message
    $line | Tee-Object -FilePath $script:LocalLogFile -Append | Out-Null
    if ($script:RemovableLogFile) {
        $line | Out-File -FilePath $script:RemovableLogFile -Append -Encoding utf8
    }
}

function Get-RemovableLogPath {
    try {
        $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType = 2"
        foreach ($drive in $drives) {
            if ($drive.DeviceID -and (Test-Path "$($drive.DeviceID)\")) {
                return "$($drive.DeviceID)\SecureBootRemediation\logs"
            }
        }
    }
    catch {
        # Fall through.
    }

    return $null
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

try {
    if (-not (Test-Path $LogRoot)) {
        New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
    }

    $script:LocalLogFile = Join-Path $LogRoot ("Apply-SecureBootUpdate_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

    $removableRoot = Get-RemovableLogPath
    if ($removableRoot) {
        New-Item -Path $removableRoot -ItemType Directory -Force | Out-Null
        $script:RemovableLogFile = Join-Path $removableRoot ("Apply-SecureBootUpdate_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
    }
    else {
        $script:RemovableLogFile = $null
    }

    Write-Log "Starting Secure Boot remediation."
    Write-Log "Payload path: $PayloadPath"
    Write-Log "Local log file: $script:LocalLogFile"
    if ($script:RemovableLogFile) {
        Write-Log "Removable-media log file: $script:RemovableLogFile"
    }
    else {
        Write-Log "No removable media detected; only local logging is enabled." 'WARN'
    }

    if (-not (Test-Path $PayloadPath)) {
        Write-Log "Payload folder not found: $PayloadPath" 'ERROR'
        exit $ExitCodes.PayloadMissing
    }

    $firmwareMode = Get-FirmwareMode
    Write-Log "Detected firmware mode: $firmwareMode"
    if ($firmwareMode -ne 'UEFI') {
        Write-Log 'System is not running in UEFI mode; cannot apply Secure Boot variable updates.' 'ERROR'
        exit $ExitCodes.InvalidEnvironment
    }

    try {
        $secureBootEnabled = Confirm-SecureBootUEFI
        Write-Log "Secure Boot enabled: $secureBootEnabled"
    }
    catch {
        Write-Log "Unable to query Secure Boot state: $($_.Exception.Message)" 'ERROR'
        exit $ExitCodes.InvalidEnvironment
    }

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
                continue
            }

            Write-Log "Required payload missing for $($item.Name): $filePath" 'ERROR'
            exit $ExitCodes.PayloadMissing
        }

        Write-Log "Applying signed update file for $($item.Name): $filePath"
        try {
            Set-SecureBootUEFI -Name $item.Name -ContentFilePath $filePath -ErrorAction Stop
            Write-Log "Update command completed for $($item.Name)."
        }
        catch {
            Write-Log "Failed to apply $($item.Name) from $filePath. Error: $($_.Exception.Message)" 'ERROR'
            exit $ExitCodes.UpdateFailed
        }
    }

    $certDir = Join-Path $PayloadPath 'certs'
    if (Test-Path $certDir) {
        $certFiles = Get-ChildItem -Path $certDir -File -Include *.cer,*.crt -ErrorAction SilentlyContinue
        foreach ($certFile in $certFiles) {
            Write-Log "Importing vetted certificate to LocalMachine\\TrustedPublisher: $($certFile.FullName)"
            try {
                certutil -f -addstore TrustedPublisher $certFile.FullName | Out-Null
            }
            catch {
                Write-Log "Certificate import failed for $($certFile.FullName): $($_.Exception.Message)" 'ERROR'
                exit $ExitCodes.UpdateFailed
            }
        }
    }

    $state = [ordered]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        FirmwareMode = $firmwareMode
        SecureBootEnabled = $secureBootEnabled
        Variables = [ordered]@{
            db = @{ Sha256 = (Get-VariableHash -Name 'db') }
            dbx = @{ Sha256 = (Get-VariableHash -Name 'dbx') }
            KEK = @{ Sha256 = (Get-VariableHash -Name 'KEK') }
            PK = @{ Sha256 = (Get-VariableHash -Name 'PK') }
        }
    }

    $statePath = Join-Path $LogRoot 'SecureBootUpdateState.json'
    $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $statePath -Encoding utf8
    Write-Log "Wrote post-update state file: $statePath"

    if ($script:RemovableLogFile) {
        $removableStatePath = Join-Path (Split-Path -Parent $script:RemovableLogFile) 'SecureBootUpdateState.json'
        $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $removableStatePath -Encoding utf8
        Write-Log "Copied state file to removable media: $removableStatePath"
    }

    Write-Log 'Secure Boot remediation completed successfully.'
    exit $ExitCodes.Success
}
catch {
    if ($script:LocalLogFile) {
        Write-Log "Unexpected error: $($_.Exception.Message)" 'ERROR'
    }

    exit $ExitCodes.UnexpectedError
}
