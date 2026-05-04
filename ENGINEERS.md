# Intune Baseline Assessment Tool: Engineer Guide

Internal reference for engineers running, debugging, or extending the tool. This document complements `README.md` (which targets first-time users) and focuses on the moving parts inside the script: how data flows, how modules cooperate, and what to touch when something breaks or a new feature is needed.

Target runtime note: the tool currently runs on a consultant workstation but is being prepared for an Azure Function App. Keep that in mind whenever you edit code: no interactive prompts, no hardcoded paths, prefer structured output over `Write-Host` for values that need to be consumed programmatically.

---

## 1. Quick orientation

| Item | Path |
|---|---|
| Entry point | `IntuneBaselineAssessment.ps1` |
| PowerShell modules | `Modules/*.psm1` |
| Runtime config | `Config/AppConfig.json` (git-ignored) |
| Config template | `Config/AppConfig.template.json` |
| Domain mapping | `Config/DomainMapping.json` |
| Finding rules | `Config/FindingRules.json` |
| Baseline cache | `Baseline/baseline-cache.json` (generated) |
| Outputs | `Exports/` (generated) |
| Service scope reference | `informational/servicedescription.md` |
| Report template | `informational/Intune_Assessment_Report_Template.docx` |

PowerShell requirement: Windows PowerShell 5.1 or later. The script sets `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`, so undeclared variables and non-terminating errors will halt execution. Write modules accordingly.

---

## 2. End-to-end execution flow

The orchestrator [IntuneBaselineAssessment.ps1](IntuneBaselineAssessment.ps1) runs five numbered stages. If something goes wrong, the banner in the console tells you which stage failed.

```
[1/5] Baseline tenant: fetch policies (or load cache) -> enrich -> level-filter
[2/5] Customer tenant: fetch policies -> enrich
[3/5] Customer inventory: devices, enrollment, apps (unless -SkipInventory)
[4/5] Compare baseline vs customer -> evaluate findings
[5/5] Export diff CSV + inventory CSVs + optional ReportData.json
```

### Stage 1: Baseline load

1. Import modules from [Modules/](Modules/) (order-sensitive because some modules share caches).
2. Load [Config/AppConfig.json](Config/AppConfig.json) and call `Initialize-AuthConfig`.
3. Load [Config/DomainMapping.json](Config/DomainMapping.json) via `Initialize-DomainMapping`.
4. Load [Config/FindingRules.json](Config/FindingRules.json) plus `riskWeights` from DomainMapping via `Initialize-FindingRules`.
5. Decide between cache vs fetch:
   - `-UseBaselineCache` and the cache file exists and schema matches: load from disk.
   - Otherwise: `Connect-BaselineTenant` -> `Get-AllPolicySettings` -> `Add-DomainEnrichment` -> write `Baseline/baseline-cache.json` (v2 schema).
6. Apply `-BaselineLevel` filter post-load via `Select-BaselineByLevel` (cumulative: L2 == L1+L2).

The cache stores a SHA-256 hash of `DomainMapping.json`. When the hash changes on a cached run, the cache is kept but enrichment is re-applied without a Graph re-fetch. If you change policy names or levels in the baseline tenant, you must pass `-RefreshBaseline`.

### Stage 2: Customer load

`Connect-CustomerTenant -TenantId $CustomerTenantId` acquires a client-credentials token for the customer tenant. The same readers run against it and their output is enriched with domain tags.

### Stage 3: Inventory (skippable)

`-SkipInventory` turns this off. When enabled it collects three inventories in order: devices, enrollment configs plus Autopilot identities, and apps. Missing Graph permissions produce a warning and an empty list rather than a fatal error.

### Stage 4: Compare and evaluate findings

`Compare-TenantSettings` builds a customer index keyed by `DefinitionId` and walks every baseline setting. Every baseline setting produces exactly one row. Customer-only settings produce `Extra` rows, deduplicated by `DefinitionId`.

`Get-Findings` then walks the rules loaded from `FindingRules.json` and returns a list sorted by severity and domain risk weight.

### Stage 5: Export

