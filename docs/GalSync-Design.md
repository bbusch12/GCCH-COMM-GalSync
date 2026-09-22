# Cross-Cloud GAL Synchronisation
## Microsoft 365 GCC High to Microsoft 365 Commercial — Architecture and Compliance Design

**Version:** 1.0
**Date:** 28 August 2026
**Classification:** Internal — describes a cross-boundary connection subject to DFARS 252.204-7012

---

## 1. Executive summary

Users in the GCC High tenant and users in the Commercial tenant cannot see each other in the Global Address List, cannot resolve each other's availability, and cannot start a Teams chat without knowing an address by heart. The two tenants sit in different Microsoft clouds, so none of the native single-cloud mechanisms — Entra cross-tenant synchronisation, B2B direct connect, a shared on-premises forest — bridge them.

This design delivers three things:

1. **A bidirectional GAL** — in-scope mailbox users in each tenant appear as mail contacts in the other, refreshed hourly, driven by a purpose-built synchronisation service running entirely inside Azure Government.
2. **Cross-cloud availability** — free/busy, MailTips and calendar sharing, configured on the Microsoft 365 Cross-Tenant Access Policy path that replaces the retiring Exchange Web Services mechanism.
3. **Allow-listed Teams federation** — external access between the two tenants restricted to each other's domains, with no open federation and no consumer Teams.

The design is deliberately conservative about what crosses the boundary. Seven directory attributes are published, by name, from an explicit allow list. Membership is opt-in by security group, with a second security group and an Entra custom security attribute available as export-control exclusions. Every write is preceded by a hash comparison, so a steady-state run performs zero writes; every run emits structured audit evidence to an immutable store; and a circuit breaker refuses any run that would create or delete beyond a configured envelope.

No third-party service is introduced. No credential, token, or source directory object leaves the Azure Government boundary. The only egress is outbound TLS from Azure Government to two named Microsoft endpoints in the worldwide cloud.

---

## 2. Requirements

| # | Requirement | How it is met |
|---|---|---|
| R1 | Users in each tenant find users of the other in the GAL | Mail contacts created and maintained by the sync service (§5) |
| R2 | Synchronisation is bidirectional, users only | Two directional flows; groups, rooms and equipment are out of scope by configuration |
| R3 | Only approved directory attributes cross the boundary | Attribute allow list enforced in a single code path (§7) |
| R4 | Individuals can be withheld from publication | Include group, exclude group, and export-control custom security attribute (§8) |
| R5 | Free/busy and Teams chat work across the two tenants | Cross-Tenant Access Policy capabilities and allow-listed external access (§10, §11) |
| R6 | The connection is auditable and defensible under CMMC L2 | Structured logging, immutable run reports, control mapping (§12, §13) |
| R7 | Failure is safe, not silent | Circuit breaker, soft-delete grace period, alerting on failure and on staleness (§9, §12) |
| R8 | Operable by the M365 team without bespoke knowledge | Runbook, pre-flight validation script, preview mode (§14) |

**Out of scope:** mailbox or content migration; SharePoint or Teams file sharing across the tenants; guest (B2B) account provisioning; distribution group, room and equipment synchronisation; photo synchronisation; on-premises Active Directory integration.

---

## 3. Constraints that shape the design

These are the platform facts that rule out the obvious approaches. They are the reason this design looks the way it does.

**Entra cross-tenant synchronisation is not GAL synchronisation.** It provisions B2B users, not mail contacts, and cross-cloud B2B *member* accounts are not supported — only guests. A guest object in the GAL is a different, more privileged thing than a mail contact, and it carries a sign-in surface. Rejected.

**Organisational contacts are read-only in Microsoft Graph.** `orgContact` supports list, get and delta, but has no create, update or delete. The only supported write path for a mail contact is Exchange Online PowerShell (`New-MailContact`, `Set-MailContact`, `Set-Contact`), which therefore anchors the whole design: the service reads with Graph and writes with Exchange Online PowerShell v3, app-only with a certificate.

