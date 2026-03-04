# =============================================================================
# DeviceConfigReader.psm1 — Reads and normalises Intune Device Configuration
#                            profiles (Sprint 2)
#
# Graph endpoints:
#   GET /deviceManagement/deviceConfigurations            — list profiles
#   GET /deviceManagement/deviceConfigurations/{id}       — full profile object
#
# Device Configuration profiles store settings as typed object properties
# rather than separate setting instances. Settings are non-null properties
# of the profile object (excluding metadata fields).
#
# Each setting is returned as a hashtable using the same schema as PolicyReader:
#   PolicyName     — profile display name
#   PolicyTemplate — "Device Configuration"
#   SettingPath    — "{profileName} > {Title Case property name}"
#   CategoryId     — "dc:{shortOdataType}" (e.g. "dc:windows10GeneralConfiguration")
#   Value          — string representation of the configured value
#   Description    — empty (no definition endpoint for typed DC profiles)
#   DefinitionId   — "dc:{shortOdataType}:{propertyName}" (comparison key)
#   Domain         — populated later by Enrichment.psm1
# =============================================================================

Set-StrictMode -Version Latest

# Properties that are metadata, not configurable settings — always skip these
$script:DcSkipProperties = [System.Collections.Generic.HashSet[string]](
    [System.StringComparer]::OrdinalIgnoreCase
)
@(
    '@odata.type', '@odata.context', '@odata.etag',
    'id', 'displayName', 'description',
    'createdDateTime', 'lastModifiedDateTime', 'version',
    'roleScopeTagIds', 'supportsScopeTags',
    'deviceManagementApplicabilityRuleOsEdition',
    'deviceManagementApplicabilityRuleOsVersion',
    'deviceManagementApplicabilityRuleDeviceMode'
) | ForEach-Object { [void]$script:DcSkipProperties.Add($_) }

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-DeviceConfigPolicies {
    <#
    .SYNOPSIS
        Fetches all Device Configuration profiles from a tenant and returns a
        flat list of normalised setting objects.
    .PARAMETER Token
        Bearer access token for the target tenant.
    .PARAMETER BaseUrl
        Graph API base URL including version, e.g. https://graph.microsoft.com/beta
    .PARAMETER PolicyFilter
        Optional wildcard patterns applied to profile display names.
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

    Write-Host "    Fetching Device Configuration profile list..." -ForegroundColor DarkGray
    $profiles = Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/deviceConfigurations" -Token $Token
    Write-Host "    Found $($profiles.Count) Device Configuration profiles." -ForegroundColor DarkGray

    if ($PolicyFilter.Count -gt 0) {
        $before   = $profiles.Count
        $profiles = @($profiles | Where-Object {
            $name = $_.displayName
            $PolicyFilter | Where-Object { $name -like $_ }
        })
        Write-Host "    Policy filter applied: $before → $($profiles.Count) profiles." -ForegroundColor DarkGray
    }

    $allSettings = [System.Collections.Generic.List[hashtable]]::new()
    $i = 0

    foreach ($profile in $profiles) {
        $i++
        Write-Progress `
            -Activity        'Reading Device Configuration' `
            -Status          "[$i/$($profiles.Count)] $($profile.displayName)" `
            -PercentComplete ([Math]::Round($i / $profiles.Count * 100))

        # Fetch the full individual profile object to guarantee all properties are returned
        $fullProfile = $null
        try {
            $fullProfile = Invoke-IbaGraphRequest `
                -Uri   "$BaseUrl/deviceManagement/deviceConfigurations/$($profile.id)" `
                -Token $Token
        }
        catch {
            Write-Verbose "  Failed to fetch DC profile '$($profile.displayName)': $_"
            continue
        }

        $rows = ConvertTo-DcFlatSettings -Profile $fullProfile
        foreach ($row in @($rows)) { if ($null -ne $row) { $allSettings.Add($row) } }
    }

    Write-Progress -Activity 'Reading Device Configuration' -Completed
    Write-Host "    Normalised $($allSettings.Count) settings from $($profiles.Count) profiles." -ForegroundColor DarkGray

    return $allSettings
}

function Reset-DeviceConfigCache {
    <#
    .SYNOPSIS
        No-op — DeviceConfigReader has no in-memory caches.
        Included for API consistency with other readers.
    #>
    Write-Verbose "DeviceConfigReader: no caches to clear."
}

# ---------------------------------------------------------------------------
# Internal — profile flattener
# ---------------------------------------------------------------------------

function ConvertTo-DcFlatSettings {
    param($Profile)

    $results   = [System.Collections.Generic.List[hashtable]]::new()
    $odataType = if ($Profile.PSObject.Properties['@odata.type']) { $Profile.'@odata.type' } else { $null }
    if ([string]::IsNullOrWhiteSpace($odataType)) { return $results }

    $shortType = $odataType -replace '^#microsoft\.graph\.', ''

    # Special handling for custom OMA-URI configurations
    if ($shortType -eq 'windows10CustomConfiguration' -and
        $Profile.PSObject.Properties['omaSettings'] -and
        $Profile.omaSettings) {

        foreach ($oma in @($Profile.omaSettings | Where-Object { $_ })) {
            $value = $null
            if ($oma.PSObject.Properties['isEncrypted'] -and $oma.isEncrypted) {
                $value = '[Encrypted]'
            }
            elseif ($oma.PSObject.Properties['value'] -and $null -ne $oma.value) {
                $value = "$($oma.value)"
            }
            elseif ($oma.PSObject.Properties['valueBase64string'] -and $oma.valueBase64string) {
                $value = "[Base64: $($oma.valueBase64string)]"
            }

            if ([string]::IsNullOrWhiteSpace($value)) { continue }

            $omaUri = if ($oma.PSObject.Properties['omaUri'] -and $oma.omaUri) { $oma.omaUri } else { 'Unknown' }
            $safeUri = $omaUri -replace '[^a-zA-Z0-9_\-./]', '_'
            $desc    = if ($oma.PSObject.Properties['description'] -and $oma.description) { $oma.description } else { '' }
            $name    = if ($oma.PSObject.Properties['displayName'] -and $oma.displayName) { $oma.displayName } else { $omaUri }

            $results.Add([ordered]@{
                PolicyName     = $Profile.displayName
                PolicyTemplate = 'Device Configuration'
                SettingPath    = "$($Profile.displayName) > $name"
                CategoryId     = "dc:$shortType"
                Value          = $value
                Description    = $desc
                DefinitionId   = "dc:windows10CustomConfiguration:$safeUri"
                Domain         = ''
            })
        }
        return $results
    }

    # Generic typed profile — enumerate non-null, non-metadata properties
    foreach ($prop in $Profile.PSObject.Properties) {
        if ($script:DcSkipProperties.Contains($prop.Name)) { continue }
        if ($null -eq $prop.Value) { continue }

        $value = ConvertTo-DcSettingValue -RawValue $prop.Value
        if ($null -eq $value) { continue }

        $results.Add([ordered]@{
            PolicyName     = $Profile.displayName
            PolicyTemplate = 'Device Configuration'
            SettingPath    = "$($Profile.displayName) > $(Convert-CamelCaseToTitle -Name $prop.Name)"
            CategoryId     = "dc:$shortType"
            Value          = $value
            Description    = ''
            DefinitionId   = "dc:${shortType}:$($prop.Name)"
            Domain         = ''
        })
    }

    return $results
}

# ---------------------------------------------------------------------------
# Internal — value helpers
# ---------------------------------------------------------------------------

function ConvertTo-DcSettingValue {
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

function Convert-CamelCaseToTitle {
    <#
    Converts a camelCase property name to Title Case Words.
    "defenderMonitoringForIncomingAndOutgoingFilesAndPrograms"
      → "Defender Monitoring For Incoming And Outgoing Files And Programs"
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }

    # Insert space before an uppercase letter that follows a lowercase letter
    $spaced = $Name -creplace '(?<=[a-z0-9])(?=[A-Z])', ' '
    # Insert space before an uppercase letter that is followed by lowercase (e.g. "WLan" → "W Lan")
    $spaced = $spaced -creplace '(?<=[A-Z])(?=[A-Z][a-z])', ' '

    return (Get-Culture).TextInfo.ToTitleCase($spaced.ToLower())
}

Export-ModuleMember -Function @(
    'Get-DeviceConfigPolicies',
    'Reset-DeviceConfigCache'
)
