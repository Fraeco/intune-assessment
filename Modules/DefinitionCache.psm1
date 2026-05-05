# =============================================================================
# DefinitionCache.psm1 — Shared in-memory cache for Intune setting definitions
#
# Bulk-fetches the global setting definition / category catalog from the
# baseline tenant once at startup. All readers then resolve definitions and
# categories via O(1) hashtable lookups instead of per-ID Graph API calls.
#
# Microsoft's setting catalog is global (same across all tenants), so a single
# fetch from the baseline tenant serves both baseline and customer comparisons.
#
# Caches:
#   $script:SettingsCatalogDefinitions  — definitionId → definition object
#   $script:SettingsCatalogCategories   — categoryId   → category object
#   $script:AdmxDefinitions             — admxDefId    → ADMX definition object
#   $script:CategoryPathCache           — categoryId   → resolved path string
#
# Optional persistent cache file (parallel to baseline-cache.json):
#   Baseline/definitions-cache.json — schemaVersion 1, atomic write
# =============================================================================

Set-StrictMode -Version Latest

$script:CacheSchemaVersion = 1

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------
$script:SettingsCatalogDefinitions = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$script:SettingsCatalogCategories  = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$script:AdmxDefinitions            = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$script:CategoryPathCache          = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

$script:CacheReady = $false
$script:CacheMeta  = $null

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Initialize-DefinitionCache {
    <#
    .SYNOPSIS
        Loads the shared definition cache from disk or bulk-fetches it from Graph.
    .PARAMETER Token
        Baseline tenant access token. Required only when fetching from Graph
        (i.e. no usable cache file).
    .PARAMETER BaseUrl
        Graph API base URL (e.g. https://graph.microsoft.com/beta). Required
        only when fetching from Graph.
    .PARAMETER CacheFile
        Optional path to a JSON cache file. When provided, the function tries
        to load from this file first; on a fresh fetch the file is written.
    .PARAMETER ForceRefresh
        Ignore any existing cache file and always fetch from Graph.
    .PARAMETER MaxCacheAgeDays
        Cache file TTL in days (default 30). Older files are refreshed.
    .PARAMETER SourceTenantId
        Optional tenant id stored in the cache file metadata for traceability.
    #>
    [CmdletBinding()]
    param(
        [string]$Token,
        [string]$BaseUrl,
        [string]$CacheFile,
        [switch]$ForceRefresh,
        [int]   $MaxCacheAgeDays = 30,
        [string]$SourceTenantId  = ''
    )

    # Try load from disk first
    if ($CacheFile -and -not $ForceRefresh -and (Test-Path $CacheFile)) {
        try {
            if (Read-DefinitionCacheFile -CacheFile $CacheFile -MaxCacheAgeDays $MaxCacheAgeDays) {
                return
            }
        }
        catch {
            Write-Warning "  Definition cache file load failed ($_). Falling back to fresh fetch."
        }
    }

    # Need to fetch from Graph
    if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($BaseUrl)) {
        throw "Initialize-DefinitionCache: -Token and -BaseUrl are required when no usable cache file is available."
    }

    Invoke-DefinitionBulkFetch -Token $Token -BaseUrl $BaseUrl

    if ($CacheFile -and $script:CacheReady) {
        try {
            Write-DefinitionCacheFile -CacheFile $CacheFile -SourceTenantId $SourceTenantId
        }
        catch {
            Write-Warning "  Could not write definition cache file '$CacheFile': $_"
        }
    }
    elseif ($CacheFile) {
        Write-Warning "  Skipping cache file write — bulk fetch returned no data."
    }
}

function Get-CachedSettingDefinition {
    <#
    .SYNOPSIS
        O(1) lookup for a Settings Catalog definition. Returns $null on miss.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$DefinitionId)

    if ([string]::IsNullOrWhiteSpace($DefinitionId)) { return $null }
    if ($script:SettingsCatalogDefinitions.ContainsKey($DefinitionId)) {
        return $script:SettingsCatalogDefinitions[$DefinitionId]
    }
    return $null
}

function Get-CachedSettingCategory {
    <#
    .SYNOPSIS
        O(1) lookup for a Settings Catalog category. Returns $null on miss.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$CategoryId)

    if ([string]::IsNullOrWhiteSpace($CategoryId)) { return $null }
    if ($script:SettingsCatalogCategories.ContainsKey($CategoryId)) {
        return $script:SettingsCatalogCategories[$CategoryId]
    }
    return $null
}

