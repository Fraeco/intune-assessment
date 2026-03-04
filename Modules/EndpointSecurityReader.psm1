# =============================================================================
# EndpointSecurityReader.psm1 — Reads and normalises Intune Endpoint Security
#                               intent policies (Sprint 2)
#
# Graph endpoints:
#   GET /deviceManagement/intents                              — list intents
#   GET /deviceManagement/intents/{id}/settings               — settings
#   GET /deviceManagement/templates/{templateId}              — template metadata
#   GET /deviceManagement/templates/{templateId}/settingDefinitions — definitions
#
# Each setting is returned as a hashtable using the same schema as PolicyReader:
#   PolicyName     — intent display name
#   PolicyTemplate — "Endpoint Security"
#   SettingPath    — "{templateDisplayName} > {definitionDisplayName}"
#   CategoryId     — templateType string (e.g. "endpointSecurityAntivirus")
#   Value          — string representation of the configured value
#   Description    — from definition; empty if unavailable
#   DefinitionId   — "es:{raw definitionId from Graph}" (comparison key)
#   Domain         — populated later by Enrichment.psm1
# =============================================================================

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# In-memory caches
# ---------------------------------------------------------------------------
$script:TemplateCache     = [System.Collections.Generic.Dictionary[string, object]]::new()
$script:EsDefinitionCache = [System.Collections.Generic.Dictionary[string, object]]::new()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-EndpointSecurityPolicies {
    <#
    .SYNOPSIS
        Fetches all Endpoint Security intent policies from a tenant and returns
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

    Write-Host "    Fetching Endpoint Security intent list..." -ForegroundColor DarkGray
    $intents = Get-GraphPagedResults -Uri "$BaseUrl/deviceManagement/intents" -Token $Token
    Write-Host "    Found $($intents.Count) Endpoint Security intents." -ForegroundColor DarkGray

    if ($PolicyFilter.Count -gt 0) {
        $before  = $intents.Count
        $intents = @($intents | Where-Object {
            $name = $_.displayName
            $PolicyFilter | Where-Object { $name -like $_ }
        })
        Write-Host "    Policy filter applied: $before → $($intents.Count) intents." -ForegroundColor DarkGray
    }

    $allSettings = [System.Collections.Generic.List[hashtable]]::new()
    $i = 0

    foreach ($intent in $intents) {
        $i++
        Write-Progress `
            -Activity        'Reading Endpoint Security' `
            -Status          "[$i/$($intents.Count)] $($intent.displayName)" `
            -PercentComplete ([Math]::Round($i / $intents.Count * 100))

        # Template metadata and setting definitions (both cached by templateId)
        $template    = Get-EsTemplate    -TemplateId $intent.templateId -Token $Token -BaseUrl $BaseUrl
        $defLookup   = Get-EsDefinitions -TemplateId $intent.templateId -Token $Token -BaseUrl $BaseUrl

        # Per-intent settings
        $rawSettings = Get-GraphPagedResults `
            -Uri   "$BaseUrl/deviceManagement/intents/$($intent.id)/settings" `
            -Token $Token

        foreach ($raw in $rawSettings) {
            $row = ConvertTo-EsFlatSetting `
                -Setting       $raw `
                -Template      $template `
                -DefLookup     $defLookup `
                -PolicyName    $intent.displayName
            if ($null -ne $row) { $allSettings.Add($row) }
        }
    }

    Write-Progress -Activity 'Reading Endpoint Security' -Completed
    Write-Host "    Normalised $($allSettings.Count) settings from $($intents.Count) intents." -ForegroundColor DarkGray

    return $allSettings
}

function Reset-EndpointSecurityCache {
    <#
    .SYNOPSIS
        Clears the in-memory template and definition caches.
        Useful when switching tenants within the same session.
    #>
    $script:TemplateCache.Clear()
    $script:EsDefinitionCache.Clear()
    Write-Verbose "EndpointSecurityReader: caches cleared."
}

# ---------------------------------------------------------------------------
# Internal — template and definition retrieval (cached)
# ---------------------------------------------------------------------------

function Get-EsTemplate {
    param([string]$TemplateId, [string]$Token, [string]$BaseUrl)

    if ($script:TemplateCache.ContainsKey($TemplateId)) {
        return $script:TemplateCache[$TemplateId]
    }

    try {
        $tmpl = Invoke-IbaGraphRequest -Uri "$BaseUrl/deviceManagement/templates/$TemplateId" -Token $Token
        $script:TemplateCache[$TemplateId] = $tmpl
        return $tmpl
    }
    catch {
        Write-Verbose "  ES template not found '$TemplateId': $_"
        $script:TemplateCache[$TemplateId] = $null
        return $null
    }
}

function Get-EsDefinitions {
    <#
    Returns a Dictionary[string, object] keyed by definition id for O(1) lookup.
    #>
    param([string]$TemplateId, [string]$Token, [string]$BaseUrl)

    if ($script:EsDefinitionCache.ContainsKey($TemplateId)) {
        return $script:EsDefinitionCache[$TemplateId]
    }

    $lookup = [System.Collections.Generic.Dictionary[string, object]]::new()
    try {
        $defs = Get-GraphPagedResults `
            -Uri   "$BaseUrl/deviceManagement/templates/$TemplateId/settingDefinitions" `
            -Token $Token
        foreach ($d in $defs) { if ($d.id) { $lookup[$d.id] = $d } }
    }
    catch {
        Write-Verbose "  ES definitions not found for template '$TemplateId': $_"
    }

    $script:EsDefinitionCache[$TemplateId] = $lookup
    return $lookup
}

# ---------------------------------------------------------------------------
# Internal — setting conversion
# ---------------------------------------------------------------------------

function ConvertTo-EsFlatSetting {
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

    $displayName    = if ($def -and $def.PSObject.Properties['displayName'] -and $def.displayName) {
                          $def.displayName
                      } else {
                          # Fallback: strip vendor prefix, title-case remainder
                          ($defId -split '--' | Select-Object -Last 1) -replace '_', ' '
                      }
    $description    = if ($def -and $def.PSObject.Properties['description'] -and $def.description) { $def.description } else { '' }
    $templateLabel  = if ($Template -and $Template.PSObject.Properties['displayName'] -and $Template.displayName) { $Template.displayName } else { 'Endpoint Security' }
    $templateType   = if ($Template -and $Template.PSObject.Properties['templateType'] -and $Template.templateType) { $Template.templateType } else { 'endpointSecurity' }

    $value = Resolve-EsValue -Setting $Setting -Definition $def
    if ($null -eq $value) { return $null }

    return [ordered]@{
        PolicyName     = $PolicyName
        PolicyTemplate = 'Endpoint Security'
        SettingPath    = "$templateLabel > $displayName"
        CategoryId     = $templateType
        Value          = $value
        Description    = $description
        DefinitionId   = "es:$defId"
        Domain         = ''
    }
}

function Resolve-EsValue {
    <#
    Extracts a human-readable string value from an intent setting.
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
        # Unparseable — return the raw JSON string as-is
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

    # Array — emit as comma-joined string
    if ($parsed -is [System.Object[]]) {
        if ($parsed.Count -eq 0) { return $null }
        $items = foreach ($el in $parsed) {
            if ($el -is [string] -or $el -is [int] -or $el -is [bool]) { "$el" }
            else { $el | ConvertTo-Json -Compress -Depth 3 }
        }
        return $items -join ', '
    }

    # PSCustomObject — serialise
    return $parsed | ConvertTo-Json -Compress -Depth 3
}

Export-ModuleMember -Function @(
    'Get-EndpointSecurityPolicies',
    'Reset-EndpointSecurityCache'
)
