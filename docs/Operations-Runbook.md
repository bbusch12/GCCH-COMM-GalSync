# GalSync Operations Runbook
## Cross-cloud GAL synchronisation — GCC High ↔ Commercial

**Audience:** Microsoft 365 operations
**Service owner:** _to be assigned_
**Escalation:** Cloud platform engineering, then security operations if the boundary or credentials are implicated

---

## 1. What this service does

Every hour, an Azure Government Automation runbook reads the in-scope mailbox users of each tenant and maintains a matching mail contact in the other tenant. Contacts it did not create are invisible to it. A run that finds nothing to change writes nothing.

**Normal indicators**

- A completed job every hour in `aa-galsync-prod`
- Job output ending with `GalSync run finished` and `failures: 0`
- A CSV in the `galsync-runreports` container for every run
- No active alerts

---

## 2. Daily check (2 minutes)

```powershell
Connect-AzAccount -Environment AzureUSGovernment
Get-AzAutomationJob -ResourceGroupName rg-galsync-prod -AutomationAccountName aa-galsync-prod `
    -RunbookName Invoke-GalSync | Sort-Object StartTime -Descending | Select-Object -First 6 |
    Format-Table StartTime, EndTime, Status
```

Anything other than `Completed` in the last six runs goes to §4.

---

## 3. Common tasks

### 3.1 Add a person to the partner GAL

Add the user to the tenant's **include** security group. They appear after the next run (≤ 1 hour). Nothing else is required.

### 3.2 Remove a person from the partner GAL

Remove them from the include group, or add them to the exclude group. The next run hides the contact and stamps it `PENDINGDELETE`. It is purged 30 days later. To remove immediately, hide first (that is what the run does) and then delete the contact manually in the target tenant — do not delete the source user's Entra object to force it.

### 3.3 Withhold someone for export-control reasons

Set the Entra custom security attribute `ExportControl / ItarRestricted = true` on the user in their home tenant. This takes precedence over include-group membership. Verify in the next run log that the exclusion count under `export-control-flag` increased.

### 3.4 Run on demand

```powershell
Start-AzAutomationRunbook -ResourceGroupName rg-galsync-prod -AutomationAccountName aa-galsync-prod `
    -Name Invoke-GalSync -Parameters @{ ConfigUri = '<config blob uri>' }
```

### 3.5 See what a run *would* do, without writing

```powershell
Start-AzAutomationRunbook -ResourceGroupName rg-galsync-prod -AutomationAccountName aa-galsync-prod `
    -Name Invoke-GalSync -Parameters @{ ConfigUri = '<config blob uri>'; Preview = $true }
```

Or, from an admin workstation with the modules installed:

```powershell
./scripts/Test-GalSyncPrereqs.ps1 -ConfigPath ./config/galsync.config.json
```

### 3.6 Change the published attribute set

1. Edit `attributeMap` in `config/galsync.config.json` — enabling an optional attribute, or removing one from `allowed`.
2. Raise it as a change with the security and export-control functions. **Adding an attribute is a change to what crosses a compliance boundary.**
3. Run in preview. Every existing contact will appear as an update, because the hash covers the attribute set — that is expected.
4. Publish the configuration blob and let the next scheduled run apply it. Watch the create/update ceilings.

### 3.7 Pause or resume the scheduled sync

The hourly schedule exists only once `infra/main.bicep` has been deployed with `enableSchedule = true` (design Phase 6). Redeploying with `enableSchedule = false` does not remove or disable an existing schedule: an incremental deployment skips the resource rather than deleting it. To pause and resume, change the schedule directly:

```powershell
Set-AzAutomationSchedule -ResourceGroupName rg-galsync-prod -AutomationAccountName aa-galsync-prod `
    -Name galsync-every-1h -IsEnabled $false    # pause; use $true to resume
```

When redeploying the template with the schedule enabled, leave `scheduleStartTime` at its default (one hour after deployment) or supply a future UTC time. A start time in the past fails the deployment.

---

## 4. Incident response

### 4.1 The run failed

1. Read the job output. The last record is a JSON summary with counters.
2. Search for `"level":"Error"`. Per-object failures name the anchor and the address.
3. Classify:

| Symptom | Likely cause | Action |
|---|---|---|
| `AADSTS700027` / certificate errors | Certificate expired or rotated on one side only | §5 certificate rotation |
| `401` / `Insufficient privileges` | App role or Exchange Recipient Administrator assignment removed | Re-apply the grants from `New-GalSyncAppRegistration.ps1`; investigate *who removed it* |
| `Connection ... could not be established` to one cloud only | Egress blocked; firewall rule or FQDN change | Check `infra/network.bicep` rule group; run `Test-GalSyncPrereqs.ps1` connectivity section |
| Throttling after retries | Bulk change in flight | Reduce `throttling.batchSize`, raise `delayBetweenBatchesMs`, re-run |
| A handful of per-object failures | Alias collision or invalid attribute value | Inspect the run report rows with `Status = Failed`; usually a source data problem |

