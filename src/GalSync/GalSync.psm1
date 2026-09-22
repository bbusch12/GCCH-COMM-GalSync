#Requires -Version 7.2
<#
    GalSync.psm1
    Cross-cloud Global Address List synchronisation between a Microsoft 365
    GCC High tenant and a Microsoft 365 Commercial tenant.

    Read path : Microsoft Graph (per-cloud endpoint, app-only certificate auth)
    Write path: Exchange Online PowerShell v3 (app-only certificate auth)
                Organisational mail contacts are read-only in Microsoft Graph,
                so New-/Set-/Remove-MailContact is the only supported write path.

    Design notes
      * No credential, token or source object ever leaves the Azure Government
        compute boundary except the explicitly allow-listed directory
        attributes written into the partner tenant.
      * Every write is preceded by a hash comparison, so a steady-state run
        performs zero writes.
      * Deletions are staged (soft delete + hide) and only purged after the
        configured grace period, behind a circuit breaker.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Logging -------------------------------------------------------------

$script:RunId = [guid]::NewGuid().ToString()
$script:Counters = [ordered]@{}

function Write-GalSyncLog {
    <#
        .SYNOPSIS
            Emits a single-line JSON log record. Automation job streams are
            forwarded to Log Analytics by diagnostic settings, so structured
            output here becomes queryable audit evidence (CMMC AU.L2-3.3.1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Flow,
        [string]$Action,
        [string]$Anchor,
        [hashtable]$Data
    )

    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        runId     = $script:RunId
        level     = $Level
        message   = $Message
    }
    if ($Flow)   { $record.flow = $Flow }
    if ($Action) { $record.action = $Action }
    if ($Anchor) { $record.anchor = $Anchor }
    if ($Data)   { foreach ($k in $Data.Keys) { $record[$k] = $Data[$k] } }

    $json = $record | ConvertTo-Json -Compress -Depth 6

    switch ($Level) {
        'Error'   { Write-Error   $json -ErrorAction Continue }
        'Warning' { Write-Warning $json }
        'Debug'   { Write-Verbose $json }
        default   { Write-Output  $json }
    }
}

function Add-GalSyncCounter {
    param([Parameter(Mandatory)][string]$Name, [int]$Value = 1)
    if (-not $script:Counters.Contains($Name)) { $script:Counters[$Name] = 0 }
    $script:Counters[$Name] += $Value
}

function Get-GalSyncCounters { [pscustomobject]$script:Counters }

function Get-GalSyncRunId { $script:RunId }

#endregion

#region Configuration -------------------------------------------------------

function Get-GalSyncConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    foreach ($required in 'tenants', 'flows', 'scope', 'attributeMap', 'target', 'safety') {
        if (-not $config.PSObject.Properties.Name.Contains($required)) {
            throw "Configuration is missing the required section '$required'."
        }
    }

    $tags = $config.tenants.tag
    if ($tags.Count -ne ($tags | Select-Object -Unique).Count) {
        throw 'Tenant tags must be unique.'
    }

    foreach ($flow in $config.flows) {
        foreach ($side in $flow.source, $flow.target) {
            if ($side -notin $tags) { throw "Flow references unknown tenant tag '$side'." }
        }
        if ($flow.source -eq $flow.target) { throw 'A flow cannot have the same source and target.' }
    }

    # Attributes on the never-sync list must never appear in the allow list.
    $collision = $config.attributeMap.allowed | Where-Object { $_ -in $config.attributeMap.neverSync }
    if ($collision) {
        throw "Attribute(s) '$($collision -join ', ')' appear in both 'allowed' and 'neverSync'."
    }

    $config
}

function Get-GalSyncTenant {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Tag
    )
    $tenant = $Config.tenants | Where-Object tag -EQ $Tag
    if (-not $tenant) { throw "Unknown tenant tag '$Tag'." }
    $tenant
}

#endregion

#region Credentials and connections ----------------------------------------

function Get-GalSyncCertificate {
    <#
        .SYNOPSIS
            Retrieves an app authentication certificate (with private key) from
            the Azure Government Key Vault using the Automation account's
            managed identity. The PFX never touches disk.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$CertificateName
    )

    $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $CertificateName -AsPlainText
    if (-not $secret) { throw "Certificate '$CertificateName' not found in vault '$VaultName'." }

    $bytes = [Convert]::FromBase64String($secret)
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    $cert  = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes, $null, $flags)

    $daysLeft = [int]([datetime]$cert.NotAfter - (Get-Date)).TotalDays
    if ($daysLeft -lt 0)  { throw "Certificate '$CertificateName' expired on $($cert.NotAfter)." }
    if ($daysLeft -lt 30) {
        Write-GalSyncLog -Level Warning -Message 'Authentication certificate expires soon.' `
            -Data @{ certificate = $CertificateName; daysRemaining = $daysLeft }
    }

    $cert
}

function Connect-GalSyncGraph {
    <#
        .SYNOPSIS
            Connects Microsoft Graph to one tenant. Only one Graph context can
            be active per session, so source enumeration is performed one
            tenant at a time and the result cached before switching.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tenant,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $environment = switch ($Tenant.cloud) {
        'USGov'    { 'USGov' }
        'USGovDoD' { 'USGovDoD' }
        'Global'   { 'Global' }
        default    { throw "Unsupported cloud '$($Tenant.cloud)' for tenant '$($Tenant.tag)'." }
    }

    Connect-MgGraph -ClientId $Tenant.appId `
                    -TenantId $Tenant.tenantId `
                    -Certificate $Certificate `
                    -Environment $environment `
                    -NoWelcome | Out-Null

    Write-GalSyncLog -Level Info -Message 'Connected to Microsoft Graph.' `
        -Data @{ tenant = $Tenant.tag; environment = $environment; endpoint = $Tenant.graphEndpoint }
}