**Application registrations do not span clouds.** An app registered in the GCC High tenant is unknown to the worldwide cloud, and vice versa. The service therefore holds two independent single-tenant applications, each with its own certificate, each scoped to its own tenant. There is no multi-tenant app and no shared credential.

**B2B direct connect is not supported cross-cloud.** Shared Channels between GCC High and Commercial are not available. Teams interoperability is external access (federation), which is why §11 configures a domain allow list rather than a trust.

**Cross-cloud collaboration must be enabled explicitly on both sides.** Microsoft cloud settings must name the partner cloud (`microsoftonline.us` from the Commercial side, `microsoftonline.com` from the GCC High side), and the partner organisation must be added by tenant ID — domain lookup does not work cross-cloud.

**Exchange Web Services is being retired, and cross-tenant sharing moved with it.** Free/busy, MailTips and calendar sharing have moved from organisation relationships, availability address spaces and sharing policies onto the Microsoft 365 Cross-Tenant Access Policy. EWS-backed sharing began gradual disablement on 1 October 2026, with full shutdown on 1 April 2027; the replacement capability reached GCC High and DoD during September 2026. This design targets the new path and treats the organisation relationship as a bridge only (§10).

**Exchange Online PowerShell app-only authentication requires a CSP-based certificate.** CNG keys are not supported. The provisioning script pins `Microsoft Enhanced RSA and AES Cryptographic Provider` for this reason.

---

## 4. Solution architecture

### 4.1 Component view

```
                    AZURE GOVERNMENT  (FedRAMP High / IL4)
   +-------------------------------------------------------------------+
   |                                                                   |
   |   Automation Account  aa-galsync-prod                             |
   |     - PowerShell 7.2 runbook  Invoke-GalSync                      |
   |     - System-assigned managed identity                            |
   |     - Hourly schedule                                             |
   |          |                    |                    |              |
   |          | RBAC               | RBAC               | diagnostics  |
   |          v                    v                    v              |
   |   Key Vault              Storage Account      Log Analytics       |
   |   (2 app certs,          (config blob,        (job logs,          |
   |    RBAC, purge           immutable run        job streams,        |
   |    protection)           reports)             alerts)             |
   +-------------------------------------------------------------------+
             |  outbound TLS 1.2+, FQDN allow-listed, no inbound
             |
     +-------+-----------------------------+
     |                                     |
     v                                     v
  GCC HIGH TENANT                     COMMERCIAL TENANT
  login.microsoftonline.us            login.microsoftonline.com
  graph.microsoft.us      (read)      graph.microsoft.com      (read)
  outlook.office365.us    (write)     outlook.office365.com    (write)
```

### 4.2 Run sequence

1. The runbook starts on schedule and signs in to Azure Government with its managed identity. No secret is stored in the Automation account.
2. It reads both application certificates from Key Vault into memory, using an ephemeral key set — nothing is written to disk.
3. It opens **both** Exchange Online sessions concurrently. This is possible because each session is loaded with a distinct cmdlet prefix (`Get-GcchMailContact`, `Get-CommMailContact`), which is what keeps a single-process design honest about which tenant it is talking to.
4. It builds, per tenant, the set of primary SMTP addresses that correspond to real user mailboxes. A directory object without a mailbox is never published.
5. For each source tenant in turn it connects Graph — one context at a time, which the Graph SDK enforces — enumerates in-scope users, projects each onto the allow-listed attribute set, computes a content hash, and caches the result. Then it disconnects.
6. For each enabled flow it reads the existing synchronised contacts in the target tenant, computes a reconciliation plan, submits the plan to the safety gate, and applies it.
7. It writes a per-run CSV report to the immutable audit container and emits a structured summary.

### 4.3 Hosting decision

Azure Automation in Azure Government, rather than a Function App or a container, for three reasons: the managed identity and Key Vault integration are native; the job stream is a first-class, retained audit artefact that diagnostic settings forward to Log Analytics without additional code; and the operational model (job history, re-run, schedule) is one the M365 operations team already uses. A Hybrid Runbook Worker in a spoke subnet is supported by the same code where egress must be forced through the hub firewall — `infra/network.bicep` carries that policy.

