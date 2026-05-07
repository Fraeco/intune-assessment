# =============================================================================
# RecommendationEngine.psm1 — Evaluates finding rules against comparison
#                               results, customer settings, and inventory data.
#                               (Sprint 7)
#
# Produces aggregated findings for the assessment report:
#   - Executive summary: top 3 risks
#   - Technical findings per domain: name, detail, severity, recommendation
#
# Finding categories:
#   comparisonFindings  — derived from diff results (keyword clusters, domain ratios)
#   structuralFindings  — derived from metadata patterns (naming, duplicates)
#   inventoryFindings   — derived from inventory thresholds (device compliance, etc.)
#
# Config: Config/FindingRules.json
# =============================================================================

Set-StrictMode -Version Latest

# Module-level state
$script:FindingRules = $null
$script:RiskWeights  = $null

# ---------------------------------------------------------------------------
# Severity helpers
# ---------------------------------------------------------------------------

$script:SeverityScoreMap = @{
    'Critical' = 10
    'High'     = 7
    'Medium'   = 4
    'Low'      = 1
}

function Get-SeverityScore {
    param([string]$Severity)
    if ($script:SeverityScoreMap.ContainsKey($Severity)) {
        return $script:SeverityScoreMap[$Severity]
    }
    return 0
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Initialize-FindingRules {
    <#
    .SYNOPSIS
        Loads and validates FindingRules.json. Must be called before Get-Findings.
    .PARAMETER RulesPath
        Path to FindingRules.json.
    .PARAMETER RiskWeights
        Hashtable of domain → weight (from DomainMapping.json riskWeights section).
        Used for severity tiebreaking.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RulesPath,
        [hashtable]$RiskWeights = @{}
    )

    if (-not (Test-Path $RulesPath)) {
        Write-Warning "FindingRules.json not found at '$RulesPath'. Findings engine disabled."
        $script:FindingRules = $null
        return
    }

    $raw = Get-Content -Path $RulesPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $script:FindingRules = @{
        comparisonFindings  = @($raw.comparisonFindings  | Where-Object { $_ })
        structuralFindings  = @($raw.structuralFindings  | Where-Object { $_ })
        inventoryFindings   = @($raw.inventoryFindings   | Where-Object { $_ })
    }

    $script:RiskWeights = $RiskWeights

    $totalRules = $script:FindingRules.comparisonFindings.Count +
                  $script:FindingRules.structuralFindings.Count +
                  $script:FindingRules.inventoryFindings.Count

    Write-Verbose "FindingRules loaded: $totalRules rules ($($script:FindingRules.comparisonFindings.Count) comparison, $($script:FindingRules.structuralFindings.Count) structural, $($script:FindingRules.inventoryFindings.Count) inventory)"
}

