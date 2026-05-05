#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Baseline Assessment Tool — compares a customer Intune tenant against
    the eVri hardened baseline and exports a diff CSV for the assessment report.

.DESCRIPTION
    Sprint 7 scope: Settings Catalog, Endpoint Security (intents), Device
    Configuration, Admin Templates, Compliance Policies, Security Baselines,
    device/enrollment/application inventory, and findings engine with risk scoring.

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
    Which baseline tier to assess against: All, L1, L2, L3, or L4.
    Defaults to All (no filtering — all baseline policies are compared).
    Levels are cumulative: L2 includes L1+L2, L3 includes L1+L2+L3, etc.
    Filtering is applied post-load, so the baseline cache always stores all
    policies and you can switch levels without re-fetching.

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

.PARAMETER UseDefinitionsCache
    Persist the bulk-fetched setting definition / category catalog to
    Baseline\definitions-cache.json so subsequent runs can skip the bulk fetch.
    Without this switch the cache is fetched into memory only (Azure Function
    App default).

.PARAMETER RefreshDefinitions
    Force a fresh bulk fetch of definitions and overwrite the cache file.

.PARAMETER GenerateReportData
    Also write a ReportData.json with aggregated scores for report population.

.PARAMETER GenerateHtmlReport
    Also write an AssessmentReport.html with executive summary and detailed sections.

.PARAMETER PreferGraphOsLifecycle
    Prefer Microsoft Graph Windows lifecycle metadata for OS enrichment.
    Falls back to Config\OSDefinition.json when unavailable.

.PARAMETER DisableGraphOsLifecycle
    Disables Graph lifecycle lookups and forces static OSDefinition.json mapping.