---

## 5. Object model

| Concern | Decision |
|---|---|
| Target object type | `MailContact` — appears in the GAL, is resolvable by Outlook and Teams, carries no sign-in surface |
| Immutable anchor | Source user `id` (Entra object ID), stored on the contact in `CustomAttribute13` |
| Provenance stamp | `CustomAttribute15 = GALSYNC`, `CustomAttribute14 = <source tenant tag>` |
| Change detection | SHA-256 over the projected attribute set, stored in `CustomAttribute12` |
| Deletion staging | `CustomAttribute11 = PENDINGDELETE:yyyyMMdd` |
| Contact `Name` (CN) | `gs-<tag>-<first 12 hex of anchor>` — deterministic and collision-free |
| Contact `Alias` | `gs_<tag>_<first 12 hex of anchor>` |
| `DisplayName` | Source display name plus a configurable tenant suffix, e.g. `Jane Doe (Contoso Defense)` |

The provenance stamp is load-bearing. Every read of the target tenant is filtered on it, so a mail contact created by any other means — a partner contact, a vendor, a legacy import — is invisible to this service and can never be modified or deleted by it. Only objects this service created are objects this service manages.

---

## 6. Identity and least privilege

Two single-tenant applications, one per tenant, each with a certificate credential only. No client secrets.

| Grant | Value | Why |
|---|---|---|
| Graph application permission | `User.Read.All` | Enumerate source users |
| Graph application permission | `GroupMember.Read.All` | Expand the include and exclude scoping groups |
| Graph application permission | `CustomSecAttributeAssignment.Read.All` | Evaluate the export-control exclusion attribute |
| Office 365 Exchange Online | `Exchange.ManageAsApp` | Required for app-only Exchange Online PowerShell |
| Entra directory role | **Exchange Recipient Administrator** | Least-privileged supported role that can create and manage mail contacts. Exchange Administrator and Global Administrator are both supported and both over-privileged for this workload |

Certificates: RSA 2048, SHA-256, CSP-based (CNG is not supported by Exchange Online app-only auth), 12-month lifetime, stored in the Azure Government Key Vault with soft delete and purge protection. The Automation account's managed identity holds *Key Vault Secrets User* and *Key Vault Certificate User* — read only. Human certificate administration is a separate, PIM-eligible role assignment.

Rotation is scheduled at nine months, giving a 90-day window. The service warns in its run log from 30 days out and the pre-flight script warns from 45 days out.

---

## 7. Attribute allow list — what actually crosses the boundary

This is the control that matters most, and it is enforced in exactly one function (`ConvertTo-GalSyncContactModel`). Nothing else in the codebase reads a source attribute.

**Published by default:**

| Attribute | Written to | Rationale |
|---|---|---|
| `displayName` | `DisplayName` | Required for a usable GAL entry |
| `givenName` | `FirstName` | Name resolution and sorting |
| `surname` | `LastName` | Name resolution and sorting |
| `mail` | `ExternalEmailAddress` | The routing address; the point of the exercise |
| `jobTitle` | `Title` | Disambiguates people with common names |
| `department` | `Department` | Disambiguation and routing |
| `companyName` | `Company` | Distinguishes the two organisations in a merged GAL |

**Available but off by default** — each requires a documented decision before enabling: `officeLocation`, `city`, `state`, `country`, `businessPhones`, `mobilePhone`, `manager`.

**Never published, enforced by configuration validation:** `userPrincipalName`, `employeeId`, `employeeHireDate`, `onPremisesSamAccountName`, `onPremisesImmutableId`, `signInActivity`, extension attributes, photos, assigned licences, custom security attributes.

