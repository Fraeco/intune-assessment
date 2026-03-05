# Intune Baseline Assessment Tool

Compares a customer Microsoft Intune tenant against a hardened baseline tenant and
exports a diff CSV for assessment reporting. Supports Settings Catalog, Endpoint
Security (intents), Device Configuration, Admin Templates, Compliance Policies,
and Security Baselines. Optional JSON output aggregates results for report
population.

## Key capabilities

- Baseline vs customer comparison with Compliant / Conflict / Missing / Extra results
- Baseline caching for faster reruns
- Domain enrichment across 5 assessment domains via Config/DomainMapping.json
- CSV output formatted for Excel (semicolon-delimited, UTF-8 with BOM)
- Optional ReportData.json for summary rollups

## Prerequisites

- Windows PowerShell 5.1
- An Azure AD app with Microsoft Graph **application** permissions to read Intune
  configuration in both the baseline and customer tenants
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

`AppConfig.json` should remain uncommitted.

## Usage

Basic run:

```powershell
.\IntuneBaselineAssessment.ps1 `
  -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -CustomerName "Contoso"
```

Filter baseline policies and reuse cache:

```powershell
.\IntuneBaselineAssessment.ps1 `
  -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -CustomerName "Contoso" `
  -BaselinePolicyFilter 'SBZ-Win-L1-*','SBZ-Win-Custom-*' `
  -UseBaselineCache `
  -GenerateReportData
```

## Outputs

Files are written to `Exports\` by default:

- `{Customer}_{yyyyMMdd}_{Lx}_IntuneDiff_Export.csv`
- `{Customer}_{yyyyMMdd}_{Lx}_ReportData.json` (when `-GenerateReportData`)

Baseline cache is stored in `Baseline\baseline-cache.json`.

## Parameters (high level)

- `CustomerTenantId` (required): customer Azure AD tenant ID (GUID)
- `CustomerName` (required): used in output filenames
- `BaselineLevel`: L1/L2/L3/L4 label used in outputs
- `BaselinePolicyFilter`: wildcard patterns for baseline policy names
- `UseBaselineCache`: use cached baseline instead of refetching
- `RefreshBaseline`: force refresh baseline cache
- `GenerateReportData`: write summary JSON
- `PolicyTypes`: subset of policy types to read

## Repository layout

- `IntuneBaselineAssessment.ps1` — entry point
- `Modules\` — policy readers, comparison engine, export, auth, Graph helpers
- `Config\` — app config template and domain mapping
- `Baseline\` — baseline cache (generated)
- `Exports\` — CSV/JSON outputs (generated)

## Notes

- Uses Microsoft Graph (default `beta`) and client credentials flow.
- Domain mapping in `Config\DomainMapping.json` drives report categorization.
- Baseline policy filters are baked into the cache; refresh if filters change.
