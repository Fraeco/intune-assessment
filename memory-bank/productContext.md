# Product Context

## Why This Project Exists
Consultants need a fast and consistent way to assess a customer Intune tenant against a hardened security baseline without manually reviewing each policy setting. Manual assessments are slow, error-prone, and hard to standardize across customers.

## Problems It Solves
- Reduces manual effort in baseline compliance assessments
- Standardizes comparison outputs across policy types
- Converts low-level setting diffs into domain-level insights and findings
- Produces artifacts suitable for report workflows

## Target Users
- Security consultants and assessment engineers
- Technical leads preparing customer hardening reports
- Future automation consumers (Azure Function + downstream reporting pipeline)

## User Experience Goals
- One-command assessment execution
- Clear staged progress (`[1/5]` through `[5/5]`)
- Predictable output files and schemas
- Safe read-only Graph interactions
- Re-runnable workflows via caching for iterative analysis

## Current Value Delivered
- Six policy type comparison support
- Domain enrichment and maturity scoring
- Findings/risk output via config-driven rule engine
- Inventory data collection for context beyond policy diffs
- OS lifecycle enrichment for device inventory (Graph-preferred with static fallback)

## Near-Term Value Still Needed
- Robin codebase merge phase 4 completion/hardening (prioritized):
  - Async reporting reliability and schema resilience validation
  - Deployment/app install status verification in tenant-scale runs
  - Assignment analysis false-positive tuning and reporting UX refinement
- Logging abstraction and Function-first execution model (Sprint 9)
- Automated testing and CI/CD (Sprint 10)
- Word report generation from template (Sprint 8, backlog)

## Recently Delivered Value
- Phase 2 complete: multi-policy settings conflict data deconcatenated to `SettingsConflicts.csv` (one row per contributing policy); `ReportData.json` exposes unique-setting counts plus `DetailRowCount`; `duplicate_coverage` counts unique baseline-scoped conflicting settings
- Phase 3 complete: self-contained HTML reporting (`HtmlReportGenerator.psm1`, `-GenerateHtmlReport`) plus Graph helper POST/body/header support (`Invoke-IbaGraphRequest`) delivered and tested
