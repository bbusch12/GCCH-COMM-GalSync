<#
    .SYNOPSIS
        Configures cross-cloud free/busy, MailTips and calendar sharing between
        a GCC High tenant and a Commercial tenant.

    .DESCRIPTION
        Run once in EACH tenant. Both sides must configure inbound access
        before anything works - cross-tenant access policy is an inbound
        consent model.

        Primary path (Mode = XTAP): Microsoft 365 Cross-Tenant Access Policy.
        This is the path that survives the EWS retirement. Microsoft began
        disabling EWS-backed cross-tenant sharing on 1 October 2026 with full
        shutdown on 1 April 2027; the replacement capability reached GCC High
        and DoD during September 2026.

        Fallback path (Mode = Legacy): the classic organization relationship,
        for use only while the XTAP capability has not yet landed in a tenant.
        It is on a retirement clock and must be removed once XTAP is proven.

    .PARAMETER LocalCloud
        The cloud of the tenant you are currently configuring.

    .PARAMETER PartnerTenantId
        The partner's Entra tenant ID. Domain lookup is not available for
        cross-cloud partners, so the GUID is mandatory.

    .NOTES
        Requires: Microsoft.Graph.Beta.Identity.SignIns, ExchangeOnlineManagement
        Roles   : Security Administrator (or Global Administrator) for the
                  policy work, Exchange Administrator for the legacy path.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('USGov', 'Global')][string]$LocalCloud,
    [Parameter(Mandatory)][ValidateSet('USGov', 'Global')][string]$PartnerCloud,
    [Parameter(Mandatory)][string]$LocalTenantId,
    [Parameter(Mandatory)][string]$PartnerTenantId,
    [Parameter(Mandatory)][string[]]$PartnerSmtpDomain,
    [ValidateSet('XTAP', 'Legacy', 'AuditOnly')][string]$Mode = 'XTAP',

    # Scope the exposure. 'All' publishes every mailbox; a group object ID
    # limits availability lookups to the members of that group.
    [string]$ResourceScopeGroupId,

    [ValidateSet('Basic', 'LimitedDetails')][string]$FreeBusyDetail = 'Basic',
    [ValidateSet('Limited', 'All')][string]$MailTipsLevel = 'Limited',
    [ValidateSet('Simple', 'Detail', 'Reviewer')][string]$CalendarSharingLevel = 'Simple',
    [string]$OrganizationRelationshipName = 'GalSync cross-cloud partner'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$cloudEndpoint = @{ USGov = 'microsoftonline.us'; Global = 'microsoftonline.com' }
$exoEnvironment = @{ USGov = 'O365USGovGCCHigh'; Global = 'O365Default' }

# Cross-cloud endpoints used by the legacy organization relationship path.
$legacyTarget = @{
    USGov  = @{ ApplicationUri = 'outlook.office365.us'; AutodiscoverEpr = 'https://autodiscover-s.office365.us/autodiscover/autodiscover.svc/WSSecurity' }
    Global = @{ ApplicationUri = 'outlook.com';          AutodiscoverEpr = 'https://autodiscover-s.outlook.com/autodiscover/autodiscover.svc/WSSecurity' }
}

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }

# ------------------------------------------------------------------ audit ---
function Get-LegacySharingInventory {
    Write-Step 'Existing (legacy) sharing configuration in this tenant'

    Write-Host '--- Organization relationships ---'
    Get-OrganizationRelationship | Format-List Name, DomainNames, Enabled,
        FreeBusyAccessEnabled, FreeBusyAccessLevel, FreeBusyAccessScope,
        MailTipsAccessEnabled, MailTipsAccessLevel, MailTipsAccessScope,
        TargetApplicationUri, TargetAutodiscoverEpr

    Write-Host '--- Availability address spaces ---'
    Get-AvailabilityAddressSpace | Format-List ForestName, AccessMethod, TargetTenantId

    Write-Host '--- Sharing policies ---'
    Get-SharingPolicy | Format-List Name, Enabled, Default, Domains
}

