# =============================================================================
# AssignmentAnalysis.psm1 — Policy/app assignment target analysis (Phase 4)
# =============================================================================

Set-StrictMode -Version Latest

function Get-GroupLookup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl
    )

    $lookup = @{}
    try {
        $groups = @(Get-GraphPagedResults -Uri "$BaseUrl/groups?`$select=id,displayName" -Token $Token)
        foreach ($g in $groups) {
            if ($g.id) { $lookup["$($g.id)"] = "$($g.displayName)" }
        }
    }
    catch {
        Write-Warning "Assignment analysis: unable to resolve group names. Falling back to group IDs."
    }
    return $lookup
}

function Resolve-AssignmentTargetText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Target,
        [hashtable]$GroupLookup = @{}
    )

    $odataType = if ($Target.PSObject.Properties['@odata.type']) { "$($Target.'@odata.type')" } else { '' }
    $groupId = if ($Target.PSObject.Properties['groupId']) { "$($Target.groupId)" } else { '' }
    $filterId = if ($Target.PSObject.Properties['deviceAndAppManagementAssignmentFilterId']) { "$($Target.deviceAndAppManagementAssignmentFilterId)" } else { '' }
    $filterType = if ($Target.PSObject.Properties['deviceAndAppManagementAssignmentFilterType']) { "$($Target.deviceAndAppManagementAssignmentFilterType)" } else { '' }

    $base = switch -Wildcard ($odataType) {
        '*allDevicesAssignmentTarget' { 'All Devices' }
        '*allLicensedUsersAssignmentTarget' { 'All Users' }
        '*groupAssignmentTarget' {
            if ($groupId) {
                if ($GroupLookup.ContainsKey($groupId)) { "Group: $($GroupLookup[$groupId])" }
                else { "GroupId: $groupId" }
            } else { 'Group (unknown)' }
        }
        '*exclusionGroupAssignmentTarget' {
            if ($groupId) {
                if ($GroupLookup.ContainsKey($groupId)) { "Exclude Group: $($GroupLookup[$groupId])" }
                else { "ExcludeGroupId: $groupId" }
            } else { 'Exclude Group (unknown)' }
        }
        default { if ($odataType) { $odataType -replace '^#microsoft\.graph\.', '' } else { 'UnknownTarget' } }
    }

    if ($filterId) {
        return "$base [Filter:${filterType}:$filterId]"
    }
    return $base
}

function Get-PolicyAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl
    )
    return @(Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/configurationPolicies?`$select=id,name" -Token $Token)
}

function Get-AssignmentAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl
    )

    $groupLookup = Get-GroupLookup -Token $Token -BaseUrl $BaseUrl
    $policies = Get-PolicyAssignments -Token $Token -BaseUrl $BaseUrl
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $unassigned = [System.Collections.Generic.List[hashtable]]::new()
    $dead = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($p in $policies) {
        $assignments = @()
        try {
            $assignments = @(Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/configurationPolicies/$($p.id)/assignments" -Token $Token)
        }
        catch {
            Write-Verbose "Assignment analysis: failed assignments lookup for '$($p.name)'."
        }

        if ($assignments.Count -eq 0) {
            $unassigned.Add([ordered]@{
                PolicyId = "$($p.id)"
                PolicyName = "$($p.name)"
            })
            $rows.Add([ordered]@{
                PolicyId = "$($p.id)"
                PolicyName = "$($p.name)"
                AssignmentCount = 0
                Targets = ''
                HasIncludeTarget = $false
                HasExcludeOnly = $false
                IsUnassigned = $true
                IsPotentiallyDead = $true
            })
            continue
        }

        $targets = [System.Collections.Generic.List[string]]::new()
        $hasIncludeTarget = $false
        $hasExcludeOnly = $true
        foreach ($a in $assignments) {
            if (-not $a.PSObject.Properties['target'] -or $null -eq $a.target) { continue }
            $targets.Add((Resolve-AssignmentTargetText -Target $a.target -GroupLookup $groupLookup))
            $tt = if ($a.target.PSObject.Properties['@odata.type']) { "$($a.target.'@odata.type')" } else { '' }
            if ($tt -notlike '*exclusionGroupAssignmentTarget') {
                $hasIncludeTarget = $true
                $hasExcludeOnly = $false
            }
        }

        $isPotentiallyDead = (-not $hasIncludeTarget) -or $hasExcludeOnly
        if ($isPotentiallyDead) {
            $dead.Add([ordered]@{
                PolicyId = "$($p.id)"
                PolicyName = "$($p.name)"
                Reason = if ($hasExcludeOnly) { 'Exclude-only assignments' } else { 'No include targets' }
            })
        }

        $rows.Add([ordered]@{
            PolicyId = "$($p.id)"
            PolicyName = "$($p.name)"
            AssignmentCount = $assignments.Count
            Targets = (@($targets | Select-Object -Unique) -join ' | ')
            HasIncludeTarget = $hasIncludeTarget
            HasExcludeOnly = $hasExcludeOnly
            IsUnassigned = $false
            IsPotentiallyDead = $isPotentiallyDead
        })
    }

    return @{
        PolicyAssignmentSummary = @($rows | Sort-Object PolicyName)
        UnassignedPolicies = @($unassigned | Sort-Object PolicyName)
        PotentiallyDeadPolicies = @($dead | Sort-Object PolicyName)
        Summary = [ordered]@{
            TotalPolicies = $policies.Count
            UnassignedPolicyCount = $unassigned.Count
            PotentiallyDeadPolicyCount = $dead.Count
        }
    }
}

Export-ModuleMember -Function @(
    'Get-AssignmentAnalysis'
)