Always produces the diff CSV. Inventory CSVs are produced when inventory collection ran and returned non-empty results. `ReportData.json` is produced only with `-GenerateReportData`.

---

## 3. Module catalogue

Each module under [Modules/](Modules/) is a standalone `.psm1` file with a minimal public surface. Treat private helpers as implementation detail. The list below names the module, its role, and the functions that the orchestrator (or other modules) calls into.

### [Auth.psm1](Modules/Auth.psm1)
OAuth2 client-credentials flow with an in-memory token cache keyed by tenant ID and a five-minute expiry buffer.
- `Initialize-AuthConfig -Config <hashtable>` must be called once at startup.
- `Connect-BaselineTenant` returns a token for the baseline tenant.
- `Connect-CustomerTenant -TenantId <guid>` returns a token for the customer tenant.
- Token acquisition now uses `Invoke-RestMethod -TimeoutSec 60` to fail fast on Entra connectivity issues.

### [GraphAPI.psm1](Modules/GraphAPI.psm1)
Graph HTTP helpers with retry, throttling, and pagination.
- `Invoke-IbaGraphRequest -Token -Uri [-TimeoutSec]` for single calls.
- `Get-GraphPagedResults -Token -Uri [-TimeoutSec]` for collection endpoints (follows `@odata.nextLink`).

The `-TimeoutSec` knob is important for slow endpoints. The Autopilot endpoint uses 300 seconds because it routinely returns 504 under load.

### [PolicyReader.psm1](Modules/PolicyReader.psm1)
Settings Catalog reader. Recursively flattens grouped and collection settings, resolves choice labels, builds category paths by walking the parent chain, and caches definition and category lookups.
- `Get-SettingsCatalogPolicies -Token -BaseUrl [-PolicyFilter]`

### [EndpointSecurityReader.psm1](Modules/EndpointSecurityReader.psm1), [DeviceConfigReader.psm1](Modules/DeviceConfigReader.psm1), [AdminTemplateReader.psm1](Modules/AdminTemplateReader.psm1), [CompliancePolicyReader.psm1](Modules/CompliancePolicyReader.psm1), [SecurityBaselineReader.psm1](Modules/SecurityBaselineReader.psm1)
Readers for the five remaining policy types. Each produces the same eight-key flat hashtable as `PolicyReader`, so downstream modules need no changes when a new type is added.

Each exposes a `Get-*Policies` function with the same `-Token -BaseUrl -PolicyFilter` shape, plus a `Reset-*Cache` helper for test scenarios.

### [DeviceInventoryReader.psm1](Modules/DeviceInventoryReader.psm1), [EnrollmentAnalyzer.psm1](Modules/EnrollmentAnalyzer.psm1), [AppInventoryReader.psm1](Modules/AppInventoryReader.psm1)
Inventory collectors. `EnrollmentAnalyzer` returns a hashtable with `EnrollmentConfigs` and `AutopilotDevices` keys. Autopilot uses `$top=25` and `-TimeoutSec 300` because the endpoint is slow.

### [Comparison.psm1](Modules/Comparison.psm1)
Diff engine. Case-insensitive DefinitionId lookups, order-insensitive collection comparison, and JSON object and array normalization. Multi-policy coverage joins policy names and values with `, `.
- `Compare-TenantSettings -BaselineSettings -CustomerSettings`

### [Enrichment.psm1](Modules/Enrichment.psm1)
Maps settings to the five assessment domains.
- `Initialize-DomainMapping -MappingPath <path>` loads rules and builds O(1) hashtables.
- `Add-DomainEnrichment -Settings <List[hashtable]>` mutates each setting by adding `Domain`.
Resolution order: `byCategoryGuid` exact match, then `byPolicyNamePrefix` (longest prefix wins), then `bySettingPathKeyword` (first match wins), then default.