function Connect-GalSyncExchange {
    <#
        .SYNOPSIS
            Connects Exchange Online PowerShell for one tenant using a cmdlet
            prefix, which is what makes concurrent GCC High and Commercial
            sessions possible inside a single runbook process.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tenant,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    Connect-ExchangeOnline -AppId $Tenant.appId `
                           -Organization $Tenant.initialDomain `
                           -Certificate $Certificate `
                           -ExchangeEnvironmentName $Tenant.exchangeEnvironmentName `
                           -Prefix $Tenant.cmdletPrefix `
                           -ShowBanner:$false `
                           -CommandName 'Get-MailContact', 'Get-Recipient', 'New-MailContact', 'Set-MailContact', 'Remove-MailContact', 'Get-Contact', 'Set-Contact', 'Get-OrganizationConfig' | Out-Null

    Write-GalSyncLog -Level Info -Message 'Connected to Exchange Online.' `
        -Data @{ tenant = $Tenant.tag; environment = $Tenant.exchangeEnvironmentName; prefix = $Tenant.cmdletPrefix }
}

function Invoke-GalSyncExoCmdlet {
    <#
        .SYNOPSIS
            Invokes a prefixed Exchange Online cmdlet with bounded exponential
            backoff. Transient throttling (429 / connection reset) is retried;
            everything else is surfaced immediately.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Noun,          # e.g. 'Get-MailContact'
        [hashtable]$Parameters = @{},
        [int]$MaxRetries = 5,
        [int]$BaseDelayMs = 2000
    )

    $parts = $Noun -split '-', 2
    $command = '{0}-{1}{2}' -f $parts[0], $Prefix, $parts[1]

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $command @Parameters
        }
        catch {
            $message = $_.Exception.Message
            $transient = $message -match '(?i)throttl|429|timed out|timeout|connection was closed|service unavailable|503|temporarily'
            if (-not $transient -or $attempt -eq $MaxRetries) { throw }

            $delay = $BaseDelayMs * [math]::Pow(2, $attempt - 1)
            Write-GalSyncLog -Level Warning -Message 'Transient Exchange Online failure; retrying.' `
                -Data @{ command = $command; attempt = $attempt; delayMs = $delay; detail = $message }
            Start-Sleep -Milliseconds $delay
        }
    }
}

#endregion

#region Source enumeration --------------------------------------------------

function Get-GalSyncGroupMemberIdSet {
    <#
        .SYNOPSIS
            Returns a HashSet of user object IDs from a transitive group
            membership expansion, or $null when no group is configured.
    #>
    [CmdletBinding()]
    param([string]$GroupId)

    if ([string]::IsNullOrWhiteSpace($GroupId)) { return $null }

    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Get-MgGroupTransitiveMember -GroupId $GroupId -All |
        Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.user' } |
        ForEach-Object { [void]$set.Add($_.Id) }

    $set
}

function Get-GalSyncMailboxAddressSet {
    <#
        .SYNOPSIS
            Builds the set of primary SMTP addresses that correspond to real
            mailboxes of the configured recipient types. Guards against
            publishing contacts for objects that are not mailboxes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string[]]$RecipientTypeDetails
    )

    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $recipients = Invoke-GalSyncExoCmdlet -Prefix $Prefix -Noun 'Get-Recipient' -Parameters @{
        RecipientTypeDetails = $RecipientTypeDetails
        ResultSize           = 'Unlimited'
    }
    foreach ($r in $recipients) {
        if ($r.PrimarySmtpAddress) { [void]$set.Add([string]$r.PrimarySmtpAddress) }
    }
    $set
}

