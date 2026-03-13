# Analysis Engine & Finding Rules

The analysis engine evaluates collected tenant data against a set of configurable rules and produces a prioritised list of findings for the assessment report. It is implemented in [`Modules/RecommendationEngine.psm1`](Modules/RecommendationEngine.psm1) and driven entirely by [`Config/FindingRules.json`](Config/FindingRules.json) — no logic changes are needed to add, remove, or tune a finding.

---

## Architecture overview

```
IntuneBaselineAssessment.ps1
  │
  ├─ Compare-TenantSettings      → ComparisonResults  (List[hashtable])
  ├─ Get-CustomerSettings        → CustomerSettings   (List[hashtable])
  ├─ Get-DeviceInventory         → DeviceInventory    (List[hashtable])
  ├─ Get-EnrollmentData          → EnrollmentData     (hashtable)
  └─ Get-AppInventory            → AppInventory       (List[hashtable])
          │
          ▼
  Initialize-FindingRules        ← Config/FindingRules.json
                                 ← DomainMapping.json riskWeights
          │
          ▼
  Get-Findings
    ├─ comparisonFindings  — evaluated against comparison diff rows
    ├─ structuralFindings  — evaluated against policy metadata / diff rows
    └─ inventoryFindings   — evaluated against device/enrollment/app data
          │
          ▼
  Sorted findings list (by severity score desc, then domain risk weight desc)
          │
          ▼
  Export-ReportData              → ReportData.json
    ├─ ExecutiveSummary.TopRisks     (top 3 findings)
    ├─ FindingSummary                (all findings, flat)
    └─ FindingsByDomain              (grouped by domain)
```

---

## Public API

### `Initialize-FindingRules`

Loads and validates `FindingRules.json`. Must be called once before `Get-Findings`.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `RulesPath` | string | Yes | Path to `FindingRules.json` |
| `RiskWeights` | hashtable | No | Domain → numeric weight from `DomainMapping.json`. Used as a tiebreaker when two findings have equal severity. |

If the file is not found, the engine is disabled and `Get-Findings` returns an empty list (no fatal error).

### `Get-Findings`

Evaluates all loaded rules and returns a sorted `List[hashtable]` of triggered findings.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `ComparisonResults` | `List[hashtable]` | Yes | Output of `Compare-TenantSettings` |
| `CustomerSettings` | `List[hashtable]` | Yes | Raw customer settings (pre-comparison) |
| `DeviceInventory` | `List[hashtable]` | No | Managed device objects |
| `EnrollmentData` | `hashtable` | No | Keys: `EnrollmentConfigs`, `AutopilotDevices` |
| `AppInventory` | `List[hashtable]` | No | Mobile app objects |

---

## Finding categories

Rules are partitioned into three categories that each consume different input data.

### `comparisonFindings`

Evaluated against the diff rows produced by `Compare-TenantSettings`. Each row carries:

- `BaselineSetting` / `CustomerSetting` — setting path string
- `DefinitionId` — namespaced identifier
- `Result` — `Compliant`, `Conflict`, `Missing`, or `Extra`
- `BaselineDomain` — domain assigned by the enrichment module

Two trigger types are available for comparison findings.

### `structuralFindings`

Evaluated against policy metadata (names, duplicate coverage) rather than individual setting values. These surface organisational or governance issues that are not visible from a per-setting diff.

Two trigger types are available for structural findings.

### `inventoryFindings`

Evaluated against device, enrollment, and app inventory. These surface operational issues (device compliance rates, provisioning gaps, app hygiene) that exist independently of policy comparison.

Two trigger types are available for inventory findings.

---

## Trigger types (6 total)

### `keyword_cluster`  *(comparisonFindings)*

Scans the combined `BaselineSetting + DefinitionId` text of every comparison row for any of the specified keywords. Fires when the ratio of rows matching `resultFilter` (e.g. `["Missing", "Conflict"]`) among those keyword-matched rows meets or exceeds `threshold`.

```jsonc
"trigger": {
  "type": "keyword_cluster",
  "keywords": ["BitLocker", "Encryption", "FDE", "DiskEncryption"],
  "resultFilter": ["Missing", "Conflict"],
  "threshold": 0.5          // fire when ≥ 50 % of matched rows have these results
}
```

| Field | Type | Description |
|---|---|---|
| `keywords` | string[] | Case-insensitive substrings searched in setting path + definition ID |
| `resultFilter` | string[] | Result values that count as "affected" |
| `threshold` | float (0–1) | Minimum ratio of affected / matched rows required to trigger |

