Set-StrictMode -Version Latest

function ConvertTo-HtmlSafe {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-HtmlFileName {
    param([string]$CustomerName, [string]$BaselineLevel)
    $timestamp = Get-Date -Format 'yyyyMMdd'
    $safeName  = $CustomerName -replace '[^\w\-]', '_'
    return "${safeName}_${timestamp}_${BaselineLevel}_AssessmentReport.html"
}

function ConvertTo-CellRaw {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    return [string]$Value
}

function Get-CellDisplayValue {
    param(
        [string]$TableId,
        [string]$ColumnKey,
        [string]$RawValue
    )

    if ($TableId -eq 'appInstallStatusAggregateSummary' -and $ColumnKey -eq 'FailedDevicePercentage') {
        $num = 0.0
        try { $num = [double]$RawValue } catch { $num = 0.0 }
        return ('{0:N2}%' -f $num)
    }

    return $RawValue
}

function Add-ResultTableRows {
    param(
        [System.Text.StringBuilder]$Builder,
        [object[]]$Rows
    )
    foreach ($row in @($Rows)) {
        [void]$Builder.AppendLine('<tr>')
        [void]$Builder.AppendLine("  <td>$(ConvertTo-HtmlSafe $row.Result)</td>")
        [void]$Builder.AppendLine("  <td>$(ConvertTo-HtmlSafe $row.BaselineDomain)</td>")
        [void]$Builder.AppendLine("  <td>$(ConvertTo-HtmlSafe $row.BaselinePolicyName)</td>")
        [void]$Builder.AppendLine("  <td>$(ConvertTo-HtmlSafe $row.BaselineSetting)</td>")
        [void]$Builder.AppendLine("  <td>$(ConvertTo-HtmlSafe $row.PolicyName)</td>")
        [void]$Builder.AppendLine("  <td>$(ConvertTo-HtmlSafe $row.PolicyValue)</td>")
        [void]$Builder.AppendLine('</tr>')
    }
}

function Get-AdvancedRowCssClass {
    param(
        [string]$TableId,
        [hashtable]$Row
    )

    switch ($TableId) {
        'allPolicyStatusOverview' {
            if ($Row.ContainsKey('NotDeployed') -and [bool]$Row['NotDeployed']) { return 'row-warn' }
            if ($Row.ContainsKey('Total') -and [int]$Row['Total'] -gt 0 -and
                $Row.ContainsKey('Succeeded') -and [int]$Row['Succeeded'] -eq [int]$Row['Total']) { return 'row-success' }
        }
        'allPolicyAssignmentSummary' {
            $isUnassigned = $Row.ContainsKey('IsUnassigned') -and [bool]$Row['IsUnassigned']
            $isDead = $Row.ContainsKey('IsPotentiallyDead') -and [bool]$Row['IsPotentiallyDead']
            if ($isUnassigned -or $isDead) { return 'row-error' }
            if ($Row.ContainsKey('HasIncludeTarget') -and [bool]$Row['HasIncludeTarget']) { return 'row-success' }
        }
        'allDeviceAssignmentStatusByConfigurationPolicy' {
            $status = if ($Row.ContainsKey('ReportStatus')) { "$($Row['ReportStatus'])" } else { '' }
            switch ($status.ToLowerInvariant()) {
                'succeeded' { return 'row-success' }
                'failed' { return 'row-error' }
                'error' { return 'row-error' }
                'pending' { return 'row-warn' }
                'inprogress' { return 'row-warn' }
                'conflict' { return 'row-warn' }
            }
        }
        'appInstallStatusAggregateSummary' {
            if ($Row.ContainsKey('FailedDeviceCount') -and [int]$Row['FailedDeviceCount'] -gt 0) { return 'row-warn' }
            if ($Row.ContainsKey('InstalledDeviceCount') -and [int]$Row['InstalledDeviceCount'] -gt 0) { return 'row-success' }
        }
    }
    return ''
}

function Add-AdvancedFilterControls {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$TableId,
        [object[]]$Rows,
        [hashtable[]]$Columns,
        [string[]]$FilterColumnKeys
    )

    [void]$Builder.AppendLine("    <div class='table-filter-bar' data-table-id='$(ConvertTo-HtmlSafe $TableId)'>")
    foreach ($key in $FilterColumnKeys) {
        $col = $Columns | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if ($null -eq $col) { continue }
        $label = $col.label

        $values = @(
            $Rows |
                ForEach-Object { if ($_.ContainsKey($key)) { ConvertTo-CellRaw -Value $_[$key] } else { '' } } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique |
                Sort-Object
        )

        [void]$Builder.AppendLine("      <label>$(ConvertTo-HtmlSafe $label)")
        [void]$Builder.AppendLine("        <select class='table-filter' data-table-id='$(ConvertTo-HtmlSafe $TableId)' data-key='$(ConvertTo-HtmlSafe $key)'>")
        [void]$Builder.AppendLine("          <option value=''>All</option>")
        foreach ($v in $values) {
            [void]$Builder.AppendLine("          <option value='$(ConvertTo-HtmlSafe $v)'>$(ConvertTo-HtmlSafe $v)</option>")
        }
        [void]$Builder.AppendLine('        </select>')
        [void]$Builder.AppendLine('      </label>')
    }
    [void]$Builder.AppendLine('    </div>')
}

