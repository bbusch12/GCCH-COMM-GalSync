<#
    Pester tests for the deterministic parts of the sync engine: scope
    filtering, attribute projection, change detection, the reconciliation
    plan and the safety gate. No tenant connectivity required.

    Run:  Invoke-Pester ./tests -Output Detailed
#>

BeforeAll {
    # Import the .psm1 directly so the tests do not need Az/Graph/EXO present.
    Import-Module "$PSScriptRoot/../src/GalSync/GalSync.psm1" -Force

    $script:Config = Get-GalSyncConfig -Path "$PSScriptRoot/../config/galsync.config.json"

    function New-TestUser {
        param(
            [string]$Id = [guid]::NewGuid().ToString(),
            [string]$Mail = 'jane.doe@contosodefense.us',
            [string]$Upn = 'jane.doe@contosodefense.us',
            [string]$DisplayName = 'Jane Doe',
            [bool]$AccountEnabled = $true,
            [string]$UserType = 'Member',
            [string]$JobTitle = 'Systems Engineer',
            [string]$Department = 'Engineering',
            [string]$CompanyName = 'Contoso Defense',
            [string]$OfficeLocation = 'Building 4',
            [string]$MobilePhone = '+1 555 0100'
        )
        [pscustomobject]@{
            Id = $Id; Mail = $Mail; UserPrincipalName = $Upn; DisplayName = $DisplayName
            GivenName = 'Jane'; Surname = 'Doe'; AccountEnabled = $AccountEnabled
            UserType = $UserType; JobTitle = $JobTitle; Department = $Department
            CompanyName = $CompanyName; OfficeLocation = $OfficeLocation
            City = 'Chicago'; State = 'IL'; Country = 'US'
            BusinessPhones = @('+1 555 0199'); MobilePhone = $MobilePhone
        }
    }

    function New-TestContact {
        param(
            [string]$Anchor,
            [string]$Hash = 'nomatch',
            [string]$Pending = '',
            [string]$Identity = 'gs-gcch-000000000000',
            [string]$Email = 'jane.doe@contosodefense.us'
        )
        [pscustomobject]@{
            Identity = $Identity
            ExternalEmailAddress = $Email
            CustomAttribute15 = 'GALSYNC'
            CustomAttribute14 = 'GCCH'
            CustomAttribute13 = $Anchor
            CustomAttribute12 = $Hash
            CustomAttribute11 = $Pending
        }
    }
}

Describe 'Get-GalSyncConfig' {
    It 'loads the shipped configuration' {
        $script:Config.tenants.Count | Should -Be 2
    }

    It 'rejects an attribute that is both allowed and never-sync' {
        $bad = $script:Config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $bad.attributeMap.allowed += 'employeeId'
        $path = Join-Path $TestDrive 'bad.json'
        $bad | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        { Get-GalSyncConfig -Path $path } | Should -Throw '*neverSync*'
    }

    It 'rejects a flow that points at an unknown tenant' {
        $bad = $script:Config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $bad.flows[0].target = 'NOPE'
        $path = Join-Path $TestDrive 'badflow.json'
        $bad | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        { Get-GalSyncConfig -Path $path } | Should -Throw '*unknown tenant tag*'
    }
}

Describe 'Test-GalSyncUserInScope' {
    It 'admits a normal, licensed, enabled user' {
        $user = New-TestUser
        $mailboxes = [System.Collections.Generic.HashSet[string]]::new([string[]]@($user.Mail), [StringComparer]::OrdinalIgnoreCase)
        Test-GalSyncUserInScope -User $user -Scope $script:Config.scope -MailboxAddresses $mailboxes | Should -BeTrue
    }

    It 'rejects a disabled account' {
        $user = New-TestUser -AccountEnabled $false
        Test-GalSyncUserInScope -User $user -Scope $script:Config.scope | Should -BeFalse
    }

    It 'rejects a guest' {
        $user = New-TestUser -UserType 'Guest'
        Test-GalSyncUserInScope -User $user -Scope $script:Config.scope | Should -BeFalse
    }

    It 'rejects service and admin naming patterns' {
        foreach ($upn in 'svc-backup@contosodefense.us', 'adm-jdoe@contosodefense.us', 'breakglass1@contosodefense.us') {
            $user = New-TestUser -Upn $upn
            Test-GalSyncUserInScope -User $user -Scope $script:Config.scope | Should -BeFalse -Because "$upn must not be published"
        }
    }

    It 'rejects the onmicrosoft routing domains' {
        $user = New-TestUser -Mail 'jane.doe@contosodefense.onmicrosoft.us'
        Test-GalSyncUserInScope -User $user -Scope $script:Config.scope | Should -BeFalse
    }

    It 'rejects a user with no matching mailbox' {
        $user = New-TestUser
        $mailboxes = [System.Collections.Generic.HashSet[string]]::new([string[]]@('someone.else@contosodefense.us'), [StringComparer]::OrdinalIgnoreCase)
        Test-GalSyncUserInScope -User $user -Scope $script:Config.scope -MailboxAddresses $mailboxes | Should -BeFalse
    }

    It 'honours the exclude group over the include group' {
        $user = New-TestUser
        $include = [System.Collections.Generic.HashSet[string]]::new([string[]]@($user.Id), [StringComparer]::OrdinalIgnoreCase)
        $exclude = [System.Collections.Generic.HashSet[string]]::new([string[]]@($user.Id), [StringComparer]::OrdinalIgnoreCase)
        Test-GalSyncUserInScope -User $user -Scope $script:Config.scope -IncludeIds $include -ExcludeIds $exclude | Should -BeFalse
    }

    It 'reports the reason for exclusion' {
        $reason = ''
        $user = New-TestUser -AccountEnabled $false
        Test-GalSyncUserInScope -User $user -Scope $script:Config.scope -Reason ([ref]$reason) | Out-Null
        $reason | Should -Be 'account-disabled'
    }
}