**Why a ratio instead of a count?** A baseline may contain 2 LAPS settings or 20. Ratios keep rules stable across baseline updates without needing to retune absolute numbers.

---

### `domain_ratio`  *(comparisonFindings)*

Fires when the ratio of rows matching `resultFilter` within a specific `BaselineDomain` meets or exceeds `threshold`. Useful for broad "domain health" findings that fire when an entire area is poorly covered.

```jsonc
"trigger": {
  "type": "domain_ratio",
  "domain": "Endpoint Security",
  "resultFilter": ["Missing", "Conflict"],
  "threshold": 0.5          // fire when ≥ 50 % of Endpoint Security rows are affected
}
```

| Field | Type | Description |
|---|---|---|
| `domain` | string | Must match one of the 5 assessment domains exactly |
| `resultFilter` | string[] | Result values that count as "affected" |
| `threshold` | float (0–1) | Minimum ratio to trigger |

---

### `naming_convention`  *(structuralFindings)*

Counts how many unique customer policy names match **any** of the supplied wildcard `patterns` (PowerShell `-like` syntax). Fires when the fraction of matching names falls **below** `threshold` — i.e., the convention is *not* being followed.

```jsonc
"trigger": {
  "type": "naming_convention",
  "patterns": ["SBZ-*", "SBZ-Win-*", "*-L1-*", "*-L2-*", "*-L3-*", "*-L4-*"],
  "threshold": 0.5          // fire when < 50 % of policies match a pattern
}
```

| Field | Type | Description |
|---|---|---|
| `patterns` | string[] | PowerShell wildcard patterns (`*`, `?`) matched against policy names |
| `threshold` | float (0–1) | If the match ratio is **below** this value, the rule fires |

The `AffectedCount` reported is the number of policies that do **not** match any pattern.

---

### `duplicate_coverage`  *(structuralFindings)*

Fires when the number of comparison rows where a setting is configured in multiple policies (comma-separated `PolicyName`) **and** the result is `Conflict` meets or exceeds the integer `threshold`.

```jsonc
"trigger": {
  "type": "duplicate_coverage",
  "threshold": 10           // fire when ≥ 10 such conflicting multi-policy rows exist
}
```

| Field | Type | Description |
|---|---|---|
| `threshold` | integer | Minimum count of conflicting multi-policy rows required to trigger |

Multi-policy rows are identified by a comma + space (`", "`) in the `PolicyName` field, which is how the comparison engine joins multiple matching policies onto one row.

---

### `inventory_metric`  *(inventoryFindings)*

Evaluates a ratio or count condition against a named inventory collection. Fires when the proportion of items where `field` matches `value` (according to `matchMode`) meets the `operator` and `threshold`.

```jsonc
"trigger": {
  "type": "inventory_metric",
  "source": "devices",
  "field": "ComplianceState",
  "value": "noncompliant",
  "operator": "percent_gte",
  "threshold": 0.1          // fire when ≥ 10 % of devices are noncompliant
}
```

```jsonc
// Using matchMode for prefix matching (e.g. OS version detection)
"trigger": {
  "type": "inventory_metric",
  "source": "devices",
  "field": "OsVersion",
  "value": "10.0.",
  "matchMode": "startsWith",
  "operator": "percent_gte",
  "threshold": 0.1
}
```

| Field | Type | Description |
|---|---|---|
| `source` | string | Inventory collection: `devices`, `apps`, `autopilotDevices`, `enrollmentConfigs` |
| `field` | string | Property name on each inventory item |
| `value` | string | Value to match against (comparison mode depends on `matchMode`) |
| `matchMode` | string | Optional. `exact` (default), `startsWith`, or `contains`. All modes are case-insensitive. |
| `operator` | string | `percent_gte`, `percent_gt`, `count_gte` |
| `threshold` | float or int | Threshold value for the operator |

---

### `inventory_empty`  *(inventoryFindings)*

Fires when a named inventory collection is `$null` or empty. Used to detect the complete absence of a feature (e.g. no Autopilot registrations).

```jsonc
"trigger": {
  "type": "inventory_empty",
  "source": "autopilotDevices"
}
```

| Field | Type | Description |
|---|---|---|
| `source` | string | Inventory collection: `devices`, `apps`, `autopilotDevices`, `enrollmentConfigs` |

---

## FindingRules.json schema

Each rule in any of the three arrays shares the following top-level fields:

