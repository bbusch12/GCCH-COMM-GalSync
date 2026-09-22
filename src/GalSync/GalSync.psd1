@{
    RootModule        = 'GalSync.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a3f1c6d2-7b48-4c19-9c53-2f6d0b8e51aa'
    Author            = 'Contoso Cloud Engineering'
    CompanyName       = 'Contoso'
    Copyright         = '(c) Contoso. All rights reserved.'
    Description       = 'Cross-cloud GAL synchronisation between Microsoft 365 GCC High and Microsoft 365 Commercial.'
    PowerShellVersion = '7.2'

    RequiredModules   = @(
        @{ ModuleName = 'Az.Accounts';               ModuleVersion = '3.0.0' },
        @{ ModuleName = 'Az.KeyVault';               ModuleVersion = '6.0.0' },
        @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.19.0' },
        @{ ModuleName = 'Microsoft.Graph.Users';     ModuleVersion = '2.19.0' },
        @{ ModuleName = 'Microsoft.Graph.Groups';    ModuleVersion = '2.19.0' },
        @{ ModuleName = 'ExchangeOnlineManagement';  ModuleVersion = '3.4.0' }
    )

    FunctionsToExport = @(
        'Invoke-GalSync', 'Invoke-GalSyncFlow', 'Get-GalSyncConfig', 'Get-GalSyncTenant',
        'Get-GalSyncCertificate', 'Connect-GalSyncGraph', 'Connect-GalSyncExchange',
        'Get-GalSyncSourceUser', 'ConvertTo-GalSyncContactModel', 'Get-GalSyncModelHash',
        'Get-GalSyncTargetContact', 'Get-GalSyncPlan', 'Test-GalSyncSafetyGate',
        'Test-GalSyncUserInScope', 'Write-GalSyncLog', 'Get-GalSyncCounters', 'Get-GalSyncRunId',
        'New-GalSyncContact', 'Set-GalSyncContactAttribute', 'Set-GalSyncContactPendingDelete',
        'Remove-GalSyncContact', 'Invoke-GalSyncExoCmdlet', 'Get-GalSyncMailboxAddressSet'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{ PSData = @{ Tags = @('GALSync', 'GCCHigh', 'ExchangeOnline', 'CrossCloud') } }
}
