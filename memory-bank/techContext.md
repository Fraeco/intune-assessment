# Technical Context

## Runtime and Language
- Windows PowerShell 5.1+ (script-level `#Requires -Version 5.1`)
- Modular PowerShell (`.psm1`) architecture
- Strict execution defaults (`Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`)

## External Platform Dependencies
- Microsoft Graph API (`beta`)
- OAuth2 client credentials flow (application permissions)
- Multi-tenant Entra app registration

Required Graph permissions include:
- `DeviceManagementConfiguration.Read.All`
- `DeviceManagementManagedDevices.Read.All`
- `DeviceManagementServiceConfig.Read.All`
- `DeviceManagementApps.Read.All`
- Optional: `Group.Read.All`

## Repository Structure
- Entry point: `IntuneBaselineAssessment.ps1`
- Business modules: `Modules/*.psm1`
- Configuration: `Config/*.json`
- Generated runtime data:
  - `Baseline/` (cache files)
  - `Exports/` (CSV + JSON outputs)

## Configuration Files
- `Config/AppConfig.template.json` is committed template
- `Config/AppConfig.json` is local secret-bearing runtime config (git-ignored intention)
- `Config/DomainMapping.json` controls domain mapping and risk weights
- `Config/FindingRules.json` defines findings behavior
- `Config/OSDefinition.json` provides fallback OS lifecycle mapping for device enrichment

## Outputs
- Semicolon-delimited UTF-8 BOM CSV exports for Excel compatibility
- Optional `ReportData.json` for report population and summaries

## Performance and Reliability Notes
- Shared Graph helpers for pagination, retry, and throttling
- `TimeoutSec` support for slow endpoints (Autopilot uses elevated timeout)
- Cache-first iterative workflow for baseline and definition metadata
- OS lifecycle enrichment uses Graph-preferred, static-fallback sourcing to keep output resilient when lifecycle endpoints are unavailable

## Portability Constraints (Function App Target)
- Avoid interactive UX dependencies
- Avoid hardcoded local paths
- Prefer structured outputs over console-only text
- Keep logic deterministic and parameter-driven

## Security Notes
- Secrets must remain outside source control (`AppConfig.json` should never be committed)
- Exposed credentials in legacy/parallel scripts are documented in roadmap as urgent rotation work