Describe 'ConvertTo-GalSyncContactModel' {
    It 'projects only the allow-listed attributes' {
        $model = ConvertTo-GalSyncContactModel -User (New-TestUser) -Config $script:Config -SourceTag 'GCCH'
        $model.Title | Should -Be 'Systems Engineer'
        $model.Department | Should -Be 'Engineering'
        $model.Company | Should -Be 'Contoso Defense'
    }

    It 'suppresses attributes that are not opted in' {
        $model = ConvertTo-GalSyncContactModel -User (New-TestUser) -Config $script:Config -SourceTag 'GCCH'
        $model.Office | Should -BeNullOrEmpty
        $model.MobilePhone | Should -BeNullOrEmpty
        $model.Phone | Should -BeNullOrEmpty
        $model.City | Should -BeNullOrEmpty
    }

    It 'applies the tenant display-name suffix' {
        $model = ConvertTo-GalSyncContactModel -User (New-TestUser) -Config $script:Config -SourceTag 'GCCH'
        $model.DisplayName | Should -Be 'Jane Doe (Contoso Defense)'
    }

    It 'produces a deterministic, collision-resistant name and alias' {
        $user = New-TestUser -Id '0f9c1a2b-3d4e-5f60-7182-93a4b5c6d7e8'
        $model = ConvertTo-GalSyncContactModel -User $user -Config $script:Config -SourceTag 'GCCH'
        $model.Name  | Should -Be 'gs-gcch-0f9c1a2b3d4e'
        $model.Alias | Should -Be 'gs_gcch_0f9c1a2b3d4e'
    }
}

Describe 'Get-GalSyncModelHash' {
    It 'is stable for identical input' {
        $a = ConvertTo-GalSyncContactModel -User (New-TestUser) -Config $script:Config -SourceTag 'GCCH'
        $b = ConvertTo-GalSyncContactModel -User (New-TestUser) -Config $script:Config -SourceTag 'GCCH'
        Get-GalSyncModelHash -Model $a | Should -Be (Get-GalSyncModelHash -Model $b)
    }

    It 'changes when a synced attribute changes' {
        $a = ConvertTo-GalSyncContactModel -User (New-TestUser) -Config $script:Config -SourceTag 'GCCH'
        $b = ConvertTo-GalSyncContactModel -User (New-TestUser -JobTitle 'Principal Engineer') -Config $script:Config -SourceTag 'GCCH'
        Get-GalSyncModelHash -Model $a | Should -Not -Be (Get-GalSyncModelHash -Model $b)
    }

    It 'does not change when a non-synced attribute changes' {
        $a = ConvertTo-GalSyncContactModel -User (New-TestUser) -Config $script:Config -SourceTag 'GCCH'
        $b = ConvertTo-GalSyncContactModel -User (New-TestUser -MobilePhone '+1 555 0999') -Config $script:Config -SourceTag 'GCCH'
        Get-GalSyncModelHash -Model $a | Should -Be (Get-GalSyncModelHash -Model $b)
    }
}