function Get-CachedCategoryPath {
    <#
    .SYNOPSIS
        Builds the readable category hierarchy ("Foo > Bar > Baz") for a leaf
        category by walking the parent chain through the in-memory cache.
        Memoized; root categories (no parent) are excluded from the path.
    .OUTPUTS
        String — empty when the category is not cached or is itself a root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$CategoryId,
        [int]                  $Depth    = 0,
        [int]                  $MaxDepth = 8
    )

    if ([string]::IsNullOrWhiteSpace($CategoryId) -or $Depth -ge $MaxDepth) {
        return ''
    }

    if ($Depth -eq 0 -and $script:CategoryPathCache.ContainsKey($CategoryId)) {
        return $script:CategoryPathCache[$CategoryId]
    }

    $cat = Get-CachedSettingCategory -CategoryId $CategoryId
    if ($null -eq $cat) { return '' }

    $parentId = if ($cat.PSObject.Properties['parentCategoryId']) { $cat.parentCategoryId } else { $null }

    # Root categories are omitted from the displayed path
    if ([string]::IsNullOrWhiteSpace($parentId)) { return '' }

    $parentPath = Get-CachedCategoryPath -CategoryId $parentId -Depth ($Depth + 1) -MaxDepth $MaxDepth

    $own  = if ($cat.PSObject.Properties['displayName']) { "$($cat.displayName)" } else { '' }
    $path = if ($parentPath) { "$parentPath > $own" } else { $own }

    if ($Depth -eq 0) { $script:CategoryPathCache[$CategoryId] = $path }
    return $path
}

function Get-CachedAdmxDefinition {
    <#
    .SYNOPSIS
        O(1) lookup for an ADMX (Group Policy) definition. Returns $null on miss.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$DefinitionId)

    if ([string]::IsNullOrWhiteSpace($DefinitionId)) { return $null }
    if ($script:AdmxDefinitions.ContainsKey($DefinitionId)) {
        return $script:AdmxDefinitions[$DefinitionId]
    }
    return $null
}

function Add-CachedDefinition {
    <#
    .SYNOPSIS
        Opportunistically pushes a definition into the shared cache. Used by
        readers when they receive inline definitions via $expand — covers
        deprecated or tenant-specific definitions not in the global catalog.
    .PARAMETER Kind
        Which sub-cache to populate: SettingsCatalog, Category, or Admx.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('SettingsCatalog', 'Category', 'Admx')]
        [string]$Kind,

        [Parameter(Mandatory)] [string]$Id,

        [Parameter(Mandatory)] $Definition
    )

    if ([string]::IsNullOrWhiteSpace($Id) -or $null -eq $Definition) { return }

    switch ($Kind) {
        'SettingsCatalog' {
            if (-not $script:SettingsCatalogDefinitions.ContainsKey($Id)) {
                $script:SettingsCatalogDefinitions[$Id] = $Definition
            }
        }
        'Category' {
            if (-not $script:SettingsCatalogCategories.ContainsKey($Id)) {
                $script:SettingsCatalogCategories[$Id] = $Definition
                # Invalidate any path resolution that might have used a missing parent
                $script:CategoryPathCache.Clear()
            }
        }
        'Admx' {
            if (-not $script:AdmxDefinitions.ContainsKey($Id)) {
                $script:AdmxDefinitions[$Id] = $Definition
            }
        }
    }
}

function Test-DefinitionCacheReady {
    <#
    .SYNOPSIS
        Returns $true once Initialize-DefinitionCache has populated the cache.
        Reader modules use this to decide whether to delegate to the shared
        cache or fall back to per-ID Graph requests.
    #>
    [OutputType([bool])]
    param()
    return [bool]$script:CacheReady
}

function Get-DefinitionCacheStats {
    <#
    .SYNOPSIS
        Returns a hashtable describing the current cache state — used for
        startup status reporting.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        Ready                       = $script:CacheReady
        SettingsCatalogDefinitions  = $script:SettingsCatalogDefinitions.Count
        SettingsCatalogCategories   = $script:SettingsCatalogCategories.Count
        AdmxDefinitions             = $script:AdmxDefinitions.Count
        Source                      = if ($null -ne $script:CacheMeta -and $script:CacheMeta.ContainsKey('source')) { $script:CacheMeta['source'] } else { 'none' }
        CachedAt                    = if ($null -ne $script:CacheMeta -and $script:CacheMeta.ContainsKey('cachedAt')) { $script:CacheMeta['cachedAt'] } else { $null }
    }
}

