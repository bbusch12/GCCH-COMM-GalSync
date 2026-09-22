using './main.bicep'

param workload = 'galsync'
param environmentCode = 'prod'
param location = 'usgovarizona'
param syncIntervalHours = 1
param logRetentionDays = 365
param auditImmutabilityDays = 2555
param certificateAdminObjectIds = [
  // Object IDs of the PIM-eligible platform administrators
]
param alertEmailRecipients = [
  'm365-operations@ttmtechdev.com'
]
param enableSchedule = false
// param scheduleStartTime = '2026-10-15T11:00:00Z'   // optional: pin a specific UTC time; otherwise defaults to now + 1h
