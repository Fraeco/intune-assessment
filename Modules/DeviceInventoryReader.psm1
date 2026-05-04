# =============================================================================
# DeviceInventoryReader.psm1 — Fetches managed device inventory (Sprint 5)
#
# Graph endpoint:
#   GET /deviceManagement/managedDevices
#
# Returns a flat list of hashtables, one per managed device. This is NOT a
# policy reader — it produces inventory data for the assessment report,
# bypassing the Comparison/Enrichment pipeline.
#
# Required permission: DeviceManagementManagedDevices.Read.All
# =============================================================================

Set-StrictMode -Version Latest

function Get-DeviceInventory {
    <#
    .SYNOPSIS
        Fetches all managed devices from the customer tenant.
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
        [Parameter(Mandatory)] [string]$BaseUrl,
        [switch]$IncludeOsLifecycleEnrichment
    )

    $selectFields = 'id,deviceName,operatingSystem,osVersion,complianceState,lastSyncDateTime,enrolledDateTime,managementAgent,deviceEnrollmentType,model,manufacturer,serialNumber,userPrincipalName'

    Write-Host "    Fetching managed device inventory..." -ForegroundColor DarkGray
    $devices = $null
    try {
        $devices = Get-GraphPagedResults `
            -Uri   "$BaseUrl/deviceManagement/managedDevices?`$select=$selectFields" `
            -Token $Token
    }
    catch {
        if ("$_" -match '403|Forbidden|Authorization_RequestDenied') {
            Write-Warning "    Insufficient permissions for device inventory. Grant DeviceManagementManagedDevices.Read.All."
            return [System.Collections.Generic.List[hashtable]]::new()
        }
        throw
    }

    Write-Host "    Found $($devices.Count) managed devices." -ForegroundColor DarkGray

    $results = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($d in $devices) {
        $row = [ordered]@{
            DeviceName        = $d.deviceName
            DeviceId          = $d.id
            OperatingSystem   = $d.operatingSystem
            OsVersion         = $d.osVersion
            ComplianceState   = $d.complianceState
            LastSync          = $d.lastSyncDateTime
            EnrolledDate      = $d.enrolledDateTime
            ManagementAgent   = $d.managementAgent
            EnrollmentType    = $d.deviceEnrollmentType
            Model             = $d.model
            Manufacturer      = $d.manufacturer
            SerialNumber      = $d.serialNumber
            UserPrincipalName = $d.userPrincipalName
        }

        if ($IncludeOsLifecycleEnrichment) {
            try {
                $osMeta = Get-OsLifecycleInfo -OperatingSystem $d.operatingSystem -OsVersion $d.osVersion
                foreach ($key in @('OsFamily', 'OsRelease', 'OsBuild', 'OsSupportState', 'OsEndOfServiceDate', 'OsSource')) {
                    $row[$key] = $osMeta[$key]
                }
            }
            catch {
                # Keep inventory resilient; enrichment failure should not break collection.
                $row['OsFamily'] = 'Unknown'
                $row['OsRelease'] = 'Unknown'
                $row['OsBuild'] = ''
                $row['OsSupportState'] = 'Unknown'
                $row['OsEndOfServiceDate'] = ''
                $row['OsSource'] = 'none'
            }
        }

        $results.Add($row)
    }

    return $results
}

Export-ModuleMember -Function @('Get-DeviceInventory')