function Get-Findings {
    <#
    .SYNOPSIS
        Evaluates all finding rules against the provided data and returns
        triggered findings sorted by severity.
    .PARAMETER ComparisonResults
        List[hashtable] from Compare-TenantSettings.
    .PARAMETER CustomerSettings
        List[hashtable] of raw customer settings (before comparison).
        Used for structural findings like naming convention checks.
    .PARAMETER DeviceInventory
        Optional List[hashtable] of managed devices.
    .PARAMETER EnrollmentData
        Optional hashtable with EnrollmentConfigs and AutopilotDevices keys.
    .PARAMETER AppInventory
        Optional List[hashtable] of mobile apps.
    .PARAMETER SettingsConflicts
        Optional List[hashtable] from Get-SettingsConflictSummary; consumed
        by structural findings such as `duplicate_coverage`.
    .OUTPUTS
        System.Collections.Generic.List[hashtable] — triggered findings, sorted by severity desc.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$ComparisonResults,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$CustomerSettings,

        [System.Collections.Generic.List[hashtable]]$DeviceInventory   = $null,
        [hashtable]$EnrollmentData                                     = $null,
        [System.Collections.Generic.List[hashtable]]$AppInventory      = $null,
        [System.Collections.Generic.List[hashtable]]$SettingsConflicts = $null,
        [hashtable]$Phase4Data                                         = $null,
        [hashtable]$AssignmentAnalysis                                 = $null
    )

    $findings = [System.Collections.Generic.List[hashtable]]::new()

    if (-not $script:FindingRules) {
        Write-Verbose 'FindingRules not loaded — skipping findings evaluation.'
        return , $findings
    }

    # ── Comparison findings ─────────────────────────────────────────────────
    foreach ($rule in $script:FindingRules.comparisonFindings) {
        $finding = Invoke-ComparisonFinding -Rule $rule -Results $ComparisonResults
        if ($finding) { $findings.Add($finding) }
    }

    # ── Structural findings ─────────────────────────────────────────────────
    foreach ($rule in $script:FindingRules.structuralFindings) {
        $finding = Invoke-StructuralFinding `
            -Rule $rule `
            -Results $ComparisonResults `
            -CustomerSettings $CustomerSettings `
            -SettingsConflicts $SettingsConflicts `
            -Phase4Data $Phase4Data `
            -AssignmentAnalysis $AssignmentAnalysis
        if ($finding) { $findings.Add($finding) }
    }

    # ── Inventory findings ──────────────────────────────────────────────────
    foreach ($rule in $script:FindingRules.inventoryFindings) {
        $finding = Invoke-InventoryFinding -Rule $rule `
            -DeviceInventory $DeviceInventory `
            -EnrollmentData  $EnrollmentData `
            -AppInventory    $AppInventory
        if ($finding) { $findings.Add($finding) }
    }

    # Sort: severity desc, then domain weight desc
    if ($findings.Count -gt 0) {
        $findings = [System.Collections.Generic.List[hashtable]]@(
            $findings | Sort-Object @(
                @{ Expression = { $_.SeverityScore }; Descending = $true }
                @{ Expression = {
                    $w = 0
                    if ($script:RiskWeights -and $script:RiskWeights.ContainsKey($_.Domain)) {
                        $w = $script:RiskWeights[$_.Domain]
                    }
                    $w
                }; Descending = $true }
            )
        )
    }

    # Use unary comma to prevent PowerShell pipeline from unwrapping empty List to $null
    return , $findings
}

# ---------------------------------------------------------------------------
# Internal — Comparison finding evaluators
# ---------------------------------------------------------------------------

function Invoke-ComparisonFinding {
    param([psobject]$Rule, [System.Collections.Generic.List[hashtable]]$Results)

    $trigger = $Rule.trigger
    $type    = $trigger.type

    switch ($type) {
        'keyword_cluster' {
            return Invoke-KeywordClusterFinding -Rule $Rule -Results $Results
        }
        'domain_ratio' {
            return Invoke-DomainRatioFinding -Rule $Rule -Results $Results
        }
        default {
            Write-Verbose "Unknown comparison trigger type '$type' for rule '$($Rule.id)'"
            return $null
        }
    }
}

function Invoke-KeywordClusterFinding {
    param([psobject]$Rule, [System.Collections.Generic.List[hashtable]]$Results)

    $trigger  = $Rule.trigger
    $keywords = @($trigger.keywords)

    # Find all comparison rows matching any keyword (case-insensitive)
    $matched = @($Results | Where-Object {
        $settingPath  = if ($_.BaselineSetting)   { $_.BaselineSetting }   else { $_.CustomerSetting }
        $definitionId = if ($_.DefinitionId)       { $_.DefinitionId }     else { '' }
        $searchText   = "$settingPath $definitionId"

        $hit = $false
        foreach ($kw in $keywords) {
            if ($searchText -match [regex]::Escape($kw)) {
                $hit = $true
                break
            }
        }
        $hit
    })

    if ($matched.Count -eq 0) { return $null }

    $resultFilter = @($trigger.resultFilter)
    $threshold    = [double]$trigger.threshold

    $matchingResult = @($matched | Where-Object { $_.Result -in $resultFilter }).Count
    $ratio = $matchingResult / $matched.Count

    if ($ratio -lt $threshold) { return $null }

    return New-Finding -Rule $Rule -Category 'comparison' `
        -AffectedCount $matchingResult -Total $matched.Count -Ratio $ratio
}