function Add-AdvancedTableSection {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$TableId,
        [string]$Title,
        [object[]]$Rows,
        [hashtable[]]$Columns,
        [string[]]$FilterColumnKeys,
        [int]$RowCap = 500
    )

    $allRows = @($Rows)
    $renderRows = @($allRows | Select-Object -First $RowCap)

    [void]$Builder.AppendLine('  <details>')
    [void]$Builder.AppendLine("    <summary>$(ConvertTo-HtmlSafe $Title) ($(ConvertTo-HtmlSafe $allRows.Count) rows)</summary>")

    if ($allRows.Count -eq 0) {
        [void]$Builder.AppendLine('    <p>No data available.</p>')
        [void]$Builder.AppendLine('  </details>')
        return
    }

    Add-AdvancedFilterControls -Builder $Builder -TableId $TableId -Rows $renderRows -Columns $Columns -FilterColumnKeys $FilterColumnKeys

    [void]$Builder.AppendLine("    <div class='interactive-table-wrapper' data-table-id='$(ConvertTo-HtmlSafe $TableId)' data-sort-key='' data-sort-dir='asc'>")
    [void]$Builder.AppendLine("      <table id='$(ConvertTo-HtmlSafe $TableId)'>")
    [void]$Builder.AppendLine('        <thead><tr>')
    foreach ($col in $Columns) {
        [void]$Builder.AppendLine("          <th class='sortable' data-table-id='$(ConvertTo-HtmlSafe $TableId)' data-key='$(ConvertTo-HtmlSafe $col.key)' data-type='$(ConvertTo-HtmlSafe $col.type)'>$(ConvertTo-HtmlSafe $col.label) <span class='sort-indicator'></span></th>")
    }
    [void]$Builder.AppendLine('        </tr></thead>')
    [void]$Builder.AppendLine('        <tbody>')

    foreach ($row in $renderRows) {
        $rowCss = Get-AdvancedRowCssClass -TableId $TableId -Row $row
        $rowClassAttr = if ([string]::IsNullOrWhiteSpace($rowCss)) { '' } else { " class='$rowCss'" }
        [void]$Builder.AppendLine("          <tr$rowClassAttr>")
        foreach ($col in $Columns) {
            $raw = if ($row.ContainsKey($col.key)) { ConvertTo-CellRaw -Value $row[$col.key] } else { '' }
            $display = Get-CellDisplayValue -TableId $TableId -ColumnKey $col.key -RawValue $raw
            [void]$Builder.AppendLine("            <td data-key='$(ConvertTo-HtmlSafe $col.key)' data-raw='$(ConvertTo-HtmlSafe $raw)'>$(ConvertTo-HtmlSafe $display)</td>")
        }
        [void]$Builder.AppendLine('          </tr>')
    }
    [void]$Builder.AppendLine('        </tbody>')
    [void]$Builder.AppendLine('      </table>')
    [void]$Builder.AppendLine('    </div>')

    if ($allRows.Count -gt $RowCap) {
        [void]$Builder.AppendLine("    <p class='muted'>Showing first $(ConvertTo-HtmlSafe $RowCap) rows.</p>")
    }
    [void]$Builder.AppendLine('  </details>')
}

function Get-MetricCssClass {
    param([string]$MetricLabel)
    switch ($MetricLabel) {
        'Total Settings' { return 'metric-total' }
        'Total'          { return 'metric-total' }
        'Compliant'      { return 'metric-compliant' }
        'Conflict'       { return 'metric-conflict' }
        'Missing'        { return 'metric-missing' }
        default          { return '' }
    }
}