function Reset-DefinitionCache {
    <#
    .SYNOPSIS
        Clears all in-memory state. Useful between tenant switches or in tests.
    #>
    $script:SettingsCatalogDefinitions.Clear()
    $script:SettingsCatalogCategories.Clear()
    $script:AdmxDefinitions.Clear()
    $script:CategoryPathCache.Clear()
    $script:CacheReady = $false
    $script:CacheMeta  = $null
    Write-Verbose "DefinitionCache: all caches cleared."
}

# ---------------------------------------------------------------------------
# Internal — bulk fetch from Graph
# ---------------------------------------------------------------------------

function Invoke-DefinitionBulkFetch {
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-IbaLog -Level Debug -Message "  Bulk-fetching Settings Catalog definitions..."
    try {
        $defs = Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/configurationSettings" -Token $Token
        foreach ($d in $defs) {
            if ($d -and $d.PSObject.Properties['id'] -and $d.id) {
                $script:SettingsCatalogDefinitions[$d.id] = $d
            }
        }
        Write-IbaLog -Level Debug -Message "    $($script:SettingsCatalogDefinitions.Count) Settings Catalog definitions cached."
    }
    catch {
        Write-Warning "  Settings Catalog bulk fetch failed: $_. Readers will fall back to per-ID lookups."
    }

    Write-IbaLog -Level Debug -Message "  Bulk-fetching Settings Catalog categories..."
    try {
        $cats = Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/configurationCategories" -Token $Token
        foreach ($c in $cats) {
            if ($c -and $c.PSObject.Properties['id'] -and $c.id) {
                $script:SettingsCatalogCategories[$c.id] = $c
            }
        }
        Write-IbaLog -Level Debug -Message "    $($script:SettingsCatalogCategories.Count) Settings Catalog categories cached."
    }
    catch {
        Write-Warning "  Settings Catalog category bulk fetch failed: $_. Readers will fall back to per-ID lookups."
    }

    Write-IbaLog -Level Debug -Message "  Bulk-fetching Admin Template (ADMX) definitions..."
    try {
        $admx = Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/groupPolicyDefinitions" -Token $Token
        foreach ($a in $admx) {
            if ($a -and $a.PSObject.Properties['id'] -and $a.id) {
                $script:AdmxDefinitions[$a.id] = $a
            }
        }
        Write-IbaLog -Level Debug -Message "    $($script:AdmxDefinitions.Count) ADMX definitions cached."
    }
    catch {
        Write-Warning "  ADMX bulk fetch failed: $_. AdminTemplateReader will fall back to per-ID lookups."
    }

    $stopwatch.Stop()

    $totalFetched = $script:SettingsCatalogDefinitions.Count +
                    $script:SettingsCatalogCategories.Count +
                    $script:AdmxDefinitions.Count
    $script:CacheReady = ($totalFetched -gt 0)
    $script:CacheMeta  = @{
        source                      = 'graph'
        cachedAt                    = (Get-Date -Format 'o')
        fetchSeconds                = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        settingsCatalogDefinitions  = $script:SettingsCatalogDefinitions.Count
        settingsCatalogCategories   = $script:SettingsCatalogCategories.Count
        admxDefinitions             = $script:AdmxDefinitions.Count
    }
}

# ---------------------------------------------------------------------------
# Internal — cache file load
# ---------------------------------------------------------------------------

