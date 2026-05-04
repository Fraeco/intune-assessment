# System Patterns

## High-Level Architecture
SBA-Maxim uses an orchestrator + module pattern:
- `IntuneBaselineAssessment.ps1` coordinates the full pipeline
- Domain modules in `Modules/*.psm1` handle isolated responsibilities
- Config-driven behavior in `Config/*.json` minimizes hardcoded policy logic

Execution pipeline:
1. Baseline load (cache or Graph fetch)
2. Customer load (Graph fetch)
3. Inventory collection (optional)
4. Comparison + findings
5. Export

## Core Data Contract
All policy readers output a common flat setting shape (8-key hashtable contract), enabling shared downstream processing:
- `PolicyName`
- `PolicyTemplate`
- `SettingPath`
- `CategoryId`
- `Value`
- `Description`
- `DefinitionId`
- `Domain` (assigned later)

This contract is the key extensibility pattern: if a new reader emits this shape, comparison/enrichment/export can work without major changes.

## Comparison Pattern
`Comparison.psm1` indexes customer settings by namespaced `DefinitionId` and compares against baseline settings:
- Result values: Compliant, Conflict, Missing, Extra
- Normalization handles booleans, JSON object/array ordering, and collection ordering
- Multi-policy strategy is optimistic: if any matching policy value is compliant, the row is compliant

## Enrichment Pattern
`Enrichment.psm1` resolves domain in ordered priority:
1. `byCategoryGuid` exact match
2. `byPolicyNamePrefix` (longest prefix first)
3. `bySettingPathKeyword`
4. fallback (`Unclassified` or default domain behavior)

## Findings Pattern
`RecommendationEngine.psm1` is config-driven via `FindingRules.json` and risk tiebreakers from `DomainMapping.json`:
- Categories: comparison, structural, inventory
- Trigger types include `keyword_cluster`, `domain_ratio`, `naming_convention`, `duplicate_coverage`, `inventory_metric`, `inventory_empty`
- Findings sort by severity score then domain risk weight

## OS Lifecycle Enrichment Pattern (Phase 2.1)
- `OsLifecycleProvider.psm1` resolves OS metadata with Graph-first, static-fallback behavior.
- Primary source: Graph lifecycle endpoints (best-effort).
- Fallback source: `Config/OSDefinition.json`.
- Device enrichment occurs at inventory collection time and is additive (existing device fields preserved).
- Enriched fields: `OsFamily`, `OsRelease`, `OsBuild`, `OsSupportState`, `OsEndOfServiceDate`, `OsSource`.
- `Export.psm1` aggregates lifecycle summaries into `ReportData.json` via `ByOsSupportState`, `ByWindowsRelease`, and `UnsupportedDeviceCount`.

## Caching Pattern
- Baseline policy cache: `Baseline/baseline-cache.json` (v2 schema with per-policy-type sections)
- Domain mapping hash enables soft re-enrichment without full re-fetch
- Definition prefetch cache (`DefinitionCache.psm1`) supports reduced Graph call volume and startup optimization

## Integration Pattern
Graph calls are routed through shared HTTP helpers in `GraphAPI.psm1`:
- Paging support
- Retry/backoff for transient failures and throttling
- Configurable `TimeoutSec` for slow endpoints (e.g., Autopilot)