function Export-HtmlAssessmentReport {
    <#
    .SYNOPSIS
        Writes a self-contained HTML assessment report with executive and detail sections.
    .PARAMETER Results
        Comparison rows from Compare-TenantSettings.
    .PARAMETER OutputPath
        Directory where the HTML report will be written.
    .PARAMETER CustomerName
        Used in report title and filename.
    .PARAMETER BaselineLevel
        Baseline level label (L1/L2/L3/L4) included in filename.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$Results,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$CustomerName  = 'Customer',
        [string]$BaselineLevel = 'L1',
        [System.Collections.Generic.List[hashtable]]$DeviceInventory = $null,
        [hashtable]$EnrollmentData = $null,
        [System.Collections.Generic.List[hashtable]]$AppInventory = $null,
        [System.Collections.Generic.List[hashtable]]$Findings = $null,
        [System.Collections.Generic.List[hashtable]]$SettingsConflicts = $null,
        [hashtable]$Phase4Data = $null,
        [hashtable]$AssignmentAnalysis = $null
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $total     = $Results.Count
    $compliant = @($Results | Where-Object { $_.Result -eq 'Compliant' }).Count
    $conflict  = @($Results | Where-Object { $_.Result -eq 'Conflict'  }).Count
    $missing   = @($Results | Where-Object { $_.Result -eq 'Missing'   }).Count
    $extra     = @($Results | Where-Object { $_.Result -eq 'Extra'     }).Count

    $byDomain = @(
        $Results |
            Where-Object { $_.BaselineDomain } |
            Group-Object BaselineDomain |
            Sort-Object Name
    )
    $byBaselinePolicy = @(
        $Results |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.BaselinePolicyName) } |
            Group-Object BaselinePolicyName |
            Sort-Object Name
    )

    $critical = @($Findings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $high     = @($Findings | Where-Object { $_.Severity -eq 'High'     }).Count
    $medium   = @($Findings | Where-Object { $_.Severity -eq 'Medium'   }).Count
    $low      = @($Findings | Where-Object { $_.Severity -eq 'Low'      }).Count

    $fileName = Get-HtmlFileName -CustomerName $CustomerName -BaselineLevel $BaselineLevel
    $filePath = Join-Path $OutputPath $fileName

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!doctype html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('  <meta charset="utf-8" />')
    [void]$sb.AppendLine('  <meta name="viewport" content="width=device-width, initial-scale=1" />')
    [void]$sb.AppendLine("  <title>Intune Assessment - $(ConvertTo-HtmlSafe $CustomerName)</title>")
    [void]$sb.AppendLine('  <style>')
    [void]$sb.AppendLine('    body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; color: #1f2937; }')
    [void]$sb.AppendLine('    h1, h2, h3 { margin-bottom: 8px; }')
    [void]$sb.AppendLine('    .muted { color: #4b5563; font-size: 0.95rem; }')
    [void]$sb.AppendLine('    .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit,minmax(160px,1fr)); gap: 12px; margin: 16px 0; }')
    [void]$sb.AppendLine('    .kpi { border: 1px solid #d1d5db; border-radius: 8px; padding: 12px; background: #f9fafb; }')
    [void]$sb.AppendLine('    .kpi .label { font-size: 0.9rem; color: #4b5563; }')
    [void]$sb.AppendLine('    .kpi .value { font-size: 1.3rem; font-weight: 600; }')
    [void]$sb.AppendLine('    .metric-total { color: #1f2937; }')
    [void]$sb.AppendLine('    .metric-compliant { color: #15803d; }')
    [void]$sb.AppendLine('    .metric-conflict { color: #b91c1c; }')
    [void]$sb.AppendLine('    .metric-missing { color: #b45309; }')
    [void]$sb.AppendLine('    table { width: 100%; border-collapse: collapse; margin: 10px 0 20px 0; }')
    [void]$sb.AppendLine('    th, td { border: 1px solid #d1d5db; padding: 8px; text-align: left; vertical-align: top; }')
    [void]$sb.AppendLine('    th { background: #f3f4f6; }')
    [void]$sb.AppendLine('    details { margin: 12px 0; border: 1px solid #d1d5db; border-radius: 8px; padding: 8px 12px; }')
    [void]$sb.AppendLine('    details > summary { cursor: pointer; font-weight: 600; }')
    [void]$sb.AppendLine('    .table-filter-bar { display: flex; flex-wrap: wrap; gap: 12px; margin: 10px 0; }')
    [void]$sb.AppendLine('    .table-filter-bar label { display: flex; flex-direction: column; gap: 4px; font-size: 0.85rem; color: #374151; }')
    [void]$sb.AppendLine('    .table-filter { min-width: 160px; padding: 4px 6px; }')
    [void]$sb.AppendLine('    th.sortable { cursor: pointer; user-select: none; }')
    [void]$sb.AppendLine('    th.sortable.active { text-decoration: underline; }')
    [void]$sb.AppendLine('    .sort-indicator { font-size: 0.85em; color: #6b7280; }')
    [void]$sb.AppendLine('    .row-success td { background: #ecfdf5; }')
    [void]$sb.AppendLine('    .row-warn td { background: #fffbeb; }')
    [void]$sb.AppendLine('    .row-error td { background: #fef2f2; }')
    [void]$sb.AppendLine('    .overview-table { table-layout: fixed; }')
    [void]$sb.AppendLine('    .overview-table col.col-name { width: 62%; }')
    [void]$sb.AppendLine('    .overview-table col.col-num { width: 9.5%; }')
    [void]$sb.AppendLine('  </style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine("  <h1>Intune Baseline Assessment</h1>")
    [void]$sb.AppendLine("  <p class='muted'>Customer: <strong>$(ConvertTo-HtmlSafe $CustomerName)</strong> | Baseline level: <strong>$(ConvertTo-HtmlSafe $BaselineLevel)</strong> | Generated: <strong>$(ConvertTo-HtmlSafe (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))</strong></p>")

    [void]$sb.AppendLine('  <h2>Executive Summary</h2>')
    [void]$sb.AppendLine('  <div class="kpi-grid">')
    foreach ($pair in @(
            @{ Label = 'Total Settings'; Value = $total },
            @{ Label = 'Compliant'; Value = $compliant },
            @{ Label = 'Conflict'; Value = $conflict },
            @{ Label = 'Missing'; Value = $missing },
            @{ Label = 'Extra'; Value = $extra },
            @{ Label = 'Findings'; Value = @($Findings).Count }
        )) {
        $valueCssClass = Get-MetricCssClass -MetricLabel $pair.Label
        $valueClassAttribute = if ([string]::IsNullOrWhiteSpace($valueCssClass)) { 'value' } else { "value $valueCssClass" }
        [void]$sb.AppendLine('    <div class="kpi">')
        [void]$sb.AppendLine("      <div class='label'>$(ConvertTo-HtmlSafe $pair.Label)</div>")
        [void]$sb.AppendLine("      <div class='$valueClassAttribute'>$(ConvertTo-HtmlSafe $pair.Value)</div>")
        [void]$sb.AppendLine('    </div>')
    }
    [void]$sb.AppendLine('  </div>')

    [void]$sb.AppendLine('  <h3>Findings by Severity</h3>')
    [void]$sb.AppendLine('  <table><thead><tr><th>Critical</th><th>High</th><th>Medium</th><th>Low</th></tr></thead>')
    [void]$sb.AppendLine("  <tbody><tr><td>$critical</td><td>$high</td><td>$medium</td><td>$low</td></tr></tbody></table>")

    [void]$sb.AppendLine('  <h3>Domain Overview</h3>')
    [void]$sb.AppendLine('  <table class="overview-table"><colgroup><col class="col-name" /><col class="col-num" /><col class="col-num" /><col class="col-num" /><col class="col-num" /></colgroup><thead><tr><th>Domain</th><th>Total</th><th>Compliant</th><th>Conflict</th><th>Missing</th></tr></thead><tbody>')
    foreach ($group in $byDomain) {
        $domainRows = @($group.Group)
        $domainTotal = $domainRows.Count
        $domainCompliant = @($domainRows | Where-Object { $_.Result -eq 'Compliant' }).Count
        $domainConflict = @($domainRows | Where-Object { $_.Result -eq 'Conflict' }).Count
        $domainMissing = @($domainRows | Where-Object { $_.Result -eq 'Missing' }).Count
        [void]$sb.AppendLine('<tr>')
        [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $group.Name)</td>")
        [void]$sb.AppendLine("  <td class='metric-total'>$(ConvertTo-HtmlSafe $domainTotal)</td>")
        [void]$sb.AppendLine("  <td class='metric-compliant'>$(ConvertTo-HtmlSafe $domainCompliant)</td>")
        [void]$sb.AppendLine("  <td class='metric-conflict'>$(ConvertTo-HtmlSafe $domainConflict)</td>")
        [void]$sb.AppendLine("  <td class='metric-missing'>$(ConvertTo-HtmlSafe $domainMissing)</td>")
        [void]$sb.AppendLine('</tr>')
    }
    [void]$sb.AppendLine('  </tbody></table>')

    [void]$sb.AppendLine('  <h3>Baseline Policy Overview</h3>')
    [void]$sb.AppendLine('  <table class="overview-table"><colgroup><col class="col-name" /><col class="col-num" /><col class="col-num" /><col class="col-num" /><col class="col-num" /></colgroup><thead><tr><th>Baseline Policy</th><th>Total</th><th>Compliant</th><th>Conflict</th><th>Missing</th></tr></thead><tbody>')
    foreach ($group in $byBaselinePolicy) {
        $policyRows = @($group.Group)
        $policyTotal = $policyRows.Count
        $policyCompliant = @($policyRows | Where-Object { $_.Result -eq 'Compliant' }).Count
        $policyConflict = @($policyRows | Where-Object { $_.Result -eq 'Conflict' }).Count
        $policyMissing = @($policyRows | Where-Object { $_.Result -eq 'Missing' }).Count

        [void]$sb.AppendLine('<tr>')
        [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $group.Name)</td>")
        [void]$sb.AppendLine("  <td class='metric-total'>$(ConvertTo-HtmlSafe $policyTotal)</td>")
        [void]$sb.AppendLine("  <td class='metric-compliant'>$(ConvertTo-HtmlSafe $policyCompliant)</td>")
        [void]$sb.AppendLine("  <td class='metric-conflict'>$(ConvertTo-HtmlSafe $policyConflict)</td>")
        [void]$sb.AppendLine("  <td class='metric-missing'>$(ConvertTo-HtmlSafe $policyMissing)</td>")
        [void]$sb.AppendLine('</tr>')
    }
    [void]$sb.AppendLine('  </tbody></table>')

    [void]$sb.AppendLine('  <h2>Detailed Sections</h2>')

    [void]$sb.AppendLine('  <details>')
    [void]$sb.AppendLine("    <summary>Top Findings ($(ConvertTo-HtmlSafe @($Findings).Count))</summary>")
    if (@($Findings).Count -gt 0) {
        [void]$sb.AppendLine('    <table><thead><tr><th>Severity</th><th>Domain</th><th>Finding</th><th>Detail</th><th>Recommendation</th></tr></thead><tbody>')
        foreach ($f in @($Findings | Select-Object -First 50)) {
            [void]$sb.AppendLine('<tr>')
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $f.Severity)</td>")
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $f.Domain)</td>")
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $f.FindingName)</td>")
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $f.Detail)</td>")
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $f.Recommendation)</td>")
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('    </tbody></table>')
        [void]$sb.AppendLine('    <p class="muted">Showing first 50 findings.</p>')
    } else {
        [void]$sb.AppendLine('    <p>No findings triggered.</p>')
    }
    [void]$sb.AppendLine('  </details>')

    [void]$sb.AppendLine('  <details>')
    [void]$sb.AppendLine("    <summary>Settings Conflicts ($(ConvertTo-HtmlSafe @($SettingsConflicts).Count) detail rows)</summary>")
    if (@($SettingsConflicts).Count -gt 0) {
        [void]$sb.AppendLine('    <table><thead><tr><th>Baseline Policy</th><th>Setting</th><th>Policy</th><th>Value</th><th>Status</th><th>Domain</th></tr></thead><tbody>')
        foreach ($c in @($SettingsConflicts | Select-Object -First 200)) {
            [void]$sb.AppendLine('<tr>')
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $c.BaselinePolicyName)</td>")
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $c.BaselineSetting)</td>")
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $c.PolicyName)</td>")
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $c.PolicyValue)</td>")
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $c.MatchStatus)</td>")
            [void]$sb.AppendLine("  <td>$(ConvertTo-HtmlSafe $c.Domain)</td>")
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('    </tbody></table>')
        [void]$sb.AppendLine('    <p class="muted">Showing first 200 conflict rows.</p>')
    } else {
        [void]$sb.AppendLine('    <p>No multi-policy conflicts detected.</p>')
    }
    [void]$sb.AppendLine('  </details>')

    [void]$sb.AppendLine('  <details>')
    [void]$sb.AppendLine("    <summary>Comparison Details ($(ConvertTo-HtmlSafe @($Results).Count) rows)</summary>")
    [void]$sb.AppendLine('    <table><thead><tr><th>Result</th><th>Domain</th><th>Baseline Policy</th><th>Setting</th><th>Policy</th><th>Value</th></tr></thead><tbody>')
    Add-ResultTableRows -Builder $sb -Rows @($Results | Select-Object -First 200)
    [void]$sb.AppendLine('    </tbody></table>')
    [void]$sb.AppendLine('    <p class="muted">Showing first 200 comparison rows.</p>')
    [void]$sb.AppendLine('  </details>')

    [void]$sb.AppendLine('  <details>')
    [void]$sb.AppendLine('    <summary>Inventory Highlights</summary>')
    [void]$sb.AppendLine('    <ul>')
    [void]$sb.AppendLine("      <li>Devices: $(ConvertTo-HtmlSafe @($DeviceInventory).Count)</li>")
    $enrollmentCount = if ($EnrollmentData -and $EnrollmentData.EnrollmentConfigs) { @($EnrollmentData.EnrollmentConfigs).Count } else { 0 }
    $autopilotCount = if ($EnrollmentData -and $EnrollmentData.AutopilotDevices) { @($EnrollmentData.AutopilotDevices).Count } else { 0 }
    [void]$sb.AppendLine("      <li>Enrollment configs: $(ConvertTo-HtmlSafe $enrollmentCount)</li>")
    [void]$sb.AppendLine("      <li>Autopilot devices: $(ConvertTo-HtmlSafe $autopilotCount)</li>")
    [void]$sb.AppendLine("      <li>Apps: $(ConvertTo-HtmlSafe @($AppInventory).Count)</li>")
    [void]$sb.AppendLine('    </ul>')
    [void]$sb.AppendLine('  </details>')

    $policyStatusRows = @()
    if ($Phase4Data -and $Phase4Data.ContainsKey('PolicyStatusOverview')) {
        $policyStatusRows = @($Phase4Data.PolicyStatusOverview)
    }
    Add-AdvancedTableSection -Builder $sb `
        -TableId 'allPolicyStatusOverview' `
        -Title 'Policy Deployment Status Overview' `
        -Rows $policyStatusRows `
        -Columns @(
            @{ key = 'PolicyId'; label = 'Policy Id'; type = 'text' },
            @{ key = 'PolicyName'; label = 'Policy Name'; type = 'text' },
            @{ key = 'Total'; label = 'Total'; type = 'number' },
            @{ key = 'Succeeded'; label = 'Succeeded'; type = 'number' },
            @{ key = 'Pending'; label = 'Pending'; type = 'number' },
            @{ key = 'Error'; label = 'Error'; type = 'number' },
            @{ key = 'Failed'; label = 'Failed'; type = 'number' },
            @{ key = 'InProgress'; label = 'In Progress'; type = 'number' },
            @{ key = 'Conflict'; label = 'Conflict'; type = 'number' },
            @{ key = 'NotApplicable'; label = 'Not Applicable'; type = 'number' },
            @{ key = 'NotDeployed'; label = 'Not Deployed'; type = 'boolean' }
        ) `
        -FilterColumnKeys @('NotDeployed') `
        -RowCap 500

    $assignmentRows = @()
    if ($AssignmentAnalysis -and $AssignmentAnalysis.ContainsKey('PolicyAssignmentSummary')) {
        $assignmentRows = @($AssignmentAnalysis.PolicyAssignmentSummary)
    }
    Add-AdvancedTableSection -Builder $sb `
        -TableId 'allPolicyAssignmentSummary' `
        -Title 'Policy Assignment Health Summary' `
        -Rows $assignmentRows `
        -Columns @(
            @{ key = 'PolicyId'; label = 'Policy Id'; type = 'text' },
            @{ key = 'PolicyName'; label = 'Policy Name'; type = 'text' },
            @{ key = 'AssignmentCount'; label = 'Assignment Count'; type = 'number' },
            @{ key = 'Targets'; label = 'Targets'; type = 'text' },
            @{ key = 'HasIncludeTarget'; label = 'Has Include Target'; type = 'boolean' },
            @{ key = 'HasExcludeOnly'; label = 'Has Exclude Only'; type = 'boolean' },
            @{ key = 'IsUnassigned'; label = 'Is Unassigned'; type = 'boolean' },
            @{ key = 'IsPotentiallyDead'; label = 'Is Potentially Dead'; type = 'boolean' }
        ) `
        -FilterColumnKeys @('HasIncludeTarget', 'HasExcludeOnly', 'IsUnassigned', 'IsPotentiallyDead') `
        -RowCap 500

    $deviceAssignmentRows = @()
    if ($Phase4Data -and $Phase4Data.ContainsKey('DeviceAssignmentStatusByConfigurationPolicy')) {
        $deviceAssignmentRows = @($Phase4Data.DeviceAssignmentStatusByConfigurationPolicy)
    }
    Add-AdvancedTableSection -Builder $sb `
        -TableId 'allDeviceAssignmentStatusByConfigurationPolicy' `
        -Title 'Device Assignment Status Details' `
        -Rows $deviceAssignmentRows `
        -Columns @(
            @{ key = 'PolicyId'; label = 'Policy Id'; type = 'text' },
            @{ key = 'PolicyName'; label = 'Policy Name'; type = 'text' },
            @{ key = 'DeviceName'; label = 'Device Name'; type = 'text' },
            @{ key = 'UserName'; label = 'User Name'; type = 'text' },
            @{ key = 'ReportStatus'; label = 'ReportStatus'; type = 'text' }
        ) `
        -FilterColumnKeys @('ReportStatus') `
        -RowCap 500

    $appAggRows = @()
    if ($Phase4Data -and $Phase4Data.ContainsKey('AppInstallStatusAggregate')) {
        $appAggRows = @($Phase4Data.AppInstallStatusAggregate)
    }
    Add-AdvancedTableSection -Builder $sb `
        -TableId 'appInstallStatusAggregateSummary' `
        -Title 'App Installation Status Summary' `
        -Rows $appAggRows `
        -Columns @(
            @{ key = 'ApplicationId'; label = 'Application Id'; type = 'text' },
            @{ key = 'DisplayName'; label = 'Display Name'; type = 'text' },
            @{ key = 'Publisher'; label = 'Publisher'; type = 'text' },
            @{ key = 'Platform'; label = 'Platform'; type = 'text' },
            @{ key = 'FailedDeviceCount'; label = 'Failed Device Count'; type = 'number' },
            @{ key = 'FailedDevicePercentage'; label = 'Failed Percentage'; type = 'number' },
            @{ key = 'InstalledDeviceCount'; label = 'Installed Device Count'; type = 'number' },
            @{ key = 'PendingInstallDeviceCount'; label = 'Pending Install Device Count'; type = 'number' },
            @{ key = 'NotApplicableDeviceCount'; label = 'Not Applicable Device Count'; type = 'number' }
        ) `
        -FilterColumnKeys @('Publisher', 'Platform') `
        -RowCap 500

    [void]$sb.AppendLine('  <script>')
    [void]$sb.AppendLine('    (function(){')
    [void]$sb.AppendLine('      function parseValue(raw, type){')
    [void]$sb.AppendLine("        if(type === 'number'){ var n = Number(raw); return Number.isNaN(n) ? -Infinity : n; }")
    [void]$sb.AppendLine("        if(type === 'boolean'){ return String(raw).toLowerCase() === 'true' ? 1 : 0; }")
    [void]$sb.AppendLine('        return String(raw).toLowerCase();')
    [void]$sb.AppendLine('      }')
    [void]$sb.AppendLine('      function applyFilters(tableId){')
    [void]$sb.AppendLine('        var table = document.getElementById(tableId); if(!table){ return; }')
    [void]$sb.AppendLine('        var rows = Array.from(table.querySelectorAll("tbody tr"));')
    [void]$sb.AppendLine('        var controls = Array.from(document.querySelectorAll(".table-filter[data-table-id=\"" + tableId + "\"]"));')
    [void]$sb.AppendLine('        rows.forEach(function(row){')
    [void]$sb.AppendLine('          var visible = true;')
    [void]$sb.AppendLine('          controls.forEach(function(ctrl){')
    [void]$sb.AppendLine('            var wanted = ctrl.value;')
    [void]$sb.AppendLine('            if(!wanted){ return; }')
    [void]$sb.AppendLine('            var key = ctrl.getAttribute("data-key");')
    [void]$sb.AppendLine('            var td = row.querySelector("td[data-key=\"" + key + "\"]");')
    [void]$sb.AppendLine('            var actual = td ? td.getAttribute("data-raw") : "";')
    [void]$sb.AppendLine('            if(String(actual) !== String(wanted)){ visible = false; }')
    [void]$sb.AppendLine('          });')
    [void]$sb.AppendLine('          row.style.display = visible ? "" : "none";')
    [void]$sb.AppendLine('        });')
    [void]$sb.AppendLine('      }')
    [void]$sb.AppendLine('      function applySort(tableId){')
    [void]$sb.AppendLine('        var wrapper = document.querySelector(".interactive-table-wrapper[data-table-id=\"" + tableId + "\"]");')
    [void]$sb.AppendLine('        var table = document.getElementById(tableId);')
    [void]$sb.AppendLine('        if(!wrapper || !table){ return; }')
    [void]$sb.AppendLine('        var sortKey = wrapper.getAttribute("data-sort-key");')
    [void]$sb.AppendLine('        var sortDir = wrapper.getAttribute("data-sort-dir") || "asc";')
    [void]$sb.AppendLine('        if(!sortKey){ return; }')
    [void]$sb.AppendLine('        var header = table.querySelector("th[data-key=\"" + sortKey + "\"]");')
    [void]$sb.AppendLine('        var type = header ? (header.getAttribute("data-type") || "text") : "text";')
    [void]$sb.AppendLine('        var tbody = table.querySelector("tbody");')
    [void]$sb.AppendLine('        var rows = Array.from(tbody.querySelectorAll("tr"));')
    [void]$sb.AppendLine('        rows.sort(function(a,b){')
    [void]$sb.AppendLine('          var av = parseValue((a.querySelector("td[data-key=\"" + sortKey + "\"]") || {getAttribute:function(){return "";}}).getAttribute("data-raw"), type);')
    [void]$sb.AppendLine('          var bv = parseValue((b.querySelector("td[data-key=\"" + sortKey + "\"]") || {getAttribute:function(){return "";}}).getAttribute("data-raw"), type);')
    [void]$sb.AppendLine('          if(av < bv){ return sortDir === "asc" ? -1 : 1; }')
    [void]$sb.AppendLine('          if(av > bv){ return sortDir === "asc" ? 1 : -1; }')
    [void]$sb.AppendLine('          return 0;')
    [void]$sb.AppendLine('        });')
    [void]$sb.AppendLine('        rows.forEach(function(r){ tbody.appendChild(r); });')
    [void]$sb.AppendLine('      }')
    [void]$sb.AppendLine('      function updateHeaderState(tableId){')
    [void]$sb.AppendLine('        var wrapper = document.querySelector(".interactive-table-wrapper[data-table-id=\"" + tableId + "\"]");')
    [void]$sb.AppendLine('        var table = document.getElementById(tableId);')
    [void]$sb.AppendLine('        if(!wrapper || !table){ return; }')
    [void]$sb.AppendLine('        var key = wrapper.getAttribute("data-sort-key");')
    [void]$sb.AppendLine('        var dir = wrapper.getAttribute("data-sort-dir") || "asc";')
    [void]$sb.AppendLine('        Array.from(table.querySelectorAll("th.sortable")).forEach(function(th){')
    [void]$sb.AppendLine('          th.classList.remove("active");')
    [void]$sb.AppendLine('          var span = th.querySelector(".sort-indicator"); if(span){ span.textContent = ""; }')
    [void]$sb.AppendLine('          if(th.getAttribute("data-key") === key){')
    [void]$sb.AppendLine('            th.classList.add("active");')
    [void]$sb.AppendLine('            if(span){ span.textContent = dir === "asc" ? "▲" : "▼"; }')
    [void]$sb.AppendLine('          }')
    [void]$sb.AppendLine('        });')
    [void]$sb.AppendLine('      }')
    [void]$sb.AppendLine('      function refresh(tableId){')
    [void]$sb.AppendLine('        applySort(tableId);')
    [void]$sb.AppendLine('        applyFilters(tableId);')
    [void]$sb.AppendLine('        updateHeaderState(tableId);')
    [void]$sb.AppendLine('      }')
    [void]$sb.AppendLine('      Array.from(document.querySelectorAll("th.sortable")).forEach(function(th){')
    [void]$sb.AppendLine('        th.addEventListener("click", function(){')
    [void]$sb.AppendLine('          var tableId = th.getAttribute("data-table-id");')
    [void]$sb.AppendLine('          var key = th.getAttribute("data-key");')
    [void]$sb.AppendLine('          var wrapper = document.querySelector(".interactive-table-wrapper[data-table-id=\"" + tableId + "\"]");')
    [void]$sb.AppendLine('          if(!wrapper){ return; }')
    [void]$sb.AppendLine('          var currentKey = wrapper.getAttribute("data-sort-key");')
    [void]$sb.AppendLine('          var currentDir = wrapper.getAttribute("data-sort-dir") || "asc";')
    [void]$sb.AppendLine('          var nextDir = (currentKey === key && currentDir === "asc") ? "desc" : "asc";')
    [void]$sb.AppendLine('          wrapper.setAttribute("data-sort-key", key);')
    [void]$sb.AppendLine('          wrapper.setAttribute("data-sort-dir", nextDir);')
    [void]$sb.AppendLine('          refresh(tableId);')
    [void]$sb.AppendLine('        });')
    [void]$sb.AppendLine('      });')
    [void]$sb.AppendLine('      Array.from(document.querySelectorAll(".table-filter")).forEach(function(ctrl){')
    [void]$sb.AppendLine('        ctrl.addEventListener("change", function(){')
    [void]$sb.AppendLine('          var tableId = ctrl.getAttribute("data-table-id");')
    [void]$sb.AppendLine('          refresh(tableId);')
    [void]$sb.AppendLine('        });')
    [void]$sb.AppendLine('      });')
    [void]$sb.AppendLine('      Array.from(document.querySelectorAll(".interactive-table-wrapper")).forEach(function(wrapper){')
    [void]$sb.AppendLine('        var tableId = wrapper.getAttribute("data-table-id");')
    [void]$sb.AppendLine('        refresh(tableId);')
    [void]$sb.AppendLine('      });')
    [void]$sb.AppendLine('    })();')
    [void]$sb.AppendLine('  </script>')

    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')

    $encoding = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $encoding)
    return $filePath
}

Export-ModuleMember -Function @(
    'Export-HtmlAssessmentReport'
)
