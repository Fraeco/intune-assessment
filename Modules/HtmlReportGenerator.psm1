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
        [System.Collections.Generic.List[hashtable]]$SettingsConflicts = $null
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
    [void]$sb.AppendLine('  <table><thead><tr><th>Domain</th><th>Total</th><th>Compliant</th><th>Conflict</th><th>Missing</th></tr></thead><tbody>')
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
    [void]$sb.AppendLine('  <table><thead><tr><th>Baseline Policy</th><th>Total</th><th>Compliant</th><th>Conflict</th><th>Missing</th></tr></thead><tbody>')
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

    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')

    $encoding = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $encoding)
    return $filePath
}

Export-ModuleMember -Function @(
    'Export-HtmlAssessmentReport'
)
