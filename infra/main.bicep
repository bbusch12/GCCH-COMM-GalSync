/*
  GalSync hosting platform - Azure Government (FedRAMP High / DoD IL4).

  Deploys the compute, secret store, audit store and monitoring for the
  cross-cloud GAL synchronisation service. All resources are in the covered
  environment; the only egress is outbound TLS to the two clouds' Graph and
  Exchange Online endpoints.

  Scope: resource group.
*/

targetScope = 'resourceGroup'

@description('Short workload name used to build resource names.')
@minLength(3)
@maxLength(12)
param workload string = 'galsync'

@description('Environment short code, e.g. prod, test.')
@allowed([ 'prod', 'test', 'dev' ])
param environmentCode string = 'prod'

@description('Azure Government region.')
param location string = resourceGroup().location

@description('Object IDs of the administrators who may manage certificates in the vault.')
param certificateAdminObjectIds array = []

@description('Cron-style schedule interval in hours for the sync runbook.')
@minValue(1)
@maxValue(24)
param syncIntervalHours int = 1

@description('Create the recurring schedule and link it to the runbook. Leave false until the runbook content is published and the pilot is signed off (Phase 6).')
param enableSchedule bool = false

@description('UTC start time for the first scheduled run (ISO 8601). Must be at least 5 minutes in the future when enableSchedule is true.')
param scheduleStartTime string = dateTimeAdd(utcNow(), 'PT1H')

@description('Days to retain audit logs in Log Analytics.')
@minValue(90)
param logRetentionDays int = 365

@description('Days to retain run reports in immutable blob storage.')
@minValue(365)
param auditImmutabilityDays int = 2555

@description('Email addresses notified when a sync run fails.')
param alertEmailRecipients array = []

@description('Resource tags.')
param tags object = {
  workload: 'GalSync GCCH-Commercial'
  dataClassification: 'CUI-adjacent directory metadata'
  complianceScope: 'DFARS 252.204-7012 / CMMC L2'
}

var suffix = '${workload}-${environmentCode}'
var storageName = toLower(replace('st${workload}${environmentCode}${uniqueString(resourceGroup().id)}', '-', ''))
var keyVaultName = take('kv-${suffix}-${uniqueString(resourceGroup().id)}', 24)

// ---------------------------------------------------------------- monitoring
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: logRetentionDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: { immediatePurgeDataOn30Days: false }
  }
}

// ------------------------------------------------------------------ key vault
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// -------------------------------------------------------------- audit storage
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: { name: 'Standard_GRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true }
        file: { enabled: true }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: { enabled: true, days: 90 }
  }
}

resource runReports 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'galsync-runreports'
  properties: {
    publicAccess: 'None'
  }
}

resource runReportsImmutability 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2023-05-01' = {
  parent: runReports
  name: 'default'
  properties: {
    immutabilityPeriodSinceCreationInDays: auditImmutabilityDays
    allowProtectedAppendWrites: true
  }
}

resource configContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'galsync-config'
  properties: {
    publicAccess: 'None'
  }
}

// ------------------------------------------------------------------ automation
resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: 'aa-${suffix}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
    disableLocalAuth: true
    encryption: { keySource: 'Microsoft.Automation' }
  }
}

var powerShell72Modules = [
  { name: 'Az.Accounts', version: '3.0.4' }
  { name: 'Az.KeyVault', version: '6.1.0' }
  { name: 'Az.Storage', version: '7.1.0' }
  { name: 'Microsoft.Graph.Authentication', version: '2.19.0' }
  { name: 'Microsoft.Graph.Users', version: '2.19.0' }
  { name: 'Microsoft.Graph.Groups', version: '2.19.0' }
  { name: 'ExchangeOnlineManagement', version: '3.4.0' }
]

// Serial import: Microsoft.Graph.Users/Groups depend on Microsoft.Graph.Authentication,
// and parallel imports fail intermittently when a dependency is not yet available.
@batchSize(1)
resource modules 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = [for m in powerShell72Modules: {
  parent: automation
  name: m.name
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/${m.name}/${m.version}'
      version: m.version
    }
  }
}]

resource syncRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automation
  name: 'Invoke-GalSync'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logProgress: true
    logVerbose: true
    description: 'Cross-cloud GAL synchronisation between GCC High and Commercial. Publish the content from src/ via the deployment pipeline.'
  }
}