### 4.2 The safety gate blocked a flow

**This is the design working.** No writes occurred. The log record names the violation and the numbers.

1. Establish whether the source really changed. Compare `inScope` in the current run's enumeration record with the previous run's.
2. If the source count collapsed: suspect the include group, a Graph permission, or a directory outage. Fix the cause. Do **not** raise the thresholds to get past it.
3. If the change is genuine (a real bulk offboarding, or the first production expansion):
   - raise the specific ceiling in `config/galsync.config.json`,
   - record the reason and the approver in the change ticket,
   - run once in preview and confirm the plan matches expectation,
   - run for real,
   - **lower the ceiling again in the same change window.**

### 4.3 Contacts were deleted that should not have been

Deletion is staged, so recovery is usually free:

- Still within the 30-day grace period: re-add the users to the include group. The next run restores the contacts (clears the stamp, unhides, refreshes attributes). No data is lost.
- Already purged: the contacts are recreated by the next run once the users are back in the include group. New objects, same content; the anchor is preserved because it comes from the source user's object ID.

Then find out why they left scope, using the exclusion counts in the enumeration log record.

### 4.4 Free/busy stopped working

1. Confirm it is not the GAL — a contact resolving but availability failing is a policy problem, not a sync problem.
2. Run `Set-CrossCloudFreeBusy.ps1 -Mode AuditOnly` in **both** tenants.
3. Confirm both sides still have: the partner cloud endpoint enabled, the partner tenant added by ID, and the inbound capabilities present.
4. Check whether a legacy organisation relationship, availability address space or sharing policy has reappeared — **legacy configuration takes precedence** over the policy path and will silently shadow it.
5. Remember the EWS retirement dates: after 1 April 2027, any remaining legacy path simply stops working.

### 4.5 Teams chat stopped working

Check `Get-CsTenantFederationConfiguration` in both tenants: `AllowFederatedUsers` true, partner domains present in `AllowedDomains`, partner domains absent from `BlockedDomains`. Changes take up to 24 hours to propagate. If a user-level external access policy is in use, confirm the user's group assignment.

---

## 5. Certificate rotation

Certificates are 12-month and rotate at 9 months. Rotation is per tenant and can be done independently.

1. Generate and register the new credential:
   ```powershell
   ./scripts/New-GalSyncAppRegistration.ps1 -Cloud USGov -TenantId <guid> `
       -DisplayName 'GalSync-GCCH-2027' -KeyVaultName <vault> -CertificateName galsync-gcch-app
   ```
   To rotate in place rather than create a new application, add the new certificate to the existing app registration and import it into Key Vault under the same certificate name — Key Vault versions it, and the service always reads the current version.
2. Run `Test-GalSyncPrereqs.ps1` and confirm the new thumbprint and expiry.
3. Let one scheduled run complete successfully.
4. Remove the old key credential from the application registration.
5. Record the new expiry in the operations calendar.

**Do not** delete the old credential before step 3 succeeds.

---

## 6. Disaster recovery

| Loss | Recovery |
|---|---|
| Automation account | Redeploy `infra/main.bicep` with `enableSchedule = false`, re-grant the managed identity RBAC, republish the runbook content and re-import modules (including GalSync), then redeploy with `enableSchedule = true` — the schedule link cannot be created against an unpublished runbook. Target: 4 hours. No data loss — the state lives on the contacts themselves |
| Key Vault | Soft delete with purge protection is enabled; recover the vault. If the certificates are unrecoverable, re-run `New-GalSyncAppRegistration.ps1` per tenant |
| Configuration blob | Restored from source control; blob versioning is enabled |
| Both tenants' contacts deleted | Re-run the service. It rebuilds the full contact set from the source directories. Watch the create ceiling — raise it deliberately for the rebuild |
| Run reports | Immutable container with append protection; retained for the configured period and not deletable within it |

The service holds no state of its own. Everything needed to rebuild is in the source directories, source control and Key Vault. That is deliberate.

---

## 7. Quarterly review

Record the outcome of each item:

- [ ] Attribute allow list — still the minimum necessary? Any optional attribute enabled since last review, and was it approved?
- [ ] Include and exclude group membership — reconcile against HR and export-control records
- [ ] Export-control flags — spot-check that flagged users are absent from the partner GAL
- [ ] Cross-Tenant Access Policy capabilities in both tenants — unchanged, and still scoped to the intended group?
- [ ] Teams federation allow list in both tenants — no unexplained additions
- [ ] Legacy sharing objects — run `-Mode AuditOnly` in both tenants; confirm none have reappeared
- [ ] Certificate expiry dates and the next rotation window
- [ ] Safety thresholds — still appropriate for the current population size?
- [ ] Run reports for the quarter — retrievable and reconciling with Log Analytics
- [ ] Residual risk register in the design document — still accurate?

---

## 8. Contacts

| Role | Name | Escalation |
|---|---|---|
| Service owner | | |
| GCC High tenant owner | | |
| Commercial tenant owner | | |
| Export control | | |
| Security operations | | |
