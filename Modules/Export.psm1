# =============================================================================
# Export.psm1 — Output generation
#
# Sprint 1: CSV export matching the IntuneDiff_Export.csv schema.
# Later sprints: ReportData.json for Word document population.
#
# CSV format: semicolon-delimited, all fields double-quoted, UTF-8 with BOM.
# =============================================================================

Set-StrictMode -Version Latest

# Column order must match the reference file schema exactly
$script:CsvColumns = @(
    'BaselinePolicyName',
    'BaselinePolicyTemplate',
    'BaselineSetting',
    'BaselineCategory',
    'BaselineDomain',
    'BaselineValue',
    'Result',
    'PolicyName',
    'CustomerSetting',
    'PolicyTemplate',
    'PolicyValue',
    'ComparisonCategory',
    'ComparisonDomain',
    'Description'
)

$script:CsvHeader = '"Baseline Policy Name";"Baseline Policy Template";"Baseline Setting";"Baseline Category";"Baseline Domain";"Baseline Setting Value";"Result";"Policy Name";"Customer Setting";"Policy Template";"Policy Value";"Comparison Category";"Comparison Domain";"Description"'

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Export-DiffCsv {
    <#
    .SYNOPSIS
        Writes the comparison results to a semicolon-delimited CSV file.
    .PARAMETER Results
        List[hashtable] as returned by Compare-TenantSettings.
    .PARAMETER OutputPath
        Directory where the CSV file will be written.
    .PARAMETER CustomerName
        Used to construct the filename.
    .PARAMETER BaselineLevel
        Baseline level label (L1/L2/L3/L4) included in the filename.
    .OUTPUTS
        String — full path of the written file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$Results,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$CustomerName   = 'Customer',
        [string]$BaselineLevel  = 'L1'
    )

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd'
    $safeName  = $CustomerName -replace '[^\w\-]', '_'
    $fileName  = "${safeName}_${timestamp}_${BaselineLevel}_IntuneDiff_Export.csv"
    $filePath  = Join-Path $OutputPath $fileName

    $lines = [System.Collections.Generic.List[string]]::new($Results.Count + 1)
    $lines.Add($script:CsvHeader)

    foreach ($row in $Results) {
        $fields = $script:CsvColumns | ForEach-Object {
            $raw = if ($row.ContainsKey($_) -and $null -ne $row[$_]) { "$($row[$_])" } else { '' }
            # Escape embedded double-quotes by doubling them
            $escaped = $raw -replace '"', '""'
            "`"$escaped`""
        }
        $lines.Add($fields -join ';')
    }

    # UTF-8 with BOM so Excel opens it correctly
    $encoding = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllLines($filePath, $lines, $encoding)

    return $filePath
}

function Export-ReportData {
    <#
    .SYNOPSIS
        Writes a structured JSON file containing aggregated data needed to
        populate the Intune Assessment Report Template.
        (Stub for Sprint 1 — will be fully implemented in Sprint 6.)
    .PARAMETER Results
        List[hashtable] from Compare-TenantSettings.
    .PARAMETER OutputPath
        Directory for the JSON file.
    .PARAMETER CustomerName
        Customer display name.
    .PARAMETER Consultant
        Consultant name (written to JSON for report population).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$Results,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$CustomerName  = 'Customer',
        [string]$Consultant    = '',
        [string]$BaselineLevel = 'L1'
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $total     = $Results.Count
    $compliant = @($Results | Where-Object { $_.Result -eq 'Compliant' }).Count
    $conflict  = @($Results | Where-Object { $_.Result -eq 'Conflict'  }).Count
    $missing   = @($Results | Where-Object { $_.Result -eq 'Missing'   }).Count
    $extra     = @($Results | Where-Object { $_.Result -eq 'Extra'     }).Count

    # Per-domain aggregation
    $domainGroups = $Results |
                    Where-Object { $_.BaselineDomain } |
                    Group-Object BaselineDomain

    $byDomain = [ordered]@{}
    foreach ($g in $domainGroups | Sort-Object Name) {
        $dc = @($g.Group | Where-Object { $_.Result -eq 'Compliant' }).Count
        $dt = $g.Group.Count
        $pct = if ($dt -gt 0) { [Math]::Round($dc / $dt * 100) } else { 0 }
        $score = Get-MaturityScore -CompliantPct $pct
        $byDomain[$g.Name] = [ordered]@{
            Compliant    = $dc
            Conflict     = @($g.Group | Where-Object { $_.Result -eq 'Conflict' }).Count
            Missing      = @($g.Group | Where-Object { $_.Result -eq 'Missing'  }).Count
            Total        = $dt
            CompliantPct = $pct
            MaturityScore = $score
        }
    }

    $reportData = [ordered]@{
        GeneratedAt    = (Get-Date -Format 'o')
        CustomerName   = $CustomerName
        Consultant     = $Consultant
        BaselineLevel  = $BaselineLevel
        Summary        = [ordered]@{
            Total     = $total
            Compliant = $compliant
            Conflict  = $conflict
            Missing   = $missing
            Extra     = $extra
        }
        ByDomain       = $byDomain
    }

    $timestamp = Get-Date -Format 'yyyyMMdd'
    $safeName  = $CustomerName -replace '[^\w\-]', '_'
    $fileName  = "${safeName}_${timestamp}_${BaselineLevel}_ReportData.json"
    $filePath  = Join-Path $OutputPath $fileName

    $reportData | ConvertTo-Json -Depth 10 |
        Set-Content -Path $filePath -Encoding UTF8

    return $filePath
}

function Get-MaturityScore {
    <#
    .SYNOPSIS
        Converts a compliance percentage (0-100) to a maturity score (0-5).
    .PARAMETER CompliantPct
        Integer percentage of compliant settings (0-100).
    .OUTPUTS
        Int — maturity score from 0 (no compliance) to 5 (>=90%).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [int]$CompliantPct
    )

    switch ($CompliantPct) {
        { $_ -eq 0 }  { return 0 }
        { $_ -lt 25 } { return 1 }
        { $_ -lt 50 } { return 2 }
        { $_ -lt 75 } { return 3 }
        { $_ -lt 90 } { return 4 }
        default        { return 5 }
    }
}

Export-ModuleMember -Function @(
    'Export-DiffCsv',
    'Export-ReportData',
    'Get-MaturityScore'
)
