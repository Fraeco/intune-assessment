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

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Initialize-DomainMapping {
    <#
    .SYNOPSIS
        Loads DomainMapping.json into the module.
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
    Write-Verbose "Domain mapping loaded from $MappingPath"
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

    $mapping = $script:DomainMapping

    # Priority 1: Category GUID
    if ($mapping.byCategoryGuid -and $Setting.CategoryId) {
        $hit = $mapping.byCategoryGuid.PSObject.Properties |
               Where-Object { $_.Name -eq $Setting.CategoryId } |
               Select-Object -First 1
        if ($hit) { return $hit.Value }
    }

    # Priority 2: Policy name prefix
    if ($mapping.byPolicyNamePrefix -and $Setting.PolicyName) {
        foreach ($prop in $mapping.byPolicyNamePrefix.PSObject.Properties) {
            if ($prop.Name.StartsWith('_')) { continue }   # skip comment keys
            if ($Setting.PolicyName.StartsWith($prop.Name, [StringComparison]::OrdinalIgnoreCase)) {
                return $prop.Value
            }
        }
    }

    # Priority 3: Setting path keyword
    if ($mapping.bySettingPathKeyword -and $Setting.SettingPath) {
        foreach ($prop in $mapping.bySettingPathKeyword.PSObject.Properties) {
            if ($prop.Name.StartsWith('_')) { continue }
            if ($Setting.SettingPath -match [Regex]::Escape($prop.Name)) {
                return $prop.Value
            }
        }
    }

    return 'Unclassified'
}

Export-ModuleMember -Function @(
    'Initialize-DomainMapping',
    'Add-DomainEnrichment'
)