function Invoke-DomainRatioFinding {
    param([psobject]$Rule, [System.Collections.Generic.List[hashtable]]$Results)

    $trigger      = $Rule.trigger
    $targetDomain = $trigger.domain
    $resultFilter = @($trigger.resultFilter)
    $threshold    = [double]$trigger.threshold

    $domainResults = @($Results | Where-Object { $_.BaselineDomain -eq $targetDomain })
    if ($domainResults.Count -eq 0) { return $null }

    $matchingResult = @($domainResults | Where-Object { $_.Result -in $resultFilter }).Count
    $ratio = $matchingResult / $domainResults.Count

    if ($ratio -lt $threshold) { return $null }

    return New-Finding -Rule $Rule -Category 'comparison' `
        -AffectedCount $matchingResult -Total $domainResults.Count -Ratio $ratio
}

# ---------------------------------------------------------------------------
# Internal — Structural finding evaluators
# ---------------------------------------------------------------------------

function Invoke-StructuralFinding {
    param(
        [psobject]$Rule,
        [System.Collections.Generic.List[hashtable]]$Results,
        [System.Collections.Generic.List[hashtable]]$CustomerSettings,
        [System.Collections.Generic.List[hashtable]]$SettingsConflicts = $null,
        [hashtable]$Phase4Data = $null,
        [hashtable]$AssignmentAnalysis = $null
    )

    $trigger = $Rule.trigger
    $type    = $trigger.type

    switch ($type) {
        'naming_convention' {
            return Invoke-NamingConventionFinding -Rule $Rule -CustomerSettings $CustomerSettings
        }
        'duplicate_coverage' {
            return Invoke-DuplicateCoverageFinding -Rule $Rule -SettingsConflicts $SettingsConflicts
        }
        'phase4_metric' {
            return Invoke-Phase4MetricFinding -Rule $Rule -Phase4Data $Phase4Data -AssignmentAnalysis $AssignmentAnalysis
        }
        'phase4_collection' {
            return Invoke-Phase4CollectionFinding -Rule $Rule -Phase4Data $Phase4Data -AssignmentAnalysis $AssignmentAnalysis
        }
        default {
            Write-Verbose "Unknown structural trigger type '$type' for rule '$($Rule.id)'"
            return $null
        }
    }
}

function Invoke-Phase4MetricFinding {
    param(
        [psobject]$Rule,
        [hashtable]$Phase4Data = $null,
        [hashtable]$AssignmentAnalysis = $null
    )

    $trigger = $Rule.trigger
    $source = "$($trigger.source)"
    $field = "$($trigger.field)"
    $operator = "$($trigger.operator)"
    $threshold = [double]$trigger.threshold

    # Optional denominator for percent_* operators (e.g. AppsWithFailures / AppCount)
    $denominatorField = ''
    if ($trigger.PSObject.Properties['denominator']) {
        $denominatorField = "$($trigger.denominator)"
    }

    $summary = $null
    switch ($source) {
        'assignmentSummary' {
            if ($AssignmentAnalysis -and $AssignmentAnalysis.ContainsKey('Summary')) {
                $summary = $AssignmentAnalysis.Summary
            }
        }
        'advancedSummary' {
            if ($Phase4Data -and $Phase4Data.ContainsKey('Summary')) {
                $summary = $Phase4Data.Summary
            }
        }
    }

    $metricValue = 0.0
    $denominatorValue = 0.0
    if ($null -ne $summary) {
        if ($summary.PSObject.Properties[$field]) {
            $metricValue = [double]$summary.$field
        }
        if ($denominatorField -and $summary.PSObject.Properties[$denominatorField]) {
            $denominatorValue = [double]$summary.$denominatorField
        }
    }

    $ratio = if ($denominatorValue -gt 0) { $metricValue / $denominatorValue } else { 0.0 }

    $fired = switch ($operator) {
        'count_gte'   { $metricValue -ge $threshold }
        'count_gt'    { $metricValue -gt $threshold }
        'percent_gte' { ($denominatorValue -gt 0) -and ($ratio -ge $threshold) }
        'percent_gt'  { ($denominatorValue -gt 0) -and ($ratio -gt $threshold) }
        default       { $metricValue -ge $threshold }
    }
    if (-not $fired) { return $null }

    if ($operator -in @('percent_gte', 'percent_gt')) {
        return New-Finding -Rule $Rule -Category 'structural' `
            -AffectedCount ([int]$metricValue) -Total ([int]$denominatorValue) -Ratio $ratio
    }

    return New-Finding -Rule $Rule -Category 'structural' `
        -AffectedCount ([int]$metricValue) -Total ([int]$metricValue) -Ratio 1.0
}

function Get-Phase4Collection {
    param(
        [string]$Source,
        [hashtable]$Phase4Data,
        [hashtable]$AssignmentAnalysis
    )

    switch ($Source) {
        'appInstallAggregate' {
            if ($Phase4Data -and $Phase4Data.ContainsKey('AppInstallStatusAggregate')) {
                return @($Phase4Data.AppInstallStatusAggregate)
            }
        }
        'policyStatusOverview' {
            if ($Phase4Data -and $Phase4Data.ContainsKey('PolicyStatusOverview')) {
                return @($Phase4Data.PolicyStatusOverview)
            }
        }
        'deviceAssignmentStatus' {
            if ($Phase4Data -and $Phase4Data.ContainsKey('DeviceAssignmentStatusByConfigurationPolicy')) {
                return @($Phase4Data.DeviceAssignmentStatusByConfigurationPolicy)
            }
        }
        'policyAssignmentSummary' {
            if ($AssignmentAnalysis -and $AssignmentAnalysis.ContainsKey('PolicyAssignmentSummary')) {
                return @($AssignmentAnalysis.PolicyAssignmentSummary)
            }
        }
        'unassignedPolicies' {
            if ($AssignmentAnalysis -and $AssignmentAnalysis.ContainsKey('UnassignedPolicies')) {
                return @($AssignmentAnalysis.UnassignedPolicies)
            }
        }
        'potentiallyDeadPolicies' {
            if ($AssignmentAnalysis -and $AssignmentAnalysis.ContainsKey('PotentiallyDeadPolicies')) {
                return @($AssignmentAnalysis.PotentiallyDeadPolicies)
            }
        }
        default {
            Write-Verbose "Unknown phase4_collection source '$Source'"
        }
    }
    return @()
}

function Get-RowFieldValue {
    param([object]$Row, [string]$Field)

    if ($null -eq $Row -or [string]::IsNullOrEmpty($Field)) { return $null }
    if ($Row -is [hashtable] -or $Row -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($Row.Contains($Field)) { return $Row[$Field] }
        return $null
    }
    if ($Row.PSObject.Properties[$Field]) { return $Row.$Field }
    return $null
}

function Test-Phase4RowCondition {
    param(
        [object]$Row,
        [psobject]$Condition
    )

    if ($null -eq $Condition) { return $false }

    $field    = "$($Condition.field)"
    $operator = "$($Condition.operator)".ToLowerInvariant()
    $expected = if ($Condition.PSObject.Properties['value']) { $Condition.value } else { $null }

    $actual = Get-RowFieldValue -Row $Row -Field $field
    if ($null -eq $actual) { return $false }

    # Numeric comparators
    if ($operator -in @('gte', 'gt', 'lte', 'lt')) {
        $actualNum   = 0.0
        $expectedNum = 0.0
        if (-not [double]::TryParse(("$actual"), [ref]$actualNum))   { return $false }
        if (-not [double]::TryParse(("$expected"), [ref]$expectedNum)) { return $false }
        switch ($operator) {
            'gte' { return $actualNum -ge $expectedNum }
            'gt'  { return $actualNum -gt  $expectedNum }
            'lte' { return $actualNum -le  $expectedNum }
            'lt'  { return $actualNum -lt  $expectedNum }
        }
    }

    # String / boolean comparators
    $actualStr   = "$actual"
    $expectedStr = "$expected"
    switch ($operator) {
        'eq'         { return $actualStr -ieq $expectedStr }
        'ne'         { return $actualStr -ine $expectedStr }
        'contains'   { return $actualStr.IndexOf($expectedStr, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }
        'startswith' { return $actualStr.StartsWith($expectedStr, [System.StringComparison]::OrdinalIgnoreCase) }
        'endswith'   { return $actualStr.EndsWith($expectedStr,   [System.StringComparison]::OrdinalIgnoreCase) }
        default {
            Write-Verbose "Unknown phase4_collection rowCondition operator '$operator'"
            return $false
        }
    }
}

function Invoke-Phase4CollectionFinding {
    <#
    .SYNOPSIS
        Evaluates a phase4_collection trigger by counting rows that satisfy a per-row
        condition in a Phase 4 collection (advanced reporting or assignment analysis).
    #>
    param(
        [psobject]$Rule,
        [hashtable]$Phase4Data = $null,
        [hashtable]$AssignmentAnalysis = $null
    )

    $trigger   = $Rule.trigger
    $source    = "$($trigger.source)"
    $operator  = "$($trigger.operator)"
    $threshold = [double]$trigger.threshold

    $collection = @(Get-Phase4Collection -Source $source `
        -Phase4Data $Phase4Data `
        -AssignmentAnalysis $AssignmentAnalysis)

    if ($collection.Count -eq 0) { return $null }

    $rowCondition = $null
    if ($trigger.PSObject.Properties['rowCondition']) {
        $rowCondition = $trigger.rowCondition
    }

    $matchCount = 0
    if ($null -eq $rowCondition) {
        # No per-row condition — all rows count
        $matchCount = $collection.Count
    } else {
        foreach ($row in $collection) {
            if (Test-Phase4RowCondition -Row $row -Condition $rowCondition) {
                $matchCount++
            }
        }
    }

    $total = $collection.Count
    $ratio = if ($total -gt 0) { $matchCount / $total } else { 0.0 }

    $fired = switch ($operator) {
        'count_gte'   { $matchCount -ge $threshold }
        'count_gt'    { $matchCount -gt  $threshold }
        'percent_gte' { ($total -gt 0) -and ($ratio -ge $threshold) }
        'percent_gt'  { ($total -gt 0) -and ($ratio -gt  $threshold) }
        default       { $matchCount -ge $threshold }
    }

    if (-not $fired) { return $null }

    return New-Finding -Rule $Rule -Category 'structural' `
        -AffectedCount $matchCount -Total $total -Ratio $ratio
}

