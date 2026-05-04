# Project Brief: SBA-Maxim

## Project Summary
SBA-Maxim is a PowerShell-based Intune Baseline Assessment Tool. It compares a customer Microsoft Intune tenant against the eVri hardened baseline (OpenIntune L1-L4) and exports structured assessment outputs.

The tool reads configuration and inventory data through Microsoft Graph (`beta`) and produces:
- A main diff CSV (Compliant, Conflict, Missing, Extra)
- Inventory CSVs (devices, enrollment, Autopilot, apps)
- Optional `ReportData.json` for downstream report generation

## Primary Goal
Deliver a repeatable, read-only, consultant-friendly assessment process that identifies policy compliance gaps and operational risks across five domains:
1. Endpoint Security
2. Device Management
3. Compliance & Governance
4. Application Lifecycle
5. Operations & Monitoring

## Scope Status
Current implementation covers approximately 70% of the broader service description:
- Core policy comparison across 6 policy types is implemented
- Inventory collection and findings engine are implemented
- Word report generation remains pending

## Strategic Direction
The long-term runtime target is Azure Function App. Engineering decisions should prioritize:
- Non-interactive execution
- Portable path handling
- Structured outputs over console-only output
- Clear separation of orchestration vs module logic

## Canonical Inputs Used For This Memory Bank
This memory bank initialization is derived from:
- Repository docs and source (`README.md`, `HANDOVER.md`, `ENGINEERS.md`, `USER_GUIDE.md`, `AnalysisEngine.md`, `IntuneBaselineAssessment.ps1`)
- Claude agent memory files:
  - `C:/Users/vangelm/.claude/projects/c--Users-vangelm-OneDrive---Cronos-Documents-code-SBA-Maxim/memory/memory.md`
  - `C:/Users/vangelm/.claude/projects/c--Users-vangelm-OneDrive---Cronos-Documents-code-SBA-Maxim/memory/roadmap.md`