Two notes on judgement rather than mechanics. First, `jobTitle` and `department` are the attributes most likely to leak programme information — a title like "F-35 Avionics Integration Lead" tells a reader in the Commercial tenant something the GCC High tenant may not have intended to say. Publishing them is the right default for usability, but the quarterly attribute review (§14) exists specifically to re-examine that call. Second, the configuration file refuses to load if any attribute appears in both the allow list and the never-sync list, so the two lists cannot silently drift apart.

---

## 8. Scoping and exclusions

Publication is **opt-in**. A user appears in the partner GAL only if every one of the following holds:

1. Member of the tenant's **include** security group (`scope.includeGroupId`)
2. *Not* a member of the tenant's **exclude** security group
3. Account is enabled
4. Not a guest
5. Has a `mail` value, and that value is not on a routing domain (`*.onmicrosoft.com`, `*.onmicrosoft.us`)
6. UPN does not match a service or privileged-account pattern (`svc-`, `adm-`, `admin*`, `*.adm@`, `break glass`)
7. The `mail` value corresponds to an actual `UserMailbox` in that tenant
8. Not flagged by the export-control custom security attribute (`ExportControl / ItarRestricted = true`)

Rule 8 deserves emphasis. Entra custom security attributes are the right home for an export-control flag: they are separately permissioned (reading them needs `CustomSecAttributeAssignment.Read.All`, which is not implied by `User.Read.All`), they are auditable, and they can be maintained by the export-control function rather than by the M365 team. If the service cannot read them — permission revoked, API failure — the flow **aborts** rather than proceeding without the exclusion. Failing open on an export-control control is not an option.

Every exclusion is counted and logged by reason on every run, so "why is this person not in the GAL?" is answerable from the run log without re-running anything.

---

## 9. Synchronisation semantics

**Change detection.** The projected attribute set is canonicalised and hashed. If the stored hash matches, the object is skipped entirely. A steady-state hourly run therefore performs zero write operations, which keeps the service well clear of Exchange Online throttling and keeps the audit log signal-to-noise high.

**Lifecycle.**

| Source state | Target action |
|---|---|
| New in scope | Create contact, stamp all control attributes |
| Attribute changed | Update contact and hash |
| Out of scope or deleted | **Stage** for deletion: stamp `PENDINGDELETE:<date>`, hide from address lists |
| Staged, then back in scope | Restore: clear the stamp, unhide, refresh attributes |
| Staged for longer than the grace period (30 days) | Purge: `Remove-MailContact` |

The grace period exists because the most common cause of "the source object disappeared" is not an offboarding — it is a group membership change, a licensing blip, or a partial Graph result. Hiding first and deleting later turns a silent data-loss event into a visible, reversible one.

**Circuit breaker.** Before any write, the plan is tested against the safety envelope:

- source returned fewer than the minimum object count (default 1) → block
- deletions exceed 50 objects in one run → block
- deletions exceed 10% of the currently synchronised set → block
- creations exceed 500 in one run → block

A blocked flow performs no writes, logs the violation with its numbers, raises the alert, and leaves the target tenant exactly as it was. A directory outage, a mis-scoped group and a genuine mass offboarding are indistinguishable to the code; the operator decides which one it was.

**Concurrency and throttling.** Writes are issued in batches of 50 with a one-second pause between batches. Transient failures (429, timeout, connection reset) are retried with exponential backoff up to five attempts; anything else surfaces immediately and is recorded per object, so one bad object cannot fail an otherwise good run.

**Preview mode.** `Invoke-GalSync -Preview` produces the full plan and the run report without issuing a single write. This is the mode used for the pre-production dry run, for change-advisory evidence, and as the first diagnostic step in any incident.

---

## 10. Free/busy, MailTips and calendar sharing

### 10.1 Target state — Cross-Tenant Access Policy

Configured **in each tenant**, inbound. Both sides must configure before availability resolves in both directions.