function Invoke-NamingConventionFinding {
    param([psobject]$Rule, [System.Collections.Generic.List[hashtable]]$CustomerSettings)

    $trigger   = $Rule.trigger
    $patterns  = @($trigger.patterns)
    $threshold = [double]$trigger.threshold

    # Get unique customer policy names
    $policyNames = @($CustomerSettings | ForEach-Object { $_.PolicyName } | Select-Object -Unique)
    if ($policyNames.Count -eq 0) { return $null }

    # Count how many match any of the patterns
    $matchCount = 0
    foreach ($name in $policyNames) {
        foreach ($pattern in $patterns) {
            if ($name -like $pattern) {
                $matchCount++
                break
            }
        }
    }

    $ratio = $matchCount / $policyNames.Count

    # Fire if FEWER than threshold % match (i.e., naming convention is NOT followed)
    if ($ratio -ge $threshold) { return $null }

    return New-Finding -Rule $Rule -Category 'structural' `
        -AffectedCount ($policyNames.Count - $matchCount) -Total $policyNames.Count -Ratio (1 - $ratio)
}

function Invoke-DuplicateCoverageFinding {
    param(
        [psobject]$Rule,
        [System.Collections.Generic.List[hashtable]]$SettingsConflicts = $null
    )

    $trigger   = $Rule.trigger
    $threshold = [int]$trigger.threshold

    if ($null -eq $SettingsConflicts) { return $null }

    # Count unique baseline-covered conflicting settings.
    # SettingsConflicts can be deconcatenated (multiple rows per setting),
    # so we deduplicate by (BaselinePolicyName, DefinitionId).
    $duplicateKeys = @(
        $SettingsConflicts |
            Where-Object { $_.HasBaseline } |
            ForEach-Object { '{0}||{1}' -f $_.BaselinePolicyName, $_.DefinitionId } |
            Select-Object -Unique
    )

    if ($duplicateKeys.Count -lt $threshold) { return $null }

    return New-Finding -Rule $Rule -Category 'structural' `
        -AffectedCount $duplicateKeys.Count -Total $duplicateKeys.Count -Ratio 1.0
}

