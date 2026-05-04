# Intune Baseline Assessment — User Guide

This guide walks you through running an Intune Baseline Assessment and reading
the output. It is written for consultants who run the assessment for a customer
and then use the results to produce a report.

> Looking for setup, repository layout, or module internals? See
> [README.md](README.md).

---

## 1. What the tool does

The tool compares a customer's Microsoft Intune tenant against the **eVri
hardened baseline** (OpenIntune L1–L4) and produces:

1. A **diff CSV** — every baseline setting and what the customer tenant has
   (or is missing).
2. **Inventory CSVs** — managed devices, enrollment configurations, Autopilot
   devices, and deployed apps.
3. An optional **ReportData.json** — aggregated scores, per-domain maturity,
   and findings, ready to drop into the Word report template.
4. A **console summary** — at-a-glance compliance counts, per-domain maturity
   score, and top findings.

It reads from Microsoft Graph only — **it never makes changes to either
tenant**.

---

## 2. Before you start

You need the following before your first run:

| Item | Notes |
|---|---|
| PowerShell 5.1 or later | Ships with Windows 10/11 by default |
| The app registration ClientId + ClientSecret | From the eVri Azure AD tenant |
| The **baseline** tenant ID | The eVri tenant hosting the hardened baseline |
| The **customer** tenant ID (GUID) | Ask the customer or look it up in the portal |
| Admin consent in the customer tenant | The customer admin must consent to the Graph permissions once |

**Graph permissions required in the customer tenant** (application permissions,
no user sign-in):

- `DeviceManagementConfiguration.Read.All` — policy comparison
- `DeviceManagementManagedDevices.Read.All` — device inventory
- `DeviceManagementServiceConfig.Read.All` — enrollment and Autopilot
- `DeviceManagementApps.Read.All` — app inventory
- `Group.Read.All` *(optional)* — resolves assignment group names

Without the last three, the relevant inventory sections come back empty with a
warning — the comparison still runs.

---

## 3. First-time setup

1. **Copy the config template** and fill in your app registration values:

   ```powershell
   Copy-Item Config\AppConfig.template.json Config\AppConfig.json
   notepad Config\AppConfig.json
   ```

   Fill in `ClientId`, `ClientSecret`, and `BaselineTenantId`. Leave the other
   fields at their defaults.

   > `AppConfig.json` contains a secret — it is git-ignored and must never be
   > committed.

2. **Verify the customer has granted admin consent** for the app registration.
   If they haven't, the tool fails at step 2 with a 401/403 error.

That's it — you are ready to run assessments.

---

## 4. Running an assessment

### 4.1 The typical run

```powershell
.\IntuneBaselineAssessment.ps1 `
    -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -CustomerName "Contoso" `
    -GenerateReportData
```

This does the following:

- `[1/5]` Fetches the full baseline from the eVri tenant (or re-uses the cache)
- `[2/5]` Fetches all policies from the customer tenant
- `[3/5]` Collects device, enrollment, and app inventory from the customer
- `[4/5]` Compares the two and evaluates findings
- `[5/5]` Writes CSVs and `ReportData.json` to `Exports\`

Expect the first run to take **5–15 minutes** depending on the size of the
customer tenant. Autopilot collection in particular can be slow.

### 4.2 Speeding up follow-up runs

After the first run the baseline is cached in `Baseline\baseline-cache.json`.
Use `-UseBaselineCache` to skip the baseline fetch on subsequent runs:

```powershell
.\IntuneBaselineAssessment.ps1 `
    -CustomerTenantId "<GUID>" -CustomerName "Contoso" `
    -UseBaselineCache -GenerateReportData
```

The baseline cache only changes when eVri updates the hardened baseline. Use
`-RefreshBaseline` to force a fresh fetch.

For Robin Phase 1 definition prefetch, you can persist and reuse the definition
catalog cache as well:

```powershell
.\IntuneBaselineAssessment.ps1 `
    -CustomerTenantId "<GUID>" -CustomerName "Contoso" `
    -UseDefinitionsCache
```

This creates/reuses `Baseline\definitions-cache.json` and reduces startup
latency on repeated runs.

### 4.3 Common scenarios

**Assess against a specific maturity tier** — baseline policies are labelled
`L1`, `L2`, `L3`, or `L4`. Levels are cumulative, so `L2` compares against
L1 + L2 policies, `L3` against L1 + L2 + L3, and so on.

```powershell
# L2 assessment — includes L1 and L2 baseline policies
.\IntuneBaselineAssessment.ps1 -CustomerTenantId "<GUID>" `
    -CustomerName "Contoso" -BaselineLevel L2
```