resource syncSchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = if (enableSchedule) {
  parent: automation
  name: 'galsync-every-${syncIntervalHours}h'
  properties: {
    description: 'Recurring cross-cloud GAL synchronisation.'
    startTime: scheduleStartTime
    frequency: 'Hour'
    interval: syncIntervalHours
    timeZone: 'Etc/UTC'
  }
}

resource scheduleLink 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = if (enableSchedule) {
  parent: automation
  name: guid(automation.id, syncRunbook.name, 'galsync-every-${syncIntervalHours}h')
  properties: {
    runbook: { name: syncRunbook.name }
    schedule: { name: syncSchedule.name }
    parameters: {
      ConfigUri: '${storage.properties.primaryEndpoints.blob}galsync-config/galsync.config.json'
      AzureEnvironment: 'AzureUSGovernment'
    }
  }
}

// ------------------------------------------------------------------------ RBAC
var keyVaultSecretsUser = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var keyVaultCertificateUser = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba')
var keyVaultAdministrator = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')
var storageBlobDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource kvSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, automation.id, 'kv-secrets-user')
  properties: {
    roleDefinitionId: keyVaultSecretsUser
    principalId: automation.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource kvCertUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, automation.id, 'kv-cert-user')
  properties: {
    roleDefinitionId: keyVaultCertificateUser
    principalId: automation.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource kvAdminAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for adminId in certificateAdminObjectIds: {
  scope: keyVault
  name: guid(keyVault.id, adminId, 'kv-admin')
  properties: {
    roleDefinitionId: keyVaultAdministrator
    principalId: adminId
    principalType: 'User'
  }
}]

resource blobWriteAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, automation.id, 'blob-contributor')
  properties: {
    roleDefinitionId: storageBlobDataContributor
    principalId: automation.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ------------------------------------------------------------- diagnostics
resource automationDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: automation
  name: 'to-law'
  properties: {
    workspaceId: workspace.id
    logs: [
      { category: 'JobLogs', enabled: true }
      { category: 'JobStreams', enabled: true }
      { category: 'AuditEvent', enabled: true }
    ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: keyVault
  name: 'to-law'
  properties: {
    workspaceId: workspace.id
    logs: [ { categoryGroup: 'audit', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

resource storageBlobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: blobService
  name: 'to-law'
  properties: {
    workspaceId: workspace.id
    logs: [
      { category: 'StorageWrite', enabled: true }
      { category: 'StorageDelete', enabled: true }
    ]
  }
}

// ----------------------------------------------------------------- alerting
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(alertEmailRecipients)) {
  name: 'ag-${suffix}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take(workload, 12)
    enabled: true
    emailReceivers: [for (email, i) in alertEmailRecipients: {
      name: 'email${i}'
      emailAddress: email
      useCommonAlertSchema: true
    }]
  }
}

resource failureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (!empty(alertEmailRecipients)) {
  name: 'alert-${suffix}-run-failure'
  location: location
  tags: tags
  properties: {
    displayName: 'GalSync run failure or safety-gate block'
    description: 'Fires when a sync job fails, is blocked by the safety gate, or logs a write error.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    scopes: [ workspace.id ]
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category in ("JobLogs", "JobStreams")
| where RunbookName_s == "Invoke-GalSync"
| where ResultType == "Failed" or StreamType_s == "Error" or ResultDescription has "safety-gate"
| summarize Failures = count() by RunbookName_s, JobId_g
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    autoMitigate: true
    actions: { actionGroups: [ actionGroup.id ] }
  }
}

resource stalenessAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (!empty(alertEmailRecipients)) {
  name: 'alert-${suffix}-no-successful-run'
  location: location
  tags: tags
  properties: {
    displayName: 'GalSync has not completed successfully'
    description: 'Fires when no successful sync run has been observed in the last 6 hours.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT6H'
    scopes: [ workspace.id ]
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobLogs"
| where RunbookName_s == "Invoke-GalSync" and ResultType == "Completed"
| summarize Successes = count()
'''
          timeAggregation: 'Count'
          operator: 'LessThanOrEqual'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    autoMitigate: true
    actions: { actionGroups: [ actionGroup.id ] }
  }
}

// ------------------------------------------------------------------- outputs
output automationAccountName string = automation.name
output automationPrincipalId string = automation.identity.principalId
output keyVaultName string = keyVault.name
output storageAccountName string = storage.name
output workspaceResourceId string = workspace.id
output configBlobUri string = '${storage.properties.primaryEndpoints.blob}galsync-config/galsync.config.json'
