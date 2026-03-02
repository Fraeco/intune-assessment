# =============================================================================
# Auth.psm1 — Token acquisition and tenant connection management
# Uses OAuth 2.0 client_credentials flow (application permissions, no user)
# =============================================================================

Set-StrictMode -Version Latest

# Per-session token cache keyed by TenantId
$script:TokenCache = [System.Collections.Generic.Dictionary[string, hashtable]]::new()

# Active app configuration (set via Initialize-AuthConfig)
$script:AppConfig = $null

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Initialize-AuthConfig {
    <#
    .SYNOPSIS
        Loads the application configuration into the auth module.
    .PARAMETER Config
        Hashtable with ClientId, ClientSecret, BaselineTenantId, Authority keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $required = @('ClientId', 'ClientSecret', 'BaselineTenantId', 'Authority')
    foreach ($key in $required) {
        if (-not $Config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($Config[$key])) {
            throw "AppConfig is missing or empty required key: '$key'"
        }
    }

    if ($Config['ClientId'] -eq '00000000-0000-0000-0000-000000000000') {
        throw "AppConfig.json contains placeholder values. Please fill in ClientId, ClientSecret, and BaselineTenantId."
    }

    $script:AppConfig = $Config
    Write-Verbose "Auth configuration loaded (ClientId: $($Config['ClientId']))"
}

function Connect-BaselineTenant {
    <#
    .SYNOPSIS
        Acquires (or returns a cached) access token for the eVri baseline tenant.
    .OUTPUTS
        String — Bearer access token
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($null -eq $script:AppConfig) {
        throw "Auth not initialised. Call Initialize-AuthConfig before connecting."
    }

    Write-Host "  Connecting to baseline tenant ($($script:AppConfig['BaselineTenantId']))..." -ForegroundColor DarkCyan
    $token = Get-GraphToken -TenantId $script:AppConfig['BaselineTenantId']
    Write-Host "  Connected to baseline tenant." -ForegroundColor Green
    return $token
}

function Connect-CustomerTenant {
    <#
    .SYNOPSIS
        Acquires (or returns a cached) access token for a customer tenant.
    .PARAMETER TenantId
        The customer's Azure AD Tenant ID (GUID).
    .OUTPUTS
        String — Bearer access token
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]$TenantId
    )

    if ($null -eq $script:AppConfig) {
        throw "Auth not initialised. Call Initialize-AuthConfig before connecting."
    }

    Write-Host "  Connecting to customer tenant ($TenantId)..." -ForegroundColor DarkCyan
    $token = Get-GraphToken -TenantId $TenantId
    Write-Host "  Connected to customer tenant." -ForegroundColor Green
    return $token
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function Get-GraphToken {
    <#
    .SYNOPSIS
        Returns a valid access token for the given tenant, acquiring a new one
        if the cache is empty or the token is within 5 minutes of expiry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId
    )

    # Return cached token if still valid with a 5-minute safety margin
    if ($script:TokenCache.ContainsKey($TenantId)) {
        $cached = $script:TokenCache[$TenantId]
        if ($cached.ExpiresAt -gt (Get-Date).AddMinutes(5)) {
            Write-Verbose "Returning cached token for tenant $TenantId (expires $(($cached.ExpiresAt).ToString('HH:mm:ss')))"
            return $cached.AccessToken
        }
        Write-Verbose "Cached token for $TenantId is expiring; acquiring new one."
    }

    $tokenUrl = "$($script:AppConfig['Authority'])/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id     = $script:AppConfig['ClientId']
        client_secret = $script:AppConfig['ClientSecret']
        scope         = 'https://graph.microsoft.com/.default'
        grant_type    = 'client_credentials'
    }

    Write-Verbose "Acquiring token from: $tokenUrl"

    try {
        $response = Invoke-RestMethod `
            -Uri         $tokenUrl `
            -Method      Post `
            -Body        $body `
            -ContentType 'application/x-www-form-urlencoded' `
            -ErrorAction Stop

        $script:TokenCache[$TenantId] = @{
            AccessToken = $response.access_token
            ExpiresAt   = (Get-Date).AddSeconds($response.expires_in)
        }

        return $response.access_token
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) {
            try { ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { $_.ErrorDetails.Message }
        } else {
            $_.Exception.Message
        }
        throw "Authentication failed for tenant '$TenantId': $detail"
    }
}

Export-ModuleMember -Function @(
    'Initialize-AuthConfig',
    'Connect-BaselineTenant',
    'Connect-CustomerTenant'
)