# ------------------------------------------------------------------- XTAP ---
function Set-CrossTenantAccessPolicy {
    Write-Step "Enabling the partner cloud endpoint '$($cloudEndpoint[$PartnerCloud])'"

    $policy = Get-MgBetaPolicyCrossTenantAccessPolicy
    $endpoints = @($policy.AllowedCloudEndpoints)
    if ($endpoints -notcontains $cloudEndpoint[$PartnerCloud]) {
        $endpoints += $cloudEndpoint[$PartnerCloud]
        if ($PSCmdlet.ShouldProcess('crossTenantAccessPolicy', "Allow cloud endpoint $($cloudEndpoint[$PartnerCloud])")) {
            Update-MgBetaPolicyCrossTenantAccessPolicy -BodyParameter @{ allowedCloudEndpoints = $endpoints }
        }
    }
    else {
        Write-Host '    already enabled'
    }

    Write-Step "Ensuring a partner configuration exists for $PartnerTenantId"
    $partner = Get-MgBetaPolicyCrossTenantAccessPolicyPartner -All |
        Where-Object TenantId -EQ $PartnerTenantId

    $collaborationBody = @{
        tenantId = $PartnerTenantId
        m365CollaborationInbound = @{
            users = @{
                accessType = 'allowed'
                targets    = @(@{ target = 'AllUsers'; targetType = 'user' })
            }
        }
    }

    if (-not $partner) {
        if ($PSCmdlet.ShouldProcess($PartnerTenantId, 'Create cross-tenant partner configuration')) {
            New-MgBetaPolicyCrossTenantAccessPolicyPartner -BodyParameter $collaborationBody | Out-Null
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($PartnerTenantId, 'Update Microsoft 365 collaboration trust')) {
            Update-MgBetaPolicyCrossTenantAccessPolicyPartner `
                -CrossTenantAccessPolicyConfigurationPartnerTenantId $PartnerTenantId `
                -BodyParameter @{ m365CollaborationInbound = $collaborationBody.m365CollaborationInbound } | Out-Null
        }
    }

    $scope = if ($ResourceScopeGroupId) {
        @{ resourceId = $ResourceScopeGroupId; resourceType = 'group' }
    } else {
        @{ resourceId = 'All'; resourceType = 'user' }
    }

    $capabilities = @(
        "crossTenantCalendarAvailability$FreeBusyDetail"
        "crossTenantMailTips$MailTipsLevel"
        "crossTenantCalendarSharingFreeBusy$CalendarSharingLevel"
    )

    foreach ($capability in $capabilities) {
        Write-Step "Enabling inbound capability '$capability'"
        $body = @{
            '@odata.type' = "microsoft.graph.$capability"
            inboundAccess = @{
                isAllowed      = $true
                resourceScopes = @{ included = @($scope); excluded = @(@{}) }
            }
        }
        if ($PSCmdlet.ShouldProcess($PartnerTenantId, "Enable $capability")) {
            New-MgBetaPolicyCrossTenantAccessPolicyPartnerM365Capability `
                -CrossTenantAccessPolicyConfigurationPartnerTenantId $PartnerTenantId `
                -BodyParameter $body | Out-Null
        }
    }

    Write-Host ''
    Write-Host 'Inbound capabilities are configured on this side only. The partner tenant must run the same script before availability resolves in both directions.' -ForegroundColor Yellow
}

# ----------------------------------------------------------------- legacy ---
function Set-LegacyOrganizationRelationship {
    Write-Warning 'The organization relationship path depends on EWS, which Microsoft began retiring on 1 October 2026 (full shutdown 1 April 2027). Use it only as a bridge and remove it once the cross-tenant access policy path is validated.'

    $target = $legacyTarget[$PartnerCloud]
    $freeBusyLevel = if ($FreeBusyDetail -eq 'LimitedDetails') { 'LimitedDetails' } else { 'AvailabilityOnly' }

    $existing = Get-OrganizationRelationship | Where-Object Name -EQ $OrganizationRelationshipName

    $params = @{
        DomainNames           = $PartnerSmtpDomain
        FreeBusyAccessEnabled = $true
        FreeBusyAccessLevel   = $freeBusyLevel
        MailTipsAccessEnabled = $true
        MailTipsAccessLevel   = $MailTipsLevel
        TargetApplicationUri  = $target.ApplicationUri
        TargetAutodiscoverEpr = $target.AutodiscoverEpr
        Enabled               = $true
    }
    if ($ResourceScopeGroupId) {
        $params.FreeBusyAccessScope = $ResourceScopeGroupId
        $params.MailTipsAccessScope = $ResourceScopeGroupId
    }

    if ($existing) {
        Write-Step "Updating organization relationship '$OrganizationRelationshipName'"
        if ($PSCmdlet.ShouldProcess($OrganizationRelationshipName, 'Set-OrganizationRelationship')) {
            Set-OrganizationRelationship -Identity $OrganizationRelationshipName @params
        }
    }
    else {
        Write-Step "Creating organization relationship '$OrganizationRelationshipName'"
        if ($PSCmdlet.ShouldProcess($OrganizationRelationshipName, 'New-OrganizationRelationship')) {
            New-OrganizationRelationship -Name $OrganizationRelationshipName @params
        }
    }
}

# ------------------------------------------------------------------- main ---
Write-Step "Connecting to Exchange Online ($($exoEnvironment[$LocalCloud]))"
Connect-ExchangeOnline -ExchangeEnvironmentName $exoEnvironment[$LocalCloud] -ShowBanner:$false

try {
    Get-LegacySharingInventory

    switch ($Mode) {
        'AuditOnly' { Write-Host 'Audit only - no changes made.' -ForegroundColor Green }
        'Legacy'    { Set-LegacyOrganizationRelationship }
        'XTAP'      {
            Write-Step "Connecting to Microsoft Graph beta ($LocalCloud)"
            Connect-MgGraph -TenantId $LocalTenantId -Environment $LocalCloud -NoWelcome -Scopes @(
                'Policy.Read.All', 'Policy.ReadWrite.CrossTenantAccess', 'Policy.ReadWrite.CrossTenantCapability'
            )
            Set-CrossTenantAccessPolicy
            Write-Host ''
            Write-Host 'Next: after both tenants are configured and availability lookups succeed, disable then remove the legacy organization relationships, availability address spaces and sharing policies listed above.' -ForegroundColor Yellow
        }
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