function Read-DefinitionCacheFile {
    <#
    Returns $true if the file was successfully loaded and is fresh enough,
    $false otherwise (caller will then fetch).
    #>
    param(
        [Parameter(Mandatory)] [string]$CacheFile,
        [int]                  $MaxCacheAgeDays = 30
    )

    Write-IbaLog -Level Debug -Message "  Loading definition cache from: $CacheFile"
    $raw = Get-Content $CacheFile -Raw | ConvertFrom-Json

    if (-not $raw.PSObject.Properties['meta']) {
        Write-Warning "  Cache file has no 'meta' section; ignoring."
        return $false
    }

    $schemaVer = if ($raw.meta.PSObject.Properties['schemaVersion']) { [int]$raw.meta.schemaVersion } else { 0 }
    if ($schemaVer -ne $script:CacheSchemaVersion) {
        Write-Warning "  Cache schema v$schemaVer not supported (expected v$($script:CacheSchemaVersion)); refreshing."
        return $false
    }

    if ($raw.meta.PSObject.Properties['cachedAt']) {
        try {
            $cachedAt = [datetime]::Parse($raw.meta.cachedAt)
            $age = (Get-Date) - $cachedAt
            if ($age.TotalDays -gt $MaxCacheAgeDays) {
                Write-IbaLog -Level Info -Message "  Cache is $([Math]::Round($age.TotalDays, 1)) days old (TTL $MaxCacheAgeDays); refreshing." -ForegroundColor Yellow
                return $false
            }
        }
        catch {
            Write-Warning "  Could not parse cache timestamp; refreshing."
            return $false
        }
    }

    # Reset state before populating
    $script:SettingsCatalogDefinitions.Clear()
    $script:SettingsCatalogCategories.Clear()
    $script:AdmxDefinitions.Clear()
    $script:CategoryPathCache.Clear()

    if ($raw.PSObject.Properties['settingsCatalog']) {
        $sc = $raw.settingsCatalog
        if ($sc.PSObject.Properties['definitions']) {
            foreach ($d in $sc.definitions) {
                if ($d -and $d.PSObject.Properties['id'] -and $d.id) {
                    $script:SettingsCatalogDefinitions[$d.id] = $d
                }
            }
        }
        if ($sc.PSObject.Properties['categories']) {
            foreach ($c in $sc.categories) {
                if ($c -and $c.PSObject.Properties['id'] -and $c.id) {
                    $script:SettingsCatalogCategories[$c.id] = $c
                }
            }
        }
    }

    if ($raw.PSObject.Properties['adminTemplates']) {
        $at = $raw.adminTemplates
        if ($at.PSObject.Properties['definitions']) {
            foreach ($a in $at.definitions) {
                if ($a -and $a.PSObject.Properties['id'] -and $a.id) {
                    $script:AdmxDefinitions[$a.id] = $a
                }
            }
        }
    }

    $script:CacheReady = $true
    $script:CacheMeta  = @{
        source                      = 'file'
        cachedAt                    = if ($raw.meta.PSObject.Properties['cachedAt']) { $raw.meta.cachedAt } else { $null }
        sourceTenantId              = if ($raw.meta.PSObject.Properties['sourceTenantId']) { $raw.meta.sourceTenantId } else { '' }
        settingsCatalogDefinitions  = $script:SettingsCatalogDefinitions.Count
        settingsCatalogCategories   = $script:SettingsCatalogCategories.Count
        admxDefinitions             = $script:AdmxDefinitions.Count
    }

    Write-IbaLog -Level Debug -Message "    Loaded from file: $($script:SettingsCatalogDefinitions.Count) defs, $($script:SettingsCatalogCategories.Count) cats, $($script:AdmxDefinitions.Count) ADMX defs."
    return $true
}

# ---------------------------------------------------------------------------
# Internal — cache file write (atomic via temp + rename)
# ---------------------------------------------------------------------------

function Write-DefinitionCacheFile {
    param(
        [Parameter(Mandatory)] [string]$CacheFile,
        [string]               $SourceTenantId = ''
    )

    $dir = Split-Path -Path $CacheFile -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $payload = [ordered]@{
        meta            = [ordered]@{
            schemaVersion   = $script:CacheSchemaVersion
            cachedAt        = (Get-Date -Format 'o')
            sourceTenantId  = $SourceTenantId
            counts          = [ordered]@{
                settingsCatalogDefinitions = $script:SettingsCatalogDefinitions.Count
                settingsCatalogCategories  = $script:SettingsCatalogCategories.Count
                admxDefinitions            = $script:AdmxDefinitions.Count
            }
        }
        settingsCatalog = [ordered]@{
            definitions = @($script:SettingsCatalogDefinitions.Values)
            categories  = @($script:SettingsCatalogCategories.Values)
        }
        adminTemplates  = [ordered]@{
            definitions = @($script:AdmxDefinitions.Values)
        }
    }

    # Atomic write: temp file + Move with overwrite=true
    $tempFile = "$CacheFile.tmp"
    $payload | ConvertTo-Json -Depth 20 -Compress | Set-Content $tempFile -Encoding UTF8
    [System.IO.File]::Move($tempFile, $CacheFile, $true)

    Write-IbaLog -Level Debug -Message "  Definition cache written: $CacheFile"
}

Export-ModuleMember -Function @(
    'Initialize-DefinitionCache',
    'Get-CachedSettingDefinition',
    'Get-CachedSettingCategory',
    'Get-CachedCategoryPath',
    'Get-CachedAdmxDefinition',
    'Add-CachedDefinition',
    'Test-DefinitionCacheReady',
    'Get-DefinitionCacheStats',
    'Reset-DefinitionCache'
)
