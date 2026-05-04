# =============================================================================
# AdminTemplateReader.psm1 — Reads and normalises Intune Admin Template
#                             (Group Policy Configuration) policies (Sprint 2)
#
# Graph endpoints:
#   GET /deviceManagement/groupPolicyConfigurations                     — list
#   GET /deviceManagement/groupPolicyConfigurations/{id}/definitionValues
#         ?$expand=definition,presentationValues                        — values
#   GET /deviceManagement/groupPolicyDefinitions/{id}                   — fallback
#   GET /deviceManagement/groupPolicyConfigurations/{id}/definitionValues/{dvId}/presentationValues
#                                                                        — fallback
#
# Each setting is returned as a hashtable using the same schema as PolicyReader:
#   PolicyName     — GP configuration display name
#   PolicyTemplate — "Admin Templates"
#   SettingPath    — "{categoryPath} > {displayName}" (/ replaced with " > ")
#   CategoryId     — definition.category.id (GUID — enables byCategoryGuid mapping)
#   Value          — "Enabled"/"Disabled" + appended presentation values
#                    e.g. "Enabled; Minimum PIN length: 6; Enhanced PIN: true"
#   Description    — definition.explainText
#   DefinitionId   — "admx:{definition.id}" (comparison key)
#   Domain         — populated later by Enrichment.psm1
# =============================================================================

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Local fallback cache — used when DefinitionCache.psm1 has not been
# initialised, or for ADMX definitions not present in the global catalog.
# ---------------------------------------------------------------------------
$script:AdmxDefinitionCache = [System.Collections.Generic.Dictionary[string, object]]::new()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-AdminTemplatePolicies {
    <#
    .SYNOPSIS
        Fetches all Admin Template (Group Policy Configuration) policies from a
        tenant and returns a flat list of normalised setting objects.
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

    Write-Host "    Fetching Admin Template policy list..." -ForegroundColor DarkGray
    $policies = Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/groupPolicyConfigurations" -Token $Token
    Write-Host "    Found $($policies.Count) Admin Template policies." -ForegroundColor DarkGray

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
            -Activity        'Reading Admin Templates' `
            -Status          "[$i/$($policies.Count)] $($policy.displayName)" `
            -PercentComplete ([Math]::Round($i / $policies.Count * 100))

        $defValues = Get-AdmxDefinitionValues -PolicyId $policy.id -Token $Token -BaseUrl $BaseUrl

        $shared = Test-DefinitionCacheReady
        foreach ($dv in $defValues) {
            # Get definition — prefer embedded expand, fall back to cache/API
            $def = $null
            if ($dv.PSObject.Properties['definition'] -and $dv.definition) {
                $def = $dv.definition
                # Populate both caches while we have the inline definition
                if ($def.PSObject.Properties['id'] -and $def.id) {
                    if (-not $script:AdmxDefinitionCache.ContainsKey($def.id)) {
                        $script:AdmxDefinitionCache[$def.id] = $def
                    }
                    if ($shared) {
                        Add-CachedDefinition -Kind 'Admx' -Id $def.id -Definition $def
                    }
                }
            }
            elseif ($dv.PSObject.Properties['definitionId'] -and $dv.definitionId) {
                $def = Get-AdmxDefinition -DefinitionId $dv.definitionId -Token $Token -BaseUrl $BaseUrl
            }

            if ($null -eq $def) { continue }

            # Get presentation values — prefer embedded expand, fall back to separate call
            $presValues = @()
            if ($dv.PSObject.Properties['presentationValues'] -and $dv.presentationValues) {
                $presValues = @($dv.presentationValues | Where-Object { $_ })
            }
            elseif ($dv.PSObject.Properties['id'] -and $dv.id) {
                $presValues = Get-AdmxPresentationValues `
                    -PolicyId $policy.id -DefinitionValueId $dv.id `
                    -Token $Token -BaseUrl $BaseUrl
            }

            $categoryId  = Get-AdmxCategoryId -Definition $def
            $settingPath = Format-AdmxSettingPath -Definition $def
            $value       = Resolve-AdmxValue -DefinitionValue $dv -PresentationValues $presValues
            $description = if ($def.PSObject.Properties['explainText'] -and $def.explainText) {
                               $def.explainText
                           } else { '' }

            $allSettings.Add([ordered]@{
                PolicyName     = $policy.displayName
                PolicyTemplate = 'Admin Templates'
                SettingPath    = $settingPath
                CategoryId     = $categoryId
                Value          = $value
                Description    = $description
                DefinitionId   = "admx:$($def.id)"
                Domain         = ''
            })
        }
    }

    Write-Progress -Activity 'Reading Admin Templates' -Completed
    Write-Host "    Normalised $($allSettings.Count) settings from $($policies.Count) policies." -ForegroundColor DarkGray

    return $allSettings
}

function Reset-AdminTemplateCache {
    <#
    .SYNOPSIS
        Clears the in-memory ADMX definition cache.
    #>
    $script:AdmxDefinitionCache.Clear()
    Write-Verbose "AdminTemplateReader: definition cache cleared."
}

# ---------------------------------------------------------------------------
# Internal — definition value retrieval
# ---------------------------------------------------------------------------