.EXAMPLE
    .\IntuneBaselineAssessment.ps1 `
        -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -CustomerName "Contoso"

.EXAMPLE
    # Assess against L2 baseline (cumulative: includes L1 + L2 policies)
    .\IntuneBaselineAssessment.ps1 `
        -CustomerTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -CustomerName "Contoso" `
        -BaselineLevel L2

.EXAMPLE
    # Only compare specific baseline policies (fetch-time filter)
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

    [ValidateSet('All', 'L1', 'L2', 'L3', 'L4')]
    [string]$BaselineLevel = 'All',

    [string[]]$BaselinePolicyFilter = @(),

    [switch]$UseBaselineCache,
    [switch]$RefreshBaseline,
    [switch]$UseDefinitionsCache,
    [switch]$RefreshDefinitions,
    [switch]$GenerateReportData,
    [switch]$GenerateHtmlReport,
    [switch]$SkipInventory,
    [switch]$EnableAdvancedReporting,
    [switch]$EnableAssignmentAnalysis,
    [switch]$PreferGraphOsLifecycle = $true,
    [switch]$DisableGraphOsLifecycle,
    [switch]$UseLegacyConsoleLogging,

    [ValidateSet('SettingsCatalog', 'EndpointSecurity', 'DeviceConfig', 'AdminTemplates', 'CompliancePolicy', 'SecurityBaseline')]
    [string[]]$PolicyTypes = @('SettingsCatalog', 'EndpointSecurity', 'DeviceConfig', 'AdminTemplates', 'CompliancePolicy', 'SecurityBaseline')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$loggerModulePath = Join-Path (Join-Path $PSScriptRoot 'Modules') 'Logger.psm1'
if (Test-Path $loggerModulePath) {
    Import-Module $loggerModulePath -Force -DisableNameChecking
    Set-IbaLogOptions -VerboseMode:($VerbosePreference -eq 'Continue') -MaskTenantIds:$true -UseLegacyConsoleLogging:$UseLegacyConsoleLogging
}

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────
Write-IbaLog -Level Info -Message ''
Write-IbaLog -Level Info -Message '╔══════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-IbaLog -Level Info -Message '║    Intune Baseline Assessment Tool  v0.8.0           ║' -ForegroundColor Cyan
Write-IbaLog -Level Info -Message '║    +Bulk Definition Pre-Fetch                        ║' -ForegroundColor Cyan
Write-IbaLog -Level Info -Message '╚══════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-IbaLog -Level Info -Message "  Customer      : $CustomerName" -ForegroundColor White
Write-IbaLog -Level Info -Message "  Tenant ID     : $CustomerTenantId" -ForegroundColor White
$levelDisplay = switch ($BaselineLevel) {
    'All'   { 'All (L1-L4)' }
    'L1'    { 'L1' }
    default { "$BaselineLevel (cumulative: L1..$BaselineLevel)" }
}
Write-IbaLog -Level Info -Message "  Baseline Level: $levelDisplay" -ForegroundColor White
if ($BaselinePolicyFilter.Count -gt 0) {
    Write-IbaLog -Level Info -Message "  Policy Filter : $($BaselinePolicyFilter -join ', ')" -ForegroundColor White
}
Write-IbaLog -Level Info -Message ''

# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap — load modules
# ─────────────────────────────────────────────────────────────────────────────
$moduleRoot = Join-Path $PSScriptRoot 'Modules'

foreach ($moduleName in @('Logger', 'Auth', 'GraphAPI', 'DefinitionCache', 'PolicyReader', 'EndpointSecurityReader', 'DeviceConfigReader', 'AdminTemplateReader', 'CompliancePolicyReader', 'SecurityBaselineReader', 'OsLifecycleProvider', 'DeviceInventoryReader', 'EnrollmentAnalyzer', 'AppInventoryReader', 'IntuneReportExporter', 'AssignmentAnalysis', 'Comparison', 'Enrichment', 'RecommendationEngine', 'Export', 'HtmlReportGenerator')) {
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
  cp Config\AppConfig.template.json Config\AppConfig.json
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

# Load finding rules + risk weights
$findingRulesFile = Join-Path $ConfigPath 'FindingRules.json'
$domainMappingObj = Get-Content $domainMappingFile -Raw | ConvertFrom-Json
$riskWeights = @{}
if ($domainMappingObj.PSObject.Properties['riskWeights']) {
    $domainMappingObj.riskWeights.PSObject.Properties | ForEach-Object { $riskWeights[$_.Name] = $_.Value }
}
Initialize-FindingRules -RulesPath $findingRulesFile -RiskWeights $riskWeights

# ─────────────────────────────────────────────────────────────────────────────
# Private helper — fetches all requested policy types and aggregates results
# ─────────────────────────────────────────────────────────────────────────────
function Get-AllPolicySettings {
    param(
        [string]   $Token,
        [string]   $BaseUrl,
        [string[]] $PolicyFilter = @(),
        [string[]] $Types        = @('SettingsCatalog', 'EndpointSecurity', 'DeviceConfig', 'AdminTemplates'),
        [string]   $Label        = 'Tenant'
    )

    $all = [System.Collections.Generic.List[hashtable]]::new()

    if ('SettingsCatalog' -in $Types) {
        Write-IbaLog -Level Debug -Message "    [$Label] Settings Catalog..."
        $sc = Get-SettingsCatalogPolicies -Token $Token -BaseUrl $BaseUrl -PolicyFilter $PolicyFilter
        foreach ($item in @($sc)) { if ($null -ne $item) { $all.Add($item) } }
    }
    if ('EndpointSecurity' -in $Types) {
        Write-IbaLog -Level Debug -Message "    [$Label] Endpoint Security (intents)..."
        $es = Get-EndpointSecurityPolicies -Token $Token -BaseUrl $BaseUrl -PolicyFilter $PolicyFilter
        foreach ($item in @($es)) { if ($null -ne $item) { $all.Add($item) } }
    }
    if ('DeviceConfig' -in $Types) {
        Write-IbaLog -Level Debug -Message "    [$Label] Device Configuration..."
        $dc = Get-DeviceConfigPolicies -Token $Token -BaseUrl $BaseUrl -PolicyFilter $PolicyFilter
        foreach ($item in @($dc)) { if ($null -ne $item) { $all.Add($item) } }
    }
    if ('AdminTemplates' -in $Types) {
        Write-IbaLog -Level Debug -Message "    [$Label] Admin Templates..."
        $at = Get-AdminTemplatePolicies -Token $Token -BaseUrl $BaseUrl -PolicyFilter $PolicyFilter
        foreach ($item in @($at)) { if ($null -ne $item) { $all.Add($item) } }
    }
    if ('CompliancePolicy' -in $Types) {
        Write-IbaLog -Level Debug -Message "    [$Label] Compliance Policies..."
        $cp = Get-CompliancePolicies -Token $Token -BaseUrl $BaseUrl -PolicyFilter $PolicyFilter
        foreach ($item in @($cp)) { if ($null -ne $item) { $all.Add($item) } }
    }
    if ('SecurityBaseline' -in $Types) {
        Write-IbaLog -Level Debug -Message "    [$Label] Security Baselines..."
        $sb = Get-SecurityBaselinePolicies -Token $Token -BaseUrl $BaseUrl -PolicyFilter $PolicyFilter
        foreach ($item in @($sb)) { if ($null -ne $item) { $all.Add($item) } }
    }

    return $all
}

# ─────────────────────────────────────────────────────────────────────────────
# Private helper — filters baseline settings by level (cumulative)
# ─────────────────────────────────────────────────────────────────────────────
function Select-BaselineByLevel {
    param(
        [System.Collections.Generic.List[hashtable]]$Settings,
        [string]$Level
    )

    if ($Level -eq 'All') { return $Settings }

    # Cumulative: L2 includes L1+L2, L3 includes L1+L2+L3, etc.
    $levelMap = @{
        'L1' = @('L1')
        'L2' = @('L1', 'L2')
        'L3' = @('L1', 'L2', 'L3')
        'L4' = @('L1', 'L2', 'L3', 'L4')
    }
    $included = $levelMap[$Level]

    $filtered = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $Settings) {
        foreach ($lvl in $included) {
            if ($s.PolicyName -like "*-$lvl-*") {
                $filtered.Add($s)
                break
            }
        }
    }
    return $filtered
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 0 — Initialise the shared definition cache
#
# Bulk-fetches Settings Catalog definitions + categories + ADMX definitions
# from the baseline tenant once, so all readers can resolve them via O(1)
# lookups instead of per-ID Graph requests.
# ─────────────────────────────────────────────────────────────────────────────
Write-IbaLog -Level Info -Message '[0/5] Initialising definition cache' -ForegroundColor Yellow

$defCacheFile = if ($UseDefinitionsCache) { Join-Path $BaselinePath 'definitions-cache.json' } else { $null }
$baselineToken = $null

# Acquire the baseline token now unless we're confident a fresh cache file exists.
# When required, the token is reused by Step 1's baseline fetch path.
$canSkipBaselineConnect = $UseDefinitionsCache -and -not $RefreshDefinitions -and $defCacheFile -and (Test-Path $defCacheFile)
if (-not $canSkipBaselineConnect) {
    $baselineToken = Connect-BaselineTenant
}

Initialize-DefinitionCache `
    -Token         $baselineToken `
    -BaseUrl       $baseUrl `
    -CacheFile     $defCacheFile `
    -ForceRefresh:$RefreshDefinitions `
    -SourceTenantId $configHash['BaselineTenantId']