1. **Microsoft cloud settings** — enable the partner cloud endpoint (`microsoftonline.com` from GCC High; `microsoftonline.us` from Commercial).
2. **Partner configuration** — add the partner by tenant ID (domain lookup is unavailable cross-cloud) and enable the Microsoft 365 collaboration trust.
3. **Capabilities** — enable the inbound capabilities the organisation has agreed to:
   - `crossTenantCalendarAvailabilityBasic` (times only) or `...LimitedDetails` (times, subject, location)
   - `crossTenantMailTipsLimited` or `...All`
   - `crossTenantCalendarSharingFreeBusySimple` / `...Detail` / `...Reviewer`
4. **Scoping** — each capability can be scoped to a security group rather than all users. Scope it to the same population as the GAL sync include group, so that GAL visibility and availability visibility do not drift apart.

Recommended starting point: `Basic` availability, `Limited` MailTips, `Simple` calendar sharing, scoped to the include group. These can be widened later; widening is a one-line change, narrowing after users have grown used to detail is a conversation.

### 10.2 Bridge — legacy organisation relationship

If the Cross-Tenant Access Policy capability has not yet appeared in a tenant, `Set-CrossCloudFreeBusy.ps1 -Mode Legacy` configures the classic organisation relationship with the correct cross-cloud endpoints:

| Partner cloud | `TargetApplicationUri` | `TargetAutodiscoverEpr` |
|---|---|---|
| GCC High | `outlook.office365.us` | `https://autodiscover-s.office365.us/autodiscover/autodiscover.svc/WSSecurity` |
| Commercial | `outlook.com` | `https://autodiscover-s.outlook.com/autodiscover/autodiscover.svc/WSSecurity` |

This path is on a retirement clock and must be removed once the policy path is validated. **Legacy configuration takes precedence over the new policy**, so the migration sequence is: configure the policy, disable the organisation relationship and sharing policy, back up and remove the availability address spaces, test, then remove the legacy objects permanently. `-Mode AuditOnly` inventories what exists today without changing anything.

### 10.3 Timeline

| Date | Event |
|---|---|
| Sept 2026 | Cross-Tenant Access Policy sharing capability reaches GCC High and DoD |
| **1 Oct 2026** | EWS-backed cross-tenant sharing begins gradual disablement |
| **1 Apr 2027** | EWS shutdown complete — legacy path stops working entirely |

Given the September GCC High rollout, validate capability availability in both tenants first, and treat the legacy path as a fallback with a hard expiry rather than a parallel option.

---

## 11. Teams federation and cross-cloud meetings

Two distinct mechanisms, both needed, both configured in each tenant.

### 11.1 Chat — external access with a domain allow list

- `AllowFederatedUsers = $true`
- `AllowedDomains` = the partner's SMTP domains only
- `AllowPublicUsers = $false`, `AllowTeamsConsumer = $false`, `AllowTeamsConsumerInbound = $false` (consumer Teams federation is unavailable in GCC High in any case)
- `BlockAllSubdomains = $true`

Open federation is not used. In a CMMC environment the external communication surface should be enumerable and reviewable, and an allow list is what makes that possible. Where only part of the organisation should federate, the optional external access **policy** assigned to a group narrows it further, so tenant-wide federation is enabled but user-level permission is granted deliberately.

### 11.2 Meetings — cross-cloud meeting connections

Teams provides a dedicated cross-cloud meeting connection for authenticated meeting join between clouds. It is configured in the Teams admin center and is independent of the external access settings above:

1. **Meetings → Meeting settings → Microsoft cloud settings** — turn on the partner Azure cloud.
2. **Meetings → Meeting settings → Cross-cloud meetings → Add** — add the partner by tenant ID (or FQDN) and set inbound and outbound connections.
3. Confirm the matching Microsoft Entra cross-tenant access settings, which §10.1 already establishes for availability.

Both organisations must configure this reciprocally. It lets partner users join as authenticated participants without guest accounts. Two limitations worth knowing before the pilot: VDI optimisation must be SlimCore-based (WebRTC-based optimisation does not support cross-cloud meetings), and Conditional Access can reject the partner's authentication with `AADSTS90072` if the two tenants' policies are not aligned.

### 11.3 What is not available

