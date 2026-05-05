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
- Logging abstraction rollout is complete across modules: business modules now use `Write-IbaLog` / `Write-IbaProgress`; `Logger.psm1` remains the single console/progress owner

## Robin Merge Plan Status
Phase 1 is implemented in the current codebase.

### Phase 2 (Quick Wins) - Complete
1. OS definition + device compliance summary - Implemented (Phase 2.1)
   - Added `Config/OSDefinition.json` fallback mapping.
   - Added `Modules/OsLifecycleProvider.psm1` (Graph-first with static fallback).
   - Integrated additive lifecycle enrichment in `DeviceInventoryReader.psm1`.
   - Extended `ReportData.json` with `ByOsSupportState`, `ByWindowsRelease`, and `UnsupportedDeviceCount`.
   - Added orchestrator switches: `-PreferGraphOsLifecycle` and `-DisableGraphOsLifecycle`.
2. Settings conflict detection (multi-policy) - Implemented (Phase 2.2)
   - Added `Get-SettingsConflictSummary` in `Modules/Comparison.psm1`: deconcatenated rows (one per contributing customer policy) for multi-policy divergences; baseline scope is `(BaselinePolicyName, DefinitionId)`; Extras are per `DefinitionId`.
   - Equality uses existing `Normalize-SettingValue` (avoids cosmetic false conflicts).
   - Standalone CSV `Export-SettingsConflictsCsv` (`{Customer}_{date}_{Lx}_SettingsConflicts.csv`) — no comma-joined policy lists (contrast with `IntuneDiff_Export`).
   - `SettingsConflicts` in `ReportData.json`: `TotalConflictingSettings` / `ByDomain` count unique conflicting settings; `DetailRowCount` + `Items` hold deconcatenated rows.
   - Refactored `Invoke-DuplicateCoverageFinding` in `Modules/RecommendationEngine.psm1` to consume the summary directly (filtered to `HasBaseline = true`).
   - Orchestrator emits a console summary line and threads the data through findings + exports.

### Phase 3 (Visual Reporting) - Complete
1. HTML report generation - Implemented
   - Added `HtmlReportGenerator.psm1` and optional `-GenerateHtmlReport` switch.
   - Produces styled, self-contained HTML summary with safe encoding.
   - Includes executive summary, domain overview, baseline policy overview, and detailed collapsible sections.
   - Added text-based metric color coding for `Total`, `Compliant`, `Conflict`, and `Missing` in KPI cards and overview tables.
2. POST support in Graph API helper - Implemented
   - Extended `Invoke-IbaGraphRequest` beyond GET to support JSON-body POST calls and optional additional headers.
   - Reused as prerequisite plumbing for async reporting work in Phase 4.

### Phase 4 (Advanced Reporting) - In Progress
1. Async report export system
   - Added `Modules/IntuneReportExporter.psm1` with async export job POST/poll/download flow.
   - Temp artifact path is parameterized and cleaned up after import.
2. Policy deployment status + app install reporting
   - Added aggregate-only app install export path (`AppInstallStatusAggregate`) and policy assignment status export path.
   - Device-level failed install details (`DeviceAppInstallationStatusReport`) are explicitly deferred to Phase 4.1.
3. Policy assignment analysis
   - Added `Modules/AssignmentAnalysis.psm1` to resolve assignment targets and flag unassigned/potentially-dead policies.
   - Added additive CSV/JSON export sections and finding triggers tied to Phase 4 metrics.
4. Advanced HTML analysis sections
   - Extended `Modules/HtmlReportGenerator.psm1` with four collapsible Phase 4 analysis sections:
     - `AllPolicyStatusOverview`
     - `AllPolicyAssignmentSummary`
     - `AllDeviceAssignmentStatusByConfigurationPolicy`
     - `AppInstallStatusAggregateSummary`
   - Added in-report sorting and per-section filters for requested columns.
   - Added color-coded row states and a 500-row render cap per advanced section.

## Immediate Next Engineering Priorities
1. Finalize Robin merge Phase 4:
   - Validate advanced report exports in a tenant run and tune column mappings.
   - Validate assignment analysis false-positive rate and adjust conservative detection rules if needed.
2. Continue Sprint 9 logger abstraction rollout:
   - Add non-interactive/structured logging mode coverage to improve Function portability.
   - Validate level/verbosity behavior parity in tenant runs.
3. Build test harness for normalization/comparison/enrichment core functions (Sprint 10 kickoff).
4. Keep Sprint 8 Word report generation in backlog until Robin merge phases are completed.

## Operational Notes
- Keep all new work Function-ready by default.
- Preserve existing data contracts to avoid breaking comparison/export pipelines.
- Prioritize additive and backward-compatible changes in config schemas.