# ---------------------------------------------------------------------------
# Internal — Inventory finding evaluators
# ---------------------------------------------------------------------------

function Invoke-InventoryFinding {
    param(
        [psobject]$Rule,
        [System.Collections.Generic.List[hashtable]]$DeviceInventory,
        [hashtable]$EnrollmentData,
        [System.Collections.Generic.List[hashtable]]$AppInventory
    )

    $trigger = $Rule.trigger
    $type    = $trigger.type

    switch ($type) {
        'inventory_metric' {
            return Invoke-InventoryMetricFinding -Rule $Rule `
                -DeviceInventory $DeviceInventory `
                -EnrollmentData  $EnrollmentData `
                -AppInventory    $AppInventory
        }
        'inventory_empty' {
            return Invoke-InventoryEmptyFinding -Rule $Rule `
                -DeviceInventory $DeviceInventory `
                -EnrollmentData  $EnrollmentData `
                -AppInventory    $AppInventory
        }
        default {
            Write-Verbose "Unknown inventory trigger type '$type' for rule '$($Rule.id)'"
            return $null
        }
    }
}

function Invoke-InventoryMetricFinding {
    param(
        [psobject]$Rule,
        [System.Collections.Generic.List[hashtable]]$DeviceInventory,
        [hashtable]$EnrollmentData,
        [System.Collections.Generic.List[hashtable]]$AppInventory
    )

    $trigger   = $Rule.trigger
    $source    = $trigger.source
    $field     = $trigger.field
    $value     = $trigger.value
    $operator  = $trigger.operator
    $matchMode = if ($trigger.PSObject.Properties['matchMode']) { $trigger.matchMode } else { 'exact' }
    $threshold = [double]$trigger.threshold

    # Resolve the data collection
    $collection = Get-InventoryCollection -Source $source `
        -DeviceInventory $DeviceInventory `
        -EnrollmentData  $EnrollmentData `
        -AppInventory    $AppInventory

    if (-not $collection -or $collection.Count -eq 0) { return $null }

    # Count items matching field=value using matchMode (case-insensitive)
    $matchCount = @($collection | Where-Object {
        $itemValue = ''
        if ($_ -is [hashtable]) {
            if ($_.ContainsKey($field)) { $itemValue = $_[$field] }
        } elseif ($_.PSObject.Properties[$field]) {
            $itemValue = $_.$field
        }
        switch ($matchMode) {
            'startsWith' { "$itemValue".StartsWith("$value", [System.StringComparison]::OrdinalIgnoreCase) }
            'contains'   { "$itemValue".IndexOf("$value", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }
            default      { "$itemValue" -eq "$value" }
        }
    }).Count

    $total = $collection.Count
    $ratio = $matchCount / $total

    # Evaluate operator
    $fired = switch ($operator) {
        'percent_gte' { $ratio -ge $threshold }
        'percent_gt'  { $ratio -gt $threshold }
        'count_gte'   { $matchCount -ge $threshold }
        default       { $ratio -ge $threshold }
    }

    if (-not $fired) { return $null }

    return New-Finding -Rule $Rule -Category 'inventory' `
        -AffectedCount $matchCount -Total $total -Ratio $ratio
}