Shared Channels (B2B direct connect) are not supported cross-cloud. Where deep, persistent collaboration on shared artefacts is needed, the answer is a guest (B2B) account under cross-tenant access settings, not a shared channel — and that is a separate decision from this design, with its own review.

Federation changes can take up to 24 hours to propagate; plan the validation window accordingly.

---

## 12. Monitoring, alerting and audit evidence

**Structured logging.** Every significant event is a single-line JSON record carrying a run ID, flow, action, anchor and outcome. Automation job logs and job streams are forwarded to Log Analytics by diagnostic setting, so operational and audit queries run against the same data.

**Run report.** Every run — including preview runs — writes a CSV of every operation (run ID, flow, action, anchor, address, status, detail, UTC timestamp) to a storage container with a legal-hold-style immutability policy and append-protection. This is the artefact to hand an assessor who asks what crossed the boundary and when.

**Alerts.**

| Alert | Condition | Severity |
|---|---|---|
| Run failure or safety-gate block | Failed job, error stream, or `safety-gate` in job output, within 1 hour | 1 |
| Staleness | No successful run in 6 hours | 2 |
| Certificate expiry | Warning at 45 days (pre-flight) and 30 days (run log) | 3 |

**Useful queries.**

```kusto
// Every object that crossed the boundary in the last 24 hours
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
| where RunbookName_s == "Invoke-GalSync"
| extend p = parse_json(ResultDescription)
| where isnotempty(p.action) and p.action !in ("plan","apply","safety-gate")
| project TimeGenerated, run = p.runId, flow = p.flow, action = p.action, anchor = p.anchor
```

```kusto
// Exclusion reasons over time - answers "why is this person not in the GAL"
AzureDiagnostics
| where RunbookName_s == "Invoke-GalSync"
| extend p = parse_json(ResultDescription)
| where p.message == "Source enumeration complete."
| project TimeGenerated, tenant = p.tenant, inScope = p.inScope, exclusions = p.exclusions
```

---

## 13. Security and compliance

### 13.1 Data flow characterisation

The synchronised payload is **directory metadata**: name, work email address, job title, department, company. It is not CUI in itself, and it is not technical data under ITAR. It is nevertheless treated as CUI-adjacent, because the combination of employer, department and title can reveal participation in a controlled programme. That judgement drives three design choices: the allow list, the opt-in scoping, and the export-control exclusion attribute.

Flow direction is **outbound from GCC High to Commercial** and outbound from Commercial to GCC High. Compute, credentials and logs remain in Azure Government throughout. There is no inbound path into the GCC High boundary from the Commercial tenant — the service pulls, it is never called.

**Before go-live, this connection requires a documented approval from the security and export-control functions**, recorded in the SSP as an authorised cross-boundary interconnection, with the attribute inventory in §7 attached.

### 13.2 Control mapping (NIST SP 800-171 R2 / CMMC L2)

| Control | Practice | How this design satisfies it |
|---|---|---|
| 3.1.1 / 3.1.2 | AC.L2-3.1.1, 3.1.2 | Two single-tenant apps, certificate-only, Exchange Recipient Administrator scope; no standing human access to the partner tenant |
| 3.1.3 | AC.L2-3.1.3 (CUI flow control) | Attribute allow list enforced in one code path; opt-in group scoping; export-control exclusion; FQDN-restricted egress |
| 3.3.1 / 3.3.2 | AU.L2-3.3.1, 3.3.2 | Structured per-object logging to Log Analytics with run ID and anchor; immutable per-run CSV |
| 3.4.1 / 3.4.2 | CM.L2-3.4.1, 3.4.2 | Infrastructure and configuration as code in source control; preview mode as the change-advisory artefact |
| 3.5.2 | IA.L2-3.5.2 | Certificate credentials from Key Vault via managed identity; no secrets in code, config or Automation variables |
| 3.13.1 / 3.13.5 | SC.L2-3.13.1, 3.13.5 | Egress-only, FQDN allow-listed boundary; explicit residual deny in the firewall policy |
| 3.13.8 | SC.L2-3.13.8 | TLS 1.2+ for all endpoints; TLS inspection deliberately bypassed for the identity endpoints, which use certificate-bound client authentication |
| 3.13.16 | SC.L2-3.13.16 | Key Vault and storage encrypted at rest; immutable audit container |
| 3.14.6 / 3.14.7 | SI.L2-3.14.6, 3.14.7 | Failure and staleness alerting; circuit breaker on anomalous volume |

