<#
    .SYNOPSIS
        Provisions the GalSync service principal, certificate credential and
        least-privilege role assignment in one tenant (GCC High or Commercial).

    .DESCRIPTION
        Run once per tenant, from a privileged admin workstation, signed in as
        a user who holds Privileged Role Administrator (or Global Administrator)
        in that tenant. The script:

          1. Creates a CSP-based self-signed certificate (Exchange Online
             app-only auth does not support CNG keys).
          2. Registers a single-tenant application and attaches the public key.
          3. Grants the application permissions, resolving app role IDs by name
             so the script is correct in every cloud.
          4. Assigns the Entra directory role 'Exchange Recipient Administrator'
             to the service principal - the least-privileged supported role that
             can create and manage mail contacts.
          5. Imports the PFX into the Azure Government Key Vault and removes the
             local copy.

        Nothing here writes a client secret; certificate credentials only.

    .PARAMETER Cloud
        USGov for the GCC High tenant, Global for the Commercial tenant.

    .EXAMPLE
        .\New-GalSyncAppRegistration.ps1 -Cloud USGov -TenantId <guid> `
            -DisplayName 'GalSync-GCCH' -KeyVaultName kv-galsync-usgv-01 `
            -CertificateName galsync-gcch-app
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('USGov', 'Global', 'USGovDoD')][string]$Cloud,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$KeyVaultName,
    [Parameter(Mandatory)][string]$CertificateName,
    [string]$KeyVaultEnvironment = 'AzureUSGovernment',
    [int]$CertificateLifetimeMonths = 12,
    [string[]]$GraphPermission = @('User.Read.All', 'GroupMember.Read.All', 'CustomSecAttributeAssignment.Read.All'),
    [string]$DirectoryRole = 'Exchange Recipient Administrator'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ExchangeOnlineAppId  = '00000002-0000-0ff1-ce00-000000000000'
$ExchangeManageAsApp  = 'dc50a0fb-09a3-484d-be87-e023b12c6440'
$GraphAppId           = '00000003-0000-0000-c000-000000000000'

Write-Host "==> Connecting to Microsoft Graph ($Cloud / $TenantId)" -ForegroundColor Cyan
Connect-MgGraph -TenantId $TenantId -Environment $Cloud -NoWelcome -Scopes @(
    'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'RoleManagement.ReadWrite.Directory'
)

# ---------------------------------------------------------------- certificate
Write-Host '==> Creating CSP-based certificate' -ForegroundColor Cyan
if (-not $IsWindows) {
    throw 'Certificate creation uses New-SelfSignedCertificate and must run on Windows. Alternatively, issue the certificate from your internal PKI with a legacy CSP key and supply the PFX.'
}

$cert = New-SelfSignedCertificate `
    -Subject "CN=$DisplayName" `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyExportPolicy Exportable `
    -KeySpec Signature `
    -KeyLength 2048 `
    -KeyAlgorithm RSA `
    -HashAlgorithm SHA256 `
    -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' `
    -NotAfter (Get-Date).AddMonths($CertificateLifetimeMonths)

$work = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $work | Out-Null
$cerPath = Join-Path $work "$CertificateName.cer"
$pfxPath = Join-Path $work "$CertificateName.pfx"
$pfxPassword = ConvertTo-SecureString -String ([guid]::NewGuid().ToString('N') + '!Aa1') -AsPlainText -Force

Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pfxPassword | Out-Null
Write-Host "    Thumbprint: $($cert.Thumbprint)  Expires: $($cert.NotAfter)"

# --------------------------------------------------------------- application
Write-Host '==> Registering the application' -ForegroundColor Cyan
$app = New-MgApplication -DisplayName $DisplayName -SignInAudience 'AzureADMyOrg' -KeyCredentials @(
    @{
        Type        = 'AsymmetricX509Cert'
        Usage       = 'Verify'
        Key         = $cert.RawData
        DisplayName = "CN=$DisplayName"
    }
)
$sp = New-MgServicePrincipal -AppId $app.AppId
Write-Host "    AppId: $($app.AppId)   ServicePrincipalId: $($sp.Id)"

# --------------------------------------------------------------- permissions
function Grant-AppRole {
    param([string]$ResourceAppId, [string]$RoleValue, [string]$RoleId)

    $resourceSp = Get-MgServicePrincipal -Filter "appId eq '$ResourceAppId'"
    if (-not $resourceSp) { throw "Resource service principal $ResourceAppId not found in this tenant." }

    if (-not $RoleId) {
        $role = $resourceSp.AppRoles | Where-Object { $_.Value -eq $RoleValue -and $_.AllowedMemberTypes -contains 'Application' }
        if (-not $role) { throw "App role '$RoleValue' not published by $ResourceAppId in this cloud." }
        $RoleId = $role.Id
    }

    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -BodyParameter @{
        principalId = $sp.Id
        resourceId  = $resourceSp.Id
        appRoleId   = $RoleId
    } | Out-Null
    Write-Host "    granted $RoleValue on $ResourceAppId"
}

Write-Host '==> Granting application permissions (admin consent)' -ForegroundColor Cyan
foreach ($permission in $GraphPermission) {
    Grant-AppRole -ResourceAppId $GraphAppId -RoleValue $permission
}
Grant-AppRole -ResourceAppId $ExchangeOnlineAppId -RoleValue 'Exchange.ManageAsApp' -RoleId $ExchangeManageAsApp

# ------------------------------------------------------------- directory role
Write-Host "==> Assigning directory role '$DirectoryRole'" -ForegroundColor Cyan
$definition = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$DirectoryRole'"
if (-not $definition) { throw "Directory role '$DirectoryRole' not found." }

New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{
    principalId      = $sp.Id
    roleDefinitionId = $definition.Id
    directoryScopeId = '/'
} | Out-Null
Write-Host "    assigned $($definition.DisplayName)"

# ------------------------------------------------------------------ key vault
Write-Host "==> Importing the certificate into Key Vault '$KeyVaultName'" -ForegroundColor Cyan
Connect-AzAccount -Environment $KeyVaultEnvironment | Out-Null
Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -FilePath $pfxPath -Password $pfxPassword | Out-Null

Remove-Item -Path $work -Recurse -Force
Get-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" | Remove-Item -Force
Write-Host '    local certificate material removed'

[pscustomobject]@{
    Cloud              = $Cloud
    TenantId           = $TenantId
    AppId              = $app.AppId
    ServicePrincipalId = $sp.Id
    Thumbprint         = $cert.Thumbprint
    NotAfter           = $cert.NotAfter
    KeyVault           = $KeyVaultName
    CertificateName    = $CertificateName
    DirectoryRole      = $DirectoryRole
} | Format-List

Write-Host ''
Write-Host 'Record the AppId in config/galsync.config.json and schedule certificate rotation at 9 months.' -ForegroundColor Yellow