function Test-GalSyncUserInScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)]$Scope,
        [System.Collections.Generic.HashSet[string]]$IncludeIds,
        [System.Collections.Generic.HashSet[string]]$ExcludeIds,
        [System.Collections.Generic.HashSet[string]]$MailboxAddresses,
        [ref]$Reason
    )

    function fail([string]$why) { if ($Reason) { $Reason.Value = $why }; return $false }

    if ($IncludeIds -and -not $IncludeIds.Contains($User.Id)) { return (fail 'not-in-include-group') }
    if ($ExcludeIds -and $ExcludeIds.Contains($User.Id))      { return (fail 'in-exclude-group') }
    if ([string]::IsNullOrWhiteSpace($User.Mail))             { return (fail 'no-mail-attribute') }
    if ($Scope.requireEnabledAccount -and -not $User.AccountEnabled) { return (fail 'account-disabled') }
    if ($Scope.excludeGuests -and $User.UserType -eq 'Guest')        { return (fail 'guest-account') }

    foreach ($domain in $Scope.excludeMailDomains) {
        if ($User.Mail -like "*@*$domain") { return (fail "excluded-mail-domain:$domain") }
    }

    foreach ($pattern in $Scope.excludeUpnPatterns) {
        if ($User.UserPrincipalName -match $pattern) { return (fail "excluded-upn-pattern:$pattern") }
    }

    if ($MailboxAddresses -and -not $MailboxAddresses.Contains($User.Mail)) {
        return (fail 'no-matching-mailbox')
    }

    # Export-control / ITAR opt-out expressed as an Entra custom security attribute.
    $csaRule = $Scope.excludeIfCustomSecurityAttribute
    if ($csaRule -and $csaRule.attributeSet -and $User.PSObject.Properties.Name -contains 'CustomSecurityAttributes') {
        $csa = $User.CustomSecurityAttributes
        if ($csa -and $csa.AdditionalProperties -and $csa.AdditionalProperties.ContainsKey($csaRule.attributeSet)) {
            $setValues = $csa.AdditionalProperties[$csaRule.attributeSet]
            if ($setValues -and $setValues.ContainsKey($csaRule.attributeName)) {
                if ($setValues[$csaRule.attributeName] -eq $csaRule.blockOnValue) {
                    return (fail 'export-control-flag')
                }
            }
        }
    }

    $true
}