**Skip inventory collection** — useful when you only need the policy diff or
when the customer has not granted the inventory permissions yet:

```powershell
.\IntuneBaselineAssessment.ps1 -CustomerTenantId "<GUID>" `
    -CustomerName "Contoso" -SkipInventory
```

**Compare a single policy type** — useful for targeted deep-dives:

```powershell
.\IntuneBaselineAssessment.ps1 -CustomerTenantId "<GUID>" `
    -CustomerName "Contoso" -PolicyTypes CompliancePolicy
```

Valid values: `SettingsCatalog`, `EndpointSecurity`, `DeviceConfig`,
`AdminTemplates`, `CompliancePolicy`, `SecurityBaseline`.

### 4.4 Every parameter

| Parameter | Required | Description |
|---|---|---|
| `-CustomerTenantId` | ✔ | Customer Azure AD tenant ID (GUID) |
| `-CustomerName` | ✔ | Used in output filenames |
| `-BaselineLevel` |   | `All` (default), `L1`, `L2`, `L3`, `L4` |
| `-PolicyTypes` |   | Subset of the 6 policy types (default: all) |
| `-BaselinePolicyFilter` |   | Wildcard patterns; narrows which baseline policies are fetched |
| `-UseBaselineCache` |   | Skip baseline fetch; use the on-disk cache |
| `-RefreshBaseline` |   | Force a fresh baseline fetch |
| `-UseDefinitionsCache` |   | Persist/reuse `Baseline\definitions-cache.json` |
| `-RefreshDefinitions` |   | Force fresh definition prefetch and overwrite definitions cache |
| `-SkipInventory` |   | Skip device/enrollment/app inventory collection |
| `-GenerateReportData` |   | Also write `ReportData.json` |
| `-ConfigPath` |   | Location of `AppConfig.json` and `DomainMapping.json` (default: `Config\`) |
| `-OutputPath` |   | Where CSVs go (default: `Exports\`) |
| `-BaselinePath` |   | Where the baseline cache lives (default: `Baseline\`) |

---

## 5. Understanding the output

All output files land in `Exports\` by default. Filenames follow the pattern:

```
{CustomerName}_{yyyyMMdd}_{L1|L2|L3|L4|All}_{Type}.csv
```

For example: `Contoso_20260416_L2_IntuneDiff_Export.csv`.

### 5.1 The diff CSV — `IntuneDiff_Export.csv`

**This is the main deliverable.** It is semicolon-delimited, UTF-8 with BOM, so
Excel opens it cleanly on a Dutch/Belgian locale. Each row represents a single
setting comparison.

| Column | Meaning |
|---|---|
| Baseline Policy Name | The eVri baseline policy this setting comes from (e.g. `SBZ-Win-L1-ES-BitLocker`) |
| Baseline Policy Template | Policy type: `Settings Catalog`, `Endpoint Security`, `Device Configuration`, `Admin Templates`, `Compliance Policy`, `Security Baseline` |
| Baseline Setting | Path/name of the setting as defined in the baseline |
| Baseline Category | Category GUID or template type — used internally for domain mapping |
| Baseline Domain | One of the 5 assessment domains (see §5.7) |
| Baseline Setting Value | Value the baseline expects |
| **Result** | **Compliant / Conflict / Missing / Extra** — see §5.2 |
| Policy Name | Customer policy that provides this setting (empty for `Missing`) |
| Customer Setting | Setting path as seen in the customer tenant |
| Policy Template | Customer policy type |
| Policy Value | Actual value in the customer tenant |
| Comparison Category | Category as seen in the customer tenant |
| Comparison Domain | Domain resolved from the customer setting (usually matches Baseline Domain) |
| Description | Human-readable explanation of the result |

### 5.2 What the four Result values mean

| Result | Meaning | Action |
|---|---|---|
| **Compliant** | Customer has this setting and the value matches the baseline. | Nothing — good. |
| **Conflict** | Customer has this setting but with a **different value**. | Investigate — often the most important class to review. |
| **Missing** | Baseline has this setting; customer doesn't have it anywhere. | Usually a gap to address. Prioritise by domain and severity. |
| **Extra** | Customer has a setting the baseline does **not** cover. | Informational — not necessarily bad. Review for policy sprawl or custom hardening. |

**If a customer has the same setting configured in multiple policies with
different values, the comparison is optimistic**: if **any** copy matches the
baseline it reports `Compliant`. The CSV row shows all policies that define it
(comma-joined) so you can still spot the inconsistency.

### 5.3 The inventory CSVs

When `-SkipInventory` is **not** used, four additional CSVs are produced:

**`DeviceInventory.csv`** — every Intune-managed device.
Columns: Device Name, Device ID, Operating System, OS Version, Compliance
State, Last Sync, Enrolled Date, Management Agent, Enrollment Type, Model,
Manufacturer, Serial Number, User Principal Name.

Useful filters in Excel:
- `Compliance State = noncompliant` → devices failing compliance policies
- `Last Sync` older than ~30 days → stale / orphaned enrolments
- Group by `Operating System` → OS diversity / unsupported Windows versions

**`EnrollmentConfigs.csv`** — enrollment restriction and limit configurations.
Columns: Config Name, Config ID, Config Type, Priority, Description, Created
Date, Last Modified.

**`AutopilotDevices.csv`** — registered Autopilot hardware.
Columns: Serial Number, Model, Manufacturer, Group Tag, Purchase Order,
Enrollment State, Last Contacted, Profile Assignment Status.

> Autopilot uses a paginated Graph endpoint that is historically slow. If the
> run logs `Autopilot devices: 0` with a 504 warning, re-run — the endpoint
> occasionally times out on large fleets and the tool will continue without it.

**`AppInventory.csv`** — every app object in Intune.
Columns: App Name, App ID, App Type, Publisher, Created Date, Last Modified,
Is Assigned, Assignment Count, Assignment Intent, Assignment Groups.

Useful filters:
- `Is Assigned = No` → orphaned apps that never reach users
- Group by `App Type` → Win32 vs. Store vs. web vs. iOS/Android mix

### 5.4 The `ReportData.json`

Only written when `-GenerateReportData` is passed. It is the single file the
Word report template reads. Top-level shape:

```
CustomerName, BaselineLevel, GeneratedAt
Summary           — totals and per-result counts
ByDomain          — per-domain compliance % and maturity score (0–5)
DeviceInventory   — totals + breakdown by OS and compliance state
EnrollmentMethods — enrollment configs + Autopilot devices
AppInventory      — totals + breakdown by assignment state and app type
ExecutiveSummary  — top 3 findings (name, severity, detail, recommendation)
FindingSummary    — count of findings per severity
FindingsByDomain  — grouped findings, full recommendations
```

You generally don't read this file by hand — it exists so the report template
can populate itself.

### 5.5 The console summary

At the end of the run the tool prints something like:

```
═══════════════════════════════════════════════════════
  Intune Baseline Assessment — Contoso
  Baseline Level  : L2 (cumulative: L1..L2)
  Total Settings  : 842
───────────────────────────────────────────────────────
  Compliant :   612  (72,7%)
  Conflict  :    47  ( 5,6%)
  Missing   :   168  (20,0%)
  Extra     :    15  ( 1,8%)
───────────────────────────────────────────────────────
  By Domain:
    Endpoint Security               Score 4/5  [ 81% compliant, 321 settings]
    Device Management               Score 3/5  [ 68% compliant, 210 settings]
    ...
───────────────────────────────────────────────────────
  Findings:
    Critical: 1  High: 3  Medium: 5  Low: 2
    [Critical] LAPS niet geconfigureerd
    [High]     Office macro- en Trust Center-hardening ontbreekt
    ...
```

This is identical to what ends up in `ReportData.json` — the console version is
there so you can sanity-check the run before sharing results.

### 5.6 Maturity scores (0–5)

Each of the 5 assessment domains gets a score based on compliance %:

| Compliant % | Score | Interpretation |
|---|---|---|
| 0–19%   | 0 | Not established |
| 20–39%  | 1 | Initial |
| 40–59%  | 2 | Developing |
| 60–74%  | 3 | Defined |
| 75–89%  | 4 | Managed |
| 90–100% | 5 | Optimised |

### 5.7 The 5 assessment domains

Every setting is tagged with exactly one domain so reports can aggregate
findings by area of responsibility:

1. **Endpoint Security** — BitLocker, Defender, Firewall, WHfB, LAPS, Attack Surface Reduction
2. **Device Management** — OS settings, Wi-Fi/VPN, update rings, Autopilot
3. **Compliance & Governance** — compliance policies, conditional-access posture
4. **Application Lifecycle** — app deployment, protection policies
5. **Operations & Monitoring** — logging, telemetry, service health

### 5.8 Findings

A **finding** is an aggregated observation — not one setting but a pattern
across many. For example, *"LAPS is not configured"* might aggregate 8 missing
Settings Catalog entries into a single actionable item with a severity and a
recommendation. Findings are driven by `Config\FindingRules.json` (16 rules
today) and appear in both the console summary and `ReportData.json`.

Severities are **Critical / High / Medium / Low**. Critical and High findings
should always be discussed with the customer explicitly.

---

## 6. Baseline levels (L1–L4)

The eVri baseline comes in four cumulative tiers:

| Level | Audience | Typical scope |
|---|---|---|
| **L1** | Standard enterprise | Foundational hardening everyone should have |
| **L2** | Security-conscious | L1 + tighter configuration (macro hardening, stricter compliance) |
| **L3** | Regulated / high-assurance | L2 + Attack Surface Reduction, advanced WDAC, etc. |
| **L4** | Maximum assurance | L3 + everything else in the baseline |

Use `-BaselineLevel L2` (or `L1`, `L3`, `L4`) to target a specific tier.
`All` (the default) compares against everything in the baseline.

Switching levels is **free** — the cache always stores the full baseline, and
the level filter is applied at read-time. You don't need `-RefreshBaseline` to
switch levels.

---

## 7. Troubleshooting

### "Configuration file not found"

You haven't created `Config\AppConfig.json` yet. See §3.

### 401 / 403 errors at step 2 ("Customer tenant")

The customer hasn't granted admin consent, or the app registration is missing
a permission. Re-check §2 and have the customer admin grant consent in the
Azure portal under *Enterprise applications → {eVri app} → Permissions*.

### Baseline tenant connect is slow or times out

Token acquisition now uses a 60-second timeout to avoid indefinite hanging.
If this still fails, validate outbound/proxy access to
`https://login.microsoftonline.com` from the execution environment.

### "Cache is v1 format" warning

You have an old baseline cache from before Sprint 2. Pass `-RefreshBaseline`
once to rebuild it — this is a one-off and future runs will be fast again.

### The run finishes but inventory CSVs are missing / empty

Either `-SkipInventory` was set, or the customer hasn't granted one of the
inventory permissions (`DeviceManagementManagedDevices.Read.All`,
`DeviceManagementServiceConfig.Read.All`,
`DeviceManagementApps.Read.All`). Missing permissions produce a warning, not
a fatal error — the diff CSV is still valid.

### Autopilot section shows 0 devices

The Autopilot Graph endpoint is known to time out on large tenants. Re-run —
if it consistently fails, the other CSVs are still complete.

### CSV opens as one column in Excel

Excel's CSV parser is locale-sensitive. The file is semicolon-delimited,
UTF-8 with BOM, which works on a Dutch/Belgian Windows by default. On an
English locale use *Data → From Text/CSV* and pick **Semicolon** as the
delimiter.

### "No baseline settings match level 'L3'"

There are no baseline policies named `*-L3-*` at the moment. Either pick a
lower level or pass `-RefreshBaseline` if the baseline tenant was recently
updated.

---

## 8. Frequently asked questions

**Does the tool change anything in the customer tenant?**
No — all Graph calls are read-only.

**Does it store credentials anywhere?**
`Config\AppConfig.json` holds the app registration secret. It is git-ignored
and only read by the script. The access token lives in memory for the run
and is discarded at exit.

**How fresh is the data?**
It's a point-in-time snapshot at the moment the script calls Graph. For a
changing customer tenant, re-run to refresh.

**Can I run this against multiple customers in parallel?**
Yes — each run is independent. Use different `-CustomerName` values so the
output filenames don't collide.

**Where does the comparison logic live?**
In [Modules/Comparison.psm1](Modules/Comparison.psm1). Result semantics are
described in §5.2.

**Can I add my own findings?**
Yes — edit [Config/FindingRules.json](Config/FindingRules.json). See
[AnalysisEngine.md](AnalysisEngine.md) for the rule schema.

**How do I change which settings map to which domain?**
Edit [Config/DomainMapping.json](Config/DomainMapping.json). The baseline
cache auto-re-enriches when the file's hash changes — no `-RefreshBaseline`
needed.
