# Intune Baseline Assessment Tool — Technical Handover

This document is a deep technical reference for colleagues taking over maintenance and extension of the Intune Baseline Assessment Tool. It assumes you are comfortable writing PowerShell scripts but does not assume software development experience. When in doubt, it explains.

> **Other documentation in this repository:**
>
> | Document | Purpose |
> |---|---|
> | [README.md](README.md) | First-time setup, prerequisites, quick-start |
> | [USER_GUIDE.md](USER_GUIDE.md) | Running assessments and reading output (consultant-facing) |
> | [ENGINEERS.md](ENGINEERS.md) | Concise developer reference (assumes development background) |
> | [AnalysisEngine.md](AnalysisEngine.md) | Deep dive on the findings engine specifically |
>
> This document covers everything those documents cover and more, but with thorough explanations. If you only have time for one document, read this one.

---

## Quick reference: "I need to do X"

| I need to... | Go to section |
|---|---|
| Understand what the tool does end-to-end | [3. Architecture Overview](#3-architecture-overview) |
| Understand the data that flows between modules | [4. The Data Model](#4-the-data-model) |
| Understand a specific module's internals | [6. Module Deep Dives](#6-module-deep-dives) |
| Add a new baseline policy and re-run | [8.1](#81-a-baseline-policy-was-added-renamed-or-removed) |
| Fix an "Unclassified" domain in the CSV | [8.2](#82-a-setting-shows-up-as-unclassified-in-the-domain-column) |
| Tune or add a finding rule | [8.4](#84-a-finding-rule-needs-tuning) / [9.2](#92-adding-a-new-finding-rule) |
| Add support for a new Intune policy type | [9.1](#91-adding-a-new-policy-reader) |
| Debug a 401/403/504 error | [10. Troubleshooting](#10-troubleshooting-reference) |
| Understand a PowerShell pattern in the code | [2. PowerShell Concepts](#2-powershell-concepts-you-need-to-know) |

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [PowerShell Concepts You Need to Know](#2-powershell-concepts-you-need-to-know)
3. [Architecture Overview](#3-architecture-overview)
4. [The Data Model](#4-the-data-model)
5. [The Orchestrator: IntuneBaselineAssessment.ps1](#5-the-orchestrator)
6. [Module Deep Dives](#6-module-deep-dives)
7. [Configuration Files In Depth](#7-configuration-files-in-depth)
8. [Maintenance Cookbook](#8-maintenance-cookbook)
9. [Extension Guide](#9-extension-guide)
10. [Troubleshooting Reference](#10-troubleshooting-reference)
11. [Glossary](#11-glossary)

---

## 1. Introduction

### What the tool does

The Intune Baseline Assessment Tool compares a customer's Microsoft Intune tenant against the eVri hardened baseline (OpenIntune L1-L4). It reads configuration from both tenants via the Microsoft Graph API, compares every setting, and exports a detailed diff report showing what is compliant, what conflicts, what is missing, and what is extra.

It also collects inventory data (devices, enrollment configurations, Autopilot registrations, and applications) from the customer tenant and runs an analysis engine that produces prioritised findings with recommendations.

**The tool only reads data. It never writes to or modifies either tenant.**

### How the codebase is organised

```
SBA-Maxim/
  IntuneBaselineAssessment.ps1    <-- Main script (the "orchestrator")
  Modules/
    Auth.psm1                     <-- OAuth2 token management
    GraphAPI.psm1                 <-- HTTP helpers for Microsoft Graph
    PolicyReader.psm1             <-- Settings Catalog reader
    EndpointSecurityReader.psm1   <-- Endpoint Security reader
    DeviceConfigReader.psm1       <-- Device Configuration reader
    AdminTemplateReader.psm1      <-- Admin Templates (ADMX) reader
    CompliancePolicyReader.psm1   <-- Compliance Policy reader
    SecurityBaselineReader.psm1   <-- Security Baselines reader
    OsLifecycleProvider.psm1      <-- OS lifecycle resolver (Graph-first, static fallback)
    DeviceInventoryReader.psm1    <-- Managed device inventory
    EnrollmentAnalyzer.psm1       <-- Enrollment configs + Autopilot
    AppInventoryReader.psm1       <-- App inventory with assignments
    Comparison.psm1               <-- Diff engine
    Enrichment.psm1               <-- Domain mapping (assigns assessment domains)
    RecommendationEngine.psm1     <-- Findings engine
    Export.psm1                   <-- CSV and JSON output writers
  Config/
    AppConfig.json                <-- Secrets (git-ignored, never commit!)
    AppConfig.template.json       <-- Template to copy for AppConfig.json
    DomainMapping.json            <-- Rules for mapping settings to domains
    FindingRules.json             <-- Rules for generating findings
    OSDefinition.json             <-- Fallback OS lifecycle mapping
  Baseline/
    baseline-cache.json           <-- Cached baseline data (generated)
  Exports/                        <-- Output files (generated)
  informational/                  <-- Report template and service description
```

---

## 2. PowerShell Concepts You Need to Know

This section explains programming patterns used throughout the codebase. If you have written PowerShell scripts but have not worked with modules or .NET collections before, read this section first. It will make the rest of the document much easier to follow.

### 2.1 Modules (.psm1 files) vs. Scripts (.ps1 files)

A `.ps1` file is a script you run directly. A `.psm1` file is a **module** — a reusable library of functions that you load into your PowerShell session with `Import-Module`.

The key difference: a module controls which functions are visible to the outside world. At the bottom of every `.psm1` file in this project, you will see a line like:

```powershell
Export-ModuleMember -Function @(
    'Compare-TenantSettings'
)
```

This means only `Compare-TenantSettings` can be called by other code. Any other functions in that file (like `Build-ComparisonRow` or `Normalize-SettingValue`) are **internal helpers** — they exist to support the public function but are not meant to be called directly.

**Why this matters for you:** When you look at a module and want to know "what does this module do?", scroll to the bottom and look at `Export-ModuleMember`. Those are the functions that matter. Everything else is implementation detail.

The orchestrator loads every module with `-Force`:

```powershell
Import-Module $modulePath -Force -DisableNameChecking
```

The `-Force` flag means "reload even if already loaded." This is important during development because without it, PowerShell would keep using the old version of a module you just edited. If you change a module and re-run the script, `-Force` ensures your changes take effect.

### 2.2 Script-scope variables ($script:)

Several modules store data in variables that start with `$script:`, for example:

```powershell
# In Auth.psm1
$script:TokenCache = [System.Collections.Generic.Dictionary[string, hashtable]]::new()

# In Enrichment.psm1
$script:CategoryGuidTable = $null
```

In PowerShell, a variable declared with `$script:` lives at the **module level**. This means:

- It is created when the module is imported.
- It survives between function calls within that module.
- It is not visible to code outside the module.
- It is destroyed when the module is re-imported (because of `-Force`).

**What this means in practice:** These are **in-memory caches**. For example, `Auth.psm1` caches authentication tokens in `$script:TokenCache`. The first time you connect to a tenant, it fetches a token from Azure AD. The second time, it returns the cached token without making a network call. This cache lives only in memory — if you close PowerShell, the cache is gone.

**Why not just use a regular variable?** A regular variable (`$myVar`) inside a function disappears when that function ends. A `$script:` variable persists for the lifetime of the module, which is what we need for caching.

### 2.3 Hashtables as data records

Throughout this codebase, data is passed around as **hashtables** (`@{}`). A hashtable is a collection of key-value pairs:

```powershell
$setting = @{
    PolicyName     = 'SBZ-Win-L1-ES-Antivirus'
    PolicyTemplate = 'Settings Catalog'
    SettingPath    = 'Antivirus > Enable Cloud Protection'
    Value          = 'true'
}

# Access a value:
$setting.PolicyName         # returns 'SBZ-Win-L1-ES-Antivirus'
$setting['PolicyName']      # same thing, different syntax
```

**Why hashtables instead of custom objects or classes?** Two reasons:

1. **Compatibility**: hashtables work identically in Windows PowerShell 5.1 and PowerShell 7+. Custom classes behave differently across versions.
2. **Flexibility**: hashtables are easy to create, modify, and pass between functions without defining a formal type.

**The critical convention in this codebase:** Every policy reader (PolicyReader, EndpointSecurityReader, DeviceConfigReader, etc.) outputs a list of hashtables with **exactly the same 8 keys**. This is the tool's "data contract" — see [Section 4](#4-the-data-model) for the full schema. Because every reader produces the same shape, the Comparison and Enrichment modules work with all policy types without any changes.

You will also see `[ordered]@{}` in some places. This creates an **ordered** hashtable where keys maintain their insertion order. This is used in output/export code where column order matters (e.g., the CSV columns or the JSON structure).

### 2.4 Generic collections: List and Dictionary

Throughout the code you will see types like:

```powershell
$results = [System.Collections.Generic.List[hashtable]]::new()
$results.Add($someHashtable)
```

This is a **strongly-typed list** from .NET. You might wonder: "Why not just use a normal PowerShell array?"

```powershell
# Normal PowerShell array approach:
$results = @()
$results += $someHashtable   # This is SLOW for large arrays!
```

The problem is that `+=` on a PowerShell array **creates a brand new array every time**, copies all existing items into it, and then adds the new item. If you are adding 5,000 settings one by one, PowerShell creates 5,000 arrays. With `List[hashtable]`, the `.Add()` method just appends to the existing list — much faster.

Similarly, `Dictionary[string, hashtable]` is a fast lookup table (like a hashtable of hashtables):

```powershell
$index = [System.Collections.Generic.Dictionary[string, hashtable]]::new()
$index['some-key'] = $someHashtable
```

**The single-element unwrapping gotcha:** When PowerShell sends a collection through the pipeline and it contains exactly one item, PowerShell "unwraps" it — you get the single item instead of a one-element array. The code handles this in several places using `@()` wrapping or the unary comma operator `, $list`:

```powershell
# Dangerous: if $results has only 1 item, this returns the item, not an array
$filtered = $results | Where-Object { $_.Result -eq 'Compliant' }

# Safe: @() forces an array context, so .Count always works
$filtered = @($results | Where-Object { $_.Result -eq 'Compliant' })
$filtered.Count  # always returns a number, even if 0 or 1
```

You will see `@(...)` used throughout the codebase. This is why.

### 2.5 Set-StrictMode and $ErrorActionPreference = 'Stop'

Every module and the main script begin with:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

**`Set-StrictMode -Version Latest`** makes PowerShell strict about variable usage. Without it, referencing a variable that does not exist silently returns `$null`. With strict mode, it throws an error. This catches typos: if you type `$Tokan` instead of `$Token`, you get an immediate error instead of silent `$null` propagation that causes a confusing failure later.

**`$ErrorActionPreference = 'Stop'`** makes non-terminating errors (like a failed HTTP request) into terminating errors that halt execution. Without this, a failed Graph API call might silently return nothing and the script would continue with empty data. With `'Stop'`, it immediately throws and you see exactly what failed.

**What this means for you:** If you edit a module and introduce a typo in a variable name, the script will fail immediately with a clear error telling you the variable does not exist. This is intentional — it is much better than the script silently continuing with wrong data.

### 2.6 The pipeline and ForEach-Object vs. foreach

You will see two looping patterns in the code:

```powershell
# Pattern 1: Pipeline with ForEach-Object (uses $_ for current item)
$results | Where-Object { $_.Result -eq 'Compliant' } | ForEach-Object { $_.PolicyName }

# Pattern 2: foreach statement (uses a named variable)
foreach ($s in $Settings) {
    $s['Domain'] = Resolve-Domain -Setting $s
}
```

Both do the same thing. The codebase uses `foreach` for performance-critical loops (it is faster than the pipeline) and the pipeline for filtering and transforming operations where readability matters more than speed.

---

## 3. Architecture Overview

### 3.1 The 5-Stage Pipeline

The main script runs five numbered stages. If something goes wrong, the console output tells you which stage failed.

```
[1/5] Baseline tenant
      |
      +-- Load from cache (if -UseBaselineCache and cache exists)
      |   +-- Re-enrich if DomainMapping.json changed (hash check)
      |
      +-- OR fetch from Graph API
      |   +-- Connect to baseline tenant (OAuth2)
      |   +-- Run all 6 policy readers
      |   +-- Enrich with domain tags
      |   +-- Write baseline-cache.json
      |
      +-- Apply -BaselineLevel filter (post-load, always)

[2/5] Customer tenant
      +-- Connect to customer tenant (OAuth2)
      +-- Run all 6 policy readers
      +-- Enrich with domain tags

[3/5] Customer inventory (skipped if -SkipInventory)
      +-- Device inventory (managed devices)
      +-- Enrollment analysis (enrollment configs + Autopilot)
      +-- App inventory (apps with assignments)

[4/5] Compare + Analyse
      +-- Compare-TenantSettings (produces diff rows)
      +-- Get-Findings (evaluates finding rules)

[5/5] Export
      +-- Diff CSV (always)
      +-- Device inventory CSV (if collected)
      +-- Enrollment configs CSV (if collected)
      +-- Autopilot devices CSV (if collected)
      +-- App inventory CSV (if collected)
      +-- ReportData.json (if -GenerateReportData)
```

### 3.2 Data Flow

This diagram shows how data flows through the modules. The arrows show which module produces data and which module consumes it.

```
                     +----------------+
                     | AppConfig.json |
                     +-------+--------+
                             |
                     +-------v--------+
                     |   Auth.psm1    |  Produces OAuth2 tokens
                     +-------+--------+
                             | token
                     +-------v--------+
                     | GraphAPI.psm1  |  HTTP layer (used by all readers)
                     +-------+--------+
                             |
           +-----------------+-----------------+
           |                                   |
  +--------v---------+              +----------v----------+
  |  Policy Readers  |              |  Inventory Readers  |
  |  (6 modules)     |              |  (3 modules)        |
  |                  |              |                     |
  |  Each outputs    |              |  Different schemas  |
  |  List[hashtable] |              |  per reader         |
  |  with 8 keys     |              |                     |
  +--------+---------+              +----------+----------+
           |                                   |
  +--------v---------+                         |
  | Enrichment.psm1  |<--- DomainMapping.json  |
  |                  |                         |
  | Adds Domain field|                         |
  +--------+---------+                         |
           |                                   |
  +--------v---------+                         |
  | Comparison.psm1  |                         |
  |                  |                         |
  | Baseline vs      |                         |
  | Customer diff    |                         |
  +--------+---------+                         |
           |                                   |
  +--------v-----------------------------------v--+
  | RecommendationEngine.psm1  <-- FindingRules.json
  |                                               |
  | Evaluates finding rules against diff+inventory|
  +---------------------+-------------------------+
                        |
              +---------v----------+
              |    Export.psm1     |
              |                   |
              | CSV + JSON output |
              +-------------------+
```

### 3.3 Module Dependency Map

This shows which modules depend on which. If you are editing a module, check what depends on it.

| Module | Depends on | Depended on by |
|---|---|---|
| Auth.psm1 | (none) | All readers (via orchestrator) |
| GraphAPI.psm1 | (none) | All readers |
| PolicyReader.psm1 | GraphAPI | Orchestrator |
| EndpointSecurityReader.psm1 | GraphAPI | Orchestrator |
| DeviceConfigReader.psm1 | GraphAPI | Orchestrator |
| AdminTemplateReader.psm1 | GraphAPI | Orchestrator |
| CompliancePolicyReader.psm1 | GraphAPI | Orchestrator |
| SecurityBaselineReader.psm1 | GraphAPI | Orchestrator |
| DeviceInventoryReader.psm1 | GraphAPI | Orchestrator |
| EnrollmentAnalyzer.psm1 | GraphAPI | Orchestrator |
| AppInventoryReader.psm1 | GraphAPI | Orchestrator |
| Enrichment.psm1 | (none — reads DomainMapping.json directly) | Orchestrator |
| Comparison.psm1 | (none) | Orchestrator |
| RecommendationEngine.psm1 | (none — reads FindingRules.json directly) | Orchestrator |
| Export.psm1 | (none) | Orchestrator |

Notice that modules do **not** call each other directly. The orchestrator (`IntuneBaselineAssessment.ps1`) is the only code that connects them. This makes each module independently testable and replaceable.

---

## 4. The Data Model

This is the single most important section of this document. Understanding the data model unlocks everything else.

### 4.1 The 8-Key Setting Hashtable

Every policy reader in the tool produces a list of hashtables, and every hashtable has **exactly these 8 keys**:

```powershell
@{
    PolicyName     = 'SBZ-Win-L1-ES-Antivirus'           # Name of the Intune policy
    PolicyTemplate = 'Settings Catalog'                    # Which policy type this came from
    SettingPath    = 'Antivirus > Enable Cloud Protection'  # Human-readable setting location
    CategoryId     = '0a1347d2-90c0-407a-baa0-e4859260532a' # Category identifier (GUID or string)
    Value          = 'true'                                 # The configured value (always a string)
    Description    = 'Enables cloud-delivered protection...' # Description from the API
    DefinitionId   = 'device_vendor_msft_policy_config...'  # THE COMPARISON KEY (see below)
    Domain         = ''                                     # Filled later by Enrichment.psm1
}
```

**Why this matters:** Because every reader produces the same shape, the downstream modules (Enrichment, Comparison, Export) work identically regardless of whether a setting came from Settings Catalog, Endpoint Security, Device Configuration, Admin Templates, Compliance Policies, or Security Baselines. If you add a new reader, it must produce this same shape — and everything else just works.

Let's look at each key:

| Key | What it is | Example |
|---|---|---|
| `PolicyName` | Display name of the Intune policy this setting belongs to | `SBZ-Win-L1-ES-Antivirus` |
| `PolicyTemplate` | Which policy type produced this setting | `Settings Catalog`, `Endpoint Security`, `Device Configuration`, `Admin Templates`, `Compliance Policy`, `Security Baseline` |
| `SettingPath` | Human-readable hierarchical path to the setting | `Antivirus > Enable Cloud Protection` |
| `CategoryId` | A category identifier used for domain mapping. Can be a GUID, a type string like `endpointSecurityAntivirus`, or a prefix like `dc:windows10GeneralConfiguration` | `0a1347d2-90c0-407a-baa0-e4859260532a` |
| `Value` | The configured value, always converted to a string | `true`, `Enabled; Minimum PIN length: 6`, `Block` |
| `Description` | Human-readable description of what this setting does | `Enables cloud-delivered protection...` |
| `DefinitionId` | **The comparison key** — the unique identifier used to match a baseline setting with the corresponding customer setting | `device_vendor_msft_policy_config_defender_allowcloudprotection` |
| `Domain` | Assessment domain (one of 5). Empty when the reader produces the setting; filled by `Add-DomainEnrichment` | `Endpoint Security` |

### 4.2 DefinitionId Namespacing

The `DefinitionId` is how the comparison engine matches a baseline setting to a customer setting. The problem is that different policy types in Intune can use the same raw identifiers — for example, an Endpoint Security setting and a Security Baseline setting might share the same underlying definition ID because they both use the intents API.

To prevent false matches, each reader prefixes its DefinitionId with a short code:

| Policy Type | Prefix | Example DefinitionId |
|---|---|---|
| Settings Catalog | *(none — uses the raw ID)* | `device_vendor_msft_policy_config_defender_allowcloudprotection` |
| Endpoint Security | `es:` | `es:abc12345-def6-7890-abcd-ef1234567890` |
| Device Configuration | `dc:` | `dc:windows10GeneralConfiguration:defenderEnabled` |
| Admin Templates | `admx:` | `admx:abc12345-def6-7890-abcd-ef1234567890` |
| Compliance Policy | `cp:` | `cp:windows10CompliancePolicy:passwordRequired` |
| Security Baseline | `sb:` | `sb:abc12345-def6-7890-abcd-ef1234567890` |

**Why `es:` and `sb:` are distinct:** Endpoint Security policies and Security Baselines both use the "intents" API in Graph, but they represent different things. Endpoint Security policies are custom policies you create; Security Baselines are Microsoft-published templates. A customer might have the same setting in both. By using different prefixes, the comparison engine treats them as separate settings and compares each against the correct baseline entry.

**If you add a new reader:** Pick a fresh two- or three-letter prefix that does not collide with any existing one.

### 4.3 The Comparison Output (15-Key Hashtable)

After comparison, each result row is a hashtable with 15 keys. This is what gets written to the CSV:

```powershell
[ordered]@{
    BaselinePolicyName     = 'SBZ-Win-L1-ES-Antivirus'         # Baseline policy name
    BaselinePolicyTemplate = 'Settings Catalog'                  # Baseline policy type
    BaselineSetting        = 'Antivirus > Enable Cloud Prot...'  # Baseline SettingPath
    BaselineCategory       = '0a1347d2-...'                      # Baseline CategoryId
    BaselineDomain         = 'Endpoint Security'                 # Baseline domain
    BaselineValue          = 'true'                              # What the baseline expects
    Result                 = 'Compliant'                         # Compliant/Conflict/Missing/Extra
    PolicyName             = 'Contoso-Antivirus-Policy'          # Customer policy name(s)
    CustomerSetting        = 'Antivirus > Enable Cloud Prot...'  # Customer SettingPath
    PolicyTemplate         = 'Settings Catalog'                  # Customer policy type
    PolicyValue            = 'true'                              # Customer value(s)
    ComparisonCategory     = '0a1347d2-...'                      # Customer CategoryId
    ComparisonDomain       = 'Endpoint Security'                 # Customer domain
    Description            = 'Enables cloud-delivered prot...'   # Setting description
    DefinitionId           = 'device_vendor_msft_...'            # Internal (not in CSV)
}
```

The four possible `Result` values:

| Result | Meaning | Baseline columns | Customer columns |
|---|---|---|---|
| **Compliant** | Customer has the setting and the value matches | Populated | Populated |
| **Conflict** | Customer has the setting but the value differs | Populated | Populated |
| **Missing** | Baseline requires the setting; customer does not have it | Populated | Empty |
| **Extra** | Customer has a setting not in the baseline | Empty | Populated |

### 4.4 Inventory Data Shapes

Inventory data uses different schemas because it is not comparison data — it is collected for reporting purposes only.

**Device Inventory** — each device is a hashtable:
```powershell
@{
    DeviceName       = 'DESKTOP-ABC123'
    DeviceId         = 'guid...'
    OperatingSystem  = 'Windows'
    OsVersion        = '10.0.22631.4317'
    ComplianceState  = 'compliant'        # or 'noncompliant', 'unknown'
    LastSync         = '2026-04-15T10:30:00Z'
    EnrolledDate     = '2025-01-10T08:00:00Z'
    ManagementAgent  = 'mdm'
    EnrollmentType   = 'windowsAzureADJoin'
    Model            = 'Surface Pro 9'
    Manufacturer     = 'Microsoft Corporation'
    SerialNumber     = 'ABC123456'
    UserPrincipalName = 'user@contoso.com'
}
```

**Enrollment Analysis** — a hashtable containing two lists:
```powershell
@{
    EnrollmentConfigs = @(     # List of enrollment configuration hashtables
        @{ ConfigName = '...'; ConfigId = '...'; ConfigType = '...'; ... }
    )
    AutopilotDevices = @(      # List of Autopilot device hashtables
        @{ SerialNumber = '...'; Model = '...'; ... }
    )
}
```

**App Inventory** — each app is a hashtable:
```powershell
@{
    AppName          = 'Microsoft Teams'
    AppId            = 'guid...'
    AppType          = 'winGet'
    Publisher        = 'Microsoft Corporation'
    CreatedDate      = '2025-06-01T00:00:00Z'
    LastModified     = '2026-03-15T00:00:00Z'
    IsAssigned       = 'Yes'            # or 'No'
    AssignmentCount  = 3
    AssignmentIntent = 'required, available'
    AssignmentGroups = 'All Users, Marketing Team'
}
```

---

## 5. The Orchestrator

The file [IntuneBaselineAssessment.ps1](IntuneBaselineAssessment.ps1) is the main entry point. It does not contain any business logic itself — it orchestrates the modules. Think of it as the "recipe" that calls the right functions in the right order.

### 5.1 Parameters (lines 83-108)

The parameter block defines everything you can pass to the script:

| Parameter | Required? | What it does |
|---|---|---|
| `-CustomerTenantId` | Yes | The GUID of the customer's Azure AD tenant. Validated by regex — must be a valid GUID format. |
| `-CustomerName` | Yes | A human-readable name for the customer. Used in output filenames (non-word characters are replaced with underscores). |
| `-ConfigPath` | No | Path to the `Config/` folder. Defaults to `Config/` next to the script. |
| `-OutputPath` | No | Directory for output files. Defaults to `Exports/` next to the script. Created automatically if missing. |
| `-BaselinePath` | No | Directory for the baseline cache. Defaults to `Baseline/` next to the script. |
| `-BaselineLevel` | No | Which baseline tier: `All` (default), `L1`, `L2`, `L3`, or `L4`. Levels are cumulative: L2 means L1+L2. |
| `-BaselinePolicyFilter` | No | Wildcard patterns to filter baseline policies at fetch time. Example: `'SBZ-Win-L1-*','SBZ-Win-Custom-*'`. **Baked into the cache** — if you change this, use `-RefreshBaseline`. |
| `-UseBaselineCache` | No | Skip fetching from the baseline tenant; load from `baseline-cache.json` instead. |
| `-RefreshBaseline` | No | Force a fresh fetch from the baseline tenant, even if a cache exists. |
| `-GenerateReportData` | No | Also produce a `ReportData.json` with aggregated scores and findings. |
| `-SkipInventory` | No | Skip device, enrollment, and app inventory collection. Useful for faster runs when you only need the policy comparison. |
| `-PreferGraphOsLifecycle` | No | Prefer Graph lifecycle source for OS metadata and fall back to `OSDefinition.json` when needed. |
| `-DisableGraphOsLifecycle` | No | Force static `OSDefinition.json` mapping and skip Graph lifecycle calls. |
| `-PolicyTypes` | No | Which policy types to compare. Defaults to all six. Example: `-PolicyTypes SettingsCatalog,EndpointSecurity` |

**Important relationship between `-BaselinePolicyFilter` and `-BaselineLevel`:**

These two filters are **independent and stackable**:
- `-BaselinePolicyFilter` runs at **fetch time** and is stored in the cache. If you change it, you must use `-RefreshBaseline`.
- `-BaselineLevel` runs **after loading** (even from cache). You can switch levels freely without re-fetching.

### 5.2 Bootstrap Sequence (lines 110-181)

After validating parameters, the script:

1. **Sets strict mode and error preference** (line 110-111) — any error is fatal, any typo is caught.
2. **Prints the banner** (lines 116-132) — shows version, customer name, tenant ID, and baseline level.
3. **Imports all modules** (lines 137-145) — loads them in a specific order from the `Modules/` folder (including `OsLifecycleProvider.psm1`). The `-Force` flag ensures fresh copies.
4. **Loads AppConfig.json** (lines 150-165) — reads the config file, converts it to a hashtable, and passes it to `Initialize-AuthConfig`.
5. **Composes the Graph base URL** (line 168) — combines `GraphBaseUrl` and `GraphApiVersion` from the config (e.g., `https://graph.microsoft.com/beta`).
6. **Loads DomainMapping.json** (lines 171-172) — initialises the enrichment module.
7. **Loads FindingRules.json and risk weights** (lines 175-181) — initialises the findings engine.

### 5.3 Stage 1 — Baseline Load (lines 266-399)

This is the most complex stage because it handles multiple scenarios:

**Decision tree:**

```
Is -UseBaselineCache set AND cache file exists AND -RefreshBaseline is NOT set?
|
+-- YES: Load from cache
|   +-- Is cache schema v2?
|   |   +-- YES: Does cache cover all requested -PolicyTypes?
|   |   |   +-- YES: Load per-type sections
|   |   |   +-- NO: Warn and re-fetch from Graph
|   |   +-- NO (v1): Is only SettingsCatalog requested?
|   |       +-- YES: Load from legacy format
|   |       +-- NO: Warn and re-fetch from Graph
|   |
|   +-- After loading: check DomainMapping hash
|       +-- Hash matches: use cached domains as-is
|       +-- Hash differs: re-apply Add-DomainEnrichment (no Graph call!)
|
+-- NO: Fetch fresh from Graph
    +-- Connect-BaselineTenant (get OAuth2 token)
    +-- Get-AllPolicySettings (runs all 6 readers)
    +-- Add-DomainEnrichment (assign domain tags)
    +-- Write baseline-cache.json (v2 format)

Then always: Apply Select-BaselineByLevel filter
```

**The `Select-BaselineByLevel` function** (lines 234-261) filters baseline settings by their policy name. It looks for the pattern `-L1-`, `-L2-`, etc. in the `PolicyName` field. Levels are cumulative:
- `L1` includes only policies with `-L1-` in the name
- `L2` includes policies with `-L1-` or `-L2-`
- `L3` includes `-L1-`, `-L2-`, or `-L3-`
- `L4` / `All` includes everything

### 5.4 Stages 2-5 (lines 402-613)

**Stage 2** connects to the customer tenant and runs the same readers. Enrichment is applied to customer settings too.

**Stage 3** collects inventory data (devices, enrollment, apps). If a Graph API permission is missing, the reader returns an empty list and logs a warning — the script continues.

**Stage 4** runs `Compare-TenantSettings` to produce the diff, then `Get-Findings` to evaluate finding rules against the diff and inventory data.

**Stage 5** exports everything to CSV files and optionally to `ReportData.json`.

After all stages, the script prints a colour-coded summary to the console showing compliance counts, per-domain maturity scores, top findings, and inventory counts.

---

## 6. Module Deep Dives

### 6.1 Auth.psm1 — Authentication

**File:** [Modules/Auth.psm1](Modules/Auth.psm1)

**What it does:** Acquires OAuth2 access tokens for the Microsoft Graph API using the "client credentials" flow. This means the tool authenticates as an **application** (not as a user) — no user sign-in is required.

**How OAuth2 client credentials works (simplified):**

1. You register an application in Azure AD and give it permissions (like `DeviceManagementConfiguration.Read.All`).
2. Azure AD gives you a Client ID (identifies your app) and a Client Secret (like a password for your app).
3. When the tool needs to talk to Graph, it sends the Client ID and Client Secret to Azure AD and receives an **access token** — a temporary key that grants access for about an hour.
4. The tool includes this token in every Graph API request as a `Bearer` token in the HTTP header.

**Token caching (line 9):**

```powershell
$script:TokenCache = [System.Collections.Generic.Dictionary[string, hashtable]]::new()
```

The token cache is a dictionary keyed by tenant ID. Each entry stores:
- `AccessToken` — the token string
- `ExpiresAt` — when the token expires

Token requests now use a 60-second HTTP timeout to avoid indefinite hangs when Entra connectivity is degraded.

When `Get-GraphToken` is called (line 98), it first checks the cache. If a cached token exists and is still valid with at least 5 minutes of remaining life (the "safety margin"), it returns the cached token. Otherwise, it fetches a new one.

**The 5-minute safety margin (line 114):** Tokens are typically valid for 60-90 minutes. The tool considers a token expired if it has less than 5 minutes of life remaining. This prevents a scenario where the tool starts a long operation with a token that expires mid-way.

**Exported functions:**
- `Initialize-AuthConfig` — validates and stores the app configuration
- `Connect-BaselineTenant` — returns a token for the baseline tenant
- `Connect-CustomerTenant` — returns a token for the customer tenant

### 6.2 GraphAPI.psm1 — HTTP Helpers

**File:** [Modules/GraphAPI.psm1](Modules/GraphAPI.psm1)

**What it does:** Provides two functions that handle all HTTP communication with the Microsoft Graph API. Every reader uses these functions — no module makes HTTP calls directly.

**`Invoke-IbaGraphRequest`** (line 12) — sends a single request with retry logic:

The function wraps `Invoke-RestMethod` with error handling for two types of failures:

1. **Throttling (HTTP 429):** Microsoft Graph limits how many requests you can make per minute. When you hit the limit, the API returns a 429 response with a `Retry-After` header saying how many seconds to wait. The function waits that long (or 30 seconds if the header is missing) and retries. This can happen up to `MaxRetries` times (default 5).

2. **Transient errors (HTTP 500, 502, 503, 504):** These are temporary server-side problems. The function uses **progressive backoff** — it waits 5 seconds on the first retry, 10 seconds on the second, 15 on the third, and so on. This gives the server time to recover.

Any other error (like 401 Unauthorized or 403 Forbidden) is immediately fatal — the function throws an error with as much detail as it can extract from the response.

**`Get-GraphPagedResults`** (line 94) — handles pagination:

The Graph API returns large collections in pages. A typical response looks like:

```json
{
    "value": [ ...first 100 items... ],
    "@odata.nextLink": "https://graph.microsoft.com/beta/...?$skiptoken=..."
}
```

The `@odata.nextLink` field is a URL for the next page. `Get-GraphPagedResults` follows these links automatically, collecting all items across all pages into a single list. It stops when there is no `@odata.nextLink` in the response.

**The `TimeoutSec` parameter:** Some Graph endpoints are slow. The Autopilot device identities endpoint, for example, can take several minutes to respond. The default timeout is 120 seconds, but callers can pass a higher value. The EnrollmentAnalyzer uses 300 seconds for Autopilot.

**HTTP headers sent with every request (line 42):**
- `Authorization: Bearer <token>` — the access token
- `Content-Type: application/json` — we expect JSON responses
- `ConsistencyLevel: eventual` — required by some Graph endpoints that use advanced query features

### 6.3 PolicyReader.psm1 — Settings Catalog

**File:** [Modules/PolicyReader.psm1](Modules/PolicyReader.psm1)

**What it does:** Reads Settings Catalog policies from Intune. This is the most complex reader because Settings Catalog uses a deeply nested data structure with multiple setting types, grouped settings, and collection settings.

**Exported functions:**
- `Get-SettingsCatalogPolicies` — main entry point, returns `List[hashtable]` with the 8-key schema
- `Reset-PolicyReaderCache` — clears the in-memory definition and category caches

**How Settings Catalog works in Intune:**

A Settings Catalog policy contains "setting instances." Each instance has a type that determines how its value is structured:

| Setting Type | What it looks like | How the reader handles it |
|---|---|---|
| `ChoiceSettingInstance` | A dropdown/radio selection (e.g., "Enabled", "Disabled", "Block") | Resolves the raw choice ID to a human-readable label using the definition's options list |
| `SimpleSettingInstance` | A single value (string, number, boolean) | Takes the value directly |
| `SimpleSettingCollectionInstance` | A list of values | Joins values with `, ` |
| `ChoiceSettingCollectionInstance` | A list of dropdown selections | Resolves each choice, then joins with `, ` |
| `GroupSettingCollectionInstance` | A container that holds child settings | Recursively processes each child, building up the `SettingPath` with each level |

The recursive nature of `GroupSettingCollectionInstance` is what makes this reader complex. A group can contain choices, which can contain sub-groups, which can contain more settings. The function `ConvertTo-FlatSettings` walks this tree recursively and produces one flat hashtable per leaf setting.

**Definition and category caching:**

When the reader encounters a setting, it needs to look up the definition (for display names, descriptions, choice labels) and the category (for building the hierarchical path). These lookups require Graph API calls, which are slow.

To avoid making the same call twice, the reader maintains two caches:

```powershell
$script:DefinitionCache  # keyed by settingDefinitionId
$script:CategoryCache    # keyed by categoryId
```

The reader pre-populates these caches from the `$expand=settingDefinitions` data that comes with the initial policy fetch. This means most definitions are already cached before individual lookups are needed.

**Category path building:**

Settings Catalog categories form a hierarchy (e.g., "Admin Templates > Windows Components > BitLocker > Fixed Data Drives"). The function `Get-CategoryPath` walks up the parent chain:

1. Start with the leaf category
2. Look up its parent category
3. Look up the parent's parent
4. Continue until there is no more parent
5. Reverse the list to get root-first order
6. Join with ` > `

### 6.4 EndpointSecurityReader.psm1 — Endpoint Security

**File:** [Modules/EndpointSecurityReader.psm1](Modules/EndpointSecurityReader.psm1)

**What it does:** Reads Endpoint Security policies (Antivirus, Firewall, Disk Encryption, etc.) from Intune's "intents" API.

**How the intents API works:**

Endpoint Security policies in Intune are built on "templates." Each template defines a set of settings. A policy is an "intent" that references a template and provides values for those settings.

The reader:
1. Fetches all intents (policies) from `/deviceManagement/intents`
2. For each intent, fetches its template metadata (display name, type)
3. For each intent, fetches its settings from `/intents/{id}/settings`
4. For each setting, looks up the definition from the template's definition set

**DefinitionId prefix:** `es:` — e.g., `es:abc12345-...`

**CategoryId:** Uses the template's `templateType` string (e.g., `endpointSecurityAntivirus`, `endpointSecurityFirewall`). This is matched directly in `DomainMapping.json`'s `byCategoryGuid` section.

**Value resolution:** Settings store their values as a JSON string in a field called `valueJson`. The reader parses this JSON, and if the value is a choice, attempts to resolve it to a human-readable label using the definition's `EnumerationConstraint`.

### 6.5 DeviceConfigReader.psm1 — Device Configuration

**File:** [Modules/DeviceConfigReader.psm1](Modules/DeviceConfigReader.psm1)

**What it does:** Reads Device Configuration profiles. These are the "older style" Intune profiles where each setting is a property on the profile object.

**How it works:**

Unlike Settings Catalog (which has a structured settings model), Device Configuration profiles expose their settings as simple JSON properties. For example, a `windows10GeneralConfiguration` profile has properties like `defenderEnabled`, `passwordRequired`, etc.

The reader:
1. Fetches all device configuration profiles
2. For each profile, fetches the full object individually (because the list endpoint may not return all properties)
3. Iterates over every property on the object
4. Skips metadata properties (like `id`, `displayName`, `@odata.type`, timestamps, etc.)
5. Skips null properties (= setting not configured)
6. Converts each remaining property to the standard 8-key hashtable

**DefinitionId format:** `dc:{shortOdataType}:{propertyName}` — e.g., `dc:windows10GeneralConfiguration:defenderEnabled`

The `shortOdataType` is extracted from the `@odata.type` field by removing the `#microsoft.graph.` prefix.

**Special case — OMA-URI custom configurations:** The type `windows10CustomConfiguration` does not have typed properties. Instead, it has an `omaSettings` array where each entry has an OMA-URI path and a value. The reader handles this by iterating over `omaSettings` and using the OMA-URI as the setting identifier.

### 6.6 AdminTemplateReader.psm1 — Admin Templates (ADMX)

**File:** [Modules/AdminTemplateReader.psm1](Modules/AdminTemplateReader.psm1)

**What it does:** Reads Administrative Templates (Group Policy-style) configurations from Intune.

**How it works:**

Admin Templates are based on Group Policy definitions. Each policy has "definition values" — settings that are either Enabled or Disabled, optionally with sub-values (called "presentation values") like text fields, dropdowns, or checkboxes.

The reader:
1. Fetches all Admin Template policies (groupPolicyConfigurations)
2. For each policy, fetches its definition values (the enabled/disabled settings) with an `$expand` to include the definition details and presentation values
3. If the `$expand` is rejected by the API (it sometimes is), falls back to fetching definitions and presentations separately

**Value format:** The value string combines the enabled/disabled state with any sub-values:

```
"Enabled; Minimum PIN length: 6; Enhanced PIN: true"
```

**DefinitionId prefix:** `admx:{groupPolicyDefinition.id}` — e.g., `admx:abc12345-...`

**CategoryId:** Uses the definition's `category.id`, which is a real GUID that can be looked up in `DomainMapping.json`'s `byCategoryGuid` section.

### 6.7 CompliancePolicyReader.psm1 — Compliance Policies

**File:** [Modules/CompliancePolicyReader.psm1](Modules/CompliancePolicyReader.psm1)

**What it does:** Reads Compliance Policies from Intune. These are policies that check whether a device meets certain requirements (like minimum OS version, encryption enabled, etc.).

**How it works:** Very similar to DeviceConfigReader — compliance policies expose their settings as properties on the policy object. The reader skips metadata properties, null values, and special action/assignment properties.

**DefinitionId prefix:** `cp:{shortOdataType}:{propertyName}` — e.g., `cp:windows10CompliancePolicy:passwordRequired`

### 6.8 SecurityBaselineReader.psm1 — Security Baselines

**File:** [Modules/SecurityBaselineReader.psm1](Modules/SecurityBaselineReader.psm1)

**What it does:** Reads Microsoft Security Baselines from Intune. These are Microsoft-published recommended configurations (as opposed to Endpoint Security policies which are custom).

**How it works:** Internally very similar to EndpointSecurityReader because both use the intents API. The key difference is in how baselines are discovered:

1. Fetch all templates filtered to `templateType eq 'securityBaseline'`
2. Build a set of baseline template IDs
3. Fetch all intents and filter to those referencing baseline templates
4. Process each intent the same way as EndpointSecurityReader

**DefinitionId prefix:** `sb:` (distinct from `es:` to prevent conflation with custom Endpoint Security policies)

### 6.9 Comparison.psm1 — The Diff Engine

**File:** [Modules/Comparison.psm1](Modules/Comparison.psm1)

This module is where the actual comparison happens. It is critical to understand its logic.

**Exported function:** `Compare-TenantSettings -BaselineSettings -CustomerSettings`

**Step 1: Build the customer index (lines 44-52)**

The function creates a dictionary keyed by `DefinitionId` (case-insensitive). Each key maps to a **list** of customer settings with that ID — because the same setting can appear in multiple customer policies.

```powershell
$customerIndex = Dictionary[string, List[hashtable]]
# For each customer setting:
#   customerIndex["device_vendor_msft_..."] = [ setting1, setting2, ... ]
```

**Step 2: Walk every baseline setting (lines 60-73)**

For each baseline setting:
- Look up its `DefinitionId` in the customer index
- If found: compare values (see multi-policy logic below)
- If not found: result is `Missing`

**Step 3: Find Extra settings (lines 75-112)**

After processing all baseline settings, the function walks all customer settings and finds those whose `DefinitionId` is NOT in the baseline. These are `Extra` rows. If the same Extra setting appears in multiple customer policies, they are grouped into one row.

**Multi-policy "optimistic" strategy (lines 162-170):**

When a customer has the same setting in multiple policies, which value do we compare against the baseline? The tool uses an **optimistic** approach:

> If **any** customer policy has a value that matches the baseline, the result is `Compliant`.

Why? Because Intune applies the "most restrictive" effective value when multiple policies configure the same setting, but we cannot determine the effective value via the API. Marking a setting as `Conflict` when at least one policy matches would produce false positives for intentional policy layering (e.g., a broad base policy + a tighter scoped policy).

The output row shows **all** customer policy names and values (comma-joined) so the reviewer can inspect the full picture.

**Value normalization (lines 208-271):**

Before comparing two values, the function normalises them through a 5-step cascade:

| Step | What it does | Example |
|---|---|---|
| 1. **Boolean synonyms** | Maps common boolean representations to `true`/`false` | `"Enabled"` becomes `"true"`, `"0"` becomes `"false"`, `"Block"` becomes `"false"` |
| 2. **JSON object** | Parses JSON objects and re-serialises with sorted keys | `{"b":1,"a":2}` and `{"a":2,"b":1}` become equal |
| 3. **JSON array** | Parses JSON arrays and sorts elements | `["b","a"]` and `["a","b"]` become equal |
| 4. **Comma-separated** | Splits on `,`, sorts items, re-joins | `"val2, val1"` and `"val1, val2"` become equal |
| 5. **Fallback** | Lowercase only | `"SomeValue"` becomes `"somevalue"` |

Steps are tried in order. The first step that applies wins. This means:
- `"Enabled"` and `"true"` are considered equal (step 1)
- `{"b":1,"a":2}` and `{"a":2,"b":1}` are considered equal (step 2)
- `"UserA, UserB"` and `"UserB, UserA"` are considered equal (step 4)

### 6.10 Enrichment.psm1 — Domain Mapping

**File:** [Modules/Enrichment.psm1](Modules/Enrichment.psm1)

**What it does:** Assigns one of the 5 assessment domains to each setting based on rules in `DomainMapping.json`.

**The 5 assessment domains:**
1. Endpoint Security
2. Device Management
3. Compliance & Governance
4. Application Lifecycle
5. Operations & Monitoring

**How domain resolution works (lines 116-160):**

The `Resolve-Domain` function tries three lookup strategies in order. The first match wins:

**Priority 1: `byCategoryGuid` — exact match on CategoryId (line 122)**

This is the most precise method. It checks whether the setting's `CategoryId` exists as a key in the `byCategoryGuid` section of `DomainMapping.json`. The lookup is O(1) because the module pre-processes these entries into a hashtable on initialization.

Example: A setting with `CategoryId = "endpointSecurityAntivirus"` maps directly to `"Endpoint Security"`.

**Priority 2: `byPolicyNamePrefix` — longest prefix match (line 129)**

If the GUID lookup did not find a match, the function checks whether the setting's `PolicyName` starts with any known prefix. The prefixes are sorted by length (longest first) so that more specific prefixes take priority.

Example: A setting from policy `SBZ-Win-L2-SC-Edge-Security-D-SmartScreen` would match `SBZ-Win-L2-SC-Edge-Security-D-` (Endpoint Security) before it could match the shorter `SBZ-Win-L2-SC-` prefix.

**Priority 3: `bySettingPathKeyword` — substring match (line 139)**

If neither the GUID nor the prefix matched, the function scans the setting's `SettingPath` for known keywords.

Example: A setting with `SettingPath = "Microsoft Defender > Real-Time Protection"` would match the keyword `"Microsoft Defender"` and map to Endpoint Security.

**Fallback:** If nothing matches, the domain is set to `"Unclassified"`. This is a signal that `DomainMapping.json` needs updating — see [Section 8.2](#82-a-setting-shows-up-as-unclassified-in-the-domain-column).

**Initialization and pre-processing (lines 27-88):**

When `Initialize-DomainMapping` is called, it does not just load the JSON — it builds optimised lookup structures:

- `$script:CategoryGuidTable` — a PowerShell hashtable for O(1) GUID lookups
- `$script:PrefixesSorted` — an array of prefix/domain pairs sorted by prefix length (longest first)
- `$script:KeywordPairs` — an array of keyword/domain pairs for path scanning
- `$script:ValidDomains` — a HashSet of valid domain names for validation

Entries whose name starts with `_` (like `_comment`) are skipped — this is how comments are embedded in the JSON file.

### 6.11 RecommendationEngine.psm1 — Findings Engine

**File:** [Modules/RecommendationEngine.psm1](Modules/RecommendationEngine.psm1)

**What it does:** Evaluates rules from `FindingRules.json` against the comparison results and inventory data to produce prioritised findings for the assessment report.

**Exported functions:**
- `Initialize-FindingRules` — loads and validates the rules JSON
- `Get-Findings` — evaluates all rules, returns sorted findings

**How it works:**

The engine walks three arrays of rules from `FindingRules.json`:

1. **`comparisonFindings`** — rules that look at the diff results (e.g., "are most BitLocker settings missing?")
2. **`structuralFindings`** — rules that look at policy metadata (e.g., "do customer policies follow a naming convention?")
3. **`inventoryFindings`** — rules that look at inventory data (e.g., "are more than 10% of devices non-compliant?")

Each rule has a `trigger` object with a `type` field. The type determines which evaluator function runs:

**Comparison trigger types:**

| Trigger type | What it checks | Example use |
|---|---|---|
| `keyword_cluster` | Finds all comparison rows matching any of the given keywords, then checks if the ratio of rows matching the `resultFilter` (e.g., "Missing") exceeds the `threshold` | "If more than 80% of LAPS-related settings are Missing, fire a Critical finding" |
| `domain_ratio` | Looks at all comparison rows for a specific domain, checks if the ratio matching the `resultFilter` exceeds the `threshold` | "If more than 50% of Endpoint Security settings are Missing or Conflict, fire a Critical finding" |

**Structural trigger types:**

| Trigger type | What it checks | Example use |
|---|---|---|
| `naming_convention` | Checks customer policy names against wildcard patterns. Fires if **fewer** than `threshold` percent match | "If less than 50% of customer policies follow the SBZ-* naming convention, fire a Medium finding" |
| `duplicate_coverage` | Counts unique baseline-scoped conflicting settings from `Get-SettingsConflictSummary` (deduplicated by `BaselinePolicyName` + `DefinitionId`). Fires if count exceeds `threshold` | "If 10 or more settings have conflicting multi-policy values, fire a Low finding" |

**Inventory trigger types:**

| Trigger type | What it checks | Example use |
|---|---|---|
| `inventory_metric` | Evaluates a specific field in a collection against a value, using an operator (`percent_gte`, `percent_gt`, `count_gte`) and `threshold`. Supports `matchMode`: `exact` (default), `startsWith`, `contains` | "If 10% or more of devices have ComplianceState = noncompliant, fire a High finding" |
| `inventory_empty` | Fires if the specified inventory collection is null or empty | "If there are no Autopilot devices registered, fire a Medium finding" |

**Severity scoring and sorting (lines 148-161):**

Each finding has a severity (Critical, High, Medium, Low) which maps to a numeric score:
- Critical = 10, High = 7, Medium = 4, Low = 1

Findings are sorted by:
1. Severity score (highest first)
2. Domain risk weight (highest first, for ties) — these weights come from `DomainMapping.json`'s `riskWeights` section

**Text templating (lines 500-507):**

Finding detail and recommendation strings in `FindingRules.json` can contain placeholders:
- `{count}` — number of affected items
- `{total}` — total items evaluated
- `{percent}` — ratio as a percentage

These are replaced at runtime by the `Format-FindingText` function.

### 6.12 Export.psm1 — Output Generation

**File:** [Modules/Export.psm1](Modules/Export.psm1)

**What it does:** Writes all output files — the diff CSV, inventory CSVs, and the aggregated ReportData.json.

**CSV format choices:**

The CSVs use a specific format designed for Excel compatibility:
- **Semicolon-delimited** (not comma) — because many European locales use comma as the decimal separator, which breaks comma-delimited CSVs in Excel
- **All fields double-quoted** — prevents issues with values that contain semicolons or newlines
- **UTF-8 with BOM** (Byte Order Mark) — the BOM is a special invisible character at the start of the file that tells Excel "this file is UTF-8." Without it, Excel may interpret special characters incorrectly
- **Embedded quotes doubled** — if a value contains a `"`, it is written as `""` per the CSV standard

**The diff CSV** has 14 columns in a fixed order (defined in `$script:CsvColumns` at line 12). The `DefinitionId` field from the comparison output is deliberately excluded from the CSV — it is an internal key, not useful for report readers.

**The settings conflict CSV** (`{Customer}_{date}_{Lx}_SettingsConflicts.csv`) is produced when `Get-SettingsConflictSummary` returns rows. It captures multi-policy divergences — situations where a single setting (`DefinitionId`) is configured by 2+ customer policies with diverging normalized values. Output is **fully deconcatenated** (one CSV row per customer policy that contributes to the conflict), unlike `IntuneDiff_Export.csv` which joins policy names and values in a single row.

For each qualifying conflict group:

- **Baseline-covered** (`Has Baseline = True`): one row per customer policy match for that `(BaselinePolicyName, DefinitionId)` scope. `Match Status` is `Configured` when the policy value matches the baseline (normalized), else `Conflict`.
- **Non-baseline (Extra)** (`Has Baseline = False`): one row per customer policy for that `DefinitionId` when values diverge across policies.

Columns: Baseline Policy Name; Baseline Setting; Baseline Value; Policy Name; Policy Value; Policy Value (Normalized); Match Status; Definition Id; Domain; Category Id; Policy Count (unique customer policies for this setting); Distinct Value Count (unique normalized values across those policies); Has Baseline.

`Get-SettingsConflictSummary` filters: a conflict group is emitted only when there are ≥ 2 unique customer policies AND the distinct normalized customer values are ≥ 2; for baseline-covered groups, additionally at least one customer policy value must differ from the baseline. Equality uses the existing `Normalize-SettingValue`, so cosmetic differences (boolean synonyms, JSON object/array order, comma-list order) do not produce false conflicts.

The structural finding `duplicate_coverage` (in `Modules/RecommendationEngine.psm1`) counts **unique** baseline-scoped conflicting settings (keys `BaselinePolicyName` + `DefinitionId`) from this summary instead of inferring from the diff row's joined `PolicyName`. This typically reduces finding volume versus the old heuristic, since it no longer counts multi-policy diff rows where customer values are identical-but-wrong.

**Maturity Score** (lines 405-429):

The `Get-MaturityScore` function converts a compliance percentage to a 0-5 scale:

| Compliance % | Maturity Score |
|---|---|
| 0% | 0 |
| 1-24% | 1 |
| 25-49% | 2 |
| 50-74% | 3 |
| 75-89% | 4 |
| 90-100% | 5 |

This score appears in the console output and in `ReportData.json`'s `ByDomain` section.

**ReportData.json structure:**

The JSON file contains everything needed to populate the Word report template:

```json
{
    "GeneratedAt": "2026-04-21T10:30:00+02:00",
    "CustomerName": "Contoso",
    "Consultant": "",
    "BaselineLevel": "L2",
    "Summary": {
        "Total": 1200,
        "Compliant": 800,
        "Conflict": 150,
        "Missing": 200,
        "Extra": 50
    },
    "ByDomain": {
        "Endpoint Security": {
            "Compliant": 400, "Conflict": 80, "Missing": 100,
            "Total": 580, "CompliantPct": 69, "MaturityScore": 3
        }
    },
    "DeviceInventory": {
        "TotalDevices": 150,
        "ByOperatingSystem": [...],
        "ByComplianceState": [...],
        "ByOsSupportState": [...],
        "ByWindowsRelease": [...],
        "UnsupportedDeviceCount": 12,
        "Devices": [ { "...": "...", "OsRelease": "Windows 11 23H2", "OsSupportState": "Supported", "OsSource": "graph|static" } ]
    },
    "EnrollmentMethods": { "EnrollmentConfigCount": 5, "AutopilotDeviceCount": 120, "..." : "..." },
    "AppInventory": { "TotalApps": 45, "AssignedApps": 30, "..." : "..." },
    "ExecutiveSummary": {
        "TopRisks": [ "...top 3 findings..." ]
    },
    "FindingSummary": {
        "Total": 12,
        "BySeverity": { "Critical": 2, "High": 4, "Medium": 4, "Low": 2 }
    },
    "FindingsByDomain": {
        "Endpoint Security": [ "...findings sorted by severity..." ]
    },
    "SettingsConflicts": {
        "TotalConflictingSettings": 18,
        "WithBaselineCount": 14,
        "WithoutBaselineCount": 4,
        "DetailRowCount": 42,
        "ByDomain": { "Endpoint Security": 9, "Device Management": 5, "...": "..." },
        "Items": [ "...deconcatenated rows: one per customer policy; see Policy Name / Match Status..." ]
    }
}
```

### 6.13 Inventory Readers

**DeviceInventoryReader.psm1**, **EnrollmentAnalyzer.psm1**, **AppInventoryReader.psm1**

These three modules follow a shared pattern:

1. Make Graph API calls to fetch data
2. Transform each item into a flat hashtable
3. Return a `List[hashtable]`
4. If the required Graph permission is missing (403), log a warning and return an empty list instead of crashing

**Notable details:**

- **Autopilot endpoint** in EnrollmentAnalyzer uses `$top=25` (small page size) and `TimeoutSec=300` (5 minutes) because this endpoint is notoriously slow and frequently returns 504 Gateway Timeout errors.
- **App assignments** in AppInventoryReader requires a separate API call per app to fetch assignment details (`/mobileApps/{id}/assignments`). This makes it the slowest inventory reader for tenants with many apps.
- **Device inventory** uses `$select` to request only the fields it needs, reducing response size and improving performance.

---

## 7. Configuration Files In Depth

### 7.1 AppConfig.json

**Path:** `Config/AppConfig.json` (git-ignored — **never commit this file!**)

Created by copying `Config/AppConfig.template.json` and filling in your values:

```json
{
    "ClientId": "your-app-registration-client-id-guid",
    "ClientSecret": "your-client-secret-value",
    "BaselineTenantId": "the-baseline-tenant-guid",
    "Authority": "https://login.microsoftonline.com",
    "GraphBaseUrl": "https://graph.microsoft.com",
    "GraphApiVersion": "beta"
}
```

| Field | What it is | When to change it |
|---|---|---|
| `ClientId` | The Application (client) ID of your Azure AD app registration | When you create a new app registration |
| `ClientSecret` | The secret value (not the secret ID!) | When the secret expires and you create a new one |
| `BaselineTenantId` | The tenant ID of the eVri baseline tenant | When the baseline moves to a different tenant |
| `Authority` | The Azure AD login endpoint | Virtually never — only for sovereign clouds (e.g., `login.microsoftonline.us` for US Gov) |
| `GraphBaseUrl` | The Graph API base URL | Virtually never — only for sovereign clouds |
| `GraphApiVersion` | The Graph API version (`beta` or `v1.0`) | **Keep this as `beta`**. Several metadata fields the tool relies on are not available on `v1.0` |

**Security:** In the future Azure Function App deployment, these values will come from Azure Key Vault, not a JSON file.

### 7.2 DomainMapping.json

**Path:** [Config/DomainMapping.json](Config/DomainMapping.json)

This file controls how settings are mapped to the 5 assessment domains. It is the most frequently edited configuration file.

**Structure:**

```json
{
    "validDomains": [ "Endpoint Security", "Device Management", ... ],
    "byCategoryGuid": { ... },
    "byPolicyNamePrefix": { ... },
    "bySettingPathKeyword": { ... },
    "riskWeights": { "Endpoint Security": 5, ... }
}
```

**`validDomains`** — the allowed domain names. If a mapping rule produces a domain not in this list, it is replaced with "Unclassified" and a warning is logged.

**`byCategoryGuid`** — the most precise mapping. Keys are category GUIDs, Endpoint Security template types (like `endpointSecurityAntivirus`), or Device Configuration type shorthands (like `dc:windows10GeneralConfiguration`). This is checked first.

**How to add an entry:** When you see a new category GUID appearing as "Unclassified" in the output, find the GUID in the CSV's "Baseline Category" or "Comparison Category" column and add it here:

```json
"byCategoryGuid": {
    "new-guid-here": "Device Management"
}
```

**`byPolicyNamePrefix`** — matches the start of policy names. The enrichment module sorts these by length (longest first) so more specific prefixes take priority. For example, `SBZ-Win-L2-SC-Edge-Security-D-` (Endpoint Security) wins over `SBZ-Win-L2-SC-Edge-` (Application Lifecycle).

**How to add an entry:** When you add a new baseline policy naming convention:

```json
"byPolicyNamePrefix": {
    "SBZ-Win-L1-NewType-": "Device Management"
}
```

**`bySettingPathKeyword`** — the last-resort fallback. Scans the `SettingPath` for keywords. Use sparingly because substring matches are the most error-prone.

**`riskWeights`** — numeric weights per domain used by the findings engine to sort findings of equal severity. Higher weight = higher priority:

```json
"riskWeights": {
    "Endpoint Security": 5,
    "Compliance & Governance": 4,
    "Device Management": 3,
    "Application Lifecycle": 2,
    "Operations & Monitoring": 1
}
```

**Comments in JSON:** JSON does not support comments. The convention in this file is to use keys starting with `_` (like `"_comment"`, `"_comment_1"`). The code skips any key that starts with `_`.

### 7.3 FindingRules.json

**Path:** [Config/FindingRules.json](Config/FindingRules.json)

Defines the rules that the findings engine evaluates. Contains three arrays:

```json
{
    "comparisonFindings": [ ... ],
    "structuralFindings": [ ... ],
    "inventoryFindings": [ ... ]
}
```

**Anatomy of a rule:**

```json
{
    "id": "bitlocker-gaps",
    "name": "BitLocker onvolledig geconfigureerd",
    "domain": "Endpoint Security",
    "severity": "Critical",
    "trigger": {
        "type": "keyword_cluster",
        "keywords": ["BitLocker", "Encryption", "FDE", "DiskEncryption"],
        "resultFilter": ["Missing", "Conflict"],
        "threshold": 0.5
    },
    "detail": "BitLocker Drive Encryption beschermt... {count} van {total}...",
    "recommendation": "Configureer BitLocker-beleid..."
}
```

| Field | Purpose |
|---|---|
| `id` | Unique identifier for the rule |
| `name` | Display name (appears in the report) |
| `domain` | Which assessment domain this finding belongs to |
| `severity` | `Critical`, `High`, `Medium`, or `Low` |
| `trigger` | Condition definition — see [Section 6.11](#611-recommendationenginepsm1--findings-engine) for all types |
| `detail` | Detailed description, supports `{count}`, `{total}`, `{percent}` placeholders |
| `recommendation` | Remediation advice, supports the same placeholders |

**Note:** The finding texts are in Dutch because the assessment reports are delivered in Dutch. If you need English findings, translate the `name`, `detail`, and `recommendation` fields.

### 7.4 baseline-cache.json

**Path:** `Baseline/baseline-cache.json` (generated, not committed)

This file caches baseline data to avoid re-fetching from the Graph API on every run. The current schema is v2:

```json
{
    "meta": {
        "schemaVersion": 2,
        "domainMappingHash": "SHA256 hash of DomainMapping.json",
        "cachedAt": "2026-04-21T10:30:00+02:00",
        "policyTypes": ["SettingsCatalog", "EndpointSecurity", ...]
    },
    "settingsCatalog": [ ... ],
    "endpointSecurity": [ ... ],
    "deviceConfig": [ ... ],
    "adminTemplates": [ ... ],
    "compliancePolicies": [ ... ],
    "securityBaselines": [ ... ]
}
```

**When to delete/refresh:**
- You changed baseline policies -> use `-RefreshBaseline`
- You changed `-BaselinePolicyFilter` -> use `-RefreshBaseline`
- You only changed `DomainMapping.json` -> use `-UseBaselineCache` (re-enrichment happens automatically)
- You only changed `-BaselineLevel` -> use `-UseBaselineCache` (level filter is post-load)
- Something seems wrong with cached data -> delete the file and re-run without `-UseBaselineCache`

---

## 8. Maintenance Cookbook

### 8.1 A baseline policy was added, renamed, or removed

**Symptom:** The diff output does not reflect recent changes to the baseline tenant.

**Fix:** Run with `-RefreshBaseline` to force a fresh fetch:

```powershell
.\IntuneBaselineAssessment.ps1 -CustomerTenantId "<guid>" -CustomerName "Contoso" -RefreshBaseline
```

This overwrites `baseline-cache.json` with fresh data.

### 8.2 A setting shows up as "Unclassified" in the domain column

**Symptom:** The diff CSV or ReportData.json shows a setting with domain "Unclassified".

**Diagnosis:** The setting's `CategoryId` is not in `byCategoryGuid`, the policy name does not match any `byPolicyNamePrefix` entry, and the `SettingPath` does not contain any `bySettingPathKeyword` keyword.

**Fix:**

1. Open the diff CSV and find the "Unclassified" row.
2. Look at the "Baseline Category" or "Comparison Category" column — this is the `CategoryId`.
3. Decide which domain the setting belongs to.
4. Add the CategoryId to `Config/DomainMapping.json` under `byCategoryGuid`:

```json
"byCategoryGuid": {
    "the-guid-from-the-csv": "Endpoint Security"
}
```

5. Re-run with `-UseBaselineCache` — the tool automatically re-enriches when it detects the DomainMapping hash has changed.

**Best practice:** Always add GUIDs to `byCategoryGuid` rather than relying on keyword fallback. GUIDs are exact matches and never produce false positives.

### 8.3 Domain mapping needs updating after adding new baseline policies

**Symptom:** New baseline policies have a new naming convention that is not mapped.

**Fix:** Add the prefix to `byPolicyNamePrefix` in `DomainMapping.json`:

```json
"byPolicyNamePrefix": {
    "SBZ-Win-L1-NewPrefix-": "Device Management"
}
```

Then re-run with `-UseBaselineCache`. The soft re-enrichment picks up the change without re-fetching from Graph.

### 8.4 A finding rule needs tuning

**Symptom:** A finding fires too often (too sensitive) or not often enough (threshold too high).

**Fix:** Edit the `threshold` value in `Config/FindingRules.json`:

```json
"trigger": {
    "type": "keyword_cluster",
    "keywords": ["BitLocker", "Encryption"],
    "resultFilter": ["Missing", "Conflict"],
    "threshold": 0.5
}
```

- **Lower the threshold** -> finding fires more easily (more sensitive)
- **Raise the threshold** -> finding fires less easily (less sensitive)

You can also add or remove keywords to broaden or narrow what the rule matches.

No code changes are needed — the engine reads the rules from JSON every time it runs.

### 8.5 The tool crashes with 401 Unauthorized

**Symptom:** `Authentication failed for tenant 'xxx': AADSTS...`

**Common causes:**
1. **Client secret expired.** Check the app registration in the Azure portal under Certificates & secrets. Create a new secret and update `AppConfig.json`.
2. **Wrong tenant ID.** Verify that `BaselineTenantId` in `AppConfig.json` is correct, and that the `-CustomerTenantId` parameter is correct.
3. **App registration deleted.** Check that the app registration still exists in the Azure portal.

### 8.6 The tool crashes with 403 Forbidden on a policy endpoint

**Symptom:** `Graph API [403] .../deviceManagement/... — Insufficient privileges`

**Cause:** The customer admin has not granted admin consent to the app registration.

**Fix:** The customer admin needs to:
1. Go to the Entra admin centre -> Enterprise Applications
2. Find the app by its Client ID
3. Grant admin consent for the required permissions

Required permissions:
- `DeviceManagementConfiguration.Read.All` — for all policy types
- `DeviceManagementManagedDevices.Read.All` — for device inventory
- `DeviceManagementServiceConfig.Read.All` — for enrollment and Autopilot
- `DeviceManagementApps.Read.All` — for app inventory

Note: 403 on **inventory** endpoints is non-fatal — the tool logs a warning and continues. 403 on **policy** endpoints is fatal.

### 8.7 Graph API returns 504 Gateway Timeout

**Symptom:** `Graph API [504] .../windowsAutopilotDeviceIdentities/...`

**Cause:** The Autopilot endpoint is notoriously slow, especially for tenants with many devices.

**Workaround:** The tool already uses a 300-second timeout and small page size ($top=25) for this endpoint. If it still fails:
- Try again later (the endpoint may be under load)
- Use `-SkipInventory` to produce the policy comparison without inventory data

### 8.8 The CSV opens with garbled characters in Excel

**Symptom:** Special characters (like accented letters or Dutch characters) appear as garbage.

**Cause:** Excel did not detect the UTF-8 encoding.

**Fix:** The tool writes CSVs with a UTF-8 BOM, which should make Excel auto-detect the encoding. If it does not:
1. Open Excel
2. Go to Data -> From Text/CSV
3. Select the file
4. In the import wizard, set the encoding to "65001: UTF-8"
5. Set the delimiter to "Semicolon"

---

## 9. Extension Guide

### 9.1 Adding a New Policy Reader

If Microsoft adds a new policy type to Intune (or you need to read from a different Graph API endpoint), follow these steps:

**Step 1: Create the module file**

Create `Modules/NewTypeReader.psm1`. Use [EndpointSecurityReader.psm1](Modules/EndpointSecurityReader.psm1) or [DeviceConfigReader.psm1](Modules/DeviceConfigReader.psm1) as a template, depending on whether the new type uses an intent/template model or a property-based model.

Your module must export a function like:

```powershell
function Get-NewTypePolicies {
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl,
        [string[]]$PolicyFilter = @()
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()

    # ... fetch data from Graph, transform to 8-key hashtables ...
    # Each hashtable MUST have: PolicyName, PolicyTemplate, SettingPath,
    # CategoryId, Value, Description, DefinitionId, Domain (empty string)

    return $results
}

Export-ModuleMember -Function @('Get-NewTypePolicies')
```

**Step 2: Choose a DefinitionId prefix**

Pick a unique 2-3 letter prefix. Check existing prefixes (es, dc, admx, cp, sb) and avoid collisions. For example, `nt:` for "new type."

**Step 3: Register the module in the orchestrator**

In [IntuneBaselineAssessment.ps1](IntuneBaselineAssessment.ps1):

1. Add `'NewTypeReader'` to the module import list (line 139)
2. Add `'NewType'` to the `[ValidateSet]` on `-PolicyTypes` (line 106)
3. Add a block to `Get-AllPolicySettings` (around line 226):
   ```powershell
   if ('NewType' -in $Types) {
       Write-Host "    [$Label] New Type..." -ForegroundColor DarkGray
       $nt = Get-NewTypePolicies -Token $Token -BaseUrl $BaseUrl -PolicyFilter $PolicyFilter
       foreach ($item in @($nt)) { if ($null -ne $item) { $all.Add($item) } }
   }
   ```
4. Add a section to the cache write block (around line 384):
   ```powershell
   newType = @($baselineSettings | Where-Object { $_.PolicyTemplate -eq 'New Type' })
   ```
5. Add a section to the cache read block — add to `$sectionMap` (around line 296):
   ```powershell
   $sectionMap = @{
       # ... existing entries ...
       NewType = 'newType'
   }
   ```

**Step 4: Update DomainMapping.json**

Add category GUIDs or policy name prefixes for the new type so enrichment can assign domains.

**Step 5: Test**

Run the tool and verify that:
- Settings from the new type appear in the diff CSV
- Domain mapping resolves correctly (not "Unclassified")
- The baseline cache includes the new section

### 9.2 Adding a New Finding Rule

1. Decide which category: `comparisonFindings`, `structuralFindings`, or `inventoryFindings`
2. Choose a trigger type (see [Section 6.11](#611-recommendationenginepsm1--findings-engine))
3. Add the rule JSON to the appropriate array in [Config/FindingRules.json](Config/FindingRules.json):

```json
{
    "id": "my-new-finding",
    "name": "Mijn nieuwe bevinding",
    "domain": "Device Management",
    "severity": "Medium",
    "trigger": {
        "type": "keyword_cluster",
        "keywords": ["SomeKeyword", "AnotherKeyword"],
        "resultFilter": ["Missing"],
        "threshold": 0.6
    },
    "detail": "{count} van {total} instellingen ontbreken.",
    "recommendation": "Configureer de ontbrekende instellingen."
}
```

4. Test with `-GenerateReportData` and check the `FindingsByDomain` section in the JSON output.

No code changes are needed unless you need a trigger type that does not exist yet.

### 9.3 Adding a New Assessment Domain

1. Add the domain name to `validDomains` in [Config/DomainMapping.json](Config/DomainMapping.json)
2. Add mapping entries in `byCategoryGuid`, `byPolicyNamePrefix`, and/or `bySettingPathKeyword`
3. Add a `riskWeights` entry:
   ```json
   "riskWeights": {
       "New Domain": 3
   }
   ```
4. Re-run the tool. The new domain will appear in the diff CSV, the console summary, and `ReportData.json`.

### 9.4 Adding a New Inventory Source

1. Create `Modules/NewInventoryReader.psm1` returning `List[hashtable]`
2. Add the module to the import list in the orchestrator
3. Wire it into Stage 3 (inventory collection) in the orchestrator
4. Add an `Export-NewInventoryCsv` function to [Modules/Export.psm1](Modules/Export.psm1) following the pattern of the existing inventory exporters
5. Wire the export into Stage 5 in the orchestrator
6. Optionally extend `Export-ReportData` to include a new section
7. Optionally add `inventory_metric` or `inventory_empty` rules to `FindingRules.json`
8. If adding `inventory_metric` rules, also update the `Get-InventoryCollection` function in `RecommendationEngine.psm1` (around line 439) to recognise the new source name

### 9.5 Modifying Value Comparison Logic

The value comparison lives in `Normalize-SettingValue` in [Modules/Comparison.psm1](Modules/Comparison.psm1) (lines 208-271).

To add a new normalisation step, insert it at the appropriate priority level. Steps are tried in order — the first one that applies wins:

1. Boolean synonyms
2. JSON object normalisation
3. JSON array normalisation
4. Comma-separated collection normalisation
5. Fallback (lowercase only)

For example, to add normalisation for semicolon-separated values, you would add a step between 4 and 5:

```powershell
# -- Step 4.5: Semicolon-separated ----------------------------------------
if ($v -match ';') {
    $items = $v -split '\s*;\s*' | Where-Object { $_ -ne '' } | Sort-Object { $_.ToLower() }
    return ($items -join ';').ToLower()
}
```

---

## 10. Troubleshooting Reference

### 10.1 "Configuration file not found: Config\AppConfig.json"

**Cause:** `AppConfig.json` does not exist.

**Fix:**
```powershell
Copy-Item Config\AppConfig.template.json Config\AppConfig.json
# Then edit Config\AppConfig.json with your values
```

### 10.2 "AppConfig.json contains placeholder values"

**Cause:** You copied the template but did not fill in the ClientId.

**Fix:** Open `Config/AppConfig.json` and replace the placeholder GUIDs with real values.

### 10.3 "Authentication failed for tenant 'xxx'"

See [Section 8.5](#85-the-tool-crashes-with-401-unauthorized).

### 10.3b Baseline tenant connect appears to hang

`Auth.psm1` now fails token acquisition after 60 seconds instead of hanging indefinitely. If this occurs, confirm outbound/proxy access to `https://login.microsoftonline.com` from the host running PowerShell.

### 10.4 "Graph API [403]" on a policy endpoint

See [Section 8.6](#86-the-tool-crashes-with-403-forbidden-on-a-policy-endpoint).

### 10.5 "Level filter (Ln cumulative): 0 of N settings"

**Cause:** None of the baseline policy names contain `-Ln-` (where n is the level you specified).

**Fix:** Check that baseline policies follow the naming convention `SBZ-Win-Ln-*`. If they use a different convention, the `Select-BaselineByLevel` function in the orchestrator (lines 234-261) needs to be updated to match.

### 10.6 "Cache is missing policy types: ..."

**Cause:** You built the cache with a subset of policy types (e.g., `-PolicyTypes SettingsCatalog`) and are now running with more types.

**Fix:** This is handled automatically — the tool warns and re-fetches. No action needed.

### 10.7 "Domain mapping returned invalid domain '...' for setting '...'"

**Cause:** A mapping rule in `DomainMapping.json` resolves to a domain name that is not in the `validDomains` list.

**Fix:** Either add the domain to `validDomains` or fix the mapping rule to use a valid domain name.

### 10.8 Settings appear as Extra that should be Compliant

**Cause:** The DefinitionId does not match between baseline and customer. This usually happens when:
- The same setting is configured via different policy types (e.g., Settings Catalog in baseline, Device Configuration in customer)
- The DefinitionId format changed due to a Graph API update

**Diagnosis:**
1. Find the setting in the diff CSV
2. Note the DefinitionId (if you add it temporarily to the CSV output, or check in debug)
3. Check if the baseline and customer are using the same DefinitionId prefix and format

**Fix:** This is a fundamental design constraint — settings can only be compared within the same policy type. Cross-type comparison would require a mapping table that does not currently exist.

### 10.9 How to enable verbose output

Add `-Verbose` to get detailed logging from every module:

```powershell
.\IntuneBaselineAssessment.ps1 -CustomerTenantId "<guid>" -CustomerName "Contoso" -Verbose
```

This shows:
- Token acquisition/caching decisions
- Graph API URLs being called
- Page counts for paginated endpoints
- Per-rule finding evaluation details
- Domain mapping resolution details

---

## 11. Glossary

| Term | Meaning |
|---|---|
| **Assessment Domain** | One of the 5 categories used to organise findings: Endpoint Security, Device Management, Compliance & Governance, Application Lifecycle, Operations & Monitoring |
| **Baseline** | The eVri hardened reference configuration (OpenIntune L1-L4) stored in a dedicated Intune tenant |
| **Baseline Level** | The tier of hardening (L1 = basic, L2 = standard, L3 = advanced, L4 = maximum). Levels are cumulative |
| **CategoryId** | An identifier for the category a setting belongs to. Can be a GUID, a template type string, or a type shorthand with prefix |
| **Client Credentials** | An OAuth2 flow where an application authenticates with its own identity (no user sign-in) |
| **Compliant** | A comparison result meaning the customer has the setting and its value matches the baseline |
| **Conflict** | A comparison result meaning the customer has the setting but its value differs from the baseline |
| **DefinitionId** | The unique key used to match a setting across tenants. Namespaced per policy type to prevent collisions |
| **Domain Enrichment** | The process of assigning an assessment domain to each setting based on rules in DomainMapping.json |
| **Extra** | A comparison result meaning the customer has a setting that the baseline does not cover |
| **Finding** | An aggregated observation produced by the findings engine, with severity and recommendation |
| **Graph API** | Microsoft's RESTful API for accessing Microsoft 365 data (Intune, Azure AD, etc.) |
| **Hashtable** | A PowerShell data structure containing key-value pairs (`@{ Key = 'Value' }`) |
| **Intent** | In the Graph API, an Endpoint Security or Security Baseline policy instance |
| **Maturity Score** | A 0-5 score derived from the compliance percentage per domain |
| **Missing** | A comparison result meaning the baseline requires a setting that the customer does not have |
| **Module (.psm1)** | A reusable PowerShell library loaded with `Import-Module` |
| **Normalisation** | The process of converting values to a canonical form for comparison (e.g., "Enabled" to "true") |
| **OMA-URI** | A path format used in custom Device Configuration profiles to target specific MDM settings |
| **Optimistic Strategy** | The comparison approach where a setting is Compliant if ANY customer policy matches the baseline |
| **Pagination** | The Graph API practice of returning large result sets in pages linked by `@odata.nextLink` |
| **PolicyTemplate** | The type label identifying which reader produced a setting (e.g., "Settings Catalog") |
| **Risk Weight** | A numeric value per domain used to sort findings of equal severity |
| **Script Scope ($script:)** | A PowerShell variable scope that persists for the lifetime of a module |
| **Settings Catalog** | The modern Intune policy type with structured, nested setting definitions |
| **SettingPath** | A human-readable hierarchical path describing where a setting lives (e.g., "Antivirus > Cloud Protection") |
| **Template** | In the Graph API, a predefined structure that defines the available settings for a policy type |
| **Throttling** | When the Graph API rejects requests (HTTP 429) because the caller is making too many requests |
| **Token** | A temporary credential (access token) used to authenticate Graph API requests |
| **Trigger** | The condition definition in a finding rule that determines when the finding fires |
| **v2 Cache** | The current baseline cache schema with per-policy-type sections and metadata |
