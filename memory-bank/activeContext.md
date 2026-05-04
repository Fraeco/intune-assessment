# Active Context

## Current Focus
Memory bank has been initialized from current repository state plus Claude memory sources. The project itself is currently beyond Sprint 7, with v0.8.0 banner in orchestrator and DefinitionCache integration present.

## Confirmed Current State
- Core policy comparison supports 6 policy types
- Inventory collection supports device, enrollment/Autopilot, and app inventory
- Findings engine is active and config-driven
- Definition prefetch/cache capability is integrated (`DefinitionCache.psm1`, `-UseDefinitionsCache`, `-RefreshDefinitions`)
- Baseline cache v2 is active with per-policy-type sections

## Roadmap Alignment (Claude Memory)
From the imported roadmap:
- Sprint 8 (Word report generation) moved to backlog
- Sprint 9 target: logging abstraction + Azure Function prep
- Sprint 10 target: tests + CI/CD
- High-priority quality concern persists: heavy `Write-Host` usage limits Function portability

## Robin Merge Plan Status
Phase 1 is implemented in the current codebase.

### Phase 2 (Quick Wins) - Pending
1. OS definition + device compliance summary - Implemented (Phase 2.1)
   - Added `Config/OSDefinition.json` fallback mapping.
   - Added `Modules/OsLifecycleProvider.psm1` (Graph-first with static fallback).
   - Integrated additive lifecycle enrichment in `DeviceInventoryReader.psm1`.
   - Extended `ReportData.json` with `ByOsSupportState`, `ByWindowsRelease`, and `UnsupportedDeviceCount`.
   - Added orchestrator switches: `-PreferGraphOsLifecycle` and `-DisableGraphOsLifecycle`.
2. Settings conflict detection (multi-policy)
   - Add standalone conflict summary output based on settings configured differently across multiple customer policies.
   - Implement in `Comparison.psm1` and expose in report-ready data.

### Phase 3 (Visual Reporting) - Pending
1. HTML report generation
   - Add `HtmlReportGenerator.psm1` and optional `-GenerateHtmlReport` switch.
   - Produce styled, self-contained HTML summary with safe encoding.
2. POST support in Graph API helper
   - Extend `Invoke-IbaGraphRequest` beyond GET to support JSON-body POST calls.
   - This is a prerequisite for Phase 4 async reporting.

### Phase 4 (Advanced Reporting) - Pending
1. Async report export system
   - Add `IntuneReportExporter.psm1` based on Graph reporting API patterns.
   - Parameterize temp paths and ensure Function-compatible execution.
2. Policy deployment status + app install reporting
   - Surface per-policy status counts and failed app install telemetry.
3. Policy assignment analysis
   - Add assignment target analysis and summary (including group/filter resolution).
   - Enable findings such as unassigned/dead policies.

## Immediate Next Engineering Priorities
1. Execute Robin merge Phase 2:
   - Standalone multi-policy settings conflict summary.
2. Execute Robin merge Phase 3:
   - HTML report generation module + switch.
   - Add POST support to `GraphAPI.psm1`.
3. Execute Robin merge Phase 4:
   - Async report export integration.
   - Policy deployment/app install reporting.
   - Policy assignment analysis and related findings.
4. Continue Sprint 9 logger abstraction (`Logger.psm1`) and replacement of high-value `Write-Host` usage.
5. Build test harness for normalization/comparison/enrichment core functions (Sprint 10 kickoff).
6. Keep Sprint 8 Word report generation in backlog until Robin merge phases are completed.

## Operational Notes
- Keep all new work Function-ready by default.
- Preserve existing data contracts to avoid breaking comparison/export pipelines.
- Prioritize additive and backward-compatible changes in config schemas.
