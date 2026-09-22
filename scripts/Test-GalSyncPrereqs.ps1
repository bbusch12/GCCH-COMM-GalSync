<#
    .SYNOPSIS
        Pre-flight validation for the cross-cloud GAL synchronisation service.

    .DESCRIPTION
        Verifies, without changing anything:
          * configuration file shape and attribute allow-list integrity
          * required modules
          * outbound reachability of every cloud endpoint the service uses
          * Key Vault access and certificate validity/expiry
          * Graph and Exchange Online app-only sign-in in both tenants
          * effective permissions (can it read users, can it see mail contacts)
          * the current change plan, as a preview

        Run this before go-live, after every certificate rotation, and as the
        first step of any incident investigation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$ReportPath = "./reports/prereq-preview-$((Get-Date).ToString('yyyyMMdd-HHmmss')).csv",
    [switch]$SkipConnectivity
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$results = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param([string]$Area, [string]$Check, [ValidateSet('Pass', 'Fail', 'Warn', 'Skip')][string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail })
    $colour = @{ Pass = 'Green'; Fail = 'Red'; Warn = 'Yellow'; Skip = 'DarkGray' }[$Status]
    Write-Host ('[{0,-4}] {1,-22} {2}' -f $Status, $Area, $Check) -ForegroundColor $colour
    if ($Detail) { Write-Host ('        {0}' -f $Detail) -ForegroundColor DarkGray }
}

Import-Module "$PSScriptRoot/../src/GalSync/GalSync.psd1" -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------ configuration --
try {
    $config = Get-GalSyncConfig -Path $ConfigPath
    Add-Check 'Configuration' 'Schema and cross-references valid' 'Pass' "$($config.tenants.Count) tenants, $(@($config.flows | Where-Object enabled).Count) enabled flow(s)"
}
catch {
    Add-Check 'Configuration' 'Schema and cross-references valid' 'Fail' $_.Exception.Message
    $results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation
    throw
}

$placeholderPattern = '^(1{8}|2{8}|3{8}|4{8}|5{8}|6{8}|7{8}|8{8}|0{8})-'
foreach ($tenant in $config.tenants) {
    foreach ($field in 'tenantId', 'appId') {
        if ($tenant.$field -match $placeholderPattern) {
            Add-Check 'Configuration' "$($tenant.tag) $field is a real GUID" 'Fail' "still set to the sample value $($tenant.$field)"
        }
    }
}

foreach ($never in $config.attributeMap.neverSync) {
    if ($never -in $config.attributeMap.allowed) {
        Add-Check 'Configuration' 'Attribute allow-list integrity' 'Fail' "'$never' is both allowed and never-sync"
    }
}
Add-Check 'Configuration' 'Attributes crossing the boundary' 'Pass' ($config.attributeMap.allowed -join ', ')

# ----------------------------------------------------------------- modules --
$requiredModules = @(
    @{ Name = 'Az.Accounts'; Version = '3.0.0' }
    @{ Name = 'Az.KeyVault'; Version = '6.0.0' }
    @{ Name = 'Microsoft.Graph.Authentication'; Version = '2.19.0' }
    @{ Name = 'Microsoft.Graph.Users'; Version = '2.19.0' }
    @{ Name = 'Microsoft.Graph.Groups'; Version = '2.19.0' }
    @{ Name = 'ExchangeOnlineManagement'; Version = '3.4.0' }
)
foreach ($module in $requiredModules) {
    $found = Get-Module -ListAvailable -Name $module.Name |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $found) {
        Add-Check 'Modules' $module.Name 'Fail' 'not installed'
    }
    elseif ($found.Version -lt [version]$module.Version) {
        Add-Check 'Modules' $module.Name 'Warn' "$($found.Version) installed, $($module.Version) required"
    }
    else {
        Add-Check 'Modules' $module.Name 'Pass' "$($found.Version)"
    }
}

