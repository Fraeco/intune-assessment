# =============================================================================
# PolicyReader.psm1 — Reads and normalises Intune Settings Catalog policies
#
# Sprint 1 scope: configurationPolicies (Settings Catalog) only.
# Later sprints add: intents (Endpoint Security), deviceConfigurations,
#                    groupPolicyConfigurations, compliancePolicies.
#
# Each setting is returned as a hashtable with these keys:
#   PolicyName     — display name of the Intune policy
#   PolicyTemplate — "Settings Catalog" (Sprint 1)
#   SettingPath    — human-readable path, e.g. "BitLocker > Require Device Encryption"
#   CategoryId     — leaf category GUID (written to Baseline/Comparison Category column)
#   Value          — string representation of the configured value
#   Description    — setting description from Graph definition
#   DefinitionId   — raw settingDefinitionId (used as comparison key)
#   Domain         — populated by Enrichment.psm1 (empty here)
# =============================================================================

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# In-memory caches (survive the life of the PowerShell session)
# ---------------------------------------------------------------------------
$script:DefinitionCache = [System.Collections.Generic.Dictionary[string, object]]::new()
$script:CategoryCache   = [System.Collections.Generic.Dictionary[string, object]]::new()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-SettingsCatalogPolicies {
    <#
    .SYNOPSIS
        Fetches all Settings Catalog policies from a tenant and returns a flat
        list of normalised setting objects.
    .PARAMETER Token
        Bearer access token for the target tenant.
    .PARAMETER BaseUrl
        Graph API base URL including version, e.g. https://graph.microsoft.com/beta
    .PARAMETER PolicyFilter
        Optional array of wildcard patterns. Only policies whose names match at
        least one pattern are processed. Wildcards (* ?) are supported.
        Example: @('SBZ-Win-L1-*', 'SBZ-Win-Custom-*')
        Leave empty (default) to include all policies.
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

    Write-Host "    Fetching Settings Catalog policy list..." -ForegroundColor DarkGray
    $policiesUrl = "$BaseUrl/deviceManagement/configurationPolicies"
    $policies    = Get-GraphPagedResults -Uri $policiesUrl -Token $Token
    Write-Host "    Found $($policies.Count) Settings Catalog policies." -ForegroundColor DarkGray

    # Apply name filter (client-side; Graph API does not support wildcard $filter on name)
    if ($PolicyFilter.Count -gt 0) {
        $before   = $policies.Count
        $policies = @($policies | Where-Object {
            $name = $_.name
            $PolicyFilter | Where-Object { $name -like $_ }
        })
        Write-Host "    Policy filter applied ($($PolicyFilter -join ', ')): $before → $($policies.Count) policies." -ForegroundColor DarkGray
    }

    $allSettings = [System.Collections.Generic.List[hashtable]]::new()
    $i = 0

    foreach ($policy in $policies) {
        $i++
        $pct = [Math]::Round($i / $policies.Count * 100)
        Write-Progress `
            -Activity        "Reading Settings Catalog" `
            -Status          "[$i/$($policies.Count)] $($policy.name)" `
            -PercentComplete $pct

        $rawSettings = Get-PolicySettings -PolicyId $policy.id -Token $Token -BaseUrl $BaseUrl

        foreach ($raw in $rawSettings) {
            if ($null -eq $raw.settingInstance) { continue }
            $flattened = ConvertTo-FlatSettings `
                -SettingInstance $raw.settingInstance `
                -Token           $Token `
                -BaseUrl         $BaseUrl `
                -PolicyName      $policy.name `
                -PolicyTemplate  'Settings Catalog' `
                -PathPrefix      ''
            foreach ($item in @($flattened)) { if ($null -ne $item) { $allSettings.Add($item) } }
        }
    }

    Write-Progress -Activity "Reading Settings Catalog" -Completed
    Write-Host "    Normalised $($allSettings.Count) settings from $($policies.Count) policies." -ForegroundColor DarkGray

    return $allSettings
}

function Reset-PolicyReaderCache {
    <#
    .SYNOPSIS
        Clears the in-memory definition and category caches.
        Useful when switching tenants within the same session.
    #>
    $script:DefinitionCache.Clear()
    $script:CategoryCache.Clear()
    Write-Verbose "PolicyReader: definition and category caches cleared."
}

# ---------------------------------------------------------------------------
# Internal — policy settings retrieval
# ---------------------------------------------------------------------------

function Get-PolicySettings {
    param(
        [string]$PolicyId,
        [string]$Token,
        [string]$BaseUrl
    )
    $url = "$BaseUrl/deviceManagement/configurationPolicies/$PolicyId/settings"
    return Get-GraphPagedResults -Uri $url -Token $Token
}

# ---------------------------------------------------------------------------
# Internal — recursive setting flattener
# ---------------------------------------------------------------------------

function ConvertTo-FlatSettings {
    <#
    Recursively walks a settingInstance and its children, emitting one
    hashtable per leaf/parent setting with a scalar value.
    $PathPrefix is the accumulated display path from parent settings.
    #>
    param(
        $SettingInstance,
        [string]$Token,
        [string]$BaseUrl,
        [string]$PolicyName,
        [string]$PolicyTemplate,
        [string]$PathPrefix          # parent path built so far (empty for top-level)
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()
    if ($null -eq $SettingInstance) { return $results }

    $defId = $SettingInstance.settingDefinitionId
    if ([string]::IsNullOrWhiteSpace($defId)) { return $results }

    # Resolve definition for display name, description, category
    $def         = Get-SettingDefinition -DefinitionId $defId -Token $Token -BaseUrl $BaseUrl
    $displayName = if ($def -and $def.displayName) { $def.displayName } else { Format-DefinitionId $defId }
    $description = if ($def -and $def.description) { $def.description } else { '' }
    $categoryId  = if ($def -and $def.categoryId)  { $def.categoryId  } else { '' }

    # Build category-prefixed path for this setting
    $settingPath = if ($PathPrefix) {
        "$PathPrefix > $displayName"
    } else {
        # Top-level: prepend category display name
        $catPath = Get-CategoryPath -CategoryId $categoryId -Token $Token -BaseUrl $BaseUrl
        if ($catPath) { "$catPath > $displayName" } else { $displayName }
    }

    # Extract value and inline children depending on instance type
    $odataType = $SettingInstance.'@odata.type'
    $value     = $null
    $inlineChildren = @()

    switch -Wildcard ($odataType) {

        '*ChoiceSettingInstance' {
            $cv = $SettingInstance.choiceSettingValue
            $value = Resolve-ChoiceLabel -RawValue $cv.value -Definition $def
            $inlineChildren = @($cv.children | Where-Object { $_ })
        }

        '*SimpleSettingInstance' {
            $sv = $SettingInstance.simpleSettingValue
            $value = if ($null -ne $sv) { "$($sv.value)" } else { '' }
        }

        '*SimpleSettingCollectionInstance' {
            $value = ($SettingInstance.simpleSettingCollectionValue |
                      Where-Object { $_ } |
                      ForEach-Object { "$($_.value)" }) -join ', '
        }

        '*ChoiceSettingCollectionInstance' {
            $resolved = $SettingInstance.choiceSettingCollectionValue |
                        Where-Object { $_ } |
                        ForEach-Object { Resolve-ChoiceLabel -RawValue $_.value -Definition $def }
            $value = $resolved -join ', '
        }

        '*GroupSettingCollectionInstance' {
            # Group settings have no scalar value themselves; all data is in children
            foreach ($group in $SettingInstance.groupSettingCollectionValue) {
                foreach ($child in ($group.children | Where-Object { $_ })) {
                    $nested = ConvertTo-FlatSettings `
                        -SettingInstance $child `
                        -Token           $Token `
                        -BaseUrl         $BaseUrl `
                        -PolicyName      $PolicyName `
                        -PolicyTemplate  $PolicyTemplate `
                        -PathPrefix      $settingPath
                    foreach ($item in @($nested)) { if ($null -ne $item) { $results.Add($item) } }
                }
            }
            # No scalar row for the group container itself
            return $results
        }

        default {
            Write-Verbose "  Unknown settingInstance type '$odataType' for definition '$defId' — skipping value."
            $value = $null
        }
    }

    # Emit a row for this setting if it has a value
    if ($null -ne $value) {
        $results.Add([ordered]@{
            PolicyName     = $PolicyName
            PolicyTemplate = $PolicyTemplate
            SettingPath    = $settingPath
            CategoryId     = $categoryId
            Value          = "$value"
            Description    = $description
            DefinitionId   = $defId
            Domain         = ''      # populated later by Enrichment.psm1
        })
    }

    # Process inline children (from choice value children)
    foreach ($child in $inlineChildren) {
        $nested = ConvertTo-FlatSettings `
            -SettingInstance $child `
            -Token           $Token `
            -BaseUrl         $BaseUrl `
            -PolicyName      $PolicyName `
            -PolicyTemplate  $PolicyTemplate `
            -PathPrefix      $settingPath
        foreach ($item in @($nested)) { if ($null -ne $item) { $results.Add($item) } }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Internal — setting definition lookup (with cache)
# ---------------------------------------------------------------------------

function Get-SettingDefinition {
    param(
        [string]$DefinitionId,
        [string]$Token,
        [string]$BaseUrl
    )

    if ($script:DefinitionCache.ContainsKey($DefinitionId)) {
        return $script:DefinitionCache[$DefinitionId]
    }

    try {
        $encoded = [Uri]::EscapeDataString($DefinitionId)
        $url     = "$BaseUrl/deviceManagement/configurationSettings/$encoded"
        $def     = Invoke-IbaGraphRequest -Uri $url -Token $Token
        $script:DefinitionCache[$DefinitionId] = $def
        return $def
    }
    catch {
        Write-Verbose "  Definition not found for '$DefinitionId': $_"
        $script:DefinitionCache[$DefinitionId] = $null
        return $null
    }
}

# ---------------------------------------------------------------------------
# Internal — category hierarchy path (recursive, with cache)
# ---------------------------------------------------------------------------

function Get-CategoryPath {
    <#
    Walks up the category parent chain and returns a display path like
    "Administrative Templates > Windows Components > BitLocker Drive Encryption".
    Root categories (parentCategoryId = $null) are excluded from the path.
    #>
    param(
        [string]$CategoryId,
        [string]$Token,
        [string]$BaseUrl,
        [int]   $Depth    = 0,
        [int]   $MaxDepth = 8
    )

    if ([string]::IsNullOrWhiteSpace($CategoryId) -or $Depth -ge $MaxDepth) {
        return ''
    }

    $cat = Get-CategoryInfo -CategoryId $CategoryId -Token $Token -BaseUrl $BaseUrl
    if ($null -eq $cat) { return '' }

    # Root categories have no parent — omit them from the displayed path
    if ([string]::IsNullOrWhiteSpace($cat.parentCategoryId)) {
        return ''
    }

    $parentPath = Get-CategoryPath `
        -CategoryId $cat.parentCategoryId `
        -Token      $Token `
        -BaseUrl    $BaseUrl `
        -Depth      ($Depth + 1) `
        -MaxDepth   $MaxDepth

    if ($parentPath) {
        return "$parentPath > $($cat.displayName)"
    } else {
        return $cat.displayName
    }
}

function Get-CategoryInfo {
    param(
        [string]$CategoryId,
        [string]$Token,
        [string]$BaseUrl
    )

    if ($script:CategoryCache.ContainsKey($CategoryId)) {
        return $script:CategoryCache[$CategoryId]
    }

    try {
        $url = "$BaseUrl/deviceManagement/configurationCategories/$CategoryId"
        $cat = Invoke-IbaGraphRequest -Uri $url -Token $Token
        $script:CategoryCache[$CategoryId] = $cat
        return $cat
    }
    catch {
        Write-Verbose "  Category not found for '$CategoryId': $_"
        $script:CategoryCache[$CategoryId] = $null
        return $null
    }
}

# ---------------------------------------------------------------------------
# Internal — value display helpers
# ---------------------------------------------------------------------------

function Resolve-ChoiceLabel {
    <#
    Resolves a raw Graph choice value like
    "device_vendor_msft_bitlocker_requiredeviceencryption_1" to its display
    label "Enabled" by looking up the option in the setting definition.
    Falls back to stripping the settingDefinitionId prefix.
    #>
    param(
        [string]$RawValue,
        $Definition
    )

    if ([string]::IsNullOrWhiteSpace($RawValue)) { return '' }

    if ($Definition -and $Definition.options) {
        $match = $Definition.options |
                 Where-Object { $_.itemId -eq $RawValue } |
                 Select-Object -First 1
        if ($match) { return $match.displayName }
    }

    # Fallback: strip the settingDefinitionId prefix (everything up to last underscore block)
    return Format-DefinitionId $RawValue
}

function Format-DefinitionId {
    <#
    Converts a raw definition ID / choice item ID into a readable label.
    "device_vendor_msft_bitlocker_requiredeviceencryption_1" → "1"
    Strips the vendor/msft prefix block, then title-cases the remainder.
    #>
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) { return $Id }

    # Strip "device_vendor_msft_<component>_" or "user_vendor_msft_<component>_" prefix
    $cleaned = $Id -replace '^(device|user)_vendor_msft_[^_]+_', ''
    # Replace underscores with spaces and title-case
    $cleaned = $cleaned -replace '_', ' '
    $cleaned = (Get-Culture).TextInfo.ToTitleCase($cleaned.ToLower())
    return $cleaned
}

Export-ModuleMember -Function @(
    'Get-SettingsCatalogPolicies',
    'Reset-PolicyReaderCache'
)