function Get-GalSyncSourceUser {
    <#
        .SYNOPSIS
            Enumerates in-scope users from the currently connected Graph tenant
            and returns them as normalised source records.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SourceTag,
        [System.Collections.Generic.HashSet[string]]$MailboxAddresses
    )

    $scope = $Config.scope
    $includeIds = Get-GalSyncGroupMemberIdSet -GroupId ($scope.includeGroupId.$SourceTag)
    $excludeIds = Get-GalSyncGroupMemberIdSet -GroupId ($scope.excludeGroupId.$SourceTag)

    $properties = @(
        'id', 'displayName', 'givenName', 'surname', 'mail', 'userPrincipalName',
        'jobTitle', 'department', 'companyName', 'officeLocation', 'city', 'state',
        'country', 'businessPhones', 'mobilePhone', 'accountEnabled', 'userType'
    )

    $graphParams = @{
        All        = $true
        Property   = $properties
        PageSize   = 999
        ErrorAction = 'Stop'
    }

    # Custom security attributes require CustomSecAttributeAssignment.Read.All.
    # Treat their absence as a hard failure only when the exclusion rule is armed.
    $csaRule = $scope.excludeIfCustomSecurityAttribute
    $wantCsa = [bool]($csaRule -and $csaRule.attributeSet)
    if ($wantCsa) { $graphParams.Property = $properties + 'customSecurityAttributes' }

    try {
        $users = Get-MgUser @graphParams
    }
    catch {
        if ($wantCsa) {
            Write-GalSyncLog -Level Error -Message 'Unable to read custom security attributes; export-control exclusions cannot be evaluated. Aborting this flow.' `
                -Data @{ tenant = $SourceTag; detail = $_.Exception.Message }
            throw
        }
        throw
    }

    $inScope = [System.Collections.Generic.List[object]]::new()
    $rejected = @{}

    foreach ($user in $users) {
        $reason = ''
        $ok = Test-GalSyncUserInScope -User $user -Scope $scope `
                -IncludeIds $includeIds -ExcludeIds $excludeIds `
                -MailboxAddresses $MailboxAddresses -Reason ([ref]$reason)
        if ($ok) {
            $inScope.Add($user)
        }
        else {
            if (-not $rejected.ContainsKey($reason)) { $rejected[$reason] = 0 }
            $rejected[$reason]++
        }
    }

    Write-GalSyncLog -Level Info -Message 'Source enumeration complete.' -Data @{
        tenant     = $SourceTag
        evaluated  = @($users).Count
        inScope    = $inScope.Count
        exclusions = $rejected
    }

    $inScope
}

#endregion

#region Projection and change detection ------------------------------------

function ConvertTo-GalSyncContactModel {
    <#
        .SYNOPSIS
            Projects a source user onto the allow-listed attribute set. This
            function is the single place where directory data crosses the
            tenant boundary, so the allow list is enforced here and nowhere else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SourceTag
    )

    $map = $Config.attributeMap
    $allowed = [System.Collections.Generic.HashSet[string]]::new([string[]]$map.allowed, [StringComparer]::OrdinalIgnoreCase)

    foreach ($opt in $map.optional.PSObject.Properties) {
        if ($opt.Value -eq $true) { [void]$allowed.Add($opt.Name) }
    }

    $take = {
        param([string]$name)
        if (-not $allowed.Contains($name)) { return $null }
        $prop = $User.PSObject.Properties[$name]
        if (-not $prop) { return $null }
        $value = $prop.Value
        if ($value -is [array]) { $value = $value | Select-Object -First 1 }
        if ([string]::IsNullOrWhiteSpace([string]$value)) { return $null }
        [string]$value
    }

    $suffix = ''
    if ($map.displayNameSuffix -and $map.displayNameSuffix.PSObject.Properties.Name -contains $SourceTag) {
        $suffix = [string]$map.displayNameSuffix.$SourceTag
    }

    $displayName = & $take 'displayName'
    if (-not $displayName) { $displayName = $User.Mail }

    $anchor = $User.Id
    $shortAnchor = ($anchor -replace '[^0-9a-fA-F]', '').Substring(0, 12)
    $tagLower = $SourceTag.ToLowerInvariant()

    [pscustomobject]@{
        Anchor          = $anchor
        SourceTag       = $SourceTag
        Name            = '{0}-{1}-{2}' -f $Config.target.contactNamePrefix, $tagLower, $shortAnchor
        Alias           = '{0}_{1}_{2}' -f $Config.target.aliasPrefix, $tagLower, $shortAnchor
        DisplayName     = ($displayName + $suffix).Trim()
        ExternalEmail   = $User.Mail
        FirstName       = & $take 'givenName'
        LastName        = & $take 'surname'
        Title           = & $take 'jobTitle'
        Department      = & $take 'department'
        Company         = & $take 'companyName'
        Office          = & $take 'officeLocation'
        City            = & $take 'city'
        StateOrProvince = & $take 'state'
        CountryOrRegion = & $take 'country'
        Phone           = & $take 'businessPhones'
        MobilePhone     = & $take 'mobilePhone'
    }
}

function Get-GalSyncModelHash {
    <#
        .SYNOPSIS
            Deterministic SHA-256 over the projected attribute set. Stored on
            the contact so that unchanged objects are never rewritten.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Model)

    $fields = 'DisplayName', 'ExternalEmail', 'FirstName', 'LastName', 'Title',
              'Department', 'Company', 'Office', 'City', 'StateOrProvince',
              'CountryOrRegion', 'Phone', 'MobilePhone'

    $canonical = ($fields | ForEach-Object { '{0}={1}' -f $_, ([string]$Model.$_).Trim() }) -join '|'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 32)
    }
    finally { $sha.Dispose() }
}

#endregion

#region Target reconciliation ----------------------------------------------

function Get-GalSyncTargetContact {
    <#
        .SYNOPSIS
            Returns the existing synchronised contacts in the target tenant for
            one source tenant, keyed by source anchor. Only objects carrying the
            provenance stamp are ever considered, so contacts created by other
            means are invisible to this tool and can never be modified or deleted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetPrefix,
        [Parameter(Mandatory)][string]$SourceTag
    )

    $t = $Config.target
    $filter = "{0} -eq '{1}' -and {2} -eq '{3}'" -f $t.provenanceAttribute, $t.provenanceValue, $t.sourceTagAttribute, $SourceTag

    $contacts = Invoke-GalSyncExoCmdlet -Prefix $TargetPrefix -Noun 'Get-MailContact' -Parameters @{
        Filter     = $filter
        ResultSize = 'Unlimited'
    }

    $map = @{}
    foreach ($c in $contacts) {
        $anchor = [string]$c.($t.anchorAttribute)
        if ([string]::IsNullOrWhiteSpace($anchor)) {
            Write-GalSyncLog -Level Warning -Message 'Synchronised contact has no anchor stamp; skipping.' `
                -Data @{ contact = [string]$c.Identity }
            continue
        }
        if ($map.ContainsKey($anchor)) {
            Write-GalSyncLog -Level Warning -Message 'Duplicate anchor detected in target tenant.' `
                -Anchor $anchor -Data @{ contact = [string]$c.Identity }
            continue
        }
        $map[$anchor] = $c
    }
    $map
}

function Get-GalSyncPlan {
    <#
        .SYNOPSIS
            Produces the create / update / restore / stage-delete / purge plan
            for one flow. Pure function: performs no writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][hashtable]$DesiredByAnchor,
        [Parameter(Mandatory)][hashtable]$ExistingByAnchor
    )

    $t = $Config.target
    $graceDays = [int]$Config.lifecycle.softDeleteGraceDays
    $now = (Get-Date).ToUniversalTime()

    $plan = [ordered]@{
        Create      = [System.Collections.Generic.List[object]]::new()
        Update      = [System.Collections.Generic.List[object]]::new()
        Restore     = [System.Collections.Generic.List[object]]::new()
        StageDelete = [System.Collections.Generic.List[object]]::new()
        Purge       = [System.Collections.Generic.List[object]]::new()
        NoChange    = 0
    }

    foreach ($anchor in $DesiredByAnchor.Keys) {
        $desired = $DesiredByAnchor[$anchor]
        $existing = $ExistingByAnchor[$anchor]

        if (-not $existing) {
            $plan.Create.Add([pscustomobject]@{ Anchor = $anchor; Model = $desired })
            continue
        }

        $pendingStamp = [string]$existing.($t.pendingDeleteAttribute)
        if (-not [string]::IsNullOrWhiteSpace($pendingStamp)) {
            # Object came back into scope before the grace period elapsed.
            $plan.Restore.Add([pscustomobject]@{ Anchor = $anchor; Model = $desired; Contact = $existing })
            continue
        }

        if ([string]$existing.($t.hashAttribute) -ne $desired.Hash) {
            $plan.Update.Add([pscustomobject]@{ Anchor = $anchor; Model = $desired; Contact = $existing })
        }
        else {
            $plan.NoChange++
        }
    }

    foreach ($anchor in $ExistingByAnchor.Keys) {
        if ($DesiredByAnchor.ContainsKey($anchor)) { continue }

        $existing = $ExistingByAnchor[$anchor]
        $pendingStamp = [string]$existing.($t.pendingDeleteAttribute)

        if ([string]::IsNullOrWhiteSpace($pendingStamp)) {
            $plan.StageDelete.Add([pscustomobject]@{ Anchor = $anchor; Contact = $existing })
            continue
        }

        $stampedOn = $null
        if ($pendingStamp -match 'PENDINGDELETE:(\d{8})') {
            $stampedOn = [datetime]::ParseExact($Matches[1], 'yyyyMMdd', $null)
        }

        if ($null -eq $stampedOn) {
            Write-GalSyncLog -Level Warning -Message 'Unparsable pending-delete stamp; re-staging.' -Anchor $anchor
            $plan.StageDelete.Add([pscustomobject]@{ Anchor = $anchor; Contact = $existing })
        }
        elseif (($now - $stampedOn).TotalDays -ge $graceDays) {
            $plan.Purge.Add([pscustomobject]@{ Anchor = $anchor; Contact = $existing; StagedOn = $stampedOn })
        }
    }

    $plan
}

function Test-GalSyncSafetyGate {
    <#
        .SYNOPSIS
            Circuit breaker. A directory outage, a mis-scoped group or a revoked
            Graph permission all look identical to "everyone left the company",
            so a run that would delete or create beyond the configured envelope
            is refused rather than executed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][int]$SourceCount,
        [Parameter(Mandatory)][int]$TargetCount,
        [Parameter(Mandatory)][string]$Flow
    )

    $safety = $Config.safety
    $deletes = $Plan.StageDelete.Count + $Plan.Purge.Count
    $violations = [System.Collections.Generic.List[string]]::new()

    if ($safety.abortOnEmptySource -and $SourceCount -lt [int]$safety.minimumSourceObjects) {
        $violations.Add("source returned $SourceCount objects, minimum is $($safety.minimumSourceObjects)")
    }
    if ($deletes -gt [int]$safety.maxDeletesPerRun) {
        $violations.Add("$deletes deletions exceed maxDeletesPerRun ($($safety.maxDeletesPerRun))")
    }
    if ($TargetCount -gt 0) {
        $pct = [math]::Round(($deletes / $TargetCount) * 100, 2)
        if ($pct -gt [double]$safety.maxDeletePercentOfTarget) {
            $violations.Add("deletions are $pct% of the target set, ceiling is $($safety.maxDeletePercentOfTarget)%")
        }
    }
    if ($Plan.Create.Count -gt [int]$safety.maxCreatesPerRun) {
        $violations.Add("$($Plan.Create.Count) creations exceed maxCreatesPerRun ($($safety.maxCreatesPerRun))")
    }

    if ($violations.Count -gt 0) {
        Write-GalSyncLog -Level Error -Flow $Flow -Action 'safety-gate' `
            -Message 'Safety gate blocked this flow; no writes were performed.' `
            -Data @{ violations = $violations; sourceCount = $SourceCount; targetCount = $TargetCount }
        return $false
    }

    $true
}

#endregion

#region Write operations ----------------------------------------------------

function Set-GalSyncContactAttribute {
    <#
        .SYNOPSIS
            Applies the directory attributes and the control stamps to an
            existing mail contact.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetPrefix,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)]$Model,
        [switch]$ClearPendingDelete
    )

    $t = $Config.target
    $retry = @{ MaxRetries = [int]$Config.throttling.maxRetries; BaseDelayMs = [int]$Config.throttling.retryBaseDelayMs }

    $mailContactParams = @{
        Identity                      = $Identity
        DisplayName                   = $Model.DisplayName
        ExternalEmailAddress          = $Model.ExternalEmail
        HiddenFromAddressListsEnabled = [bool]$t.hiddenFromAddressLists
        $t.provenanceAttribute        = $t.provenanceValue
        $t.sourceTagAttribute         = $Model.SourceTag
        $t.anchorAttribute            = $Model.Anchor
        $t.hashAttribute              = $Model.Hash
        WarningAction                 = 'SilentlyContinue'
    }
    if ($ClearPendingDelete) { $mailContactParams[$t.pendingDeleteAttribute] = '' }

    $contactParams = @{
        Identity      = $Identity
        WarningAction = 'SilentlyContinue'
    }
    foreach ($pair in @{
        FirstName       = $Model.FirstName
        LastName        = $Model.LastName
        Title           = $Model.Title
        Department      = $Model.Department
        Company         = $Model.Company
        Office          = $Model.Office
        City            = $Model.City
        StateOrProvince = $Model.StateOrProvince
        CountryOrRegion = $Model.CountryOrRegion
        Phone           = $Model.Phone
        MobilePhone     = $Model.MobilePhone
    }.GetEnumerator()) {
        # Empty string clears a previously populated attribute; $null would be ignored.
        $contactParams[$pair.Key] = if ($null -eq $pair.Value) { '' } else { $pair.Value }
    }

    if ($PSCmdlet.ShouldProcess($Identity, 'Set mail contact attributes')) {
        Invoke-GalSyncExoCmdlet -Prefix $TargetPrefix -Noun 'Set-MailContact' -Parameters $mailContactParams @retry | Out-Null
        Invoke-GalSyncExoCmdlet -Prefix $TargetPrefix -Noun 'Set-Contact'     -Parameters $contactParams     @retry | Out-Null
    }
}

function New-GalSyncContact {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetPrefix,
        [Parameter(Mandatory)]$Model
    )

    $retry = @{ MaxRetries = [int]$Config.throttling.maxRetries; BaseDelayMs = [int]$Config.throttling.retryBaseDelayMs }

    $newParams = @{
        Name                 = $Model.Name
        Alias                = $Model.Alias
        DisplayName          = $Model.DisplayName
        ExternalEmailAddress = $Model.ExternalEmail
        WarningAction        = 'SilentlyContinue'
    }
    if ($Model.FirstName) { $newParams.FirstName = $Model.FirstName }
    if ($Model.LastName)  { $newParams.LastName  = $Model.LastName }

    if (-not $PSCmdlet.ShouldProcess($Model.ExternalEmail, 'Create mail contact')) { return }

    Invoke-GalSyncExoCmdlet -Prefix $TargetPrefix -Noun 'New-MailContact' -Parameters $newParams @retry | Out-Null
    Set-GalSyncContactAttribute -Config $Config -TargetPrefix $TargetPrefix -Identity $Model.Name -Model $Model -Confirm:$false
}

function Set-GalSyncContactPendingDelete {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetPrefix,
        [Parameter(Mandatory)][string]$Identity
    )

    $t = $Config.target
    $stamp = 'PENDINGDELETE:{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd')

    $params = @{
        Identity                      = $Identity
        $t.pendingDeleteAttribute     = $stamp
        WarningAction                 = 'SilentlyContinue'
    }
    if ($Config.lifecycle.hideOnSoftDelete) { $params.HiddenFromAddressListsEnabled = $true }

    if ($PSCmdlet.ShouldProcess($Identity, "Stage for deletion ($stamp)")) {
        Invoke-GalSyncExoCmdlet -Prefix $TargetPrefix -Noun 'Set-MailContact' -Parameters $params `
            -MaxRetries ([int]$Config.throttling.maxRetries) -BaseDelayMs ([int]$Config.throttling.retryBaseDelayMs) | Out-Null
    }
}

