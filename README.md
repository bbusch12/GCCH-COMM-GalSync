# GCCH ↔ Commercial GAL Synchronisation

Bidirectional Global Address List synchronisation, cross-cloud free/busy, and allow-listed Teams federation between a Microsoft 365 **GCC High** tenant and a Microsoft 365 **Commercial** tenant.

Reads with Microsoft Graph, writes with Exchange Online PowerShell (organisational contacts are read-only in Graph), runs entirely inside Azure Government.

## Start here

| Document | What it is for |
|---|---|
| [docs/GalSync-Design.md](docs/GalSync-Design.md) | Architecture, attribute allow list, compliance mapping, implementation plan |
| [docs/Operations-Runbook.md](docs/Operations-Runbook.md) | Day-two operations, incident response, certificate rotation, DR |

## Layout

```
config/galsync.config.json              Tenants, scope, attribute allow list, safety envelope
src/GalSync/                            Sync engine (PowerShell module)
src/Invoke-GalSyncRunbook.ps1           Azure Automation entry point
scripts/New-GalSyncAppRegistration.ps1  Per-tenant app + certificate + least-privilege grants
scripts/Test-GalSyncPrereqs.ps1         Pre-flight validation and change preview
scripts/Set-CrossCloudFreeBusy.ps1      Cross-Tenant Access Policy (with legacy bridge)
scripts/Set-TeamsFederation.ps1         Allow-listed Teams external access
infra/main.bicep                        Automation, Key Vault, storage, Log Analytics, alerts
infra/network.bicep                     Azure Firewall egress policy (optional)
tests/GalSync.Tests.ps1                 Pester tests — 30 tests, no tenant required
```

## Quick start

```powershell
# 1. Platform (Azure Government). enableSchedule stays false until Phase 6;
#    copy keyVaultName / storageAccountName / workspaceResourceId from the outputs into the config runtime block
az deployment group create -g rg-galsync-prod -f infra/main.bicep -p infra/main.bicepparam

# 2. Identity - once per tenant
./scripts/New-GalSyncAppRegistration.ps1 -Cloud USGov  -TenantId <gcch-guid> -DisplayName GalSync-GCCH `
    -KeyVaultName <vault> -CertificateName galsync-gcch-app
./scripts/New-GalSyncAppRegistration.ps1 -Cloud Global -TenantId <comm-guid> -DisplayName GalSync-COMM `
    -KeyVaultName <vault> -CertificateName galsync-comm-app

# 3. Fill in config/galsync.config.json (tenant IDs, app IDs, scoping group IDs)

# 4. Validate - nothing is written
./scripts/Test-GalSyncPrereqs.ps1 -ConfigPath ./config/galsync.config.json

# 5. Preview, then go
Invoke-GalSync -ConfigPath ./config/galsync.config.json -Preview
Invoke-GalSync -ConfigPath ./config/galsync.config.json
```

Then configure availability and federation in **both** tenants:

```powershell
./scripts/Set-CrossCloudFreeBusy.ps1 -LocalCloud USGov -PartnerCloud Global `
    -LocalTenantId <gcch-guid> -PartnerTenantId <comm-guid> -PartnerSmtpDomain contoso.com -Mode XTAP
./scripts/Set-TeamsFederation.ps1 -Cloud USGov -AllowedDomain contoso.com
```

## Design principles

- **Opt-in, not opt-out.** A user is published only if they are in the include group and pass every exclusion test.
- **One place enforces the boundary.** `ConvertTo-GalSyncContactModel` is the only function that reads a source attribute.
- **Only manage what you created.** Every target read is filtered on a provenance stamp; contacts created by other means are invisible.
- **Fail closed.** Missing export-control data aborts the flow. Anomalous volume blocks the flow. Deletion is staged for 30 days.
- **Zero-write steady state.** Hash comparison means an unchanged directory produces an empty run.

## Tests

```powershell
Invoke-Pester ./tests -Output Detailed
```

30 tests covering scope filtering, attribute projection, hash stability, the reconciliation plan (create / update / restore / stage / purge) and the safety gate. No tenant connectivity required.

## Timeline note

Cross-tenant free/busy, MailTips and calendar sharing have moved from Exchange Web Services to the Microsoft 365 Cross-Tenant Access Policy. EWS-backed sharing will begin gradual disablement on **1 October 2026**; full shutdown is **1 April 2027**. Configure the policy path; use the organisation relationship only as a bridge.
