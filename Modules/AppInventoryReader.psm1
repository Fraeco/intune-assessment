# =============================================================================
# AppInventoryReader.psm1 — Fetches mobile app inventory with assignments
#                            (Sprint 5)
#
# Graph endpoints:
#   GET /deviceAppManagement/mobileApps                    — list all apps
#   GET /deviceAppManagement/mobileApps/{id}/assignments   — per-app assignments
#
# Returns a flat list of hashtables, one per app. Includes assignment metadata
# (intent, groups). This is NOT a policy reader — it produces inventory data
# for the assessment report, bypassing the Comparison/Enrichment pipeline.
#
# Required permission: DeviceManagementApps.Read.All
# =============================================================================

Set-StrictMode -Version Latest

function Get-AppInventory {
    <#
    .SYNOPSIS
        Fetches all mobile apps and their assignment status from the customer tenant.
    .PARAMETER Token
        Bearer access token for the target tenant.
    .PARAMETER BaseUrl
        Graph API base URL including version, e.g. https://graph.microsoft.com/beta
    .OUTPUTS
        System.Collections.Generic.List[hashtable]
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl
    )

    Write-IbaLog -Level Debug -Message "    Fetching mobile app inventory..."
    $apps = $null
    try {
        $apps = @(Get-GraphPagedResults `
            -Uri   "$BaseUrl/deviceAppManagement/mobileApps" `
            -Token $Token)
    }
    catch {
        if ("$_" -match '403|Forbidden|Authorization_RequestDenied') {
            Write-Warning "    Insufficient permissions for app inventory. Grant DeviceManagementApps.Read.All."
            return [System.Collections.Generic.List[hashtable]]::new()
        }
        throw
    }

    Write-IbaLog -Level Debug -Message "    Found $($apps.Count) apps. Fetching assignments..."

    $results = [System.Collections.Generic.List[hashtable]]::new()
    $i = 0

    foreach ($app in $apps) {
        $i++
        if ($apps.Count -gt 0) {
            Write-IbaProgress `
                -Activity        'Reading App Assignments' `
                -Status          "[$i/$($apps.Count)] $($app.displayName)" `
                -PercentComplete ([Math]::Round($i / $apps.Count * 100))
        }

        $odataType = if ($app.PSObject.Properties['@odata.type']) { $app.'@odata.type' } else { '' }
        $shortType = $odataType -replace '^#microsoft\.graph\.', ''

        # Fetch assignments for this app
        $assignmentInfo = Get-AppAssignmentInfo -AppId $app.id -Token $Token -BaseUrl $BaseUrl

        $results.Add([ordered]@{
            AppName          = $app.displayName
            AppId            = $app.id
            AppType          = $shortType
            Publisher        = if ($app.PSObject.Properties['publisher']) { $app.publisher } else { '' }
            CreatedDate      = $app.createdDateTime
            LastModified     = $app.lastModifiedDateTime
            IsAssigned       = $assignmentInfo.IsAssigned
            AssignmentCount  = $assignmentInfo.AssignmentCount
            AssignmentIntent = $assignmentInfo.AssignmentIntent
            AssignmentGroups = $assignmentInfo.AssignmentGroups
        })
    }

    Write-IbaProgress -Activity 'Reading App Assignments' -Completed
    Write-IbaLog -Level Debug -Message "    Processed $($results.Count) apps with assignment data."

    return $results
}

# ---------------------------------------------------------------------------
# Internal — per-app assignment lookup
# ---------------------------------------------------------------------------

function Get-AppAssignmentInfo {
    param([string]$AppId, [string]$Token, [string]$BaseUrl)

    $empty = @{
        IsAssigned       = 'No'
        AssignmentCount  = '0'
        AssignmentIntent = ''
        AssignmentGroups = ''
    }

    try {
        $assignments = @(Get-GraphPagedResults `
            -Uri   "$BaseUrl/deviceAppManagement/mobileApps/$AppId/assignments" `
            -Token $Token)
    }
    catch {
        Write-Verbose "  Failed to fetch assignments for app '$AppId': $_"
        return $empty
    }

    if ($assignments.Count -eq 0) { return $empty }

    # Collect unique intents
    $intents = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $groups  = [System.Collections.Generic.List[string]]::new()

    foreach ($a in $assignments) {
        if ($a.PSObject.Properties['intent'] -and $a.intent) {
            [void]$intents.Add($a.intent)
        }

        if ($a.PSObject.Properties['target'] -and $a.target) {
            $targetType = if ($a.target.PSObject.Properties['@odata.type']) { $a.target.'@odata.type' } else { '' }
            switch -Wildcard ($targetType) {
                '*allLicensedUsersAssignmentTarget' { $groups.Add('All Users') }
                '*allDevicesAssignmentTarget'       { $groups.Add('All Devices') }
                '*groupAssignmentTarget' {
                    if ($a.target.PSObject.Properties['groupId'] -and $a.target.groupId) {
                        $groups.Add($a.target.groupId)
                    }
                }
            }
        }
    }

    return @{
        IsAssigned       = 'Yes'
        AssignmentCount  = "$($assignments.Count)"
        AssignmentIntent = ($intents | Sort-Object) -join ', '
        AssignmentGroups = ($groups | Select-Object -Unique) -join ', '
    }
}

Export-ModuleMember -Function @('Get-AppInventory')