### [RecommendationEngine.psm1](Modules/RecommendationEngine.psm1)
Config-driven findings engine. Supports six trigger types: `keyword_cluster`, `comparison`, `domain_ratio`, `structural`, `inventory_metric`, `inventory_empty`, plus naming convention and duplicate coverage evaluators.
- `Initialize-FindingRules -RulesPath -RiskWeights <hashtable>`
- `Get-Findings -ComparisonResults -CustomerSettings [-DeviceInventory] [-EnrollmentData] [-AppInventory]`

### [Export.psm1](Modules/Export.psm1)
CSV and JSON writers.
- `Export-DiffCsv`: 14-column semicolon-delimited CSV, double-quoted, UTF-8 with BOM.
- `Export-DeviceInventoryCsv`, `Export-EnrollmentCsv` (two files), `Export-AppInventoryCsv`: inventory exports.
- `Export-ReportData`: aggregated JSON with summary, by-domain rollups, inventory sections, and findings sections.
- `Get-MaturityScore -CompliantPct`: 0..100 percentage to a 0..5 maturity score.

---

## 4. Configuration files

### AppConfig.json (git-ignored, required)
Created by copying `AppConfig.template.json`. Holds secrets; never commit.

```json
{
  "ClientId": "<guid>",
  "ClientSecret": "<secret>",
  "BaselineTenantId": "<guid>",
  "Authority": "https://login.microsoftonline.com",
  "GraphBaseUrl": "https://graph.microsoft.com",
  "GraphApiVersion": "beta"
}
```

`beta` is intentional: several Settings Catalog metadata fields are not exposed on `v1.0`.

### DomainMapping.json
Drives domain enrichment across the five assessment domains (Endpoint Security, Device Management, Compliance and Governance, Application Lifecycle, Operations and Monitoring).

Sections:
- `byCategoryGuid`: exact category GUID or Endpoint Security template type to domain.
- `byPolicyNamePrefix`: match on the start of a policy name (longest prefix wins).
- `bySettingPathKeyword`: substring match on SettingPath.
- `riskWeights`: numeric weight per domain, used by the findings engine to tiebreak equal-severity findings.

When you add a new SBZ baseline policy naming convention, add the prefix here; avoid relying on keyword fallback.

### FindingRules.json
Sixteen rules across three arrays: `comparisonFindings`, `structuralFindings`, `inventoryFindings`. Every rule has at least `id`, `name`, `domain`, `severity`, `trigger`, `detail`, `recommendation`. The trigger's `type` field selects which evaluator runs; see the Recommendation Engine section below for details.

### OSDefinition.json
`Config/OSDefinition.json` is the resilient fallback mapping for OS lifecycle enrichment.

Inventory OS lifecycle enrichment is implemented via `Modules/OsLifecycleProvider.psm1`:
- Provider attempts Graph lifecycle source first (when enabled).
- If Graph source is unavailable/incomplete, it falls back to `OSDefinition.json`.
- Device rows are enriched additively with:
  - `OsFamily`
  - `OsRelease`
  - `OsBuild`
  - `OsSupportState`
  - `OsEndOfServiceDate`
  - `OsSource` (`graph` or `static`)

---

## 5. Running the tool

Required parameters are `-CustomerTenantId` (GUID, validated by regex) and `-CustomerName` (free-form, used in filenames after replacing non-word characters with underscore).

```powershell
# Full run against all six policy types
.\IntuneBaselineAssessment.ps1 `
    -CustomerTenantId "<guid>" -CustomerName "Contoso"

# Iterative work: reuse cache, produce report data, skip inventory
.\IntuneBaselineAssessment.ps1 `
    -CustomerTenantId "<guid>" -CustomerName "Contoso" `
    -UseBaselineCache -GenerateReportData -SkipInventory

# Switch levels from a warm cache (no Graph calls to baseline)
.\IntuneBaselineAssessment.ps1 `
    -CustomerTenantId "<guid>" -CustomerName "Contoso" `
    -UseBaselineCache -BaselineLevel L2

# Rebuild cache after you changed baseline policies or filters
.\IntuneBaselineAssessment.ps1 `
    -CustomerTenantId "<guid>" -CustomerName "Contoso" `
    -BaselinePolicyFilter 'SBZ-Win-L1-*','SBZ-Win-Custom-*' `
    -RefreshBaseline

# Regression test: behave like the Sprint 1 version
.\IntuneBaselineAssessment.ps1 `
    -CustomerTenantId "<guid>" -CustomerName "Contoso" `
    -PolicyTypes SettingsCatalog
```