function Invoke-InventoryEmptyFinding {
    param(
        [psobject]$Rule,
        [System.Collections.Generic.List[hashtable]]$DeviceInventory,
        [hashtable]$EnrollmentData,
        [System.Collections.Generic.List[hashtable]]$AppInventory
    )

    $trigger = $Rule.trigger
    $source  = $trigger.source

    $collection = Get-InventoryCollection -Source $source `
        -DeviceInventory $DeviceInventory `
        -EnrollmentData  $EnrollmentData `
        -AppInventory    $AppInventory

    # Fire if collection is null or empty
    if ($collection -and $collection.Count -gt 0) { return $null }

    return New-Finding -Rule $Rule -Category 'inventory' `
        -AffectedCount 0 -Total 0 -Ratio 0
}

function Get-InventoryCollection {
    param(
        [string]$Source,
        [System.Collections.Generic.List[hashtable]]$DeviceInventory,
        [hashtable]$EnrollmentData,
        [System.Collections.Generic.List[hashtable]]$AppInventory
    )

    switch ($Source) {
        'devices'          { return $DeviceInventory }
        'apps'             { return $AppInventory }
        'autopilotDevices' {
            if ($EnrollmentData -and $EnrollmentData.ContainsKey('AutopilotDevices')) {
                return $EnrollmentData['AutopilotDevices']
            }
            return $null
        }
        'enrollmentConfigs' {
            if ($EnrollmentData -and $EnrollmentData.ContainsKey('EnrollmentConfigs')) {
                return $EnrollmentData['EnrollmentConfigs']
            }
            return $null
        }
        default {
            Write-Verbose "Unknown inventory source '$Source'"
            return $null
        }
    }
}

# ---------------------------------------------------------------------------
# Internal — Finding construction
# ---------------------------------------------------------------------------

function New-Finding {
    param(
        [psobject]$Rule,
        [string]$Category,
        [int]$AffectedCount,
        [int]$Total,
        [double]$Ratio
    )

    $percent = [Math]::Round($Ratio * 100)

    $detail         = Format-FindingText -Template $Rule.detail -Count $AffectedCount -Total $Total -Percent $percent
    $recommendation = Format-FindingText -Template $Rule.recommendation -Count $AffectedCount -Total $Total -Percent $percent

    return [ordered]@{
        FindingId      = $Rule.id
        FindingName    = $Rule.name
        Domain         = $Rule.domain
        Severity       = $Rule.severity
        SeverityScore  = Get-SeverityScore $Rule.severity
        Detail         = $detail
        Recommendation = $recommendation
        AffectedCount  = $AffectedCount
        Category       = $Category
    }
}

function Format-FindingText {
    param([string]$Template, [int]$Count, [int]$Total, [int]$Percent)

    return $Template `
        -replace '\{count\}',   "$Count" `
        -replace '\{total\}',   "$Total" `
        -replace '\{percent\}', "$Percent"
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'Initialize-FindingRules',
    'Get-Findings'
)
