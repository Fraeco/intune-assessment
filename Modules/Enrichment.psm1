# =============================================================================
# Enrichment.psm1 — Maps settings to the 5 eVri assessment domains
#
# Lookup priority (first match wins):
#   1. byCategoryGuid   — most precise; keyed on the leaf categoryId GUID
#   2. byPolicyNamePrefix — matches SBZ naming convention prefixes
#   3. bySettingPathKeyword — keyword scan of the human-readable setting path
#   4. Fallback: "Unclassified"
#
# After running for the first time, add newly-discovered category GUIDs to
# DomainMapping.json → byCategoryGuid for the most accurate mapping.
# =============================================================================

Set-StrictMode -Version Latest

$script:DomainMapping = $null
# Pre-processed lookup structures for O(1) / sorted matching
$script:CategoryGuidTable    = $null   # Hashtable for O(1) GUID lookup
$script:PrefixesSorted       = $null   # Array of [PSCustomObject]@{Prefix;Domain} sorted by length desc
$script:KeywordPairs          = $null   # Array of [PSCustomObject]@{Keyword;Domain} for path matching
$script:ValidDomains          = $null   # HashSet for domain validation

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Initialize-DomainMapping {
    <#
    .SYNOPSIS
        Loads DomainMapping.json into the module and pre-processes lookup
        structures for efficient matching.
    .PARAMETER MappingPath
        Full path to DomainMapping.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MappingPath
    )

    if (-not (Test-Path $MappingPath)) {
        throw "Domain mapping file not found: $MappingPath"
    }

    $script:DomainMapping = Get-Content $MappingPath -Raw | ConvertFrom-Json
    $mapping = $script:DomainMapping

    # Build O(1) Hashtable for byCategoryGuid (replaces linear PSObject.Properties scan)
    $script:CategoryGuidTable = @{}
    if ($mapping.byCategoryGuid) {
        foreach ($prop in $mapping.byCategoryGuid.PSObject.Properties) {
            if (-not $prop.Name.StartsWith('_')) {
                $script:CategoryGuidTable[$prop.Name] = $prop.Value
            }
        }
    }

    # Build sorted prefix list (longest-first) for correct greedy matching
    $script:PrefixesSorted = @()
    if ($mapping.byPolicyNamePrefix) {
        $script:PrefixesSorted = @(
            $mapping.byPolicyNamePrefix.PSObject.Properties |
                Where-Object { -not $_.Name.StartsWith('_') } |
                ForEach-Object { [PSCustomObject]@{ Prefix = $_.Name; Domain = $_.Value } } |
                Sort-Object { $_.Prefix.Length } -Descending
        )
    }

    # Build keyword pairs for path matching
    $script:KeywordPairs = @()
    if ($mapping.bySettingPathKeyword) {
        $script:KeywordPairs = @(
            $mapping.bySettingPathKeyword.PSObject.Properties |
                Where-Object { -not $_.Name.StartsWith('_') } |
                ForEach-Object { [PSCustomObject]@{ Keyword = $_.Name; Domain = $_.Value } }
        )
    }

    # Build valid domains set for validation
    $script:ValidDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($mapping.validDomains) {
        foreach ($d in $mapping.validDomains) {
            [void]$script:ValidDomains.Add($d)
        }
    }

    Write-Verbose "Domain mapping loaded from $MappingPath ($($script:CategoryGuidTable.Count) GUIDs, $($script:PrefixesSorted.Count) prefixes, $($script:KeywordPairs.Count) keywords)"
}

function Add-DomainEnrichment {
    <#
    .SYNOPSIS
        Resolves and writes the Domain field on each setting hashtable in-place.
    .PARAMETER Settings
        List[hashtable] — the settings list returned by Get-SettingsCatalogPolicies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$Settings
    )

    if ($null -eq $script:DomainMapping) {
        throw "Domain mapping not initialised. Call Initialize-DomainMapping first."
    }

    foreach ($s in $Settings) {
        $s['Domain'] = Resolve-Domain -Setting $s
    }
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function Resolve-Domain {
    param([hashtable]$Setting)

    $domain = $null

    # Priority 1: Category GUID — O(1) Hashtable lookup
    if ($script:CategoryGuidTable -and $Setting.CategoryId) {
        if ($script:CategoryGuidTable.ContainsKey($Setting.CategoryId)) {
            $domain = $script:CategoryGuidTable[$Setting.CategoryId]
        }
    }

    # Priority 2: Policy name prefix — sorted longest-first for correct greedy match
    if (-not $domain -and $script:PrefixesSorted -and $Setting.PolicyName) {
        foreach ($entry in $script:PrefixesSorted) {
            if ($Setting.PolicyName.StartsWith($entry.Prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $domain = $entry.Domain
                break
            }
        }
    }

    # Priority 3: Setting path keyword
    if (-not $domain -and $script:KeywordPairs -and $Setting.SettingPath) {
        foreach ($entry in $script:KeywordPairs) {
            if ($Setting.SettingPath -match [Regex]::Escape($entry.Keyword)) {
                $domain = $entry.Domain
                break
            }
        }
    }

    if (-not $domain) {
        return 'Unclassified'
    }

    # Validate domain against known valid domains
    if ($script:ValidDomains -and $script:ValidDomains.Count -gt 0 -and
        -not $script:ValidDomains.Contains($domain)) {
        Write-Warning "Domain mapping returned invalid domain '$domain' for setting '$($Setting.SettingPath)'. Falling back to 'Unclassified'."
        return 'Unclassified'
    }

    return $domain
}

Export-ModuleMember -Function @(
    'Initialize-DomainMapping',
    'Add-DomainEnrichment'
)
