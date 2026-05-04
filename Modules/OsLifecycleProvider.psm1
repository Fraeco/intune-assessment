# =============================================================================
# OsLifecycleProvider.psm1 — Resolves OS lifecycle metadata for device rows
#
# Strategy:
#   1) Attempt Microsoft Graph Windows Updates lifecycle source (beta)
#   2) Fall back to static Config/OSDefinition.json mapping
#
# Output contract:
#   OsFamily, OsRelease, OsBuild, OsSupportState, OsEndOfServiceDate, OsSource
# =============================================================================

Set-StrictMode -Version Latest

$script:OsLifecycleEntries = @()
$script:ProviderInitialized = $false
$script:ProviderSource = 'none'

function Initialize-OsLifecycleProvider {
    [CmdletBinding()]
    param(
        [string]$Token,
        [string]$BaseUrl,
        [Parameter(Mandatory)] [string]$OsDefinitionPath,
        [switch]$PreferGraph,
        [switch]$DisableGraph
    )

    $script:OsLifecycleEntries = @()
    $script:ProviderInitialized = $false
    $script:ProviderSource = 'none'

    if (-not (Test-Path $OsDefinitionPath)) {
        throw "OS definition file not found: $OsDefinitionPath"
    }

    $loadedFromGraph = $false
    if (-not $DisableGraph -and $PreferGraph -and $Token -and $BaseUrl) {
        try {
            $graphEntries = Get-OsLifecycleFromGraph -Token $Token -BaseUrl $BaseUrl
            if ($graphEntries -and @($graphEntries).Count -gt 0) {
                $script:OsLifecycleEntries = $graphEntries
                $script:ProviderSource = 'graph'
                $loadedFromGraph = $true
                Write-Verbose "OS lifecycle provider initialized from Graph ($(@($graphEntries).Count) entries)."
            }
        }
        catch {
            Write-Verbose "OS lifecycle Graph source unavailable: $($_.Exception.Message)"
        }
    }

    if (-not $loadedFromGraph) {
        $script:OsLifecycleEntries = Get-OsLifecycleFromStaticFile -Path $OsDefinitionPath
        $script:ProviderSource = 'static'
        Write-Verbose "OS lifecycle provider initialized from static file ($($script:OsLifecycleEntries.Count) entries)."
    }

    $script:ProviderInitialized = $true
}

function Get-OsLifecycleInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$OperatingSystem,
        [string]$OsVersion
    )

    if (-not $script:ProviderInitialized) {
        throw 'OS lifecycle provider is not initialized. Call Initialize-OsLifecycleProvider first.'
    }

    $family = Get-OsFamily -OperatingSystem $OperatingSystem
    $build  = Get-OsBuildPrefix -OsVersion $OsVersion
    $entry  = Find-OsLifecycleEntry -Family $family -BuildPrefix $build

    if ($null -eq $entry) {
        return [ordered]@{
            OsFamily           = $family
            OsRelease          = 'Unknown'
            OsBuild            = $build
            OsSupportState     = 'Unknown'
            OsEndOfServiceDate = ''
            OsSource           = $script:ProviderSource
        }
    }

    return [ordered]@{
        OsFamily           = $entry.OsFamily
        OsRelease          = $entry.OsRelease
        OsBuild            = $entry.BuildPrefix
        OsSupportState     = $entry.SupportState
        OsEndOfServiceDate = $entry.EndOfServiceDate
        OsSource           = $script:ProviderSource
    }
}

function Get-OsLifecycleFromStaticFile {
    param([string]$Path)

    $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
    if (-not $raw.PSObject.Properties['entries']) {
        throw "Invalid OS definition schema in '$Path'. Expected 'entries' array."
    }

    $entries = @()
    foreach ($item in @($raw.entries)) {
        $entries += [ordered]@{
            OsFamily         = "$($item.osFamily)"
            OsRelease        = "$($item.osRelease)"
            BuildPrefix      = "$($item.buildPrefix)"
            SupportState     = "$($item.supportState)"
            EndOfServiceDate = "$($item.endOfServiceDate)"
        }
    }

    return $entries
}

