[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$StatePath = "$PSScriptRoot\logs\SecureBootUpdateState.json",

    [Parameter(Mandatory = $false)]
    [string]$LogRoot = "$PSScriptRoot\logs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExitCodes = @{
    Success = 0
    StateFileMissing = 50
    VerificationMismatch = 60
    InvalidEnvironment = 70
    UnexpectedError = 99
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = "{0:u} [{1}] {2}" -f (Get-Date), $Level, $Message
    $line | Tee-Object -FilePath $script:LogFile -Append | Out-Null
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

    $script:LogFile = Join-Path $LogRoot ("Verify-SecureBootUpdate_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
    Write-Log "Verifying Secure Boot update state using: $StatePath"

    if (-not (Test-Path $StatePath)) {
        Write-Log "State file not found: $StatePath" 'ERROR'
        exit $ExitCodes.StateFileMissing
    }

    $state = Get-Content -Path $StatePath -Raw | ConvertFrom-Json

    try {
        $secureBootEnabled = Confirm-SecureBootUEFI
        Write-Log "Current Secure Boot enabled state: $secureBootEnabled"
    }
    catch {
        Write-Log "Unable to query current Secure Boot state: $($_.Exception.Message)" 'ERROR'
        exit $ExitCodes.InvalidEnvironment
    }

    if (-not $secureBootEnabled) {
        Write-Log 'Secure Boot is disabled after update; verification failed.' 'ERROR'
        exit $ExitCodes.VerificationMismatch
    }

    $names = @('db', 'dbx', 'KEK', 'PK')
    foreach ($name in $names) {
        $expected = $state.Variables.$name.Sha256
        $actual = Get-VariableHash -Name $name
        Write-Log "Variable $name hash. expected=$expected actual=$actual"

        if ($expected -ne $actual) {
            Write-Log "Hash mismatch detected for $name." 'ERROR'
            exit $ExitCodes.VerificationMismatch
        }
    }

    Write-Log 'Secure Boot update verification passed.'
    exit $ExitCodes.Success
}
catch {
    if ($script:LogFile) {
        Write-Log "Unexpected verification error: $($_.Exception.Message)" 'ERROR'
    }

    exit $ExitCodes.UnexpectedError
}