Full parameter table:

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `CustomerTenantId` | string, required | n/a | GUID validated by regex |
| `CustomerName` | string, required | n/a | Used in filenames |
| `ConfigPath` | string | `Config\` next to script | Holds AppConfig, DomainMapping, FindingRules |
| `OutputPath` | string | `Exports\` next to script | Auto-created if missing |
| `BaselinePath` | string | `Baseline\` next to script | Holds baseline-cache.json |
| `BaselineLevel` | `All`/`L1`/`L2`/`L3`/`L4` | `All` | Cumulative: L2 == L1+L2 |
| `BaselinePolicyFilter` | string[] | `@()` | Fetch-time wildcard filter, baked into cache |
| `UseBaselineCache` | switch | off | Load from `baseline-cache.json` instead of refetching |
| `RefreshBaseline` | switch | off | Force refetch even if cache exists |
| `GenerateReportData` | switch | off | Write `ReportData.json` |
| `SkipInventory` | switch | off | Skip device, enrollment, and app collection |
| `PreferGraphOsLifecycle` | switch | on | Prefer Graph lifecycle source for OS enrichment |
| `DisableGraphOsLifecycle` | switch | off | Force static `OSDefinition.json` mapping |
| `PolicyTypes` | string[] | all six | Subset of policy types to compare |

Note that `-BaselinePolicyFilter` and `-BaselineLevel` are independent and stackable: the first runs at fetch time and ships into the cache, the second runs after load and is free to change between runs.

---

## 6. Outputs

All written under `OutputPath`. Filenames use the pattern `{safeCustomerName}_{yyyyMMdd}_{Level}_{kind}.{ext}`.

| File | When produced |
|---|---|
| `..._IntuneDiff_Export.csv` | Always |
| `..._DeviceInventory.csv` | Inventory collected, non-empty |
| `..._EnrollmentConfigs.csv` | Inventory collected |
| `..._AutopilotDevices.csv` | Inventory collected |
| `..._AppInventory.csv` | Inventory collected, non-empty |
| `..._ReportData.json` | `-GenerateReportData` set |

### Diff CSV schema

Semicolon-delimited, all fields double-quoted, UTF-8 with BOM so Excel picks up the encoding. Fourteen columns:

1. Baseline Policy Name
2. Baseline Policy Template
3. Baseline Setting
4. Baseline Category (categoryId GUID)
5. Baseline Domain
6. Baseline Setting Value
7. Result: `Compliant`, `Conflict`, `Missing`, or `Extra`
8. Policy Name (customer policy)
9. Customer Setting (SettingPath; empty for `Missing`)
10. Policy Template
11. Policy Value
12. Comparison Category
13. Comparison Domain
14. Description

### ReportData.json top-level keys

`GeneratedAt`, `CustomerName`, `Consultant`, `BaselineLevel`, `Summary`, `ByDomain`, optionally `DeviceInventory`, `EnrollmentMethods`, `AppInventory`, `ExecutiveSummary`, `FindingSummary`, `FindingsByDomain`. Everything is an ordered hashtable serialised at depth 10.

Within `DeviceInventory`, lifecycle enrichment now adds:
- `ByOsSupportState`
- `ByWindowsRelease`
- `UnsupportedDeviceCount`
- Device-level lifecycle fields in `Devices[]` rows

---

## 7. Comparison semantics

### DefinitionId namespacing

The diff engine keys on `DefinitionId`. To prevent collisions across policy types, every reader namespaces its IDs:

| Policy type | Format | Example |
|---|---|---|
| Settings Catalog | raw settingDefinitionId | `device_vendor_msft_...` |
| Endpoint Security | `es:{raw}` | `es:abc123...` |
| Device Configuration | `dc:{shortOdataType}:{property}` | `dc:windows10GeneralConfiguration:defenderEnabled` |
| Admin Templates | `admx:{groupPolicyDefinition.id}` | `admx:{guid}` |
| Compliance Policy | `cp:{shortOdataType}:{property}` | `cp:windows10CompliancePolicy:passwordRequired` |
| Security Baseline | `sb:{raw}` | `sb:abc123...` |

If you add a new reader, pick a fresh two- or three-letter prefix and keep the shape consistent so Comparison keeps working unchanged.

### Result codes

- `Compliant`: customer has the setting and the value matches (case-insensitive for strings, order-insensitive for collections, normalized for JSON objects and arrays).
- `Conflict`: customer has the setting but the value differs.
- `Missing`: the baseline requires the setting; the customer has no matching DefinitionId.
- `Extra`: the customer has a setting that the baseline does not cover.

### Multi-policy coverage

If the same DefinitionId appears in multiple customer policies, all policy names and values are comma-joined into a single row. The comparison uses an optimistic strategy: if any one of the customer copies matches the baseline, the row is Compliant.

---

## 8. Baseline cache

Path: `Baseline/baseline-cache.json`.

### v2 schema (current)

```json
{
  "meta": {
    "schemaVersion": 2,
    "domainMappingHash": "<sha256>",
    "cachedAt": "<ISO8601>",
    "policyTypes": ["SettingsCatalog", "EndpointSecurity", ...]
  },
  "settingsCatalog":    [...],
  "endpointSecurity":   [...],
  "deviceConfig":       [...],
  "adminTemplates":     [...],
  "compliancePolicies": [...],
  "securityBaselines":  [...]
}
```

When you run with `-UseBaselineCache` and the cache is missing one of the `-PolicyTypes` you asked for, the orchestrator warns and re-fetches automatically.

### v1 legacy schema

```json
{ "meta": { "domainMappingHash": "<sha256>", "cachedAt": "<ISO8601>" },
  "settings": [...] }
