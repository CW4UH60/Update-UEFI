[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $PSScriptRoot '..\winpe\payload\certs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stores = @(
    'Cert:\LocalMachine\CA',
    'Cert:\LocalMachine\Root',
    'Cert:\LocalMachine\TrustedPublisher'
)

New-Item -Path $Destination -ItemType Directory -Force | Out-Null

$exported = 0
foreach ($store in $stores) {
    $storeName = Split-Path -Path $store -Leaf
    Get-ChildItem -Path $store | Where-Object {
        $_.NotBefore.Year -le 2023 -and $_.NotAfter.Year -ge 2023
    } | ForEach-Object {
        $thumb = $_.Thumbprint -replace '[^A-Fa-f0-9]', ''
        $path = Join-Path $Destination ("{0}_{1}.cer" -f $storeName, $thumb)
        Export-Certificate -Cert $_ -FilePath $path -Type CERT | Out-Null
        $exported++
    }
}

Write-Host "Exported $exported certificates covering year 2023 to $Destination"
