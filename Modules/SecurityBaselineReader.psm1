# =============================================================================
# SecurityBaselineReader.psm1 — Reads and normalises Microsoft-published
#                                Security Baselines (Sprint 4)
#
# Graph endpoints:
#   GET /deviceManagement/templates?$filter=templateType eq 'securityBaseline'
#   GET /deviceManagement/intents                              — list intents
#   GET /deviceManagement/intents/{id}/settings               — settings
#   GET /deviceManagement/templates/{templateId}              — template metadata
#   GET /deviceManagement/templates/{templateId}/settingDefinitions — definitions
#
# Security Baselines are a sub-type of the Endpoint Security intents surface
# but use templateType = 'securityBaseline'. Each baseline edition (e.g.
# "MDM Security Baseline for Windows 11 22H2") has a distinct templateId.
#
# Uses a distinct "sb:" DefinitionId prefix to avoid conflating with "es:"
# Endpoint Security intents in comparisons.
#
# Each setting is returned as a hashtable using the standard schema:
#   PolicyName     — intent display name
#   PolicyTemplate — "Security Baseline"
#   SettingPath    — "{templateDisplayName} > {definitionDisplayName}"
#   CategoryId     — "securityBaseline" (templateType string)
#   Value          — string representation of the configured value
#   Description    — from definition; empty if unavailable
#   DefinitionId   — "sb:{raw definitionId from Graph}" (comparison key)
#   Domain         — populated later by Enrichment.psm1
# =============================================================================

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# In-memory caches
# ---------------------------------------------------------------------------
$script:SbTemplateCache    = [System.Collections.Generic.Dictionary[string, object]]::new()
$script:SbDefinitionCache  = [System.Collections.Generic.Dictionary[string, object]]::new()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-SecurityBaselinePolicies {
    <#
    .SYNOPSIS
        Fetches all Security Baseline intent policies from a tenant and returns
        a flat list of normalised setting objects.
    .PARAMETER Token
        Bearer access token for the target tenant.
    .PARAMETER BaseUrl
        Graph API base URL including version, e.g. https://graph.microsoft.com/beta
    .PARAMETER PolicyFilter
        Optional wildcard patterns. Only intents whose displayName matches at
        least one pattern are processed. Leave empty to include all intents.
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

    # Step 1 — Discover Security Baseline templates
    Write-IbaLog -Level Debug -Message "    Discovering Security Baseline templates..."
    $sbTemplates = $null
    try {
        $sbTemplates = Get-GraphPagedResults `
            -Uri   "$BaseUrl/deviceManagement/templates?`$filter=templateType eq 'securityBaseline'" `
            -Token $Token
    }
    catch {
        Write-Warning "  Failed to fetch Security Baseline templates: $_"
        return [System.Collections.Generic.List[hashtable]]::new()
    }

    if ($sbTemplates.Count -eq 0) {
        Write-IbaLog -Level Debug -Message "    No Security Baseline templates found."
        return [System.Collections.Generic.List[hashtable]]::new()
    }

    $sbTemplateIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tmpl in $sbTemplates) {
        if ($tmpl.id) { [void]$sbTemplateIds.Add($tmpl.id) }
    }
    Write-IbaLog -Level Debug -Message "    Found $($sbTemplateIds.Count) Security Baseline templates."

    # Step 2 — Fetch all intents, filter to those referencing a SB template
    Write-IbaLog -Level Debug -Message "    Fetching intents for Security Baselines..."
    $allIntents = Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/intents" -Token $Token
    $intents = @($allIntents | Where-Object {
        $_.PSObject.Properties['templateId'] -and $sbTemplateIds.Contains($_.templateId)
    })
    Write-IbaLog -Level Debug -Message "    Found $($intents.Count) Security Baseline intents."

    if ($PolicyFilter.Count -gt 0) {
        $before  = $intents.Count
        $intents = @($intents | Where-Object {
            $name = $_.displayName
            $PolicyFilter | Where-Object { $name -like $_ }
        })
        Write-IbaLog -Level Debug -Message "    Policy filter applied: $before -> $($intents.Count) intents."
    }

    $allSettings = [System.Collections.Generic.List[hashtable]]::new()
    $i = 0

    foreach ($intent in $intents) {
        $i++
        Write-IbaProgress `
            -Activity        'Reading Security Baselines' `
            -Status          "[$i/$($intents.Count)] $($intent.displayName)" `
            -PercentComplete ([Math]::Round($i / $intents.Count * 100))

        # Template metadata and setting definitions (both cached by templateId)
        $template  = Get-SbTemplate    -TemplateId $intent.templateId -Token $Token -BaseUrl $BaseUrl
        $defLookup = Get-SbDefinitions -TemplateId $intent.templateId -Token $Token -BaseUrl $BaseUrl

        # Per-intent settings
        $rawSettings = Get-GraphPagedResults `
            -Uri   "$BaseUrl/deviceManagement/intents/$($intent.id)/settings" `
            -Token $Token

        foreach ($raw in $rawSettings) {
            $row = ConvertTo-SbFlatSetting `
                -Setting       $raw `
                -Template      $template `
                -DefLookup     $defLookup `
                -PolicyName    $intent.displayName
            if ($null -ne $row) { $allSettings.Add($row) }
        }
    }

    Write-IbaProgress -Activity 'Reading Security Baselines' -Completed
    Write-IbaLog -Level Debug -Message "    Normalised $($allSettings.Count) settings from $($intents.Count) intents."

    return $allSettings
}

function Reset-SecurityBaselineCache {
    <#
    .SYNOPSIS
        Clears the in-memory template and definition caches.
        Useful when switching tenants within the same session.
    #>
    $script:SbTemplateCache.Clear()
    $script:SbDefinitionCache.Clear()
    Write-Verbose "SecurityBaselineReader: caches cleared."
}

# ---------------------------------------------------------------------------
# Internal — template and definition retrieval (cached)
# ---------------------------------------------------------------------------

function Get-SbTemplate {
    param([string]$TemplateId, [string]$Token, [string]$BaseUrl)

    if ($script:SbTemplateCache.ContainsKey($TemplateId)) {
        return $script:SbTemplateCache[$TemplateId]
    }

    try {
        $tmpl = Invoke-IbaGraphRequest -Uri "$BaseUrl/deviceManagement/templates/$TemplateId" -Token $Token
        $script:SbTemplateCache[$TemplateId] = $tmpl
        return $tmpl
    }
    catch {
        Write-Verbose "  SB template not found '$TemplateId': $_"
        $script:SbTemplateCache[$TemplateId] = $null
        return $null
    }
}

function Get-SbDefinitions {
    <#
    Returns a Dictionary[string, object] keyed by definition id for O(1) lookup.
    #>
    param([string]$TemplateId, [string]$Token, [string]$BaseUrl)

    if ($script:SbDefinitionCache.ContainsKey($TemplateId)) {
        return $script:SbDefinitionCache[$TemplateId]
    }

    $lookup = [System.Collections.Generic.Dictionary[string, object]]::new()
    try {
        $defs = Get-GraphPagedResults `
            -Uri   "$BaseUrl/deviceManagement/templates/$TemplateId/settingDefinitions" `
            -Token $Token
        foreach ($d in $defs) { if ($d.id) { $lookup[$d.id] = $d } }
    }
    catch {
        Write-Verbose "  SB definitions not found for template '$TemplateId': $_"
    }

    $script:SbDefinitionCache[$TemplateId] = $lookup
    return $lookup
}

# ---------------------------------------------------------------------------
# Internal — setting conversion
# ---------------------------------------------------------------------------

function ConvertTo-SbFlatSetting {
    param(
        $Setting,
        $Template,
        [System.Collections.Generic.Dictionary[string, object]]$DefLookup,
        [string]$PolicyName
    )

    $defId = if ($Setting.PSObject.Properties['definitionId']) { $Setting.definitionId } else { $null }
    if ([string]::IsNullOrWhiteSpace($defId)) { return $null }

    # Look up definition for display name and description
    $def = $null
    if ($DefLookup.ContainsKey($defId)) { $def = $DefLookup[$defId] }

    $displayName   = if ($def -and $def.PSObject.Properties['displayName'] -and $def.displayName) {
                         $def.displayName
                     } else {
                         ($defId -split '--' | Select-Object -Last 1) -replace '_', ' '
                     }
    $description   = if ($def -and $def.PSObject.Properties['description'] -and $def.description) { $def.description } else { '' }
    $templateLabel = if ($Template -and $Template.PSObject.Properties['displayName'] -and $Template.displayName) { $Template.displayName } else { 'Security Baseline' }
    $templateType  = if ($Template -and $Template.PSObject.Properties['templateType'] -and $Template.templateType) { $Template.templateType } else { 'securityBaseline' }

    $value = Resolve-SbValue -Setting $Setting -Definition $def
    if ($null -eq $value) { return $null }

    return [ordered]@{
        PolicyName     = $PolicyName
        PolicyTemplate = 'Security Baseline'
        SettingPath    = "$templateLabel > $displayName"
        CategoryId     = $templateType
        Value          = $value
        Description    = $description
        DefinitionId   = "sb:$defId"
        Domain         = ''
    }
}

function Resolve-SbValue {
    <#
    Extracts a human-readable string value from a Security Baseline intent setting.
    Intent settings store their value as a JSON-encoded string in valueJson.
    Returns $null if the setting is not configured (null valueJson).
    #>
    param($Setting, $Definition)

    $valueJson = if ($Setting.PSObject.Properties['valueJson']) { $Setting.valueJson } else { $null }
    if ([string]::IsNullOrWhiteSpace($valueJson) -or $valueJson -eq 'null') { return $null }

    # Parse the JSON-encoded value
    try {
        $parsed = $valueJson | ConvertFrom-Json
    }
    catch {
        return "$valueJson"
    }

    if ($null -eq $parsed) { return $null }

    # Attempt to resolve choice label via EnumerationConstraint
    if ($Definition -and $Definition.PSObject.Properties['constraints']) {
        $enumC = @($Definition.constraints | Where-Object {
            $_ -and $_.'@odata.type' -like '*EnumerationConstraint'
        })
        if ($enumC.Count -gt 0 -and $enumC[0].PSObject.Properties['values']) {
            $rawStr = "$parsed"
            $match  = @($enumC[0].values | Where-Object { $_.value -eq $rawStr } | Select-Object -First 1)
            if ($match.Count -gt 0 -and $match[0].PSObject.Properties['displayName']) {
                return $match[0].displayName
            }
        }
    }

    # Scalar types
    if ($parsed -is [bool])   { if ($parsed) { return 'true' } else { return 'false' } }
    if ($parsed -is [int] -or $parsed -is [long] -or $parsed -is [double]) { return "$parsed" }
    if ($parsed -is [string]) { return $parsed }

    # Array
    if ($parsed -is [System.Object[]]) {
        if ($parsed.Count -eq 0) { return $null }
        $items = foreach ($el in $parsed) {
            if ($el -is [string] -or $el -is [int] -or $el -is [bool]) { "$el" }
            else { $el | ConvertTo-Json -Compress -Depth 3 }
        }
        return $items -join ', '
    }

    # PSCustomObject
    return $parsed | ConvertTo-Json -Compress -Depth 3
}

Export-ModuleMember -Function @(
    'Get-SecurityBaselinePolicies',
    'Reset-SecurityBaselineCache'
)
