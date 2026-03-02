# =============================================================================
# Comparison.psm1 — Diff engine: Baseline vs Customer settings
#
# Result codes:
#   Compliant  — customer has the setting and value matches the baseline
#   Conflict   — customer has the setting but value differs
#   Missing    — baseline requires the setting; customer has none
#   Extra      — customer has the setting; it is not in the baseline
#
# Multi-policy: if a customer has the same setting in N policies, all N
# policy names and values are joined with ", " in the output row.
# =============================================================================

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Compare-TenantSettings {
    <#
    .SYNOPSIS
        Compares normalised baseline settings against customer settings and
        returns one output row per baseline setting (plus Extra rows).
    .PARAMETER BaselineSettings
        List[hashtable] as produced by Get-SettingsCatalogPolicies for the
        baseline tenant, enriched with Domain.
    .PARAMETER CustomerSettings
        List[hashtable] as produced by Get-SettingsCatalogPolicies for the
        customer tenant, enriched with Domain.
    .OUTPUTS
        System.Collections.Generic.List[hashtable] — comparison result rows
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$BaselineSettings,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$CustomerSettings
    )

    # Index customer settings by DefinitionId for O(1) lookup
    $customerIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[hashtable]]]::new()
    foreach ($s in $CustomerSettings) {
        $id = $s.DefinitionId
        if (-not $customerIndex.ContainsKey($id)) {
            $customerIndex[$id] = [System.Collections.Generic.List[hashtable]]::new()
        }
        $customerIndex[$id].Add($s)
    }

    # Track which definition IDs are covered by the baseline (for Extra detection)
    $baselineIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $results = [System.Collections.Generic.List[hashtable]]::new()

    # ── Process each baseline setting ────────────────────────────────────────
    foreach ($baseline in $BaselineSettings) {
        $defId = $baseline.DefinitionId
        [void]$baselineIds.Add($defId)

        # Assign inside if/else — avoids PowerShell pipeline-enumerating the empty
        # List returned from the else branch, which would collapse it to $null.
        if ($customerIndex.ContainsKey($defId)) {
            $customerMatches = $customerIndex[$defId]
        } else {
            $customerMatches = [System.Collections.Generic.List[hashtable]]::new()
        }

        $results.Add((Build-ComparisonRow -BaselineSetting $baseline -CustomerMatches $customerMatches))
    }

    # ── Extra settings (customer-only) ───────────────────────────────────────
    # Deduplicate: if the same DefinitionId appears in multiple customer policies
    # it should produce only ONE Extra row (all policies comma-separated).
    $extraIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[hashtable]]]::new()
    foreach ($s in $CustomerSettings) {
        if (-not $baselineIds.Contains($s.DefinitionId)) {
            if (-not $extraIndex.ContainsKey($s.DefinitionId)) {
                $extraIndex[$s.DefinitionId] = [System.Collections.Generic.List[hashtable]]::new()
            }
            $extraIndex[$s.DefinitionId].Add($s)
        }
    }

    foreach ($kvp in $extraIndex.GetEnumerator()) {
        $group        = $kvp.Value
        $policyNames  = ($group | ForEach-Object { $_.PolicyName }  | Select-Object -Unique) -join ', '
        $policyValues = ($group | ForEach-Object { $_.Value })                               -join ', '
        $templates    = ($group | ForEach-Object { $_.PolicyTemplate } | Select-Object -Unique | Sort-Object) -join ', '
        $first        = $group[0]

        $results.Add([ordered]@{
            BaselinePolicyName     = ''
            BaselinePolicyTemplate = ''
            BaselineSetting        = ''
            BaselineCategory       = ''
            BaselineDomain         = ''
            BaselineValue          = ''
            Result                 = 'Extra'
            PolicyName             = $policyNames
            CustomerSetting        = $first.SettingPath
            PolicyTemplate         = $templates
            PolicyValue            = $policyValues
            ComparisonCategory     = $first.CategoryId
            ComparisonDomain       = $first.Domain
            Description            = $first.Description
            DefinitionId           = $first.DefinitionId   # internal, not in CSV
        })
    }

    # @() ensures Where-Object always produces an array (never $null), so .Count is safe.
    $compliant = @($results | Where-Object { $_.Result -eq 'Compliant' }).Count
    $conflict  = @($results | Where-Object { $_.Result -eq 'Conflict'  }).Count
    $missing   = @($results | Where-Object { $_.Result -eq 'Missing'   }).Count
    $extra     = @($results | Where-Object { $_.Result -eq 'Extra'     }).Count

    Write-Verbose ("Comparison: {0} Compliant, {1} Conflict, {2} Missing, {3} Extra" -f $compliant, $conflict, $missing, $extra)

    return $results
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function Build-ComparisonRow {
    param(
        [hashtable]$BaselineSetting,
        [System.Collections.Generic.List[hashtable]]$CustomerMatches
    )

    if ($CustomerMatches.Count -eq 0) {
        return [ordered]@{
            BaselinePolicyName     = $BaselineSetting.PolicyName
            BaselinePolicyTemplate = $BaselineSetting.PolicyTemplate
            BaselineSetting        = $BaselineSetting.SettingPath
            BaselineCategory       = $BaselineSetting.CategoryId
            BaselineDomain         = $BaselineSetting.Domain
            BaselineValue          = $BaselineSetting.Value
            Result                 = 'Missing'
            PolicyName             = ''
            CustomerSetting        = ''
            PolicyTemplate         = ''
            PolicyValue            = ''
            ComparisonCategory     = ''
            ComparisonDomain       = ''
            Description            = $BaselineSetting.Description
            DefinitionId           = $BaselineSetting.DefinitionId
        }
    }

    $policyNames  = ($CustomerMatches | ForEach-Object { $_.PolicyName })                              -join ', '
    $policyValues = ($CustomerMatches | ForEach-Object { $_.Value })                                   -join ', '
    $templates    = ($CustomerMatches | ForEach-Object { $_.PolicyTemplate } | Select-Object -Unique | Sort-Object) -join ', '
    # We already know Count > 0 here; index directly to avoid null-property issues.
    $compCatId    = $CustomerMatches[0].CategoryId
    $compDomain   = $CustomerMatches[0].Domain

    # Compliant if ANY customer match equals the baseline value
    $anyMatch = $CustomerMatches | Where-Object { Compare-SettingValue $_.Value $BaselineSetting.Value }
    $result   = if ($anyMatch) { 'Compliant' } else { 'Conflict' }

    return [ordered]@{
        BaselinePolicyName     = $BaselineSetting.PolicyName
        BaselinePolicyTemplate = $BaselineSetting.PolicyTemplate
        BaselineSetting        = $BaselineSetting.SettingPath
        BaselineCategory       = $BaselineSetting.CategoryId
        BaselineDomain         = $BaselineSetting.Domain
        BaselineValue          = $BaselineSetting.Value
        Result                 = $result
        PolicyName             = $policyNames
        CustomerSetting        = $CustomerMatches[0].SettingPath
        PolicyTemplate         = $templates
        PolicyValue            = $policyValues
        ComparisonCategory     = $compCatId
        ComparisonDomain       = $compDomain
        Description            = $BaselineSetting.Description
        DefinitionId           = $BaselineSetting.DefinitionId
    }
}

function Compare-SettingValue {
    <#
    .SYNOPSIS
        Returns $true if two setting value strings are semantically equal.
        Case-insensitive; normalises common boolean synonyms.
    #>
    param(
        [string]$CustomerValue,
        [string]$BaselineValue
    )

    $n1 = Normalize-SettingValue $CustomerValue
    $n2 = Normalize-SettingValue $BaselineValue

    return $n1 -eq $n2
}

function Normalize-SettingValue {
    <#
    .SYNOPSIS
        Produces a canonical lowercase string for value comparison.
        Common boolean synonyms are all mapped to 'true' or 'false'.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    $v = $Value.Trim().ToLower()

    $trueValues  = @('true',  '1', 'enabled',  'yes', 'allow', 'on')
    $falseValues = @('false', '0', 'disabled', 'no',  'block', 'off')

    if ($v -in $trueValues)  { return 'true'  }
    if ($v -in $falseValues) { return 'false' }

    return $v
}

Export-ModuleMember -Function @(
    'Compare-TenantSettings'
)
