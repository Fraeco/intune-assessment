# Intune Baseline Assessment Tool

Compares a customer Microsoft Intune tenant against a hardened baseline tenant and
exports a diff CSV for assessment reporting. Supports Settings Catalog, Endpoint
Security (intents), Device Configuration, Admin Templates, Compliance Policies,
and Security Baselines. Also collects device, enrollment, and application inventory
for the customer tenant. Optional JSON output aggregates all results for report
population.

## Key capabilities

- Baseline vs customer comparison with Compliant / Conflict / Missing / Extra results
- 6 policy types: Settings Catalog, Endpoint Security, Device Configuration, Admin Templates, Compliance Policies, Security Baselines
- Device inventory — managed devices with compliance state, OS version, and lifecycle enrichment
- Enrollment analysis — enrollment configurations and Autopilot device identities
- Application inventory — mobile apps with assignment intent and group targeting
- Domain enrichment across 5 assessment domains via `Config/DomainMapping.json`
- Baseline caching (v2) for faster reruns; hash-based soft re-enrichment on domain mapping changes
- CSV outputs formatted for Excel (semicolon-delimited, UTF-8 with BOM)
- Optional `ReportData.json` for summary rollups including inventory sections
- Optional self-contained `AssessmentReport.html` with executive and detailed sections
- Multi-policy settings conflict export (`SettingsConflicts.csv`): one row per contributing customer policy (deconcatenated); `IntuneDiff_Export` remains the joined summary

## Prerequisites

