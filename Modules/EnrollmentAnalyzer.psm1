# =============================================================================
# EnrollmentAnalyzer.psm1 — Fetches enrollment configs & Autopilot devices
#                            (Sprint 5)
#
# Graph endpoints:
#   GET /deviceManagement/deviceEnrollmentConfigurations
#   GET /deviceManagement/windowsAutopilotDeviceIdentities
#
# Returns a hashtable with two keys: EnrollmentConfigs and AutopilotDevices.
# This is NOT a policy reader — it produces inventory data for the assessment
# report, bypassing the Comparison/Enrichment pipeline.
#
# Required permission: DeviceManagementServiceConfig.Read.All
# =============================================================================

Set-StrictMode -Version Latest

function Get-EnrollmentAnalysis {
    <#
    .SYNOPSIS
        Fetches enrollment configurations and Autopilot device identities
        from the customer tenant.
    .PARAMETER Token
        Bearer access token for the target tenant.
    .PARAMETER BaseUrl
        Graph API base URL including version, e.g. https://graph.microsoft.com/beta
    .OUTPUTS
        hashtable — keys: EnrollmentConfigs (List[hashtable]), AutopilotDevices (List[hashtable])
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BaseUrl
    )

    $enrollmentConfigs = Get-EnrollmentConfigs -Token $Token -BaseUrl $BaseUrl
    $autopilotDevices  = Get-AutopilotDevices  -Token $Token -BaseUrl $BaseUrl

    return @{
        EnrollmentConfigs = $enrollmentConfigs
        AutopilotDevices  = $autopilotDevices
    }
}

# ---------------------------------------------------------------------------
# Internal — Enrollment Configurations
# ---------------------------------------------------------------------------

function Get-EnrollmentConfigs {
    param([string]$Token, [string]$BaseUrl)

    Write-Host "    Fetching enrollment configurations..." -ForegroundColor DarkGray
    $configs = $null
    try {
        $configs = Get-GraphPagedResults `
            -Uri   "$BaseUrl/deviceManagement/deviceEnrollmentConfigurations" `
            -Token $Token
    }
    catch {
        if ("$_" -match '403|Forbidden|Authorization_RequestDenied') {
            Write-Warning "    Insufficient permissions for enrollment configurations. Grant DeviceManagementServiceConfig.Read.All."
            return [System.Collections.Generic.List[hashtable]]::new()
        }
        throw
    }

    Write-Host "    Found $($configs.Count) enrollment configurations." -ForegroundColor DarkGray

    $results = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($c in $configs) {
        $odataType = if ($c.PSObject.Properties['@odata.type']) { $c.'@odata.type' } else { '' }
        $shortType = $odataType -replace '^#microsoft\.graph\.', ''

        $results.Add([ordered]@{
            ConfigName   = $c.displayName
            ConfigId     = $c.id
            ConfigType   = $shortType
            Priority     = if ($c.PSObject.Properties['priority']) { $c.priority } else { '' }
            Description  = if ($c.PSObject.Properties['description']) { $c.description } else { '' }
            CreatedDate  = $c.createdDateTime
            LastModified = $c.lastModifiedDateTime
        })
    }

    return $results
}

# ---------------------------------------------------------------------------
# Internal — Autopilot Device Identities
# ---------------------------------------------------------------------------

function Get-AutopilotDevices {
    param([string]$Token, [string]$BaseUrl)

    Write-Host "    Fetching Autopilot device identities..." -ForegroundColor DarkGray
    $devices = $null
    try {
        $devices = Get-GraphPagedResults `
            -Uri        "$BaseUrl/deviceManagement/windowsAutopilotDeviceIdentities?`$top=25" `
            -Token      $Token `
            -TimeoutSec 300
    }
    catch {
        if ("$_" -match '403|Forbidden|Authorization_RequestDenied') {
            Write-Warning "    Insufficient permissions for Autopilot devices. Grant DeviceManagementServiceConfig.Read.All."
            return [System.Collections.Generic.List[hashtable]]::new()
        }
        throw
    }

    Write-Host "    Found $($devices.Count) Autopilot devices." -ForegroundColor DarkGray

    $results = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($d in $devices) {
        $results.Add([ordered]@{
            SerialNumber                      = $d.serialNumber
            Model                             = $d.model
            Manufacturer                      = $d.manufacturer
            GroupTag                          = if ($d.PSObject.Properties['groupTag']) { $d.groupTag } else { '' }
            PurchaseOrderId                   = if ($d.PSObject.Properties['purchaseOrderIdentifier']) { $d.purchaseOrderIdentifier } else { '' }
            EnrollmentState                   = if ($d.PSObject.Properties['enrollmentState']) { $d.enrollmentState } else { '' }
            LastContactedDateTime             = if ($d.PSObject.Properties['lastContactedDateTime']) { $d.lastContactedDateTime } else { '' }
            DeploymentProfileAssignmentStatus = if ($d.PSObject.Properties['deploymentProfileAssignmentStatus']) { $d.deploymentProfileAssignmentStatus } else { '' }
        })
    }

    return $results
}

Export-ModuleMember -Function @('Get-EnrollmentAnalysis')
