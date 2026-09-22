<#
    .SYNOPSIS
        Configures Microsoft Teams external access (federation) between a
        GCC High tenant and a Commercial tenant, using an explicit domain
        allow list rather than open federation.

    .DESCRIPTION
        Run once in EACH tenant. Cross-cloud Teams chat and meetings between
        GCC High and Commercial work over external access with both sides
        allow-listing the other's SMTP domains. Open federation is deliberately
        not used: an allow list is the defensible control for a CMMC/DFARS
        environment and keeps the external surface enumerable.

        Consumer (unmanaged) Teams federation is not available in GCC High and
        is explicitly disabled here in both tenants for symmetry.

    .PARAMETER Cloud
        The cloud of the tenant being configured.

    .PARAMETER AllowedDomain
        The partner tenant's SMTP domains to allow.

    .PARAMETER Replace
        Replace the entire allow list rather than adding to it. Use with care.

        This script covers CHAT (external access). Authenticated cross-cloud
        MEETING join uses a separate mechanism that is configured in the Teams
        admin center and is not exposed as a cmdlet: enable the partner cloud
        under Meetings > Meeting settings > Microsoft cloud settings, then add
        the partner tenant under Cross-cloud meetings, setting inbound and
        outbound connections. Both tenants must do this. The reminder is
        printed at the end of this script.

    .NOTES
        Requires: MicrosoftTeams module, Teams Administrator role.
        Federation changes can take up to 24 hours to propagate.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('USGov', 'Global', 'USGovDoD')][string]$Cloud,
    [Parameter(Mandatory)][string[]]$AllowedDomain,
    [switch]$Replace,
    [string]$ExternalAccessPolicyName = 'GalSync-CrossCloud-Federation',
    [string[]]$PolicyAssignmentGroupId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$teamsEnvironment = @{ USGov = 'TeamsGCCH'; USGovDoD = 'TeamsDOD'; Global = $null }

Write-Host "==> Connecting to Microsoft Teams ($Cloud)" -ForegroundColor Cyan
if ($teamsEnvironment[$Cloud]) {
    Connect-MicrosoftTeams -TeamsEnvironmentName $teamsEnvironment[$Cloud] | Out-Null
}
else {
    Connect-MicrosoftTeams | Out-Null
}

$current = Get-CsTenantFederationConfiguration
Write-Host '--- Current federation configuration ---'
$current | Format-List AllowFederatedUsers, AllowPublicUsers, AllowTeamsConsumer,
    AllowTeamsConsumerInbound, BlockAllSubdomains, AllowedDomains, BlockedDomains

$existingDomains = @()
if ($current.AllowedDomains -and $current.AllowedDomains.AllowedDomain) {
    $existingDomains = @($current.AllowedDomains.AllowedDomain.Domain)
}

$targetDomains = if ($Replace) { $AllowedDomain } else { @($existingDomains + $AllowedDomain | Select-Object -Unique) }
$targetDomains = @($targetDomains | Where-Object { $_ })

Write-Host "==> Target allow list: $($targetDomains -join ', ')" -ForegroundColor Cyan

$patterns = foreach ($d in $targetDomains) { New-CsEdgeDomainPattern -Domain $d }
$allowList = New-CsEdgeAllowList -AllowedDomain $patterns

if ($PSCmdlet.ShouldProcess('TenantFederationConfiguration', 'Apply allow-listed external access')) {
    Set-CsTenantFederationConfiguration `
        -AllowFederatedUsers $true `
        -AllowedDomains $allowList `
        -AllowPublicUsers $false `
        -AllowTeamsConsumer $false `
        -AllowTeamsConsumerInbound $false `
        -BlockAllSubdomains $true
}

# Optional: restrict which users may federate, rather than the whole tenant.
if ($PolicyAssignmentGroupId) {
    Write-Host "==> Ensuring external access policy '$ExternalAccessPolicyName'" -ForegroundColor Cyan

    $policy = Get-CsExternalAccessPolicy | Where-Object Identity -Like "*$ExternalAccessPolicyName"
    if (-not $policy) {
        if ($PSCmdlet.ShouldProcess($ExternalAccessPolicyName, 'New-CsExternalAccessPolicy')) {
            New-CsExternalAccessPolicy -Identity $ExternalAccessPolicyName `
                -EnableFederationAccess $true `
                -EnablePublicCloudAccess $false `
                -EnableTeamsConsumerAccess $false | Out-Null
        }
    }

    foreach ($groupId in $PolicyAssignmentGroupId) {
        if ($PSCmdlet.ShouldProcess($groupId, "Assign $ExternalAccessPolicyName")) {
            New-CsGroupPolicyAssignment -GroupId $groupId `
                -PolicyType ExternalAccessPolicy `
                -PolicyName $ExternalAccessPolicyName `
                -Rank 1 | Out-Null
        }
    }
}

Write-Host ''
Write-Host 'Both tenants must allow-list the other before chat resolves. Allow up to 24 hours for propagation.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Still to do in the Teams admin center (both tenants) for authenticated cross-cloud MEETING join:' -ForegroundColor Yellow
Write-Host '  1. Meetings > Meeting settings > Microsoft cloud settings  -> turn on the partner Azure cloud' -ForegroundColor Yellow
Write-Host '  2. Meetings > Meeting settings > Cross-cloud meetings > Add -> partner tenant ID, inbound and outbound On' -ForegroundColor Yellow
Write-Host '  Note: VDI optimisation must be SlimCore-based; WebRTC-based optimisation does not support cross-cloud meetings.' -ForegroundColor Yellow
Get-CsTenantFederationConfiguration | Format-List AllowFederatedUsers, AllowedDomains, AllowTeamsConsumer, BlockAllSubdomains
