#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Baseline Assessment Tool — compares a customer Intune tenant against
    the eVri hardened baseline and exports a diff CSV for the assessment report.

.DESCRIPTION
    Sprint 1 scope: Settings Catalog policies only.
    Future sprints will add: Endpoint Security (intents), Device Configuration,
    Security Baselines, Admin Templates, Compliance Policies.

.PARAMETER CustomerTenantId
    Azure AD Tenant ID (GUID) of the customer tenant to assess.

.PARAMETER CustomerName
    Display name of the customer — used in output filenames.

.PARAMETER ConfigPath
    Path to the Config\ folder containing AppConfig.json and DomainMapping.json.
    Defaults to Config\ next to this script.

.PARAMETER OutputPath
    Directory where CSV (and optionally ReportData.json) will be written.
    Defaults to Exports\ next to this script.

.PARAMETER BaselinePath
    Directory that holds the baseline cache file.
    Defaults to Baseline\ next to this script.

.PARAMETER BaselineLevel
    Which baseline tier to assess against: L1, L2, L3, or L4.
    Currently informational — used in filenames and summary output.

.PARAMETER UseBaselineCache
    Skip re-fetching the baseline tenant; use the cached baseline-cache.json.
    Use this for faster iterative runs after the initial fetch.

.PARAMETER RefreshBaseline
    Force a fresh fetch from the baseline tenant and overwrite the cache.

.PARAMETER BaselinePolicyFilter
    One or more wildcard patterns. Only baseline policies whose names match at
    least one pattern are included in the comparison. Wildcards (* ?) are
    supported. Leave empty (default) to include all policies in the baseline
    tenant.
    Example: -BaselinePolicyFilter 'SBZ-Win-L1-*','SBZ-Win-Custom-*'
    Note: the filter is baked into the baseline cache. If you change the filter,
    use -RefreshBaseline to re-fetch.

.PARAMETER GenerateReportData
    Also write a ReportData.json with aggregated scores for report population.

.EXAMPLE
    .\IntuneBaselineAssessment.ps1 `
        -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -CustomerName "Contoso"

.EXAMPLE
    # Only compare L1 baseline policies
    .\IntuneBaselineAssessment.ps1 `
        -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -CustomerName "Contoso" `
        -BaselinePolicyFilter 'SBZ-Win-L1-*','SBZ-Win-Custom-*'

.EXAMPLE
    # Re-use cached baseline (faster for iterative testing)
    .\IntuneBaselineAssessment.ps1 `
        -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -CustomerName "Contoso" `
        -UseBaselineCache `
        -GenerateReportData
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Customer Azure AD Tenant ID (GUID)')]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$CustomerTenantId,

    [Parameter(Mandatory, HelpMessage = 'Customer display name — used in output filenames')]
    [string]$CustomerName,

    [string]$ConfigPath   = (Join-Path $PSScriptRoot 'Config'),
    [string]$OutputPath   = (Join-Path $PSScriptRoot 'Exports'),
    [string]$BaselinePath = (Join-Path $PSScriptRoot 'Baseline'),

    [ValidateSet('L1', 'L2', 'L3', 'L4')]
    [string]$BaselineLevel = 'L1',

    [string[]]$BaselinePolicyFilter = @(),

    [switch]$UseBaselineCache,
    [switch]$RefreshBaseline,
    [switch]$GenerateReportData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║    Intune Baseline Assessment Tool  v0.1.0           ║' -ForegroundColor Cyan
Write-Host '║    Sprint 1 — Settings Catalog                       ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host "  Customer      : $CustomerName" -ForegroundColor White
Write-Host "  Tenant ID     : $CustomerTenantId" -ForegroundColor White
Write-Host "  Baseline Level: $BaselineLevel" -ForegroundColor White
if ($BaselinePolicyFilter.Count -gt 0) {
    Write-Host "  Policy Filter : $($BaselinePolicyFilter -join ', ')" -ForegroundColor White
}
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap — load modules
# ─────────────────────────────────────────────────────────────────────────────
$moduleRoot = Join-Path $PSScriptRoot 'Modules'