```jsonc
{
  "id": "bitlocker-gaps",           // unique kebab-case identifier
  "name": "BitLocker not fully configured",
  "domain": "Endpoint Security",    // must match one of the 5 assessment domains
  "severity": "Critical",           // Critical | High | Medium | Low
  "trigger": { ... },               // trigger object (type-specific fields above)
  "detail": "...",                  // human-readable finding description; supports {count}, {total}, {percent}
  "recommendation": "..."           // remediation guidance; supports {count}, {total}, {percent}
}
```

### Text interpolation tokens

The `detail` and `recommendation` strings support three runtime tokens:

| Token | Replaced with |
|---|---|
| `{count}` | Number of affected items (rows, devices, apps, etc.) |
| `{total}` | Total items in the evaluated set |
| `{percent}` | `count / total × 100`, rounded to the nearest integer |

---

## Severity scoring

Findings are sorted by severity score (descending), then by domain risk weight (descending, from `DomainMapping.json`).

| Severity | Score |
|---|---|
| Critical | 10 |
| High | 7 |
| Medium | 4 |
| Low | 1 |

---

## Finding output format

Each triggered finding is a `[ordered]hashtable` with these keys:

| Key | Type | Description |
|---|---|---|
| `FindingId` | string | Rule `id` from JSON |
| `FindingName` | string | Rule `name` from JSON |
| `Domain` | string | Assessment domain |
| `Severity` | string | Critical / High / Medium / Low |
| `SeverityScore` | int | Numeric score for sorting |
| `Detail` | string | Interpolated detail text |
| `Recommendation` | string | Interpolated recommendation text |
| `AffectedCount` | int | Number of affected items |
| `Category` | string | `comparison`, `structural`, or `inventory` |

Findings appear in `ReportData.json` in three sections:

- **`ExecutiveSummary.TopRisks`** — the top 3 findings (highest severity) as a brief list for the report cover page
- **`FindingSummary`** — all triggered findings, flat list
- **`FindingsByDomain`** — triggered findings grouped under their assessment domain key

---

## Current rules (27 total)

### Comparison findings (19 keyword_cluster + 4 domain_ratio)

| ID | Name | Domain | Severity | Trigger type | Condition |
|---|---|---|---|---|---|
| `laps-not-configured` | LAPS not configured | Endpoint Security | **Critical** | keyword_cluster | ≥ 80 % of LAPS/LocalAdminPassword settings are Missing |
| `bitlocker-gaps` | BitLocker not fully configured | Endpoint Security | **Critical** | keyword_cluster | ≥ 50 % of BitLocker/Encryption settings are Missing or Conflict |
| `whfb-not-configured` | Windows Hello for Business not configured | Endpoint Security | **Critical** | keyword_cluster | ≥ 60 % of WHfB/PassportForWork settings are Missing or Conflict |
| `office-macro-hardening-missing` | Office macro and Trust Center hardening missing | Endpoint Security | **High** | keyword_cluster | ≥ 50 % of TrustCenter/Macro/VBA/ActiveX settings are Missing |
| `local-security-policy-gaps` | Local security policy hardening missing | Endpoint Security | **High** | keyword_cluster | ≥ 50 % of LocalPoliciesSecurityOptions/NTLMv2 settings are Missing or Conflict |
| `defender-gaps` | Windows Defender gaps | Endpoint Security | **High** | keyword_cluster | ≥ 40 % of Defender/Antivirus settings are Missing or Conflict |
| `firewall-gaps` | Firewall not configured | Endpoint Security | **High** | keyword_cluster | ≥ 60 % of Firewall/MdmStore settings are Missing |
| `asr-not-configured` | Attack Surface Reduction gaps | Endpoint Security | **High** | keyword_cluster | ≥ 60 % of ASR/ExploitGuard settings are Missing |
| `user-rights-not-configured` | User Rights Assignment not configured | Endpoint Security | **Medium** | keyword_cluster | ≥ 50 % of UserRights settings are Missing |
| `audit-policy-not-configured` | Audit policy not configured | Compliance & Governance | **Medium** | keyword_cluster | ≥ 50 % of Auditing/AuditPolicy settings are Missing |
| `edge-hardening-missing` | Microsoft Edge hardening not configured | Application Lifecycle | **Medium** | keyword_cluster | ≥ 50 % of Edge/SmartScreen settings are Missing |
| `device-restrictions-incomplete` | Device restrictions incomplete | Device Management | **Medium** | keyword_cluster | ≥ 40 % of DeviceRestriction/Password/ScreenLock settings are Missing or Conflict |
| `windows-update-misconfigured` | Windows Update misconfigured | Device Management | **Medium** | keyword_cluster | ≥ 40 % of WindowsUpdate/UpdateRing settings are Missing or Conflict |
| `app-protection-missing` | App protection gaps | Application Lifecycle | **Medium** | keyword_cluster | ≥ 60 % of AppProtection/MAM settings are Missing |
| `onedrive-not-configured` | OneDrive configuration missing | Application Lifecycle | **Low** | keyword_cluster | ≥ 50 % of OneDrive/KnownFolderMove settings are Missing |
| `endpoint-security-low` | Critical Endpoint Security gaps | Endpoint Security | **Critical** | domain_ratio | ≥ 50 % of all Endpoint Security domain rows are Missing or Conflict |
| `compliance-coverage-low` | Compliance policy coverage low | Compliance & Governance | **High** | domain_ratio | ≥ 40 % of all Compliance & Governance domain rows are Missing |
| `device-management-coverage-low` | Device Management coverage low | Device Management | **Medium** | domain_ratio | ≥ 50 % of all Device Management domain rows are Missing or Conflict |
| `application-lifecycle-coverage-low` | Application Lifecycle coverage low | Application Lifecycle | **Low** | domain_ratio | ≥ 50 % of all Application Lifecycle domain rows are Missing |