- Windows PowerShell 5.1+
- A multi-tenant Azure AD app registration with Microsoft Graph **application** permissions (see [App Registration](#app-registration))
- Access to the baseline tenant ID used for comparison

## Setup

1. Copy the template config and fill in values:

   ```powershell
   Copy-Item Config\AppConfig.template.json Config\AppConfig.json
   ```

2. Edit `Config\AppConfig.json` with your app registration details:
   - `ClientId`
   - `ClientSecret`
   - `BaselineTenantId`
   - `Authority` (default: `https://login.microsoftonline.com`)
   - `GraphBaseUrl` and `GraphApiVersion` (default: `beta`)

`AppConfig.json` is git-ignored and should never be committed.

## App Registration

Create a multi-tenant Azure AD app registration with the following **application** permissions (no user sign-in required). Customer admins must grant admin consent.

| Permission | Purpose |
|---|---|
| `DeviceManagementConfiguration.Read.All` | Settings Catalog, Device Config, Admin Templates, Compliance Policies, Security Baselines |
| `DeviceManagementManagedDevices.Read.All` | Device inventory |
| `DeviceManagementServiceConfig.Read.All` | Enrollment configurations, Autopilot devices |
| `DeviceManagementApps.Read.All` | Application inventory and assignments |
| `Group.Read.All` | *(Optional)* Resolve assignment group GUIDs to display names |

## Usage

Full run (all 6 policy types + inventory):

```powershell
.\IntuneBaselineAssessment.ps1 `
  -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -CustomerName "Contoso"
```

With cached baseline and report data (JSON + HTML):

```powershell
.\IntuneBaselineAssessment.ps1 `
  -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -CustomerName "Contoso" `
  -UseBaselineCache `
  -GenerateReportData `
  -GenerateHtmlReport
```

Skip inventory collection (faster for iterative testing):

```powershell
.\IntuneBaselineAssessment.ps1 `
  -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -CustomerName "Contoso" `
  -SkipInventory
```

Specific policy types only:

```powershell
.\IntuneBaselineAssessment.ps1 `
  -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -CustomerName "Contoso" `
  -PolicyTypes SettingsCatalog, CompliancePolicy
```

Filter baseline policies and force cache refresh:

```powershell
.\IntuneBaselineAssessment.ps1 `
  -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -CustomerName "Contoso" `
  -BaselinePolicyFilter 'SBZ-Win-L1-*','SBZ-Win-Custom-*' `
  -RefreshBaseline
```

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `CustomerTenantId` | string (required) | Customer Azure AD tenant ID (GUID) |
| `CustomerName` | string (required) | Used in output filenames |
| `BaselineLevel` | All/L1/L2/L3/L4 | Baseline tier label (default: All) |
| `BaselinePolicyFilter` | string[] | Wildcard patterns for baseline policy names |
| `UseBaselineCache` | switch | Use `Baseline\baseline-cache.json` instead of refetching |
| `RefreshBaseline` | switch | Force baseline re-fetch and overwrite cache |
| `UseDefinitionsCache` | switch | Persist/reuse `Baseline\definitions-cache.json` for definition prefetch |
| `RefreshDefinitions` | switch | Force refresh of the definitions cache |
| `GenerateReportData` | switch | Write `ReportData.json` with aggregated scores and inventory |
| `GenerateHtmlReport` | switch | Write `AssessmentReport.html` with executive and detailed sections |
| `SkipInventory` | switch | Skip device/enrollment/app inventory collection |
| `PreferGraphOsLifecycle` | switch | Prefer Graph lifecycle source for OS metadata, with static fallback |
| `DisableGraphOsLifecycle` | switch | Disable Graph lifecycle lookup and force static `Config\OSDefinition.json` |
| `PolicyTypes` | string[] | Subset of policy types to compare (default: all 6) |

`PolicyTypes` values: `SettingsCatalog`, `EndpointSecurity`, `DeviceConfig`, `AdminTemplates`, `CompliancePolicy`, `SecurityBaseline`

## Outputs

All files are written to `Exports\` by default:

| File | When |
|---|---|
| `{Customer}_{date}_{Lx}_IntuneDiff_Export.csv` | Always |
| `{Customer}_{date}_{Lx}_DeviceInventory.csv` | When inventory collected |
| `{Customer}_{date}_{Lx}_EnrollmentConfigs.csv` | When inventory collected |
| `{Customer}_{date}_{Lx}_AutopilotDevices.csv` | When inventory collected |
| `{Customer}_{date}_{Lx}_AppInventory.csv` | When inventory collected |
| `{Customer}_{date}_{Lx}_SettingsConflicts.csv` | When multi-policy conflicts detected |
| `{Customer}_{date}_{Lx}_ReportData.json` | With `-GenerateReportData` |
| `{Customer}_{date}_{Lx}_AssessmentReport.html` | With `-GenerateHtmlReport` |

Baseline cache: `Baseline\baseline-cache.json`

## Repository layout

```
IntuneBaselineAssessment.ps1   — entry point (orchestrator)
Modules\
  Auth.psm1                    — OAuth2 client credentials, token caching
  GraphAPI.psm1                — Graph HTTP helpers, pagination, retry/throttle
  PolicyReader.psm1            — Settings Catalog reader
  EndpointSecurityReader.psm1  — Endpoint Security intents reader
  DeviceConfigReader.psm1      — Device Configuration profiles reader
  AdminTemplateReader.psm1     — Admin Templates (ADMX/GP) reader
  CompliancePolicyReader.psm1  — Compliance Policy reader
  SecurityBaselineReader.psm1  — Security Baselines reader
  DeviceInventoryReader.psm1   — Managed device inventory
  EnrollmentAnalyzer.psm1      — Enrollment configs + Autopilot devices
  AppInventoryReader.psm1      — App inventory with assignment data
  OsLifecycleProvider.psm1     — OS lifecycle resolver (Graph-first, static fallback)
  Comparison.psm1              — Diff engine (Compliant/Conflict/Missing/Extra)
  Enrichment.psm1              — Domain enrichment via DomainMapping.json
  Export.psm1                  — CSV and JSON output generation
  HtmlReportGenerator.psm1     — Self-contained HTML report generation
Config\
  AppConfig.template.json      — Config template (copy to AppConfig.json)
  DomainMapping.json           — Domain enrichment rules
  OSDefinition.json            — OS lifecycle fallback mapping
Baseline\                      — Baseline cache (generated, not committed)
Exports\                       — Output files (generated, not committed)
```

## Notes

- Uses Microsoft Graph API (`beta` endpoint) with the OAuth2 client credentials flow.
- Domain mapping in `Config\DomainMapping.json` drives report categorization across 5 assessment domains: Endpoint Security, Device Management, Compliance & Governance, Application Lifecycle, Operations & Monitoring.
- Baseline policy filters are baked into the cache; use `-RefreshBaseline` if filters change.
- Baseline auth token acquisition in `Auth.psm1` uses a 60-second timeout to avoid indefinite hangs when Entra connectivity is degraded.
- New Graph API permissions (`DeviceManagementServiceConfig.Read.All`, `DeviceManagementApps.Read.All`) must be granted by the customer admin before inventory collection will succeed. Missing permissions produce a warning and an empty inventory, not a fatal error.
- OS lifecycle enrichment is additive and backward compatible: existing inventory fields remain unchanged, while `OsFamily`, `OsRelease`, `OsBuild`, `OsSupportState`, `OsEndOfServiceDate`, and `OsSource` are appended.
- `Invoke-IbaGraphRequest` in `Modules\GraphAPI.psm1` now supports optional JSON request body and additional headers to support Phase 4 async reporting API calls.