foreach ($moduleName in @('Auth', 'GraphAPI', 'PolicyReader', 'Comparison', 'Enrichment', 'Export')) {
    $modulePath = Join-Path $moduleRoot "$moduleName.psm1"
    if (-not (Test-Path $modulePath)) {
        throw "Required module not found: $modulePath"
    }
    Import-Module $modulePath -Force -DisableNameChecking
}

# ─────────────────────────────────────────────────────────────────────────────
# Load configuration
# ─────────────────────────────────────────────────────────────────────────────
$configFile = Join-Path $ConfigPath 'AppConfig.json'
if (-not (Test-Path $configFile)) {
    throw @"
Configuration file not found: $configFile

Copy the template and fill in your values:
  cp Config\AppConfig.json Config\AppConfig.json
Then edit AppConfig.json with your ClientId, ClientSecret, and BaselineTenantId.
"@
}

$configObj  = Get-Content $configFile -Raw | ConvertFrom-Json
$configHash = [hashtable]@{}
$configObj.PSObject.Properties | ForEach-Object { $configHash[$_.Name] = $_.Value }

Initialize-AuthConfig -Config $configHash

# Compose Graph base URL from config
$baseUrl = "$($configHash['GraphBaseUrl'])/$($configHash['GraphApiVersion'])"

# Load domain mapping
$domainMappingFile = Join-Path $ConfigPath 'DomainMapping.json'
Initialize-DomainMapping -MappingPath $domainMappingFile

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Baseline settings
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '[1/4] Baseline tenant — Settings Catalog' -ForegroundColor Yellow

$baselineCacheFile = Join-Path $BaselinePath 'baseline-cache.json'
$baselineSettings  = $null