function Remove-GalSyncContact {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetPrefix,
        [Parameter(Mandatory)][string]$Identity
    )

    if ($PSCmdlet.ShouldProcess($Identity, 'Permanently remove mail contact')) {
        Invoke-GalSyncExoCmdlet -Prefix $TargetPrefix -Noun 'Remove-MailContact' -Parameters @{
            Identity = $Identity
            Confirm  = $false
        } -MaxRetries ([int]$Config.throttling.maxRetries) -BaseDelayMs ([int]$Config.throttling.retryBaseDelayMs) | Out-Null
    }
}

#endregion

#region Orchestration -------------------------------------------------------

function Invoke-GalSyncFlow {
    <#
        .SYNOPSIS
            Executes one directional flow (source tenant -> target tenant).
        .PARAMETER Preview
            Plan only. No write cmdlet is invoked and the plan is returned for
            review. This is the mode used for the pre-production dry run and
            for the change-advisory evidence pack.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SourceTag,
        [Parameter(Mandatory)][string]$TargetTag,
        [Parameter(Mandatory)][hashtable]$SourceModels,
        [Parameter(Mandatory)][hashtable]$Sessions,
        [switch]$Preview
    )

    $flow = '{0}->{1}' -f $SourceTag, $TargetTag
    $targetPrefix = $Sessions[$TargetTag].Prefix

    $desired = $SourceModels[$SourceTag]
    $existing = Get-GalSyncTargetContact -Config $Config -TargetPrefix $targetPrefix -SourceTag $SourceTag

    Write-GalSyncLog -Level Info -Flow $flow -Message 'Reconciling.' `
        -Data @{ desired = $desired.Count; existing = $existing.Count }

    $plan = Get-GalSyncPlan -Config $Config -DesiredByAnchor $desired -ExistingByAnchor $existing

    Write-GalSyncLog -Level Info -Flow $flow -Action 'plan' -Message 'Plan computed.' -Data @{
        create = $plan.Create.Count; update = $plan.Update.Count; restore = $plan.Restore.Count
        stageDelete = $plan.StageDelete.Count; purge = $plan.Purge.Count; noChange = $plan.NoChange
    }

    $gateOk = Test-GalSyncSafetyGate -Config $Config -Plan $plan -Flow $flow `
                -SourceCount $desired.Count -TargetCount $existing.Count

    $results = [System.Collections.Generic.List[object]]::new()

    $record = {
        param($action, $anchor, $email, $status, $detail)
        $results.Add([pscustomobject]@{
            RunId = $script:RunId; Flow = $flow; Action = $action; Anchor = $anchor
            Email = $email; Status = $status; Detail = $detail
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        })
    }

    if (-not $gateOk) {
        & $record 'flow' '' '' 'Blocked' 'Safety gate violation'
        Add-GalSyncCounter -Name "$flow.blocked"
        return [pscustomobject]@{ Flow = $flow; Plan = $plan; Results = $results; Blocked = $true }
    }

    if ($Preview) {
        foreach ($item in $plan.Create)      { & $record 'Create'      $item.Anchor $item.Model.ExternalEmail 'Preview' '' }
        foreach ($item in $plan.Update)      { & $record 'Update'      $item.Anchor $item.Model.ExternalEmail 'Preview' '' }
        foreach ($item in $plan.Restore)     { & $record 'Restore'     $item.Anchor $item.Model.ExternalEmail 'Preview' '' }
        foreach ($item in $plan.StageDelete) { & $record 'StageDelete' $item.Anchor ([string]$item.Contact.ExternalEmailAddress) 'Preview' '' }
        foreach ($item in $plan.Purge)       { & $record 'Purge'       $item.Anchor ([string]$item.Contact.ExternalEmailAddress) 'Preview' "staged $($item.StagedOn.ToString('yyyy-MM-dd'))" }
        return [pscustomobject]@{ Flow = $flow; Plan = $plan; Results = $results; Blocked = $false }
    }

    $batchSize = [int]$Config.throttling.batchSize
    $batchDelay = [int]$Config.throttling.delayBetweenBatchesMs
    $processed = 0

    $apply = {
        param($action, $item)
        $anchor = $item.Anchor
        $email = if ($item.Model) { $item.Model.ExternalEmail } else { [string]$item.Contact.ExternalEmailAddress }
        try {
            switch ($action) {
                'Create'      { New-GalSyncContact -Config $Config -TargetPrefix $targetPrefix -Model $item.Model -Confirm:$false }
                'Update'      { Set-GalSyncContactAttribute -Config $Config -TargetPrefix $targetPrefix -Identity ([string]$item.Contact.Identity) -Model $item.Model -Confirm:$false }
                'Restore'     { Set-GalSyncContactAttribute -Config $Config -TargetPrefix $targetPrefix -Identity ([string]$item.Contact.Identity) -Model $item.Model -ClearPendingDelete -Confirm:$false }
                'StageDelete' { Set-GalSyncContactPendingDelete -Config $Config -TargetPrefix $targetPrefix -Identity ([string]$item.Contact.Identity) -Confirm:$false }
                'Purge'       { Remove-GalSyncContact -Config $Config -TargetPrefix $targetPrefix -Identity ([string]$item.Contact.Identity) -Confirm:$false }
            }
            & $record $action $anchor $email 'Success' ''
            Add-GalSyncCounter -Name "$flow.$action"
        }
        catch {
            & $record $action $anchor $email 'Failed' $_.Exception.Message
            Add-GalSyncCounter -Name "$flow.$action.failed"
            Write-GalSyncLog -Level Error -Flow $flow -Action $action -Anchor $anchor `
                -Message 'Write operation failed.' -Data @{ email = $email; detail = $_.Exception.Message }
        }

        $script:__batchCounter++
        if ($script:__batchCounter % $batchSize -eq 0 -and $batchDelay -gt 0) {
            Start-Sleep -Milliseconds $batchDelay
        }
    }

    $script:__batchCounter = 0

    # Order matters: restore before delete-staging so a rename never flaps,
    # and purge last so the grace window is evaluated against a settled set.
    foreach ($item in $plan.Restore)     { & $apply 'Restore'     $item; $processed++ }
    foreach ($item in $plan.Create)      { & $apply 'Create'      $item; $processed++ }
    foreach ($item in $plan.Update)      { & $apply 'Update'      $item; $processed++ }
    foreach ($item in $plan.StageDelete) { & $apply 'StageDelete' $item; $processed++ }
    foreach ($item in $plan.Purge)       { & $apply 'Purge'       $item; $processed++ }

    Write-GalSyncLog -Level Info -Flow $flow -Action 'apply' -Message 'Flow complete.' `
        -Data @{ processed = $processed; failed = @($results | Where-Object Status -EQ 'Failed').Count }

    [pscustomobject]@{ Flow = $flow; Plan = $plan; Results = $results; Blocked = $false }
}

function Invoke-GalSync {
    <#
        .SYNOPSIS
            Entry point. Connects both tenants, enumerates both directories and
            executes every enabled flow.
        .PARAMETER Preview
            Produce the change plan without writing anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$ReportPath,
        [switch]$Preview
    )

    $config = Get-GalSyncConfig -Path $ConfigPath
    $mode = if ($Preview) { 'Preview' } else { 'Apply' }

    Write-GalSyncLog -Level Info -Message 'GalSync run starting.' -Data @{
        mode = $mode
        flows = @($config.flows | Where-Object enabled | ForEach-Object { '{0}->{1}' -f $_.source, $_.target })
        host = $env:COMPUTERNAME
    }

    $sessions = @{}
    $allResults = [System.Collections.Generic.List[object]]::new()
    $failed = $false

    try {
        # 1. Exchange Online: both tenants, concurrently, via cmdlet prefixes.
        foreach ($tenant in $config.tenants) {
            $cert = Get-GalSyncCertificate -VaultName $config.runtime.keyVaultName -CertificateName $tenant.certificateName
            Connect-GalSyncExchange -Tenant $tenant -Certificate $cert
            $sessions[$tenant.tag] = @{ Tenant = $tenant; Prefix = $tenant.cmdletPrefix; Certificate = $cert }
        }

        # 2. Mailbox address sets, used to reject non-mailbox objects.
        $mailboxSets = @{}
        foreach ($tenant in $config.tenants) {
            $mailboxSets[$tenant.tag] = Get-GalSyncMailboxAddressSet -Prefix $tenant.cmdletPrefix `
                -RecipientTypeDetails ([string[]]$config.scope.requireMailboxRecipientTypes)
        }

        # 3. Microsoft Graph: one tenant at a time (single active context).
        $sourceTags = @($config.flows | Where-Object enabled | ForEach-Object { $_.source } | Select-Object -Unique)
        $sourceModels = @{}

        foreach ($tag in $sourceTags) {
            $tenant = Get-GalSyncTenant -Config $config -Tag $tag
            Connect-GalSyncGraph -Tenant $tenant -Certificate $sessions[$tag].Certificate
            try {
                $users = Get-GalSyncSourceUser -Config $config -SourceTag $tag -MailboxAddresses $mailboxSets[$tag]
                $models = @{}
                foreach ($user in $users) {
                    $model = ConvertTo-GalSyncContactModel -User $user -Config $config -SourceTag $tag
                    $model | Add-Member -NotePropertyName Hash -NotePropertyValue (Get-GalSyncModelHash -Model $model) -Force
                    if ($models.ContainsKey($model.Anchor)) { continue }
                    $models[$model.Anchor] = $model
                }
                $sourceModels[$tag] = $models
            }
            finally {
                Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            }
        }

        # 4. Execute flows.
        foreach ($flow in $config.flows | Where-Object enabled) {
            $result = Invoke-GalSyncFlow -Config $config -SourceTag $flow.source -TargetTag $flow.target `
                        -SourceModels $sourceModels -Sessions $sessions -Preview:$Preview
            $allResults.AddRange($result.Results)
            if ($result.Blocked) { $failed = $true }
        }
    }
    catch {
        $failed = $true
        Write-GalSyncLog -Level Error -Message 'GalSync run aborted.' -Data @{ detail = $_.Exception.Message; stack = $_.ScriptStackTrace }
        throw
    }
    finally {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

        if ($ReportPath) {
            $dir = Split-Path -Parent $ReportPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $allResults | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding utf8
            Write-GalSyncLog -Level Info -Message 'Run report written.' -Data @{ path = $ReportPath; rows = $allResults.Count }
        }

        $failures = @($allResults | Where-Object Status -EQ 'Failed').Count
        Write-GalSyncLog -Level Info -Message 'GalSync run finished.' -Data @{
            mode = $mode; runId = $script:RunId; operations = $allResults.Count
            failures = $failures; counters = (Get-GalSyncCounters)
        }
    }

    if ($failed -or (@($allResults | Where-Object Status -EQ 'Failed').Count -gt 0)) {
        throw "GalSync run $($script:RunId) completed with errors. See the run report for detail."
    }

    $allResults
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-GalSync', 'Invoke-GalSyncFlow', 'Get-GalSyncConfig', 'Get-GalSyncTenant',
    'Get-GalSyncCertificate', 'Connect-GalSyncGraph', 'Connect-GalSyncExchange',
    'Get-GalSyncSourceUser', 'ConvertTo-GalSyncContactModel', 'Get-GalSyncModelHash',
    'Get-GalSyncTargetContact', 'Get-GalSyncPlan', 'Test-GalSyncSafetyGate',
    'Test-GalSyncUserInScope', 'Write-GalSyncLog', 'Get-GalSyncCounters', 'Get-GalSyncRunId',
    'New-GalSyncContact', 'Set-GalSyncContactAttribute', 'Set-GalSyncContactPendingDelete',
    'Remove-GalSyncContact', 'Invoke-GalSyncExoCmdlet', 'Get-GalSyncMailboxAddressSet'
)