$cacheStats = Get-DefinitionCacheStats
Write-IbaLog -Level Info -Message ("  Ready ({0}): {1} SC defs, {2} categories, {3} ADMX defs." -f `
    $cacheStats.Source, $cacheStats.SettingsCatalogDefinitions, `
    $cacheStats.SettingsCatalogCategories, $cacheStats.AdmxDefinitions) -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Baseline settings (all policy types)
# ─────────────────────────────────────────────────────────────────────────────
Write-IbaLog -Level Info -Message ''
Write-IbaLog -Level Info -Message '[1/5] Baseline tenant — all policy types' -ForegroundColor Yellow

$baselineCacheFile = Join-Path $BaselinePath 'baseline-cache.json'
$baselineSettings  = $null

if ($UseBaselineCache -and -not $RefreshBaseline -and (Test-Path $baselineCacheFile)) {
    Write-IbaLog -Level Debug -Message "  Loading baseline from cache: $baselineCacheFile"

    $rawCache  = Get-Content $baselineCacheFile -Raw | ConvertFrom-Json
    $schemaVer = 1
    if ($rawCache.PSObject.Properties['meta'] -and
        $rawCache.meta.PSObject.Properties['schemaVersion']) {
        $schemaVer = [int]$rawCache.meta.schemaVersion
    }

    $cacheUsed = $false

    if ($schemaVer -ge 2) {
        # v2 format — per-type sections; validate coverage
        $cachedTypes  = @()
        if ($rawCache.meta.PSObject.Properties['policyTypes']) {
            $cachedTypes = [string[]]$rawCache.meta.policyTypes
        }
        $missingTypes = @($PolicyTypes | Where-Object { $_ -notin $cachedTypes })

        if ($missingTypes.Count -gt 0) {
            Write-Warning "  Cache is missing policy types: $($missingTypes -join ', '). Re-fetching baseline."
        }
        else {
            $sectionMap = @{
                SettingsCatalog  = 'settingsCatalog'
                EndpointSecurity = 'endpointSecurity'
                DeviceConfig     = 'deviceConfig'
                AdminTemplates   = 'adminTemplates'
                CompliancePolicy = 'compliancePolicies'
                SecurityBaseline = 'securityBaselines'
            }
            $baselineSettings = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($type in $PolicyTypes) {
                $section = $sectionMap[$type]
                if ($rawCache.PSObject.Properties[$section]) {
                    foreach ($item in $rawCache.$section) {
                        $ht = [hashtable]@{}
                        $item.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
                        $baselineSettings.Add($ht)
                    }
                }
            }
            $cacheUsed = $true
        }
    }
    else {
        # v1 legacy format — Settings Catalog only
        if ($PolicyTypes.Count -gt 1 -or
            ($PolicyTypes.Count -eq 1 -and $PolicyTypes[0] -ne 'SettingsCatalog')) {
            Write-Warning "  Cache is v1 format (Settings Catalog only). Re-fetching with all requested policy types."
        }
        else {
            $rawSettings = if ($rawCache.PSObject.Properties['settings']) { $rawCache.settings } else { $rawCache }
            $baselineSettings = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($item in $rawSettings) {
                $ht = [hashtable]@{}
                $item.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
                $baselineSettings.Add($ht)
            }
            $cacheUsed = $true
        }
    }

    if ($cacheUsed) {
        # Re-apply enrichment if domain mapping has changed
        $currentHash = (Get-FileHash -Path $domainMappingFile -Algorithm SHA256).Hash
        $cachedHash  = if ($rawCache.PSObject.Properties['meta'] -and
                           $rawCache.meta.PSObject.Properties['domainMappingHash']) {
                           $rawCache.meta.domainMappingHash
                       } else { $null }

        if ($cachedHash -ne $currentHash) {
            Write-IbaLog -Level Info -Message "  Domain mapping changed — re-applying enrichment to cached settings." -ForegroundColor Yellow
            Add-DomainEnrichment -Settings $baselineSettings
        }

        Write-IbaLog -Level Info -Message "  Loaded $($baselineSettings.Count) settings from cache." -ForegroundColor Green
    }
}

