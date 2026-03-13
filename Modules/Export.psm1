# =============================================================================
# Export.psm1 — Output generation
#
# CSV export (IntuneDiff_Export schema) + inventory CSVs + ReportData.json.
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

# ---------------------------------------------------------------------------
# Internal — shared CSV writer
# ---------------------------------------------------------------------------

function Write-SemicolonCsv {
    <#
    .SYNOPSIS
        Writes a semicolon-delimited, double-quoted, UTF-8 BOM CSV file.
    #>
    param(
        [string]$FilePath,
        [string]$Header,
        [string[]]$ColumnKeys,
        $Rows
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($Header)

    foreach ($row in $Rows) {
        $fields = $ColumnKeys | ForEach-Object {
            $raw = if ($row.ContainsKey($_) -and $null -ne $row[$_]) { "$($row[$_])" } else { '' }
            $escaped = $raw -replace '"', '""'
            "`"$escaped`""
        }
        $lines.Add($fields -join ';')
    }

    $encoding = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllLines($FilePath, $lines, $encoding)
}

# ---------------------------------------------------------------------------
# Internal — shared filename builder
# ---------------------------------------------------------------------------

function Get-ExportFileName {
    param([string]$CustomerName, [string]$BaselineLevel, [string]$Suffix)
    $timestamp = Get-Date -Format 'yyyyMMdd'
    $safeName  = $CustomerName -replace '[^\w\-]', '_'
    return "${safeName}_${timestamp}_${BaselineLevel}_${Suffix}.csv"
}

# ---------------------------------------------------------------------------
# Public — Inventory CSV exporters
# ---------------------------------------------------------------------------

function Export-DeviceInventoryCsv {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.List[hashtable]]$Devices,
        [Parameter(Mandatory)] [string]$OutputPath,
        [string]$CustomerName  = 'Customer',
        [string]$BaselineLevel = 'L1'
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $header = '"Device Name";"Device ID";"Operating System";"OS Version";"Compliance State";"Last Sync";"Enrolled Date";"Management Agent";"Enrollment Type";"Model";"Manufacturer";"Serial Number";"User Principal Name"'
    $columns = @('DeviceName','DeviceId','OperatingSystem','OsVersion','ComplianceState','LastSync','EnrolledDate','ManagementAgent','EnrollmentType','Model','Manufacturer','SerialNumber','UserPrincipalName')

    $fileName = Get-ExportFileName -CustomerName $CustomerName -BaselineLevel $BaselineLevel -Suffix 'DeviceInventory'
    $filePath = Join-Path $OutputPath $fileName

    Write-SemicolonCsv -FilePath $filePath -Header $header -ColumnKeys $columns -Rows $Devices
    return $filePath
}

function Export-EnrollmentCsv {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$EnrollmentData,
        [Parameter(Mandatory)] [string]$OutputPath,
        [string]$CustomerName  = 'Customer',
        [string]$BaselineLevel = 'L1'
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Enrollment Configs CSV
    $configHeader  = '"Config Name";"Config ID";"Config Type";"Priority";"Description";"Created Date";"Last Modified"'
    $configColumns = @('ConfigName','ConfigId','ConfigType','Priority','Description','CreatedDate','LastModified')
    $configFile    = Get-ExportFileName -CustomerName $CustomerName -BaselineLevel $BaselineLevel -Suffix 'EnrollmentConfigs'
    $configPath    = Join-Path $OutputPath $configFile
    Write-SemicolonCsv -FilePath $configPath -Header $configHeader -ColumnKeys $configColumns -Rows $EnrollmentData.EnrollmentConfigs

    # Autopilot Devices CSV
    $apHeader  = '"Serial Number";"Model";"Manufacturer";"Group Tag";"Purchase Order";"Enrollment State";"Last Contacted";"Profile Assignment Status"'
    $apColumns = @('SerialNumber','Model','Manufacturer','GroupTag','PurchaseOrderId','EnrollmentState','LastContactedDateTime','DeploymentProfileAssignmentStatus')
    $apFile    = Get-ExportFileName -CustomerName $CustomerName -BaselineLevel $BaselineLevel -Suffix 'AutopilotDevices'
    $apPath    = Join-Path $OutputPath $apFile
    Write-SemicolonCsv -FilePath $apPath -Header $apHeader -ColumnKeys $apColumns -Rows $EnrollmentData.AutopilotDevices

    return @{ ConfigsCsv = $configPath; AutopilotCsv = $apPath }
}

function Export-AppInventoryCsv {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.List[hashtable]]$Apps,
        [Parameter(Mandatory)] [string]$OutputPath,
        [string]$CustomerName  = 'Customer',
        [string]$BaselineLevel = 'L1'
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $header  = '"App Name";"App ID";"App Type";"Publisher";"Created Date";"Last Modified";"Is Assigned";"Assignment Count";"Assignment Intent";"Assignment Groups"'
    $columns = @('AppName','AppId','AppType','Publisher','CreatedDate','LastModified','IsAssigned','AssignmentCount','AssignmentIntent','AssignmentGroups')

    $fileName = Get-ExportFileName -CustomerName $CustomerName -BaselineLevel $BaselineLevel -Suffix 'AppInventory'
    $filePath = Join-Path $OutputPath $fileName

    Write-SemicolonCsv -FilePath $filePath -Header $header -ColumnKeys $columns -Rows $Apps
    return $filePath
}

# ---------------------------------------------------------------------------
# Public — ReportData.json
# ---------------------------------------------------------------------------

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
        [string]$BaselineLevel = 'L1',

        [System.Collections.Generic.List[hashtable]]$DeviceInventory = $null,
        [hashtable]$EnrollmentData = $null,
        [System.Collections.Generic.List[hashtable]]$AppInventory = $null,
        [System.Collections.Generic.List[hashtable]]$Findings = $null
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

    # Inventory sections (optional — only present when data was collected)
    if ($null -ne $DeviceInventory) {
        $osSummary = @($DeviceInventory | Group-Object OperatingSystem |
            ForEach-Object { [ordered]@{ OS = $_.Name; Count = $_.Count } })
        $complianceSummary = @($DeviceInventory | Group-Object ComplianceState |
            ForEach-Object { [ordered]@{ State = $_.Name; Count = $_.Count } })

        $reportData['DeviceInventory'] = [ordered]@{
            TotalDevices      = $DeviceInventory.Count
            ByOperatingSystem = $osSummary
            ByComplianceState = $complianceSummary
            Devices           = @($DeviceInventory)
        }
    }

    if ($null -ne $EnrollmentData) {
        $reportData['EnrollmentMethods'] = [ordered]@{
            EnrollmentConfigCount = $EnrollmentData.EnrollmentConfigs.Count
            AutopilotDeviceCount  = $EnrollmentData.AutopilotDevices.Count
            EnrollmentConfigs     = @($EnrollmentData.EnrollmentConfigs)
            AutopilotDevices      = @($EnrollmentData.AutopilotDevices)
        }
    }

    if ($null -ne $AppInventory) {
        $typeSummary     = @($AppInventory | Group-Object AppType |
            ForEach-Object { [ordered]@{ Type = $_.Name; Count = $_.Count } })
        $assignedCount   = @($AppInventory | Where-Object { $_.IsAssigned -eq 'Yes' }).Count
        $unassignedCount = @($AppInventory | Where-Object { $_.IsAssigned -eq 'No'  }).Count

        $reportData['AppInventory'] = [ordered]@{
            TotalApps      = $AppInventory.Count
            AssignedApps   = $assignedCount
            UnassignedApps = $unassignedCount
            ByAppType      = $typeSummary
            Apps           = @($AppInventory)
        }
    }

    # Findings sections (optional — only present when findings engine ran)
    if ($null -ne $Findings -and $Findings.Count -gt 0) {
        # Executive summary — top 3 findings by severity
        $topRisks = @($Findings | Select-Object -First 3 | ForEach-Object {
            [ordered]@{
                FindingName    = $_.FindingName
                Domain         = $_.Domain
                Severity       = $_.Severity
                Detail         = $_.Detail
                Recommendation = $_.Recommendation
            }
        })

        $reportData['ExecutiveSummary'] = [ordered]@{
            TopRisks = $topRisks
        }

        # Finding summary — counts by severity
        $bySeverity = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0 }
        foreach ($f in $Findings) {
            if ($bySeverity.Contains($f.Severity)) {
                $bySeverity[$f.Severity]++
            }
        }

        $reportData['FindingSummary'] = [ordered]@{
            Total      = $Findings.Count
            BySeverity = $bySeverity
        }

        # Findings grouped by domain, sorted by severity within each domain
        $domainFindings = [ordered]@{}
        $grouped = $Findings | Group-Object Domain | Sort-Object Name
        foreach ($g in $grouped) {
            $domainFindings[$g.Name] = @($g.Group | Sort-Object @{
                Expression = { $_.SeverityScore }; Descending = $true
            } | ForEach-Object {
                [ordered]@{
                    FindingId      = $_.FindingId
                    FindingName    = $_.FindingName
                    Severity       = $_.Severity
                    Detail         = $_.Detail
                    Recommendation = $_.Recommendation
                    AffectedCount  = $_.AffectedCount
                    Category       = $_.Category
                }
            })
        }

        $reportData['FindingsByDomain'] = $domainFindings
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
    'Export-DeviceInventoryCsv',
    'Export-EnrollmentCsv',
    'Export-AppInventoryCsv',
    'Export-ReportData',
    'Get-MaturityScore'
)
