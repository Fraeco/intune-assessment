# =============================================================================
# IntuneReportExporter.psm1 — Async Intune report export helpers (Phase 4)
# =============================================================================

Set-StrictMode -Version Latest

function Invoke-IntuneExportJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl,
        [Parameter(Mandatory)] [string]$ReportName,
        [Parameter(Mandatory)] [string[]]$Select,
        [string]$Filter = '',
        [int]$PollIntervalSec = 5,
        [int]$MaxPollAttempts = 36,
        [string]$TempPath = $env:TEMP
    )

    if (-not (Test-Path $TempPath)) {
        New-Item -ItemType Directory -Path $TempPath -Force | Out-Null
    }

    $requestBody = [ordered]@{
        reportName = $ReportName
        format     = 'csv'
        select     = @($Select)
    }
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $requestBody.filter = $Filter
    }

    $job = Invoke-IbaGraphRequest `
        -Uri "$BaseUrl/deviceManagement/reports/exportJobs" `
        -Token $Token `
        -Method 'POST' `
        -Body $requestBody

    if (-not $job -or -not $job.id) {
        throw "Failed to create export job for report '$ReportName'."
    }

    $jobUri = "$BaseUrl/deviceManagement/reports/exportJobs('$($job.id)')"
    $attempt = 0
    $state = ''
    $downloadUrl = ''

    while ($attempt -lt $MaxPollAttempts) {
        $attempt++
        $current = Invoke-IbaGraphRequest -Uri $jobUri -Token $Token -Method 'GET'
        $state = "$($current.status)"
        Write-Verbose "Report '$ReportName' job status: $state (attempt $attempt/$MaxPollAttempts)"

        if ($state -eq 'completed') {
            $downloadUrl = "$($current.url)"
            break
        }
        if ($state -eq 'failed') {
            throw "Export job failed for '$ReportName'."
        }
        Start-Sleep -Seconds $PollIntervalSec
    }

    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        throw "Export job timed out for '$ReportName' (last status: '$state')."
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $safeReport = $ReportName -replace '[^\w\-]', '_'
    $downloadFile = Join-Path $TempPath "${safeReport}_${stamp}.zip"
    $extractPath  = Join-Path $TempPath "${safeReport}_${stamp}"

    Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadFile -UseBasicParsing
    Expand-Archive -Path $downloadFile -DestinationPath $extractPath -Force

    $csvFile = Get-ChildItem -Path $extractPath -Filter '*.csv' | Select-Object -First 1
    if ($null -eq $csvFile) {
        throw "No CSV artifact found for '$ReportName'."
    }

    $rows = @(Import-Csv -Path $csvFile.FullName)

    Remove-Item -Path $downloadFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue

    return $rows
}

function Convert-AppInstallAggregateRows {
    [CmdletBinding()]
    param([object[]]$Rows)

    $result = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($r in @($Rows)) {
        $result.Add([ordered]@{
            ApplicationId              = "$($r.ApplicationId)"
            DisplayName                = "$($r.DisplayName)"
            Publisher                  = "$($r.Publisher)"
            Platform                   = "$($r.Platform)"
            FailedDeviceCount          = [int]($r.FailedDeviceCount -as [int])
            FailedDevicePercentage     = [double]($r.FailedDevicePercentage -as [double])
            InstalledDeviceCount       = [int]($r.InstalledDeviceCount -as [int])
            PendingInstallDeviceCount  = [int]($r.PendingInstallDeviceCount -as [int])
            NotApplicableDeviceCount   = [int]($r.NotApplicableDeviceCount -as [int])
        })
    }
    return $result
}

function Convert-PolicyAssignmentStatusRows {
    [CmdletBinding()]
    param([object[]]$Rows)

    $result = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($r in @($Rows)) {
        $result.Add([ordered]@{
            PolicyId     = "$($r.PolicyId)"
            PolicyName   = "$($r.PolicyName)"
            DeviceName   = "$($r.DeviceName)"
            UserName     = "$($r.UserName)"
            ReportStatus = "$($r.ReportStatus)"
        })
    }
    return $result
}