### 13.3 Residual risks

| Risk | Mitigation | Residual |
|---|---|---|
| A newly hired person in a controlled programme is published before the export-control flag is set | Include group is opt-in; onboarding adds to the include group only after export-control review | Low — depends on onboarding discipline |
| Job title reveals programme information | Quarterly attribute review; title can be disabled in one configuration change | Accepted, reviewed quarterly |
| Certificate expiry stops synchronisation | Rotation at 9 months, warnings at 45 and 30 days, staleness alert at 6 hours | Low |
| Partner tenant admin removes the inbound capability, breaking free/busy | Staleness and functional monitoring; documented in the shared operating agreement | Low |
| Legacy EWS path is left in place past April 2027 | Migration tracked with a hard date; `-Mode AuditOnly` inventory in the quarterly review | Low |

---

## 14. Implementation plan

**Phase 0 — Agreement (1 week).** Confirm the attribute list with security and export control. Agree the include-group population on both sides. Exchange tenant IDs. Record the interconnection in the SSP. Nominate an operations owner in each tenant.

**Phase 1 — Platform (2 days).** Deploy `infra/main.bicep` into the Azure Government subscription with `enableSchedule = false` (the default). This creates the Automation account, runbook and module imports but no schedule, so nothing can run unattended before the pilot is signed off. Deploy `infra/network.bicep` if the runbook will egress through the hub firewall. Confirm the Automation managed identity's Key Vault and storage role assignments, and copy the `keyVaultName`, `storageAccountName` and `workspaceResourceId` deployment outputs into the `runtime` block of `config/galsync.config.json`.

**Phase 2 — Identity (1 day).** Run `New-GalSyncAppRegistration.ps1` once per tenant. Record the application IDs in `config/galsync.config.json`. Create the include and exclude security groups in both tenants. Define the `ExportControl` attribute set and the `ItarRestricted` attribute in both tenants.

**Phase 3 — Validation (1 day).** Run `Test-GalSyncPrereqs.ps1`. Every check must pass. Review the preview plan object by object with the M365 owner in each tenant. **Gate: no writes until the preview is signed off.**

**Phase 4 — Pilot (1 week).** Populate the include groups with 10–20 users per tenant. Publish the runbook content and run once manually, not on schedule. Verify GAL appearance in Outlook desktop, Outlook on the web and Teams. Verify update propagation by changing a job title. Verify soft-delete behaviour by removing a pilot user from the include group.

**Phase 5 — Availability and federation (2 days).** Run `Set-CrossCloudFreeBusy.ps1 -Mode AuditOnly` in both tenants and review. Configure the Cross-Tenant Access Policy path in both. Run `Set-TeamsFederation.ps1` in both, then add the cross-cloud meeting connection in each Teams admin center. Allow 24 hours, then validate free/busy lookup, Teams chat and cross-cloud meeting join in both directions.

**Phase 6 — Production (1 week).** Expand the include groups to the full agreed population — watch the create ceiling and raise it deliberately for the first bulk run, then lower it again. Enable the hourly schedule by redeploying `infra/main.bicep` with `enableSchedule = true`; `scheduleStartTime` defaults to one hour after the deployment, or set a future UTC time in `main.bicepparam`. Enable the alert rules. Hand over using `docs/Operations-Runbook.md`.

**Phase 7 — Legacy decommission (before 1 April 2027).** Remove any organisation relationships, availability address spaces and sharing policies used as a bridge.

### Acceptance criteria