```

Still loads, but only covers Settings Catalog. If you request anything else while pointed at a v1 cache the orchestrator warns and re-fetches with all the requested types.

### Soft re-enrichment

On cache load, the current SHA-256 of `DomainMapping.json` is compared with `meta.domainMappingHash`. If they differ, the cache is still used but `Add-DomainEnrichment` runs again over the cached settings so domain tags stay current. This avoids a full Graph re-fetch when you are just tweaking mapping rules.

### When to use which flag

- You changed `DomainMapping.json` only: run with `-UseBaselineCache`, re-enrichment happens automatically.
- You changed the baseline tenant (added or edited a policy): run with `-RefreshBaseline`.
- You changed `-BaselinePolicyFilter`: run with `-RefreshBaseline` (the filter is baked into the cache).
- You only changed `-BaselineLevel`: run with `-UseBaselineCache`, the filter is applied post-load.

---

## 9. Domain enrichment

`Add-DomainEnrichment` mutates each setting by assigning `Domain` based on `DomainMapping.json`. The resolution order inside `Resolve-Domain`:

1. `byCategoryGuid` lookup using the raw `CategoryId`.
2. `byPolicyNamePrefix` with prefixes sorted by length descending (longest wins).
3. `bySettingPathKeyword` substring scan of `SettingPath`.
4. `defaultDomain` (usually `Endpoint Security`).

When you add a new baseline policy prefix, add it to `byPolicyNamePrefix`. When you add a new Endpoint Security template type, add it to `byCategoryGuid`. Only add keywords as a last resort because substring matches are the easiest to get wrong.

---

## 10. Recommendation engine

`Get-Findings` walks `FindingRules.json` once. Each rule has a `trigger.type` that selects an evaluator. Every rule produces at most one finding.

| Trigger type | Used for | Rule fields of interest |
|---|---|---|
| `keyword_cluster` | Several settings that share a topic (BitLocker, LAPS, WHfB) | `keywords`, `resultFilter`, `threshold` |
| `comparison` | A specific DefinitionId or a specific value mismatch | `definitionId`, `expected` |
| `domain_ratio` | Overall compliance of a domain below a threshold | `domain`, `threshold` |
| `structural` | Policy-metadata checks | Varies per sub-kind |
| `naming_convention` (structural sub-kind) | Customer policies not following the SBZ naming pattern | `pattern` |
| `duplicate_coverage` (structural sub-kind) | Unique baseline-scoped conflicting settings from `Get-SettingsConflictSummary` (dedupe by baseline policy + DefinitionId) | `threshold` |
| `inventory_metric` | Ratio or threshold over inventory list | `collection`, `field`, `op`, `threshold` |
| `inventory_empty` | Collection is empty when it should not be | `collection` |

Outputs are sorted by severity score (Critical 10, High 7, Medium 4, Low 1) and, for ties, by the domain's `riskWeights` value. The top three findings are used to build `ExecutiveSummary.TopRisks` in `ReportData.json`.

### Adding a new rule

1. Append a JSON object to the appropriate array in `FindingRules.json`.
2. If you need a trigger type that does not exist, add an evaluator to `RecommendationEngine.psm1` next to the others and dispatch from `Invoke-ComparisonFinding`, `Invoke-StructuralFinding`, or `Invoke-InventoryFinding`.
3. Test with a known-good tenant and `-GenerateReportData`.

### Text templating

`Format-FindingText` expands tokens like `{count}` and `{total}` in `detail` strings. Use this rather than building strings in each evaluator.

---

## 11. Extending the tool

### Adding a new policy type

1. Create `Modules/XxxReader.psm1` exposing `Get-XxxPolicies -Token -BaseUrl [-PolicyFilter]`.
2. Pick a fresh DefinitionId prefix (two or three letters) to keep the namespace clean.
3. Output flat hashtables with the same eight keys as `PolicyReader`: `PolicyName`, `PolicyTemplate`, `SettingName`, `SettingPath`, `Value`, `DefinitionId`, `CategoryId`, `Description`.
4. Register the module name in the import list at the top of [IntuneBaselineAssessment.ps1](IntuneBaselineAssessment.ps1).
5. Add the policy type to the `[ValidateSet]` on `-PolicyTypes`, to `Get-AllPolicySettings`, and to both the cache read and cache write blocks (add a new key to `sectionMap` and a new filter when writing).
6. Add a corresponding `PolicyTemplate` value so the writer at `baselineSettings | Where-Object { $_.PolicyTemplate -eq ... }` partitions the cache correctly.
7. Extend `DomainMapping.json` with category GUIDs or name prefixes so enrichment resolves.
8. Document the DefinitionId prefix in this file.

### Adding a new domain

1. Add the domain name to the relevant lookup sections of `DomainMapping.json`.
2. Add a `riskWeights` entry so the findings engine can tiebreak with it.
3. Optionally add a baseline-level threshold in the report template consumer (Sprint 8 work).

### Adding a new finding rule

See the Recommendation Engine section above.

### Adding a new inventory source

1. Create a reader in `Modules/XxxInventoryReader.psm1` that returns `List[hashtable]`.
2. Wire it into Stage 3 in the orchestrator.
3. Add an `Export-XxxInventoryCsv` function to `Export.psm1`.
4. Extend `Export-ReportData` with a new inventory block.
5. Add an `inventory_metric` or `inventory_empty` rule to `FindingRules.json` if the data is worth evaluating.

---

## 12. Graph API considerations

- Endpoint: `beta` only. Several metadata fields we rely on are not on `v1.0`.
- Auth flow: OAuth2 client credentials. No user context, no delegated permissions.
- Throttling: 429 and 503 are retried with exponential backoff inside `Invoke-IbaGraphRequest` and `Get-GraphPagedResults`.
- Timeouts: pass `-TimeoutSec` explicitly for slow endpoints. Autopilot uses 300 seconds and `$top=25`.
- Pagination: always use `Get-GraphPagedResults` for list endpoints; do not hand-roll `@odata.nextLink` handling.
- Permissions: missing permissions on inventory endpoints produce a warning and an empty collection, not a fatal error. Missing permissions on policy endpoints are fatal.

---

## 13. Permissions

Customer admins must grant admin consent to the multi-tenant app registration for the permissions below.

| Permission | Used by |
|---|---|
| `DeviceManagementConfiguration.Read.All` | Settings Catalog, Device Config, Admin Templates, Compliance Policy, Security Baselines |
| `DeviceManagementManagedDevices.Read.All` | Device inventory |
| `DeviceManagementServiceConfig.Read.All` | Enrollment configs, Autopilot devices |
| `DeviceManagementApps.Read.All` | App inventory and assignments |
| `Group.Read.All` (optional) | Resolve assignment group GUIDs to display names |

All are Application permissions, not Delegated. No user sign-in occurs.

---

## 14. Troubleshooting

### Config not found
The script throws with a message telling you to copy `AppConfig.template.json` to `AppConfig.json`. Do that and fill in `ClientId`, `ClientSecret`, and `BaselineTenantId`.

### Baseline connect timeout
If baseline connect fails quickly with an auth timeout, validate network/proxy egress to `login.microsoftonline.com` from the PowerShell host.

### 401 Unauthorized on customer tenant
The customer admin has not granted admin consent. Confirm consent in Entra admin portal under Enterprise Applications.

### 403 Forbidden on an inventory endpoint
One of the inventory-specific permissions is missing. The tool logs a warning and continues with an empty inventory; the diff CSV is still produced.

### Graph 504 on Autopilot
The tool already uses `-TimeoutSec 300` and `$top=25`. If it still fails, the endpoint is genuinely down. Rerun later or pass `-SkipInventory` for a partial result.

### Empty baseline after level filter
`Level filter (Ln cumulative): 0 of N settings.` means none of the baseline policy names contain `-Ln-`. Check that the baseline policies follow the `SBZ-Win-Ln-*` naming convention or adjust the filter in `Select-BaselineByLevel`.

### Cache claims to be missing a policy type
You ran once with `-PolicyTypes SettingsCatalog` (cache built for that subset only) and then ran with more types against the cache. The orchestrator warns and re-fetches automatically, which is the correct behaviour.

### v1 cache warning
You have a cache from a Sprint 1 build. Delete `Baseline/baseline-cache.json` or run with `-RefreshBaseline`.

### Every domain resolves to the default
`DomainMapping.json` did not load, or no rule matches. Check for JSON syntax errors; `Initialize-DomainMapping` does a schema-lite validation at load time.

### Findings engine reports zero findings
Either `FindingRules.json` is missing (warning at startup, engine disabled) or no rule's trigger fired. Run with `-Verbose` to see per-rule evaluation.

### Settings appear as Extra that you expected to be Compliant
Usually a DefinitionId mismatch. Confirm both sides produce the same namespaced ID by inspecting the raw reader output before comparison.

---

## 15. Azure Function App portability

The tool is targeted at Azure Function App deployment. Apply these rules to every change:

- No interactive prompts. No `Read-Host`, no `Out-GridView`, no `-Confirm` prompts without `-Force`.
- No hardcoded file paths. Use `$PSScriptRoot` or parameter defaults; accept overrides via parameters.
- Prefer structured output over `Write-Host` for anything downstream needs to parse. `Write-Host` is fine for humans; return values or write JSON for machines.
- Keep state in module-scope variables (not in the file system) unless caching is the explicit goal. The baseline cache is the one exception and is documented as such.
- Avoid dependencies on modules that are not shipped in the Azure Functions PowerShell runtime.
- Do not write secrets to stdout. `AppConfig.json` is the only acceptable place for them locally; in Azure, these values will come from Key Vault references.

See `memory/roadmap.md` for full portability notes and the Sprint 9 plan.

---

## 16. Known gaps and roadmap (high level)

- Sprint 8: Word report generation from the template in `informational/`.
- Sprint 9: logging abstraction (replace `Write-Host` in hot paths with a structured logger) and Azure Function App entry point.
- Sprint 10: Pester tests plus CI.

For current backlog and sprint-by-sprint detail, see `memory/roadmap.md` (not committed; held in Claude's memory store).
