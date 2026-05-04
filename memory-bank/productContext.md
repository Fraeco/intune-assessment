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
- Robin codebase merge phases 2-4 (prioritized):
  - Phase 2: multi-policy conflict summary (Phase 2.1 OS enrichment is completed)
  - Phase 3: HTML reporting and Graph API POST support
  - Phase 4: async reporting, deployment/app install status, assignment analysis
- Logging abstraction and Function-first execution model (Sprint 9)
- Automated testing and CI/CD (Sprint 10)
- Word report generation from template (Sprint 8, backlog)
