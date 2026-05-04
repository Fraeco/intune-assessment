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

    # Index customer settings by DefinitionId for O(1) lookup (case-insensitive)
    $customerIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[hashtable]]]::new([System.StringComparer]::OrdinalIgnoreCase)
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
    $extraIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[hashtable]]]::new([System.StringComparer]::OrdinalIgnoreCase)
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

function Get-SettingsConflictSummary {
    <#
    .SYNOPSIS
        Builds a standalone multi-policy settings conflict summary.
    .DESCRIPTION
        Detects settings configured by 2+ customer policies with diverging
        normalized values. Emits one deconcatenated row per contributing
        customer policy (not comma-joined lists). Baseline scope is still
        (BaselinePolicyName, DefinitionId) for in-baseline groups; Extra groups
        are per DefinitionId only.

        Filter rules:
        - HasBaseline = true:  >= 2 unique customer policies, at least one
                               customer policy differs from baseline, and
                               distinct normalized customer values >= 2.
        - HasBaseline = false: >= 2 unique customer policies, and distinct
                               normalized customer values >= 2.

        Equality uses Normalize-SettingValue so cosmetic differences
        (boolean synonyms, JSON key/array order, comma-list order) do not
        appear as conflicts.
    .PARAMETER BaselineSettings
        List[hashtable] of baseline settings (post-enrichment).
    .PARAMETER CustomerSettings
        List[hashtable] of customer settings (post-enrichment).
    .OUTPUTS
        System.Collections.Generic.List[hashtable] — deconcatenated conflict rows.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$BaselineSettings,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$CustomerSettings
    )

    $rows = [System.Collections.Generic.List[hashtable]]::new()

    # Index customer settings by DefinitionId (O(1) lookup, case-insensitive)
    $customerIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[hashtable]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $CustomerSettings) {
        if ([string]::IsNullOrWhiteSpace($s.DefinitionId)) { continue }
        if (-not $customerIndex.ContainsKey($s.DefinitionId)) {
            $customerIndex[$s.DefinitionId] = [System.Collections.Generic.List[hashtable]]::new()
        }
        $customerIndex[$s.DefinitionId].Add($s)
    }

    # Group baseline settings by (PolicyName, DefinitionId).
    # Same DefinitionId can be pinned by multiple baseline policies; each
    # baseline-policy scope produces its own summary row (Robin parity).
    $baselineGroups = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[hashtable]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $baselineIds    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($b in $BaselineSettings) {
        if ([string]::IsNullOrWhiteSpace($b.DefinitionId)) { continue }
        [void]$baselineIds.Add($b.DefinitionId)
        $key = '{0}||{1}' -f $b.PolicyName, $b.DefinitionId
        if (-not $baselineGroups.ContainsKey($key)) {
            $baselineGroups[$key] = [System.Collections.Generic.List[hashtable]]::new()
        }
        $baselineGroups[$key].Add($b)
    }

    # ── Baseline-covered conflicts (HasBaseline = true) ──────────────────────
    foreach ($kvp in $baselineGroups.GetEnumerator()) {
        $baselineGroup = $kvp.Value
        $baselineFirst = $baselineGroup[0]
        $defId         = $baselineFirst.DefinitionId

        if (-not $customerIndex.ContainsKey($defId)) { continue }
        $customerMatches = $customerIndex[$defId]

        $uniquePolicyNames = @(
            $customerMatches |
                ForEach-Object { $_.PolicyName } |
                Where-Object   { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object  -Unique |
                Sort-Object
        )
        if ($uniquePolicyNames.Count -lt 2) { continue }

        $normalizedValues = @(
            $customerMatches |
                ForEach-Object { Normalize-SettingValue -Value $_.Value } |
                Select-Object  -Unique |
                Sort-Object
        )
        if ($normalizedValues.Count -lt 2) { continue }

        # Build deconcatenated rows while preserving summary metadata.
        $configured = 0
        $conflict   = 0
        foreach ($cm in $customerMatches) {
            if (Compare-SettingValue $cm.Value $baselineFirst.Value) {
                $configured++
            } else {
                $conflict++
            }
        }
        if ($conflict -lt 1) { continue }

        $domain = if ([string]::IsNullOrWhiteSpace($baselineFirst.Domain)) {
            $customerMatches[0].Domain
        } else {
            $baselineFirst.Domain
        }

        foreach ($cm in $customerMatches) {
            $matchStatus = if (Compare-SettingValue $cm.Value $baselineFirst.Value) { 'Configured' } else { 'Conflict' }
            $rows.Add([ordered]@{
                BaselinePolicyName       = $baselineFirst.PolicyName
                BaselineSetting          = $baselineFirst.SettingPath
                BaselineValue            = $baselineFirst.Value
                PolicyName               = $cm.PolicyName
                PolicyValue              = $cm.Value
                PolicyValueNormalized    = Normalize-SettingValue -Value $cm.Value
                MatchStatus              = $matchStatus
                DefinitionId             = $defId
                Domain                   = $domain
                CategoryId               = $baselineFirst.CategoryId
                PolicyCount              = $uniquePolicyNames.Count
                DistinctValueCount       = $normalizedValues.Count
                HasBaseline              = $true
            })
        }
    }

    # ── Extra (non-baseline) multi-policy divergences (HasBaseline = false) ─
    foreach ($kvp in $customerIndex.GetEnumerator()) {
        $defId = $kvp.Key
        if ($baselineIds.Contains($defId)) { continue }

        $customerMatches = $kvp.Value

        $uniquePolicyNames = @(
            $customerMatches |
                ForEach-Object { $_.PolicyName } |
                Where-Object   { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object  -Unique |
                Sort-Object
        )
        if ($uniquePolicyNames.Count -lt 2) { continue }

        $normalizedValues = @(
            $customerMatches |
                ForEach-Object { Normalize-SettingValue -Value $_.Value } |
                Select-Object  -Unique |
                Sort-Object
        )
        if ($normalizedValues.Count -lt 2) { continue }

        $first = $customerMatches[0]
        foreach ($cm in $customerMatches) {
            $rows.Add([ordered]@{
                BaselinePolicyName       = ''
                BaselineSetting          = ''
                BaselineValue            = ''
                PolicyName               = $cm.PolicyName
                PolicyValue              = $cm.Value
                PolicyValueNormalized    = Normalize-SettingValue -Value $cm.Value
                MatchStatus              = 'Conflict'
                DefinitionId             = $defId
                Domain                   = $first.Domain
                CategoryId               = $first.CategoryId
                PolicyCount              = $uniquePolicyNames.Count
                DistinctValueCount       = $normalizedValues.Count
                HasBaseline              = $false
            })
        }
    }

    # Sort: HasBaseline desc, Domain, BaselinePolicyName, BaselineSetting, PolicyName.
    $sorted = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($r in ($rows | Sort-Object `
            @{ Expression = { $_.HasBaseline };        Descending = $true  }, `
            @{ Expression = { $_.Domain };             Descending = $false }, `
            @{ Expression = { $_.BaselinePolicyName }; Descending = $false }, `
            @{ Expression = { $_.BaselineSetting };    Descending = $false }, `
            @{ Expression = { $_.PolicyName };         Descending = $false })) {
        $sorted.Add($r)
    }

    Write-Verbose ("ConflictSummary: {0} rows ({1} with baseline, {2} without)" -f `
        $sorted.Count, `
        @($sorted | Where-Object { $_.HasBaseline }).Count, `
        @($sorted | Where-Object { -not $_.HasBaseline }).Count)

    return $sorted
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

    # Multi-policy strategy: OPTIMISTIC — Compliant if ANY customer policy matches
    # the baseline value for this setting. Rationale: when a setting is configured
    # in multiple policies Intune applies the most-restrictive effective value, but
    # we cannot reliably determine precedence via API alone. Flagging the setting
    # Compliant when at least one policy matches avoids false-positive Conflicts for
    # intentional policy layering (e.g. a broad base policy + a tighter scoped
    # policy). Reviewers should inspect the full PolicyValue column for all values.
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
        Produces a canonical string for value comparison.

        Normalization steps applied in order:
        1. Boolean synonyms  — true/1/enabled/yes/allow/on → 'true';
                               false/0/disabled/no/block/off → 'false'
        2. JSON object       — parsed and re-serialized with keys sorted
                               alphabetically, so key order does not affect
                               equality (e.g. {"b":1,"a":2} == {"a":2,"b":1})
        3. JSON array        — elements sorted so array order does not affect
                               equality (e.g. ["b","a"] == ["a","b"])
        4. Comma-separated   — items split on ', ' and sorted; handles
                               SimpleSettingCollectionInstance / ChoiceSettingCollectionInstance
                               values produced by PolicyReader (e.g. "val2, val1" == "val1, val2")
        5. Fallback          — ToLower() only
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    $v = $Value.Trim()

    # ── Step 1: Boolean synonyms ──────────────────────────────────────────────
    $vLower      = $v.ToLower()
    $trueValues  = @('true',  '1', 'enabled',  'yes', 'allow', 'on')
    $falseValues = @('false', '0', 'disabled', 'no',  'block', 'off')

    if ($vLower -in $trueValues)  { return 'true'  }
    if ($vLower -in $falseValues) { return 'false' }

    # ── Step 2: JSON object — key-order-insensitive ───────────────────────────
    if ($v.StartsWith('{') -and $v.EndsWith('}')) {
        try {
            $obj    = $v | ConvertFrom-Json -ErrorAction Stop
            $sorted = [ordered]@{}
            $obj.PSObject.Properties | Sort-Object Name | ForEach-Object { $sorted[$_.Name] = $_.Value }
            return ($sorted | ConvertTo-Json -Compress -Depth 10).ToLower()
        }
        catch { <# not valid JSON — fall through #> }
    }

    # ── Step 3: JSON array — element-order-insensitive ────────────────────────
    if ($v.StartsWith('[') -and $v.EndsWith(']')) {
        try {
            $arr    = @($v | ConvertFrom-Json -ErrorAction Stop)
            $sorted = @($arr | Sort-Object { "$_".ToLower() })
            return ($sorted | ConvertTo-Json -Compress -Depth 10).ToLower()
        }
        catch { <# not valid JSON — fall through #> }
    }

    # ── Step 4: Comma-separated collection — item-order-insensitive ──────────
    # PolicyReader joins SimpleSettingCollectionInstance / ChoiceSettingCollectionInstance
    # values with ', ' — sort items so ["A","B"] and ["B","A"] compare equal.
    if ($v -match ',') {
        $items = $v -split '\s*,\s*' | Where-Object { $_ -ne '' } | Sort-Object { $_.ToLower() }
        return ($items -join ',').ToLower()
    }

    # ── Step 5: Fallback ──────────────────────────────────────────────────────
    return $vLower
}

Export-ModuleMember -Function @(
    'Compare-TenantSettings',
    'Get-SettingsConflictSummary'
)