function Get-PolicyStatusOverview {
    [CmdletBinding()]
    param([System.Collections.Generic.List[hashtable]]$Rows)

    $overview = [System.Collections.Generic.List[hashtable]]::new()
    if ($null -eq $Rows -or $Rows.Count -eq 0) {
        return , $overview
    }

    foreach ($g in ($Rows | Group-Object PolicyId)) {
        $group = @($g.Group)
        $name = if ($group.Count -gt 0) { $group[0].PolicyName } else { '' }
        $statusCounts = @{
            Succeeded  = @($group | Where-Object { $_.ReportStatus -eq 'Succeeded' }).Count
            Pending    = @($group | Where-Object { $_.ReportStatus -eq 'Pending' }).Count
            Error      = @($group | Where-Object { $_.ReportStatus -eq 'Error' }).Count
            Failed     = @($group | Where-Object { $_.ReportStatus -eq 'Failed' }).Count
            InProgress = @($group | Where-Object { $_.ReportStatus -eq 'InProgress' }).Count
            Conflict   = @($group | Where-Object { $_.ReportStatus -eq 'Conflict' }).Count
            NotApplicable = @($group | Where-Object { $_.ReportStatus -eq 'NotApplicable' }).Count
        }
        $total = 0
        foreach ($k in $statusCounts.Keys) { $total += $statusCounts[$k] }
        $overview.Add([ordered]@{
            PolicyId       = $g.Name
            PolicyName     = $name
            Total          = $total
            Succeeded      = $statusCounts.Succeeded
            Pending        = $statusCounts.Pending
            Error          = $statusCounts.Error
            Failed         = $statusCounts.Failed
            InProgress     = $statusCounts.InProgress
            Conflict       = $statusCounts.Conflict
            NotApplicable  = $statusCounts.NotApplicable
            NotDeployed    = $false
        })
    }

    return , $overview
}

function Get-IntuneAdvancedReportData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl,
        [System.Collections.Generic.List[hashtable]]$CustomerSettings = $null,
        [string]$TempPath = $env:TEMP
    )

    $appRowsRaw = Invoke-IntuneExportJob `
        -Token $Token `
        -BaseUrl $BaseUrl `
        -ReportName 'AppInstallStatusAggregate' `
        -Select @('ApplicationId','DisplayName','Publisher','Platform','FailedDeviceCount','FailedDevicePercentage','InstalledDeviceCount','PendingInstallDeviceCount','NotApplicableDeviceCount') `
        -TempPath $TempPath

    $policyRowsRaw = Invoke-IntuneExportJob `
        -Token $Token `
        -BaseUrl $BaseUrl `
        -ReportName 'DeviceAssignmentStatusByConfigurationPolicy' `
        -Select @('PolicyId','PolicyName','DeviceName','UserName','ReportStatus') `
        -TempPath $TempPath

    $appRows = Convert-AppInstallAggregateRows -Rows $appRowsRaw
    $policyRows = Convert-PolicyAssignmentStatusRows -Rows $policyRowsRaw
    $policyOverview = Get-PolicyStatusOverview -Rows $policyRows
    if ($policyOverview -isnot [System.Collections.Generic.List[hashtable]]) {
        $mutableOverview = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($row in @($policyOverview)) { $mutableOverview.Add($row) }
        $policyOverview = $mutableOverview
    }

    if ($null -ne $CustomerSettings -and $CustomerSettings.Count -gt 0) {
        $policyNames = @(
            $CustomerSettings |
                ForEach-Object { $_.PolicyName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
        $existingIds = @($policyOverview | ForEach-Object { $_.PolicyId })
        foreach ($p in $policyNames) {
            $match = @($policyOverview | Where-Object { $_.PolicyName -eq $p })
            if ($match.Count -eq 0) {
                $policyOverview.Add([ordered]@{
                    PolicyId = ''
                    PolicyName = $p
                    Total = 0
                    Succeeded = 0
                    Pending = 0
                    Error = 0
                    Failed = 0
                    InProgress = 0
                    Conflict = 0
                    NotApplicable = 0
                    NotDeployed = $true
                })
            }
        }
    }

    $appFailureCount = @($appRows | Where-Object { $_.FailedDeviceCount -gt 0 }).Count
    $platformSummary = @(
        $appRows | Group-Object Platform | ForEach-Object {
            [ordered]@{
                Platform = $_.Name
                AppCount = $_.Count
                FailedDeviceCount = (@($_.Group | Measure-Object -Property FailedDeviceCount -Sum).Sum)
            }
        }
    )

    return @{
        AppInstallStatusAggregate = $appRows
        DeviceAssignmentStatusByConfigurationPolicy = $policyRows
        PolicyStatusOverview = @($policyOverview | Sort-Object PolicyName)
        Summary = [ordered]@{
            AppCount = $appRows.Count
            AppsWithFailures = $appFailureCount
            PolicyStatusRows = $policyRows.Count
            PoliciesInOverview = $policyOverview.Count
            AppFailuresByPlatform = $platformSummary
        }
    }
}

Export-ModuleMember -Function @(
    'Get-IntuneAdvancedReportData'
)