1. A user created in either tenant appears in the partner GAL within two scheduled runs.
2. A job title change propagates within two scheduled runs.
3. A user removed from the include group is hidden from the partner GAL within one run and purged after 30 days.
4. A user flagged `ItarRestricted = true` never appears, and is counted under `export-control-flag` in the run log.
5. Free/busy resolves in both directions for a pilot user.
6. Teams chat initiates in both directions for a pilot user, and a cross-cloud meeting is joined as an authenticated participant in both directions.
7. A deliberately induced mass-delete condition is blocked by the safety gate and raises the severity-1 alert.
8. The run report for any day can be retrieved from the immutable container and reconciles with the Log Analytics record.

---

## 15. Operations

Day-to-day procedures — monitoring, failure handling, certificate rotation, adding and removing users, disaster recovery — are in `docs/Operations-Runbook.md`. Quarterly, the following are reviewed and the review recorded: the attribute allow list, the include and exclude group membership, the Cross-Tenant Access Policy capabilities in both tenants, the Teams federation allow list, and the residual risk register in §13.3.

---

## Appendix A — Endpoints

| Purpose | GCC High | Commercial |
|---|---|---|
| Entra authentication | `login.microsoftonline.us` | `login.microsoftonline.com`, `login.windows.net` |
| Microsoft Graph | `graph.microsoft.us` | `graph.microsoft.com` |
| Exchange Online PowerShell | `outlook.office365.us` | `outlook.office365.com`, `outlook.office.com` |
| Autodiscover (legacy sharing) | `autodiscover-s.office365.us` | `autodiscover-s.outlook.com` |

Azure Government platform endpoints used by the runbook: `management.usgovcloudapi.net`, `*.vault.usgovcloudapi.net`, `*.blob.core.usgovcloudapi.net`, `*.azure-automation.us`, `*.ods.opinsights.azure.us`, `*.oms.opinsights.azure.us`, `*.agentsvc.azure.us`.

## Appendix B — Repository layout

```
config/galsync.config.json          Runtime configuration (tenants, scope, attributes, safety)
src/GalSync/                        Sync engine module (GalSync.psd1, GalSync.psm1)
src/Invoke-GalSyncRunbook.ps1       Automation runbook entry point
scripts/New-GalSyncAppRegistration.ps1   Per-tenant app, certificate, permissions, Key Vault import
scripts/Test-GalSyncPrereqs.ps1     Pre-flight validation and preview
scripts/Set-CrossCloudFreeBusy.ps1  Cross-Tenant Access Policy (and legacy bridge)
scripts/Set-TeamsFederation.ps1     Allow-listed Teams external access
infra/main.bicep                    Automation, Key Vault, storage, Log Analytics, alerts, RBAC
infra/network.bicep                 Azure Firewall egress policy (optional)
tests/GalSync.Tests.ps1             Pester tests for scoping, projection, planning, safety gate
docs/                               This design, the operations runbook, the attribute inventory
```

## Appendix C — References

- App-only authentication in Exchange Online PowerShell — https://learn.microsoft.com/powershell/exchange/app-only-auth-powershell-v2
- Microsoft Graph national cloud deployments — https://learn.microsoft.com/graph/deployments
- orgContact resource type (read-only) — https://learn.microsoft.com/graph/api/resources/orgcontact
- Migrate to Microsoft 365 Cross-Tenant Access Policy for Free/Busy, Calendars and MailTips — https://learn.microsoft.com/exchange/sharing/migrate-to-m365-xtap
- Microsoft cloud settings for cross-cloud B2B — https://learn.microsoft.com/entra/external-id/cross-cloud-settings
- Collaborate with guests from other Microsoft 365 cloud environments — https://learn.microsoft.com/microsoft-365/solutions/collaborate-guests-cross-cloud
- Manage external meetings and chat — https://learn.microsoft.com/microsoftteams/trusted-organizations-external-meetings-chat
- MC1446796 — Migrate Free/Busy, MailTips and Calendar Sharing before EWS deprecation