### Structural findings (2)

| ID | Name | Domain | Severity | Trigger type | Condition |
|---|---|---|---|---|---|
| `no-naming-convention` | No consistent naming convention | Operations & Monitoring | **Medium** | naming_convention | < 50 % of customer policies match any recognised naming pattern |
| `duplicate-policy-coverage` | Overlapping policy settings | Operations & Monitoring | **Low** | duplicate_coverage | ≥ 10 settings are configured in multiple conflicting policies |

### Inventory findings (6)

| ID | Name | Domain | Severity | Trigger type | Condition |
|---|---|---|---|---|---|
| `devices-noncompliant` | Devices out of compliance | Compliance & Governance | **High** | inventory_metric | ≥ 10 % of managed devices have `ComplianceState = noncompliant` |
| `devices-unknown-compliance` | Devices with unknown compliance state | Compliance & Governance | **Medium** | inventory_metric | ≥ 5 % of managed devices have `ComplianceState = unknown` |
| `outdated-os` | Outdated OS versions | Device Management | **Medium** | inventory_metric | ≥ 10 % of managed devices have `OsVersion` starting with `10.0.` (Windows 10) |
| `no-autopilot` | No Autopilot enrollment | Operations & Monitoring | **Medium** | inventory_empty | No Autopilot device identities registered |
| `legacy-msi-apps` | Legacy MSI app deployments in use | Application Lifecycle | **Low** | inventory_metric | ≥ 1 app has `App Type = windowsMobileMSI` |
| `unassigned-apps` | Unassigned applications | Application Lifecycle | **Low** | inventory_metric | ≥ 30 % of apps have `IsAssigned = No` |

---

## Adding or tuning rules

All changes are made in `Config/FindingRules.json` only — no PowerShell edits are needed.

**To add a new rule:**

1. Choose the correct category array (`comparisonFindings`, `structuralFindings`, or `inventoryFindings`).
2. Add a new object with a unique `id`, a human-readable `name`, a valid `domain`, a `severity`, a `trigger` block, and `detail`/`recommendation` strings.
3. Select the appropriate `trigger.type` and fill in its required fields (see trigger type reference above).
4. Use `{count}`, `{total}`, and `{percent}` tokens in `detail`/`recommendation` as needed.

**To disable a rule without deleting it:** Remove the object from the array, or add an `"enabled": false` field (the engine currently loads all objects present — deletion is the cleanest approach).

**To tune a threshold:** Adjust the `threshold` value. Lower values make a rule fire more easily; higher values require a worse situation before it fires.

**To change severity:** Update the `severity` string. Valid values: `Critical`, `High`, `Medium`, `Low`.

---

## Risk weights

`DomainMapping.json` contains a `riskWeights` object that assigns a numeric weight to each assessment domain. These weights act as a tiebreaker when two findings share the same severity score — the finding from the higher-weighted domain appears first.

```jsonc
"riskWeights": {
  "Endpoint Security": 5,
  "Compliance & Governance": 4,
  "Device Management": 3,
  "Application Lifecycle": 2,
  "Operations & Monitoring": 1
}
```

Weights do not affect which rules fire — only the sort order of the output list.