function Get-AdmxDefinitionValues {
    <#
    Fetches definition values for a GP configuration policy.
    Attempts combined $expand; falls back to plain list if the API rejects it.
    #>
    param([string]$PolicyId, [string]$Token, [string]$BaseUrl)

    $expandUrl = "$BaseUrl/deviceManagement/groupPolicyConfigurations/$PolicyId/definitionValues?`$expand=definition,presentationValues"

    try {
        return @(Get-GraphPagedResults -Uri $expandUrl -Token $Token)
    }
    catch {
        Write-Verbose "  ADMX expand failed for policy '$PolicyId', retrying without expand: $_"
    }

    # Fallback: fetch without expand
    $plainUrl = "$BaseUrl/deviceManagement/groupPolicyConfigurations/$PolicyId/definitionValues"
    try {
        return @(Get-GraphPagedResults -Uri $plainUrl -Token $Token)
    }
    catch {
        Write-Verbose "  Could not fetch ADMX definition values for policy '$PolicyId': $_"
        return @()
    }
}

function Get-AdmxDefinition {
    param([string]$DefinitionId, [string]$Token, [string]$BaseUrl)

    # Shared cache first — eliminates per-ID Graph requests when initialised
    if (Test-DefinitionCacheReady) {
        $shared = Get-CachedAdmxDefinition -DefinitionId $DefinitionId
        if ($null -ne $shared) { return $shared }
    }

    # Local fallback
    if ($script:AdmxDefinitionCache.ContainsKey($DefinitionId)) {
        return $script:AdmxDefinitionCache[$DefinitionId]
    }

    # Last resort: per-ID API call
    try {
        $def = Invoke-IbaGraphRequest `
            -Uri   "$BaseUrl/deviceManagement/groupPolicyDefinitions/$DefinitionId" `
            -Token $Token
        $script:AdmxDefinitionCache[$DefinitionId] = $def
        if ($null -ne $def -and (Test-DefinitionCacheReady)) {
            Add-CachedDefinition -Kind 'Admx' -Id $DefinitionId -Definition $def
        }
        return $def
    }
    catch {
        Write-Verbose "  ADMX definition not found '$DefinitionId': $_"
        $script:AdmxDefinitionCache[$DefinitionId] = $null
        return $null
    }
}

function Get-AdmxPresentationValues {
    param([string]$PolicyId, [string]$DefinitionValueId, [string]$Token, [string]$BaseUrl)

    $url = "$BaseUrl/deviceManagement/groupPolicyConfigurations/$PolicyId/definitionValues/$DefinitionValueId/presentationValues"
    try {
        return @(Get-GraphPagedResults -Uri $url -Token $Token)
    }
    catch {
        Write-Verbose "  Could not fetch presentation values for '$DefinitionValueId': $_"
        return @()
    }
}

# ---------------------------------------------------------------------------
# Internal — value and path helpers
# ---------------------------------------------------------------------------

function Get-AdmxCategoryId {
    param($Definition)

    if ($Definition.PSObject.Properties['category'] -and $Definition.category) {
        if ($Definition.category.PSObject.Properties['id'] -and $Definition.category.id) {
            return $Definition.category.id
        }
    }
    return ''
}

function Format-AdmxSettingPath {
    <#
    Builds a readable setting path from the definition.
    Input:  categoryPath = "Windows Components/BitLocker Drive Encryption/Operating System Drives"
            displayName  = "Require additional authentication at startup"
    Output: "Windows Components > BitLocker Drive Encryption > Operating System Drives > Require additional authentication at startup"
    #>
    param($Definition)

    $displayName = if ($Definition.PSObject.Properties['displayName'] -and $Definition.displayName) {
                       $Definition.displayName
                   } else { 'Unknown Setting' }

    if ($Definition.PSObject.Properties['categoryPath'] -and $Definition.categoryPath) {
        $normalizedPath = $Definition.categoryPath -replace '/', ' > '
        return "$normalizedPath > $displayName"
    }

    # Fallback: category display name + setting name
    if ($Definition.PSObject.Properties['category'] -and $Definition.category -and
        $Definition.category.PSObject.Properties['displayName'] -and $Definition.category.displayName) {
        return "$($Definition.category.displayName) > $displayName"
    }

    return $displayName
}

function Resolve-AdmxValue {
    <#
    Builds a human-readable value string from a definitionValue and its
    optional presentation sub-values.

    Examples:
      "Enabled"
      "Disabled"
      "Enabled; Minimum PIN length: 6"
      "Enabled; Startup authentication required: true; Startup authentication required on compatible TPM only: false"
    #>
    param($DefinitionValue, $PresentationValues)

    $enabled = if ($DefinitionValue.PSObject.Properties['enabled']) { [bool]$DefinitionValue.enabled } else { $false }
    $base    = if ($enabled) { 'Enabled' } else { 'Disabled' }

    if ($null -eq $PresentationValues -or $PresentationValues.Count -eq 0) {
        return $base
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($pv in $PresentationValues) {
        $label = 'Value'
        if ($pv.PSObject.Properties['presentation'] -and $pv.presentation -and
            $pv.presentation.PSObject.Properties['label'] -and $pv.presentation.label) {
            $label = $pv.presentation.label
        }

        $val = $null
        if ($pv.PSObject.Properties['value'] -and $null -ne $pv.value) {
            $val = "$($pv.value)"
        }
        elseif ($pv.PSObject.Properties['values'] -and $pv.values) {
            $val = ($pv.values | ForEach-Object { "$_" }) -join ', '
        }

        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $parts.Add("${label}: ${val}")
        }
    }

    if ($parts.Count -gt 0) {
        return "$base; " + ($parts -join '; ')
    }
    return $base
}

Export-ModuleMember -Function @(
    'Get-AdminTemplatePolicies',
    'Reset-AdminTemplateCache'
)
