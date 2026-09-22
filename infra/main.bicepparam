using './main.bicep'

param workload = 'galsync'
param environmentCode = 'prod'
param location = 'usgovvirginia'
param scheduleStartTime = '2026-09-08T06:00:00Z'
param syncIntervalHours = 1
param logRetentionDays = 365
param auditImmutabilityDays = 2555
param certificateAdminObjectIds = [
  // Object IDs of the PIM-eligible platform administrators
]
param alertEmailRecipients = [
  'm365-operations@contosodefense.us'
]