if ($UseBaselineCache -and -not $RefreshBaseline -and (Test-Path $baselineCacheFile)) {
    Write-Host "  Loading baseline from cache: $baselineCacheFile" -ForegroundColor DarkGray

    $rawCache    = Get-Content $baselineCacheFile -Raw | ConvertFrom-Json

    # Support both new wrapper format and legacy plain-array format
    $rawSettings = if ($rawCache.PSObject.Properties['settings']) { $rawCache.settings } else { $rawCache }
    $cachedHash  = if ($rawCache.PSObject.Properties['meta'])     { $rawCache.meta.domainMappingHash } else { $null }

    $baselineSettings = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($item in $rawSettings) {
        $ht = [hashtable]@{}
        $item.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        $baselineSettings.Add($ht)
    }

    # Re-apply enrichment if domain mapping has changed (or cache is old format)
    $currentHash = (Get-FileHash -Path $domainMappingFile -Algorithm SHA256).Hash
    if ($cachedHash -ne $currentHash) {
        Write-Host "  Domain mapping changed — re-applying enrichment to cached settings." -ForegroundColor Yellow
        Add-DomainEnrichment -Settings $baselineSettings
    }

    Write-Host "  Loaded $($baselineSettings.Count) settings from cache." -ForegroundColor Green
}
else {
    if ($UseBaselineCache -and -not (Test-Path $baselineCacheFile)) {
        Write-Warning "  --UseBaselineCache specified but no cache found; fetching from baseline tenant."
    }

    $baselineToken    = Connect-BaselineTenant
    $baselineSettings = Get-SettingsCatalogPolicies -Token $baselineToken -BaseUrl $baseUrl -PolicyFilter $BaselinePolicyFilter
    Add-DomainEnrichment -Settings $baselineSettings

    # Save cache (wrapped with metadata for domain-mapping change detection)
    if (-not (Test-Path $BaselinePath)) {
        New-Item -ItemType Directory -Path $BaselinePath -Force | Out-Null
    }
    $domainHash   = (Get-FileHash -Path $domainMappingFile -Algorithm SHA256).Hash
    $cachePayload = [ordered]@{
        meta     = [ordered]@{
            domainMappingHash = $domainHash
            cachedAt          = (Get-Date -Format 'o')
        }
        settings = $baselineSettings
    }
    $cachePayload | ConvertTo-Json -Depth 10 | Set-Content $baselineCacheFile -Encoding UTF8
    Write-Host "  Baseline cached: $baselineCacheFile" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Customer settings
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[2/4] Customer tenant — Settings Catalog' -ForegroundColor Yellow

$customerToken    = Connect-CustomerTenant -TenantId $CustomerTenantId
$customerSettings = Get-SettingsCatalogPolicies -Token $customerToken -BaseUrl $baseUrl
Add-DomainEnrichment -Settings $customerSettings

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Compare
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[3/4] Comparing settings...' -ForegroundColor Yellow

$comparisonResults = Compare-TenantSettings `
    -BaselineSettings $baselineSettings `
    -CustomerSettings $customerSettings

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — Export
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[4/4] Exporting results...' -ForegroundColor Yellow

$csvPath = Export-DiffCsv `
    -Results       $comparisonResults `
    -OutputPath    $OutputPath `
    -CustomerName  $CustomerName `
    -BaselineLevel $BaselineLevel

Write-Host "  CSV:  $csvPath" -ForegroundColor Green

if ($GenerateReportData) {
    $jsonPath = Export-ReportData `
        -Results       $comparisonResults `
        -OutputPath    $OutputPath `
        -CustomerName  $CustomerName `
        -BaselineLevel $BaselineLevel
    Write-Host "  JSON: $jsonPath" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
$total     = $comparisonResults.Count
$compliant = @($comparisonResults | Where-Object { $_.Result -eq 'Compliant' }).Count
$conflict  = @($comparisonResults | Where-Object { $_.Result -eq 'Conflict'  }).Count
$missing   = @($comparisonResults | Where-Object { $_.Result -eq 'Missing'   }).Count
$extra     = @($comparisonResults | Where-Object { $_.Result -eq 'Extra'     }).Count

$pCompliant = if ($total -gt 0) { $compliant / $total } else { 0 }
$pConflict  = if ($total -gt 0) { $conflict  / $total } else { 0 }
$pMissing   = if ($total -gt 0) { $missing   / $total } else { 0 }
$pExtra     = if ($total -gt 0) { $extra     / $total } else { 0 }

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "  Intune Baseline Assessment — $CustomerName"           -ForegroundColor Cyan
Write-Host "  Baseline Level  : $BaselineLevel"                     -ForegroundColor Cyan
Write-Host "  Total Settings  : $total"                             -ForegroundColor Cyan
Write-Host '───────────────────────────────────────────────────────' -ForegroundColor Cyan
Write-Host ("  Compliant : {0,5}  ({1,5:P1})" -f $compliant, $pCompliant) -ForegroundColor Green
Write-Host ("  Conflict  : {0,5}  ({1,5:P1})" -f $conflict,  $pConflict)  -ForegroundColor Red
Write-Host ("  Missing   : {0,5}  ({1,5:P1})" -f $missing,   $pMissing)   -ForegroundColor DarkYellow
Write-Host ("  Extra     : {0,5}  ({1,5:P1})" -f $extra,     $pExtra)     -ForegroundColor Gray

# Per-domain breakdown
$domainGroups = @($comparisonResults | Where-Object { $_.BaselineDomain } | Group-Object BaselineDomain)
if ($domainGroups.Count -gt 0) {
    Write-Host '───────────────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host '  By Domain:' -ForegroundColor Cyan

    foreach ($d in $domainGroups | Sort-Object Name) {
        $dc  = @($d.Group | Where-Object { $_.Result -eq 'Compliant' }).Count
        $dt  = $d.Group.Count
        $pct = if ($dt -gt 0) { [Math]::Round($dc / $dt * 100) } else { 0 }
        $score = switch ($pct) {
            { $_ -eq 0 }  { 0; break }
            { $_ -lt 25 } { 1; break }
            { $_ -lt 50 } { 2; break }
            { $_ -lt 75 } { 3; break }
            { $_ -lt 90 } { 4; break }
            default        { 5 }
        }
        $scoreColor = switch ($score) {
            0 { 'DarkRed'    }
            1 { 'Red'        }
            2 { 'DarkYellow' }
            3 { 'Yellow'     }
            4 { 'Cyan'       }
            5 { 'Green'      }
        }
        Write-Host ("    {0,-32} Score {1}/5  [{2,3}% compliant, {3} settings]" -f `
            $d.Name, $score, $pct, $dt) -ForegroundColor $scoreColor
    }
}

Write-Host '═══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "  Output: $csvPath" -ForegroundColor Green
Write-Host ''
