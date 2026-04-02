Set-StrictMode -Version Latest

Describe 'Verify-SecureBootUpdate script behavior' {
    BeforeAll {
        . "$PSScriptRoot/../winpe/Verify-SecureBootUpdate.ps1"
    }

    It 'returns success for dry-run states' {
        $logRoot = Join-Path $TestDrive 'logs'
        New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
        $statePath = Join-Path $logRoot 'SecureBootUpdateState.json'
        @{ DryRun = $true } | ConvertTo-Json | Set-Content -Path $statePath

        $code = & {
            try {
                Invoke-VerifySecureBootUpdate -StatePath $statePath -LogRoot $logRoot
            } catch {
                throw
            }
        }

        $code | Should -Be 0
    }

    It 'returns mismatch when hash differs' {
        $logRoot = Join-Path $TestDrive 'logs2'
        New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
        $statePath = Join-Path $logRoot 'SecureBootUpdateState.json'

        @{
            DryRun = $false
            CurrentCertStateAfter = @{ db = @{ Sha256 = 'A' * 64 }; dbx = @{ Sha256 = 'A' * 64 }; KEK = @{ Sha256 = 'A' * 64 }; PK = @{ Sha256 = 'A' * 64 } }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath

        Mock Confirm-SecureBootUEFI { $true }
        Mock Get-VariableHash { 'B' * 64 }

        $code = Invoke-VerifySecureBootUpdate -StatePath $statePath -LogRoot $logRoot
        $code | Should -Be 60
    }
}