# ------------------------------------------------------------ connectivity --
if ($SkipConnectivity) {
    Add-Check 'Connectivity' 'Endpoint reachability' 'Skip' 'skipped by request'
}
else {
    $endpoints = [System.Collections.Generic.List[string]]::new()
    foreach ($tenant in $config.tenants) {
        $endpoints.Add(([uri]$tenant.graphEndpoint).Host)
        $endpoints.Add(([uri]$tenant.loginEndpoint).Host)
        $endpoints.Add($(if ($tenant.cloud -eq 'USGov') { 'outlook.office365.us' } else { 'outlook.office365.com' }))
    }
    foreach ($endpoint in ($endpoints | Select-Object -Unique)) {
        $ok = Test-Connection -TargetName $endpoint -TcpPort 443 -Quiet -TimeoutSeconds 5 -ErrorAction SilentlyContinue
        Add-Check 'Connectivity' "$endpoint:443" $(if ($ok) { 'Pass' } else { 'Fail' }) `
            $(if ($ok) { '' } else { 'blocked - check the Azure Firewall application rules and the runbook egress path' })
    }
}

# --------------------------------------------------------- vault and certs --
$certificates = @{}
try {
    $ctx = Get-AzContext
    if (-not $ctx) { Connect-AzAccount -Environment $config.runtime.azureEnvironment | Out-Null }
    Add-Check 'Azure' 'Signed in to Azure' 'Pass' "$((Get-AzContext).Environment.Name)"
}
catch {
    Add-Check 'Azure' 'Signed in to Azure' 'Fail' $_.Exception.Message
}

foreach ($tenant in $config.tenants) {
    try {
        $cert = Get-GalSyncCertificate -VaultName $config.runtime.keyVaultName -CertificateName $tenant.certificateName
        $certificates[$tenant.tag] = $cert
        $days = [int]([datetime]$cert.NotAfter - (Get-Date)).TotalDays
        $status = if ($days -lt 0) { 'Fail' } elseif ($days -lt 45) { 'Warn' } else { 'Pass' }
        Add-Check 'Key Vault' "$($tenant.tag) certificate" $status "thumbprint $($cert.Thumbprint), $days day(s) remaining"
        if (-not $cert.HasPrivateKey) {
            Add-Check 'Key Vault' "$($tenant.tag) private key present" 'Fail' 'the vault object has no private key'
        }
    }
    catch {
        Add-Check 'Key Vault' "$($tenant.tag) certificate" 'Fail' $_.Exception.Message
    }
}

# --------------------------------------------------------------- sign-in ----
foreach ($tenant in $config.tenants) {
    if (-not $certificates.ContainsKey($tenant.tag)) {
        Add-Check 'Sign-in' "$($tenant.tag) Graph app-only" 'Skip' 'no certificate'
        continue
    }
    try {
        Connect-GalSyncGraph -Tenant $tenant -Certificate $certificates[$tenant.tag] | Out-Null
        $probe = Get-MgUser -Top 1 -Property id, mail -ErrorAction Stop
        Add-Check 'Sign-in' "$($tenant.tag) Graph app-only" 'Pass' "read $((@($probe)).Count) user object(s)"
    }
    catch {
        Add-Check 'Sign-in' "$($tenant.tag) Graph app-only" 'Fail' $_.Exception.Message
    }
    finally { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }

    try {
        Connect-GalSyncExchange -Tenant $tenant -Certificate $certificates[$tenant.tag] | Out-Null
        $org = Invoke-GalSyncExoCmdlet -Prefix $tenant.cmdletPrefix -Noun 'Get-OrganizationConfig'
        Add-Check 'Sign-in' "$($tenant.tag) Exchange app-only" 'Pass' "$($org.DisplayName)"

        $existing = Invoke-GalSyncExoCmdlet -Prefix $tenant.cmdletPrefix -Noun 'Get-MailContact' -Parameters @{
            Filter = "$($config.target.provenanceAttribute) -eq '$($config.target.provenanceValue)'"
            ResultSize = 'Unlimited'
        }
        Add-Check 'Baseline' "$($tenant.tag) existing synced contacts" 'Pass' "$(@($existing).Count) contact(s) already stamped"
    }
    catch {
        Add-Check 'Sign-in' "$($tenant.tag) Exchange app-only" 'Fail' $_.Exception.Message
    }
}
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

# ------------------------------------------------------------------ preview --
if (-not ($results | Where-Object Status -EQ 'Fail')) {
    try {
        Invoke-GalSync -ConfigPath $ConfigPath -ReportPath $ReportPath -Preview | Out-Null
        Add-Check 'Preview' 'Change plan produced' 'Pass' "see $ReportPath"
    }
    catch {
        Add-Check 'Preview' 'Change plan produced' 'Fail' $_.Exception.Message
    }
}
else {
    Add-Check 'Preview' 'Change plan produced' 'Skip' 'earlier checks failed'
}

Write-Host ''
$results | Group-Object Status | ForEach-Object { Write-Host ('{0}: {1}' -f $_.Name, $_.Count) }
$results | Export-Csv -LiteralPath ($ReportPath -replace '\.csv$', '-checks.csv') -NoTypeInformation
if ($results | Where-Object Status -EQ 'Fail') { exit 1 }
