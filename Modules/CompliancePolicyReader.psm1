# =============================================================================
# CompliancePolicyReader.psm1 — Reads and normalises Intune Compliance Policies
#                                (Sprint 4)
#
# Graph endpoints:
#   GET /deviceManagement/deviceCompliancePolicies          — list policies
#   GET /deviceManagement/deviceCompliancePolicies/{id}     — full policy object
#
# Compliance policies store settings as typed object properties (same pattern
# as Device Configuration). Settings are non-null properties of the policy
# object, excluding metadata and action/status fields.
#
# Each setting is returned as a hashtable using the standard schema:
#   PolicyName     — policy display name
#   PolicyTemplate — "Compliance Policy"
#   SettingPath    — "{policyName} > {Title Case property name}"
#   CategoryId     — "cp:{shortOdataType}" (e.g. "cp:windows10CompliancePolicy")
#   Value          — string representation of the configured value
#   Description    — empty (no definition endpoint for typed compliance policies)
#   DefinitionId   — "cp:{shortOdataType}:{propertyName}" (comparison key)
#   Domain         — populated later by Enrichment.psm1
# =============================================================================

Set-StrictMode -Version Latest

# Properties that are metadata or action/status fields — always skip these
$script:CpSkipProperties = [System.Collections.Generic.HashSet[string]](
    [System.StringComparer]::OrdinalIgnoreCase
)
@(
    '@odata.type', '@odata.context', '@odata.etag',
    'id', 'displayName', 'description',
    'createdDateTime', 'lastModifiedDateTime', 'version',
    'roleScopeTagIds', 'supportsScopeTags',
    'deviceManagementApplicabilityRuleOsEdition',
    'deviceManagementApplicabilityRuleOsVersion',
    'deviceManagementApplicabilityRuleDeviceMode',
    'scheduledActionsForRule', 'scheduledActionConfigurations',
    'assignments', 'deviceStatuses', 'userStatuses',
    'deviceStatusOverview', 'userStatusOverview',
    'deviceSettingStateSummaries'
) | ForEach-Object { [void]$script:CpSkipProperties.Add($_) }

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-CompliancePolicies {
    <#
    .SYNOPSIS
        Fetches all Compliance Policies from a tenant and returns a flat list
        of normalised setting objects.
    .PARAMETER Token
        Bearer access token for the target tenant.
    .PARAMETER BaseUrl
        Graph API base URL including version, e.g. https://graph.microsoft.com/beta
    .PARAMETER PolicyFilter
        Optional wildcard patterns applied to policy display names.
    .OUTPUTS
        System.Collections.Generic.List[hashtable]
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl,
        [string[]]             $PolicyFilter = @()
    )

    Write-Host "    Fetching Compliance Policy list..." -ForegroundColor DarkGray
    $policies = Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/deviceCompliancePolicies" -Token $Token
    Write-Host "    Found $($policies.Count) Compliance Policies." -ForegroundColor DarkGray

    if ($PolicyFilter.Count -gt 0) {
        $before   = $policies.Count
        $policies = @($policies | Where-Object {
            $name = $_.displayName
            $PolicyFilter | Where-Object { $name -like $_ }
        })
        Write-Host "    Policy filter applied: $before → $($policies.Count) policies." -ForegroundColor DarkGray
    }

    $allSettings = [System.Collections.Generic.List[hashtable]]::new()
    $i = 0

    foreach ($policy in $policies) {
        $i++
        Write-Progress `
            -Activity        'Reading Compliance Policies' `
            -Status          "[$i/$($policies.Count)] $($policy.displayName)" `
            -PercentComplete ([Math]::Round($i / $policies.Count * 100))

        # Fetch full policy object to guarantee all properties are returned
        $fullPolicy = $null
        try {
            $fullPolicy = Invoke-IbaGraphRequest `
                -Uri   "$BaseUrl/deviceManagement/deviceCompliancePolicies/$($policy.id)" `
                -Token $Token
        }
        catch {
            Write-Verbose "  Failed to fetch compliance policy '$($policy.displayName)': $_"
            continue
        }

        $rows = ConvertTo-CpFlatSettings -Policy $fullPolicy
        foreach ($row in @($rows)) { if ($null -ne $row) { $allSettings.Add($row) } }
    }

    Write-Progress -Activity 'Reading Compliance Policies' -Completed
    Write-Host "    Normalised $($allSettings.Count) settings from $($policies.Count) policies." -ForegroundColor DarkGray

    return $allSettings
}

function Reset-CompliancePolicyCache {
    <#
    .SYNOPSIS
        No-op — CompliancePolicyReader has no in-memory caches.
        Included for API consistency with other readers.
    #>
    Write-Verbose "CompliancePolicyReader: no caches to clear."
}

# ---------------------------------------------------------------------------
# Internal — policy flattener
# ---------------------------------------------------------------------------

function ConvertTo-CpFlatSettings {
    param($Policy)

    $results   = [System.Collections.Generic.List[hashtable]]::new()
    $odataType = if ($Policy.PSObject.Properties['@odata.type']) { $Policy.'@odata.type' } else { $null }
    if ([string]::IsNullOrWhiteSpace($odataType)) { return $results }

    $shortType = $odataType -replace '^#microsoft\.graph\.', ''

    foreach ($prop in $Policy.PSObject.Properties) {
        if ($script:CpSkipProperties.Contains($prop.Name)) { continue }
        if ($null -eq $prop.Value) { continue }

        $value = ConvertTo-CpSettingValue -RawValue $prop.Value
        if ($null -eq $value) { continue }

        $results.Add([ordered]@{
            PolicyName     = $Policy.displayName
            PolicyTemplate = 'Compliance Policy'
            SettingPath    = "$($Policy.displayName) > $(Convert-CpCamelCaseToTitle -Name $prop.Name)"
            CategoryId     = "cp:$shortType"
            Value          = $value
            Description    = ''
            DefinitionId   = "cp:${shortType}:$($prop.Name)"
            Domain         = ''
        })
    }

    return $results
}

# ---------------------------------------------------------------------------
# Internal — value helpers
# ---------------------------------------------------------------------------

function ConvertTo-CpSettingValue {
    param($RawValue)

    if ($null -eq $RawValue) { return $null }

    if ($RawValue -is [bool]) {
        if ($RawValue) { return 'true' } else { return 'false' }
    }

    if ($RawValue -is [int] -or $RawValue -is [long] -or $RawValue -is [double]) {
        return "$RawValue"
    }

    if ($RawValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($RawValue)) { return $null } else { return $RawValue }
    }

    if ($RawValue -is [System.Object[]]) {
        if ($RawValue.Count -eq 0) { return $null }
        $items = foreach ($el in $RawValue) {
            if ($el -is [string] -or $el -is [int] -or $el -is [bool]) { "$el" }
            else { $el | ConvertTo-Json -Compress -Depth 3 }
        }
        return $items -join ', '
    }

    # PSCustomObject — nested object (serialise compactly)
    return $RawValue | ConvertTo-Json -Compress -Depth 3
}

function Convert-CpCamelCaseToTitle {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }

    $spaced = $Name -creplace '(?<=[a-z0-9])(?=[A-Z])', ' '
    $spaced = $spaced -creplace '(?<=[A-Z])(?=[A-Z][a-z])', ' '

    return (Get-Culture).TextInfo.ToTitleCase($spaced.ToLower())
}

Export-ModuleMember -Function @(
    'Get-CompliancePolicies',
    'Reset-CompliancePolicyCache'
)