Describe 'Get-GalSyncPlan' {
    BeforeEach {
        $script:User = New-TestUser
        $script:Model = ConvertTo-GalSyncContactModel -User $script:User -Config $script:Config -SourceTag 'GCCH'
        $script:Model | Add-Member -NotePropertyName Hash -NotePropertyValue (Get-GalSyncModelHash -Model $script:Model) -Force
        $script:Desired = @{ $script:Model.Anchor = $script:Model }
    }

    It 'creates when the target has nothing' {
        $plan = Get-GalSyncPlan -Config $script:Config -DesiredByAnchor $script:Desired -ExistingByAnchor @{}
        $plan.Create.Count | Should -Be 1
        $plan.Update.Count | Should -Be 0
    }

    It 'does nothing when the hash matches' {
        $existing = @{ $script:Model.Anchor = (New-TestContact -Anchor $script:Model.Anchor -Hash $script:Model.Hash) }
        $plan = Get-GalSyncPlan -Config $script:Config -DesiredByAnchor $script:Desired -ExistingByAnchor $existing
        $plan.NoChange | Should -Be 1
        $plan.Update.Count | Should -Be 0
    }

    It 'updates when the hash differs' {
        $existing = @{ $script:Model.Anchor = (New-TestContact -Anchor $script:Model.Anchor -Hash 'stale') }
        $plan = Get-GalSyncPlan -Config $script:Config -DesiredByAnchor $script:Desired -ExistingByAnchor $existing
        $plan.Update.Count | Should -Be 1
    }

    It 'stages a delete when the source object disappears' {
        $existing = @{ 'orphan-anchor' = (New-TestContact -Anchor 'orphan-anchor' -Hash 'x') }
        $plan = Get-GalSyncPlan -Config $script:Config -DesiredByAnchor @{} -ExistingByAnchor $existing
        $plan.StageDelete.Count | Should -Be 1
        $plan.Purge.Count | Should -Be 0
    }

    It 'does not purge before the grace period elapses' {
        $recent = 'PENDINGDELETE:{0}' -f (Get-Date).ToUniversalTime().AddDays(-5).ToString('yyyyMMdd')
        $existing = @{ 'orphan-anchor' = (New-TestContact -Anchor 'orphan-anchor' -Pending $recent) }
        $plan = Get-GalSyncPlan -Config $script:Config -DesiredByAnchor @{} -ExistingByAnchor $existing
        $plan.Purge.Count | Should -Be 0
        $plan.StageDelete.Count | Should -Be 0
    }

    It 'purges once the grace period has elapsed' {
        $old = 'PENDINGDELETE:{0}' -f (Get-Date).ToUniversalTime().AddDays(-31).ToString('yyyyMMdd')
        $existing = @{ 'orphan-anchor' = (New-TestContact -Anchor 'orphan-anchor' -Pending $old) }
        $plan = Get-GalSyncPlan -Config $script:Config -DesiredByAnchor @{} -ExistingByAnchor $existing
        $plan.Purge.Count | Should -Be 1
    }

    It 'restores a staged object that comes back into scope' {
        $stamp = 'PENDINGDELETE:{0}' -f (Get-Date).ToUniversalTime().AddDays(-2).ToString('yyyyMMdd')
        $existing = @{ $script:Model.Anchor = (New-TestContact -Anchor $script:Model.Anchor -Hash $script:Model.Hash -Pending $stamp) }
        $plan = Get-GalSyncPlan -Config $script:Config -DesiredByAnchor $script:Desired -ExistingByAnchor $existing
        $plan.Restore.Count | Should -Be 1
        $plan.Purge.Count | Should -Be 0
    }
}

Describe 'Test-GalSyncSafetyGate' {
    BeforeEach {
        $script:EmptyPlan = [ordered]@{
            Create = [System.Collections.Generic.List[object]]::new()
            Update = [System.Collections.Generic.List[object]]::new()
            Restore = [System.Collections.Generic.List[object]]::new()
            StageDelete = [System.Collections.Generic.List[object]]::new()
            Purge = [System.Collections.Generic.List[object]]::new()
            NoChange = 0
        }
    }

    It 'passes a benign plan' {
        $script:EmptyPlan.Create.Add([pscustomobject]@{})
        Test-GalSyncSafetyGate -Config $script:Config -Plan $script:EmptyPlan -SourceCount 500 -TargetCount 500 -Flow 'T' -ErrorAction SilentlyContinue |
            Should -BeTrue
    }

    It 'blocks when the source directory comes back empty' {
        Test-GalSyncSafetyGate -Config $script:Config -Plan $script:EmptyPlan -SourceCount 0 -TargetCount 500 -Flow 'T' -ErrorAction SilentlyContinue |
            Should -BeFalse
    }

    It 'blocks a mass deletion by absolute count' {
        1..60 | ForEach-Object { $script:EmptyPlan.StageDelete.Add([pscustomobject]@{}) }
        Test-GalSyncSafetyGate -Config $script:Config -Plan $script:EmptyPlan -SourceCount 5000 -TargetCount 5000 -Flow 'T' -ErrorAction SilentlyContinue |
            Should -BeFalse
    }

    It 'blocks a mass deletion by percentage of the target set' {
        1..30 | ForEach-Object { $script:EmptyPlan.StageDelete.Add([pscustomobject]@{}) }
        Test-GalSyncSafetyGate -Config $script:Config -Plan $script:EmptyPlan -SourceCount 100 -TargetCount 100 -Flow 'T' -ErrorAction SilentlyContinue |
            Should -BeFalse
    }

    It 'blocks a runaway creation burst' {
        1..600 | ForEach-Object { $script:EmptyPlan.Create.Add([pscustomobject]@{}) }
        Test-GalSyncSafetyGate -Config $script:Config -Plan $script:EmptyPlan -SourceCount 600 -TargetCount 100 -Flow 'T' -ErrorAction SilentlyContinue |
            Should -BeFalse
    }
}
