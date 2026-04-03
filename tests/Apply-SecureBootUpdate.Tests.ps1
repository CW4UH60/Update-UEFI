Set-StrictMode -Version Latest

Describe 'Apply-SecureBootUpdate helpers' {
    BeforeAll {
        . "$PSScriptRoot/../winpe/Apply-SecureBootUpdate.ps1"
    }

    It 'parses manifest entries and ignores comments' {
        $dir = Join-Path $TestDrive 'payload'
        New-Item -Path $dir -ItemType Directory | Out-Null
        $manifestPath = Join-Path $dir 'manifest.sha256'
        @(
            '# comment'
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA *db.auth'
            'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB certs/test.cer'
        ) | Set-Content -Path $manifestPath

        $manifest = Get-PayloadManifest -Path $manifestPath

        $manifest.Keys.Count | Should -Be 2
        $manifest['db.auth'] | Should -Be 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        $manifest['certs/test.cer'] | Should -Be 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
    }

    It 'validates manifest entries using computed hash' {
        $payload = Join-Path $TestDrive 'payload'
        New-Item -Path (Join-Path $payload 'certs') -ItemType Directory -Force | Out-Null
        $filePath = Join-Path $payload 'certs/test.cer'
        'demo' | Set-Content -Path $filePath

        Mock Get-FileSha256 { 'C' * 64 }
        $manifest = @{ 'certs/test.cer' = 'C' * 64 }

        $result = Test-ManifestEntry -Manifest $manifest -PayloadRoot $payload -FilePath $filePath
        $result.Validated | Should -BeTrue
        $result.RelativePath | Should -Be 'certs/test.cer'
    }

    It 'flags unsupported firmware versions' {
        $platform = [ordered]@{ Model = 'X500 G2'; FirmwareVersion = '0.99' }
        {
            Test-SupportedPlatform -Platform $platform -Supported @('X500 G2') -MinimumFirmware @{ 'X500 G2' = '1.00' } -Override:$false
        } | Should -Throw
    }

    It 'allows override for unsupported model' {
        $platform = [ordered]@{ Model = 'Unknown Model'; FirmwareVersion = '1.50' }
        $result = Test-SupportedPlatform -Platform $platform -Supported @('X500 G2') -MinimumFirmware @{} -Override:$true
        $result.IsSupported | Should -BeFalse
        ($result.Notes -join ' ') | Should -Match 'override'
    }
}
