# =============================================================================
# GraphAPI.psm1 — Low-level Microsoft Graph HTTP helpers
# Handles pagination, throttle-aware retry, and transient error recovery
# =============================================================================

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Invoke-IbaGraphRequest {
    <#
    .SYNOPSIS
        Sends a single request to the Microsoft Graph API with retry logic.
    .PARAMETER Uri
        Full Graph API URI.
    .PARAMETER Token
        Bearer access token.
    .PARAMETER Method
        HTTP method (default GET).
    .PARAMETER MaxRetries
        Maximum number of retry attempts for throttling / transient errors.
    .PARAMETER TimeoutSec
        Timeout in seconds for each individual HTTP request (default 120).
    .OUTPUTS
        PSCustomObject — The parsed JSON response body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Token,

        [string]$Method     = 'GET',
        [int]   $MaxRetries = 5,
        [int]   $TimeoutSec = 120
    )

    $headers = @{
        Authorization    = "Bearer $Token"
        'Content-Type'   = 'application/json'
        ConsistencyLevel = 'eventual'
    }

    $attempt = 0

    while ($attempt -le $MaxRetries) {
        try {
            Write-Verbose "[$Method] $Uri  (attempt $($attempt + 1))"
            $response = Invoke-RestMethod `
                -Uri         $Uri `
                -Method      $Method `
                -Headers     $headers `
                -TimeoutSec  $TimeoutSec `
                -ErrorAction Stop
            return $response
        }
        catch {
            $statusCode = [int]$_.Exception.Response.StatusCode

            if ($statusCode -eq 429) {
                # Respect Retry-After header; default 30 s if absent
                $retryAfter = 30
                $raHeader   = $_.Exception.Response.Headers['Retry-After']
                if ($raHeader) { $retryAfter = [int]$raHeader }

                Write-Warning "Graph API throttled (429). Waiting $retryAfter s before retry $($attempt + 1)/$MaxRetries..."
                Start-Sleep -Seconds $retryAfter
                $attempt++
            }
            elseif ($statusCode -in @(500, 502, 503, 504) -and $attempt -lt $MaxRetries) {
                $wait = 5 * ($attempt + 1)   # progressive back-off: 5, 10, 15 …
                Write-Warning "Transient error ($statusCode) on '$Uri'. Waiting $wait s... (retry $($attempt + 1)/$MaxRetries)"
                Start-Sleep -Seconds $wait
                $attempt++
            }
            else {
                $detail = if ($_.ErrorDetails.Message) {
                    try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $_.ErrorDetails.Message }
                } else {
                    $_.Exception.Message
                }
                throw "Graph API [$statusCode] $Uri — $detail"
            }
        }
    }

    throw "Graph API request failed after $MaxRetries retries: $Uri"
}

function Get-GraphPagedResults {
    <#
    .SYNOPSIS
        Fetches all pages of a Graph API collection, following @odata.nextLink.
    .PARAMETER Uri
        Initial collection URI (may include $filter, $select, etc.)
    .PARAMETER Token
        Bearer access token.
    .OUTPUTS
        System.Collections.Generic.List[object] — All items across all pages.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Token,

        [int]$TimeoutSec = 120
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $nextUrl = $Uri
    $page    = 0

    while ($nextUrl) {
        $page++
        Write-Verbose "  Paged fetch page ${page}: $nextUrl"
        $response = Invoke-IbaGraphRequest -Uri $nextUrl -Token $Token -TimeoutSec $TimeoutSec

        if ($null -ne $response.value) {
            $results.AddRange([object[]]$response.value)
        }

        $prop    = $response.PSObject.Properties['@odata.nextLink']
        $nextUrl = if ($prop) { $prop.Value } else { $null }
    }

    return $results
}

Export-ModuleMember -Function @(
    'Invoke-IbaGraphRequest',
    'Get-GraphPagedResults'
)
