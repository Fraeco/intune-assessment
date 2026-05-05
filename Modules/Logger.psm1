Set-StrictMode -Version Latest

$script:IbaLogOptions = @{
    VerboseMode             = $false
    JsonMode                = $false
    MaskTenantIds           = $true
    UseLegacyConsoleLogging = $false
}

function Set-IbaLogOptions {
    [CmdletBinding()]
    param(
        [bool]$VerboseMode = $false,
        [bool]$JsonMode = $false,
        [bool]$MaskTenantIds = $true,
        [bool]$UseLegacyConsoleLogging = $false
    )

    $script:IbaLogOptions.VerboseMode = $VerboseMode
    $script:IbaLogOptions.JsonMode = $JsonMode
    $script:IbaLogOptions.MaskTenantIds = $MaskTenantIds
    $script:IbaLogOptions.UseLegacyConsoleLogging = $UseLegacyConsoleLogging
}

function Protect-IbaLogMessage {
    [CmdletBinding()]
    param([string]$Message)

    if ([string]::IsNullOrEmpty($Message)) { return $Message }
    if (-not $script:IbaLogOptions.MaskTenantIds) { return $Message }

    $msg = $Message
    $msg = [regex]::Replace($msg, '(?i)\b([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})\b', '$1-****-****-****-$5')
    $msg = [regex]::Replace($msg, '(?i)(ClientSecret\s*[:=]\s*)([^,\s]+)', '$1***')
    return $msg
}

function Convert-IbaContextToString {
    [CmdletBinding()]
    param([hashtable]$Context)

    if ($null -eq $Context -or $Context.Count -eq 0) { return '' }
    return (($Context.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ' ')
}

function Write-IbaLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [hashtable]$Context,

        [string]$ForegroundColor
    )

    $safeMessage = Protect-IbaLogMessage -Message $Message
    $contextText = Convert-IbaContextToString -Context $Context

    if ($script:IbaLogOptions.JsonMode) {
        $payload = [ordered]@{
            ts      = (Get-Date -Format 'o')
            level   = $Level
            message = $safeMessage
            context = $Context
        }
        Write-Output ($payload | ConvertTo-Json -Depth 5 -Compress)
        return
    }

    $text = if ([string]::IsNullOrWhiteSpace($contextText)) { $safeMessage } else { '{0} [{1}]' -f $safeMessage, $contextText }

    switch ($Level) {
        'Debug' {
            if ($script:IbaLogOptions.VerboseMode) {
                if ($script:IbaLogOptions.UseLegacyConsoleLogging) { Write-Host $text -ForegroundColor DarkGray }
                else { Write-Verbose $text }
            }
        }
        'Info' {
            if ($ForegroundColor) { Write-Host $text -ForegroundColor $ForegroundColor }
            else { Write-Host $text }
        }
        'Warn' { Write-Warning $text }
        'Error' { Write-Error $text }
    }
}

function Write-IbaProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Activity,
        [string]$Status = '',
        [int]$PercentComplete = -1,
        [int]$Id = 0,
        [switch]$Completed
    )

    if ($Completed) {
        Write-Progress -Activity $Activity -Id $Id -Completed
        return
    }

    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete -Id $Id
}

Export-ModuleMember -Function @(
    'Set-IbaLogOptions',
    'Write-IbaLog',
    'Write-IbaProgress'
)