if ($null -eq $baselineSettings) {
    if ($UseBaselineCache -and -not (Test-Path $baselineCacheFile)) {
        Write-Warning "  --UseBaselineCache specified but no cache found; fetching from baseline tenant."
    }

    if ($null -eq $baselineToken) { $baselineToken = Connect-BaselineTenant }
    $baselineSettings = Get-AllPolicySettings `
        -Token        $baselineToken `
        -BaseUrl      $baseUrl `
        -PolicyFilter $BaselinePolicyFilter `
        -Types        $PolicyTypes `
        -Label        'Baseline'

    Add-DomainEnrichment -Settings $baselineSettings

    # Save v2 cache
    if (-not (Test-Path $BaselinePath)) {
        New-Item -ItemType Directory -Path $BaselinePath -Force | Out-Null
    }
    $domainHash   = (Get-FileHash -Path $domainMappingFile -Algorithm SHA256).Hash
    $cachePayload = [ordered]@{
        meta             = [ordered]@{
            schemaVersion     = 2
            domainMappingHash = $domainHash
            cachedAt          = (Get-Date -Format 'o')
            policyTypes       = $PolicyTypes
        }
        settingsCatalog    = @($baselineSettings | Where-Object { $_.PolicyTemplate -eq 'Settings Catalog' })
        endpointSecurity   = @($baselineSettings | Where-Object { $_.PolicyTemplate -eq 'Endpoint Security' })
        deviceConfig       = @($baselineSettings | Where-Object { $_.PolicyTemplate -eq 'Device Configuration' })
        adminTemplates     = @($baselineSettings | Where-Object { $_.PolicyTemplate -eq 'Admin Templates' })
        compliancePolicies = @($baselineSettings | Where-Object { $_.PolicyTemplate -eq 'Compliance Policy' })
        securityBaselines  = @($baselineSettings | Where-Object { $_.PolicyTemplate -eq 'Security Baseline' })
    }
    $cachePayload | ConvertTo-Json -Depth 10 | Set-Content $baselineCacheFile -Encoding UTF8
    Write-IbaLog -Level Debug -Message ('  Baseline cached ({0} settings): {1}' -f $baselineSettings.Count, $baselineCacheFile)
}

# ── Apply BaselineLevel filter (post-load) ──────────────────────────────────
$preFilterCount = $baselineSettings.Count
$baselineSettings = Select-BaselineByLevel -Settings $baselineSettings -Level $BaselineLevel

if ($BaselineLevel -ne 'All') {
    Write-IbaLog -Level Debug -Message ('  Level filter ({0} cumulative): {1} of {2} settings.' -f $BaselineLevel, $baselineSettings.Count, $preFilterCount)
}
if ($baselineSettings.Count -eq 0) {
    Write-Warning "No baseline settings match level '$BaselineLevel'. Check that baseline policies contain '-$BaselineLevel-' in their names."
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Customer settings
# ─────────────────────────────────────────────────────────────────────────────
Write-IbaLog -Level Info -Message ''
Write-IbaLog -Level Info -Message '[2/5] Customer tenant — policy settings' -ForegroundColor Yellow

$customerToken    = Connect-CustomerTenant -TenantId $CustomerTenantId
$customerSettings = Get-AllPolicySettings `
    -Token  $customerToken `
    -BaseUrl $baseUrl `
    -Types   $PolicyTypes `
    -Label   'Customer'
Add-DomainEnrichment -Settings $customerSettings

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Customer tenant inventory (devices, enrollment, apps)
# ─────────────────────────────────────────────────────────────────────────────
$deviceInventory  = $null
$enrollmentData   = $null
$appInventory     = $null

if (-not $SkipInventory) {
    Write-IbaLog -Level Info -Message ''
    Write-IbaLog -Level Info -Message '[3/5] Customer tenant — inventory collection' -ForegroundColor Yellow

    $osDefinitionPath = Join-Path $ConfigPath 'OSDefinition.json'
    Initialize-OsLifecycleProvider `
        -Token $customerToken `
        -BaseUrl $baseUrl `
        -OsDefinitionPath $osDefinitionPath `
        -PreferGraph:$PreferGraphOsLifecycle `
        -DisableGraph:$DisableGraphOsLifecycle

    $deviceInventory = Get-DeviceInventory -Token $customerToken -BaseUrl $baseUrl -IncludeOsLifecycleEnrichment
    $enrollmentData  = Get-EnrollmentAnalysis -Token $customerToken -BaseUrl $baseUrl
    $appInventory    = Get-AppInventory -Token $customerToken -BaseUrl $baseUrl

    $invDevices = if ($null -ne $deviceInventory) { $deviceInventory.Count } else { 0 }
    $invConfigs = if ($null -ne $enrollmentData -and $null -ne $enrollmentData.EnrollmentConfigs) { $enrollmentData.EnrollmentConfigs.Count } else { 0 }
    $invAp      = if ($null -ne $enrollmentData -and $null -ne $enrollmentData.AutopilotDevices) { $enrollmentData.AutopilotDevices.Count } else { 0 }
    $invApps    = if ($null -ne $appInventory) { $appInventory.Count } else { 0 }

    Write-IbaLog -Level Info -Message "    Collected: $invDevices devices, $invConfigs enrollment configs, $invAp Autopilot devices, $invApps apps." -ForegroundColor Green
}
else {
    Write-IbaLog -Level Info -Message ''
    Write-IbaLog -Level Debug -Message '[3/5] Customer tenant — inventory collection (skipped)'
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — Advanced reporting and assignment analysis (optional)
# ─────────────────────────────────────────────────────────────────────────────
$phase4Data = $null
$assignmentAnalysis = $null

if ($EnableAdvancedReporting -or $EnableAssignmentAnalysis) {
    Write-IbaLog -Level Info -Message ''
    Write-IbaLog -Level Info -Message '[4/6] Customer tenant — advanced reporting' -ForegroundColor Yellow
}

if ($EnableAdvancedReporting) {
    try {
        Write-IbaLog -Level Debug -Message '  Collecting Intune advanced report exports...'
        $phase4Data = Get-IntuneAdvancedReportData `
            -Token $customerToken `
            -BaseUrl $baseUrl `
            -CustomerSettings $customerSettings `
            -TempPath $env:TEMP
        Write-IbaLog -Level Info -Message ('  Advanced reports collected: {0} policy status rows, {1} app aggregate rows.' -f $phase4Data.Summary.PolicyStatusRows, $phase4Data.Summary.AppCount) -ForegroundColor Green
    }
    catch {
        Write-Warning ('  Advanced reporting failed and will be skipped: {0}' -f $_.Exception.Message)
        $phase4Data = $null
    }
}

if ($EnableAssignmentAnalysis) {
    try {
        Write-IbaLog -Level Debug -Message '  Running assignment analysis...'
        $assignmentAnalysis = Get-AssignmentAnalysis -Token $customerToken -BaseUrl $baseUrl
        Write-IbaLog -Level Info -Message ('  Assignment analysis complete: {0} unassigned, {1} potentially dead.' -f $assignmentAnalysis.Summary.UnassignedPolicyCount, $assignmentAnalysis.Summary.PotentiallyDeadPolicyCount) -ForegroundColor Green
    }
    catch {
        Write-Warning ('  Assignment analysis failed and will be skipped: {0}' -f $_.Exception.Message)
        $assignmentAnalysis = $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — Compare
# ─────────────────────────────────────────────────────────────────────────────
Write-IbaLog -Level Info -Message ''
Write-IbaLog -Level Info -Message '[5/6] Comparing settings...' -ForegroundColor Yellow

$comparisonResults = Compare-TenantSettings `
    -BaselineSettings $baselineSettings `
    -CustomerSettings $customerSettings

# Multi-policy settings conflict summary (Phase 2.2)
Write-IbaLog -Level Debug -Message '  Building settings conflict summary...'
$settingsConflicts = Get-SettingsConflictSummary `
    -BaselineSettings $baselineSettings `
    -CustomerSettings $customerSettings

$conflictSettingKeysWith = @(
    $settingsConflicts |
        Where-Object { $_.HasBaseline } |
        ForEach-Object { '{0}||{1}' -f $_.BaselinePolicyName, $_.DefinitionId } |
        Select-Object -Unique
)
$conflictSettingKeysWithout = @(
    $settingsConflicts |
        Where-Object { -not $_.HasBaseline } |
        ForEach-Object { 'EXTRA||{0}' -f $_.DefinitionId } |
        Select-Object -Unique
)
$conflictUniqueKeys = @(
    $settingsConflicts |
        ForEach-Object {
            if ($_.HasBaseline) { '{0}||{1}' -f $_.BaselinePolicyName, $_.DefinitionId }
            else { 'EXTRA||{0}' -f $_.DefinitionId }
        } |
        Select-Object -Unique
)
$conflictUniqueCount = @($conflictUniqueKeys).Count

if ($settingsConflicts.Count -gt 0) {
    Write-IbaLog -Level Info -Message ("  Conflict summary: {0} conflicting settings ({1} with baseline, {2} without); {3} detail rows" -f `
        $conflictUniqueCount, @($conflictSettingKeysWith).Count, @($conflictSettingKeysWithout).Count, $settingsConflicts.Count) -ForegroundColor Yellow
} else {
    Write-IbaLog -Level Info -Message '  Conflict summary: no multi-policy conflicts detected.' -ForegroundColor Green
}

# Evaluate findings
Write-IbaLog -Level Debug -Message '  Evaluating findings...'
$findings = Get-Findings `
    -ComparisonResults $comparisonResults `
    -CustomerSettings  $customerSettings `
    -DeviceInventory   $deviceInventory `
    -EnrollmentData    $enrollmentData `
    -AppInventory      $appInventory `
    -SettingsConflicts $settingsConflicts `
    -Phase4Data        $phase4Data `
    -AssignmentAnalysis $assignmentAnalysis

$fCritical = @($findings | Where-Object { $_.Severity -eq 'Critical' }).Count
$fHigh     = @($findings | Where-Object { $_.Severity -eq 'High'     }).Count
$fMedium   = @($findings | Where-Object { $_.Severity -eq 'Medium'   }).Count
$fLow      = @($findings | Where-Object { $_.Severity -eq 'Low'      }).Count

if ($findings.Count -gt 0) {
    Write-IbaLog -Level Info -Message "  $($findings.Count) findings: $fCritical Critical, $fHigh High, $fMedium Medium, $fLow Low" -ForegroundColor Yellow
} else {
    Write-IbaLog -Level Info -Message '  No findings triggered.' -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 6 — Export
# ─────────────────────────────────────────────────────────────────────────────
Write-IbaLog -Level Info -Message ''
Write-IbaLog -Level Info -Message '[6/6] Exporting results...' -ForegroundColor Yellow

$csvPath = Export-DiffCsv `
    -Results       $comparisonResults `
    -OutputPath    $OutputPath `
    -CustomerName  $CustomerName `
    -BaselineLevel $BaselineLevel

Write-IbaLog -Level Info -Message "  Diff CSV:       $csvPath" -ForegroundColor Green

# Inventory CSVs
if ($null -ne $deviceInventory -and $deviceInventory.Count -gt 0) {
    $deviceCsvPath = Export-DeviceInventoryCsv `
        -Devices       $deviceInventory `
        -OutputPath    $OutputPath `
        -CustomerName  $CustomerName `
        -BaselineLevel $BaselineLevel
    Write-IbaLog -Level Info -Message "  Device CSV:     $deviceCsvPath" -ForegroundColor Green
}

if ($null -ne $enrollmentData) {
    $enrollmentPaths = Export-EnrollmentCsv `
        -EnrollmentData $enrollmentData `
        -OutputPath     $OutputPath `
        -CustomerName   $CustomerName `
        -BaselineLevel  $BaselineLevel
    Write-IbaLog -Level Info -Message "  Enrollment CSV: $($enrollmentPaths.ConfigsCsv)" -ForegroundColor Green
    Write-IbaLog -Level Info -Message "  Autopilot CSV:  $($enrollmentPaths.AutopilotCsv)" -ForegroundColor Green
}

if ($null -ne $appInventory -and $appInventory.Count -gt 0) {
    $appCsvPath = Export-AppInventoryCsv `
        -Apps          $appInventory `
        -OutputPath    $OutputPath `
        -CustomerName  $CustomerName `
        -BaselineLevel $BaselineLevel
    Write-IbaLog -Level Info -Message "  App CSV:        $appCsvPath" -ForegroundColor Green
}

if ($null -ne $settingsConflicts -and $settingsConflicts.Count -gt 0) {
    $conflictCsvPath = Export-SettingsConflictsCsv `
        -Conflicts     $settingsConflicts `
        -OutputPath    $OutputPath `
        -CustomerName  $CustomerName `
        -BaselineLevel $BaselineLevel
    Write-IbaLog -Level Info -Message "  Conflict CSV:   $conflictCsvPath" -ForegroundColor Green
}

if ($null -ne $phase4Data) {
    if ($phase4Data.ContainsKey('AppInstallStatusAggregate') -and $phase4Data.AppInstallStatusAggregate.Count -gt 0) {
        $appInstallCsvPath = Export-AppInstallStatusAggregateCsv `
            -Rows $phase4Data.AppInstallStatusAggregate `
            -OutputPath $OutputPath `
            -CustomerName $CustomerName `
            -BaselineLevel $BaselineLevel
        Write-IbaLog -Level Info -Message ('  App Install CSV: {0}' -f $appInstallCsvPath) -ForegroundColor Green
    }
    if ($phase4Data.ContainsKey('DeviceAssignmentStatusByConfigurationPolicy') -and $phase4Data.DeviceAssignmentStatusByConfigurationPolicy.Count -gt 0) {
        $policyStatusDetailCsv = Export-DeviceAssignmentStatusByConfigurationPolicyCsv `
            -Rows $phase4Data.DeviceAssignmentStatusByConfigurationPolicy `
            -OutputPath $OutputPath `
            -CustomerName $CustomerName `
            -BaselineLevel $BaselineLevel
        Write-IbaLog -Level Info -Message ('  Policy Status Detail CSV: {0}' -f $policyStatusDetailCsv) -ForegroundColor Green
    }
    if ($phase4Data.ContainsKey('PolicyStatusOverview') -and $phase4Data.PolicyStatusOverview.Count -gt 0) {
        $policyStatusOverviewCsv = Export-PolicyStatusOverviewCsv `
            -Rows $phase4Data.PolicyStatusOverview `
            -OutputPath $OutputPath `
            -CustomerName $CustomerName `
            -BaselineLevel $BaselineLevel
        Write-IbaLog -Level Info -Message ('  Policy Status Overview CSV: {0}' -f $policyStatusOverviewCsv) -ForegroundColor Green
    }
}

if ($null -ne $assignmentAnalysis -and $assignmentAnalysis.ContainsKey('PolicyAssignmentSummary') -and $assignmentAnalysis.PolicyAssignmentSummary.Count -gt 0) {
    $assignmentCsvPath = Export-PolicyAssignmentSummaryCsv `
        -Rows $assignmentAnalysis.PolicyAssignmentSummary `
        -OutputPath $OutputPath `
        -CustomerName $CustomerName `
        -BaselineLevel $BaselineLevel
    Write-IbaLog -Level Info -Message ('  Assignment Summary CSV: {0}' -f $assignmentCsvPath) -ForegroundColor Green
}

if ($GenerateReportData) {
    $jsonPath = Export-ReportData `
        -Results           $comparisonResults `
        -OutputPath        $OutputPath `
        -CustomerName      $CustomerName `
        -BaselineLevel     $BaselineLevel `
        -DeviceInventory   $deviceInventory `
        -EnrollmentData    $enrollmentData `
        -AppInventory      $appInventory `
        -Findings          $findings `
        -SettingsConflicts $settingsConflicts `
        -Phase4Data        $phase4Data `
        -AssignmentAnalysis $assignmentAnalysis
    Write-IbaLog -Level Info -Message "  JSON: $jsonPath" -ForegroundColor Green
}

if ($GenerateHtmlReport) {
    $htmlPath = Export-HtmlAssessmentReport `
        -Results           $comparisonResults `
        -OutputPath        $OutputPath `
        -CustomerName      $CustomerName `
        -BaselineLevel     $BaselineLevel `
        -DeviceInventory   $deviceInventory `
        -EnrollmentData    $enrollmentData `
        -AppInventory      $appInventory `
        -Findings          $findings `
        -SettingsConflicts $settingsConflicts `
        -Phase4Data        $phase4Data `
        -AssignmentAnalysis $assignmentAnalysis
    Write-IbaLog -Level Info -Message "  HTML: $htmlPath" -ForegroundColor Green
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

Write-IbaLog -Level Info -Message ''
Write-IbaLog -Level Info -Message '═══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-IbaLog -Level Info -Message "  Intune Baseline Assessment — $CustomerName"           -ForegroundColor Cyan
Write-IbaLog -Level Info -Message "  Baseline Level  : $levelDisplay"                      -ForegroundColor Cyan
Write-IbaLog -Level Info -Message "  Total Settings  : $total"                             -ForegroundColor Cyan
Write-IbaLog -Level Info -Message '───────────────────────────────────────────────────────' -ForegroundColor Cyan
Write-IbaLog -Level Info -Message ("  Compliant : {0,5}  ({1,5:P1})" -f $compliant, $pCompliant) -ForegroundColor Green
Write-IbaLog -Level Info -Message ("  Conflict  : {0,5}  ({1,5:P1})" -f $conflict,  $pConflict)  -ForegroundColor Red
Write-IbaLog -Level Info -Message ("  Missing   : {0,5}  ({1,5:P1})" -f $missing,   $pMissing)   -ForegroundColor DarkYellow
Write-IbaLog -Level Info -Message ("  Extra     : {0,5}  ({1,5:P1})" -f $extra,     $pExtra)     -ForegroundColor Gray

# Per-domain breakdown
$domainGroups = @($comparisonResults | Where-Object { $_.BaselineDomain } | Group-Object BaselineDomain)
if ($domainGroups.Count -gt 0) {
    Write-IbaLog -Level Info -Message '───────────────────────────────────────────────────────' -ForegroundColor Cyan
    Write-IbaLog -Level Info -Message '  By Domain:' -ForegroundColor Cyan

    foreach ($d in $domainGroups | Sort-Object Name) {
        $dc  = @($d.Group | Where-Object { $_.Result -eq 'Compliant' }).Count
        $dt  = $d.Group.Count
        $pct = if ($dt -gt 0) { [Math]::Round($dc / $dt * 100) } else { 0 }
        $score = Get-MaturityScore -CompliantPct $pct
        $scoreColor = switch ($score) {
            0 { 'DarkRed'    }
            1 { 'Red'        }
            2 { 'DarkYellow' }
            3 { 'Yellow'     }
            4 { 'Cyan'       }
            5 { 'Green'      }
        }
        Write-IbaLog -Level Info -Message ("    {0,-32} Score {1}/5  [{2,3}% compliant, {3} settings]" -f `
            $d.Name, $score, $pct, $dt) -ForegroundColor $scoreColor
    }
}

# Findings summary
if ($findings.Count -gt 0) {
    Write-IbaLog -Level Info -Message '───────────────────────────────────────────────────────' -ForegroundColor Cyan
    Write-IbaLog -Level Info -Message '  Findings:' -ForegroundColor Cyan
    Write-IbaLog -Level Info -Message ("    Critical: {0}  High: {1}  Medium: {2}  Low: {3}" -f $fCritical, $fHigh, $fMedium, $fLow) -ForegroundColor White
    # Show top 3 findings
    $topFindings = @($findings | Select-Object -First 3)
    foreach ($f in $topFindings) {
        $sevColor = switch ($f.Severity) {
            'Critical' { 'Red'        }
            'High'     { 'DarkYellow' }
            'Medium'   { 'Yellow'     }
            'Low'      { 'Gray'       }
        }
        Write-IbaLog -Level Info -Message ("    [{0}] {1}" -f $f.Severity, $f.FindingName) -ForegroundColor $sevColor
    }
}

# Inventory summary
if ($null -ne $deviceInventory -and $deviceInventory.Count -gt 0) {
    Write-IbaLog -Level Info -Message '───────────────────────────────────────────────────────' -ForegroundColor Cyan
    Write-IbaLog -Level Info -Message '  Inventory:' -ForegroundColor Cyan
    $compliantDevices = @($deviceInventory | Where-Object { $_.ComplianceState -eq 'compliant' }).Count
    Write-IbaLog -Level Info -Message "    Devices: $($deviceInventory.Count) total, $compliantDevices compliant" -ForegroundColor White
    if ($null -ne $enrollmentData) {
        Write-IbaLog -Level Info -Message "    Autopilot: $($enrollmentData.AutopilotDevices.Count) registered" -ForegroundColor White
        Write-IbaLog -Level Info -Message "    Enrollment configs: $($enrollmentData.EnrollmentConfigs.Count)" -ForegroundColor White
    }
    if ($null -ne $appInventory -and $appInventory.Count -gt 0) {
        $assignedApps = @($appInventory | Where-Object { $_.IsAssigned -eq 'Yes' }).Count
        Write-IbaLog -Level Info -Message "    Apps: $($appInventory.Count) total, $assignedApps assigned" -ForegroundColor White
    }
}

Write-IbaLog -Level Info -Message '═══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-IbaLog -Level Info -Message "  Output: $csvPath" -ForegroundColor Green
Write-IbaLog -Level Info -Message ''
