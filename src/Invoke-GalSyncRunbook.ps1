<#
    .SYNOPSIS
        Azure Automation runbook entry point for cross-cloud GAL synchronisation.

    .DESCRIPTION
        Runs inside an Azure Government Automation account (PowerShell 7.2+
        runtime) using the account's system-assigned managed identity to read
        the app authentication certificates from Key Vault. All partner-tenant
        credentials stay inside the Azure Government boundary; only the
        allow-listed directory attributes leave it.

    .PARAMETER ConfigUri
        HTTPS URI (typically a blob in the Azure Government storage account,
        read with the managed identity) of galsync.config.json.

    .PARAMETER Preview
        Produce the change plan and the run report without writing anything.

    .NOTES
        Schedule: hourly is normally sufficient. Because unchanged objects are
        detected by hash and skipped, a steady-state run performs zero writes.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigUri,
    [Parameter()][string]$ConfigPath,
    [Parameter()][switch]$Preview,
    [Parameter()][string]$AzureEnvironment = 'AzureUSGovernment'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/GalSync/GalSync.psd1" -Force -ErrorAction Stop

# Managed identity in Azure Government. No secret material in the runbook.
Connect-AzAccount -Identity -Environment $AzureEnvironment | Out-Null

if (-not $ConfigPath) {
    if (-not $ConfigUri) { throw 'Supply either -ConfigPath or -ConfigUri.' }
    $token = (Get-AzAccessToken -ResourceUrl 'https://storage.azure.com').Token
    $ConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) 'galsync.config.json'
    Invoke-RestMethod -Uri $ConfigUri -Headers @{
        Authorization  = "Bearer $token"
        'x-ms-version' = '2021-08-06'
    } -OutFile $ConfigPath
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$reportPath = Join-Path ([System.IO.Path]::GetTempPath()) "galsync-run-$stamp.csv"

try {
    Invoke-GalSync -ConfigPath $ConfigPath -ReportPath $reportPath -Preview:$Preview | Out-Null
    $exitState = 'Success'
}
catch {
    $exitState = 'Failed'
    Write-Error $_
}
finally {
    # Retain the run report as audit evidence (immutable container).
    if (Test-Path -LiteralPath $reportPath) {
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        $account = $config.runtime.auditStorageAccount
        $container = $config.runtime.auditContainer
        if ($account -and $container) {
            try {
                $ctx = New-AzStorageContext -StorageAccountName $account -UseConnectedAccount
                Set-AzStorageBlobContent -File $reportPath -Container $container `
                    -Blob ("{0}/{1}" -f (Get-Date).ToUniversalTime().ToString('yyyy/MM/dd'), (Split-Path -Leaf $reportPath)) `
                    -Context $ctx -Force | Out-Null
            }
            catch {
                Write-Warning "Run report upload failed: $($_.Exception.Message)"
            }
        }
    }
    Write-Output "GalSync runbook finished with state: $exitState"
}

if ($exitState -eq 'Failed') { throw 'GalSync runbook failed. See job output and the run report.' }