function Get-OsLifecycleFromGraph {
    param(
        [string]$Token,
        [string]$BaseUrl
    )

    # These endpoints are in beta and may vary by tenant capability.
    # We attempt known candidate roots and normalize any parsable rows.
    if (-not (Get-Command Get-GraphPagedResults -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Get-GraphPagedResults is unavailable; skipping Graph OS lifecycle source.'
        return @()
    }

    $candidates = @(
        "$BaseUrl/admin/windows/updates/products",
        "$BaseUrl/admin/windows/updates/catalog/entries"
    )

    foreach ($uri in $candidates) {
        try {
            $items = Get-GraphPagedResults -Uri $uri -Token $Token -TimeoutSec 60
            $normalized = Convert-GraphLifecycleItems -Items $items
            if ($normalized -and @($normalized).Count -gt 0) {
                return $normalized
            }
        }
        catch {
            Write-Verbose "OS lifecycle Graph endpoint failed '$uri': $($_.Exception.Message)"
        }
    }

    return @()
}

function Convert-GraphLifecycleItems {
    param([object[]]$Items)

    $entries = @()
    foreach ($item in @($Items)) {
        $buildPrefix = Get-FirstStringProperty -Object $item -Candidates @(
            'buildPrefix',
            'buildNumber',
            'build',
            'version'
        )
        if (-not $buildPrefix) { continue }

        $family = Get-FirstStringProperty -Object $item -Candidates @(
            'osFamily',
            'productFamily',
            'family'
        )
        if (-not $family) { $family = 'Windows' }

        $release = Get-FirstStringProperty -Object $item -Candidates @(
            'release',
            'displayName',
            'versionName',
            'name'
        )
        if (-not $release) { $release = "$buildPrefix" }

        $supportState = Get-FirstStringProperty -Object $item -Candidates @(
            'supportState',
            'servicingState',
            'state'
        )
        if (-not $supportState) {
            $isInService = $null
            if ($item.PSObject.Properties['isInService']) { $isInService = $item.isInService }
            $supportState = if ($isInService -eq $true) { 'Supported' } elseif ($isInService -eq $false) { 'Unsupported' } else { 'Unknown' }
        }

        $eos = Get-FirstStringProperty -Object $item -Candidates @(
            'endOfServiceDate',
            'endOfServiceDateTime'
        )
        if (-not $eos) { $eos = '' }

        $entries += [ordered]@{
            OsFamily         = "$family"
            OsRelease        = "$release"
            BuildPrefix      = "$buildPrefix"
            SupportState     = "$supportState"
            EndOfServiceDate = "$eos"
        }
    }

    return $entries
}

function Get-FirstStringProperty {
    param(
        [object]$Object,
        [string[]]$Candidates
    )

    foreach ($name in $Candidates) {
        if ($Object.PSObject.Properties[$name]) {
            $value = $Object.$name
            if ($null -ne $value -and "$value".Trim().Length -gt 0) {
                return "$value"
            }
        }
    }
    return $null
}

function Get-OsFamily {
    param([string]$OperatingSystem)

    $os = if ($OperatingSystem) { "$OperatingSystem".Trim() } else { '' }
    if (-not $os) { return 'Unknown' }

    if ($os -match 'Windows') { return 'Windows' }
    if ($os -match 'iOS') { return 'iOS' }
    if ($os -match 'Android') { return 'Android' }
    if ($os -match 'macOS|Mac') { return 'macOS' }
    return $os
}

function Get-OsBuildPrefix {
    param([string]$OsVersion)

    $raw = if ($OsVersion) { "$OsVersion".Trim() } else { '' }
    if (-not $raw) { return '' }

    # Common managedDevice format: 10.0.22631.4317 -> 22631
    if ($raw -match '^\d+\.\d+\.(\d+)') { return $Matches[1] }
    if ($raw -match '^(\d{4,5})') { return $Matches[1] }
    return $raw
}

function Find-OsLifecycleEntry {
    param(
        [string]$Family,
        [string]$BuildPrefix
    )

    if (-not $BuildPrefix) { return $null }

    foreach ($entry in $script:OsLifecycleEntries) {
        if ($entry.OsFamily -eq $Family -and $entry.BuildPrefix -eq $BuildPrefix) {
            return $entry
        }
    }
    return $null
}

Export-ModuleMember -Function @(
    'Initialize-OsLifecycleProvider',
    'Get-OsLifecycleInfo'
)
