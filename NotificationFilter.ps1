<#
.SYNOPSIS
    Application filter and privacy engine for Windows-to-iPhone Notification Forwarder.
.DESCRIPTION
    Supports dual filtering modes:
    - Allowlist (Default): strictly permits only explicitly whitelisted application identifiers.
    - AllWindowsNotifications: accepts all applications publishing to the Windows Notification Platform,
      excluding those explicitly placed on the IgnoreAppIds list.
    Bounds payload lengths, sanitizes content, and enforces TitleOnly privacy boundaries.
#>

function Test-IsAppAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AppUserModelId,

        [Parameter(Mandatory = $false)]
        [string]$AppDisplayName,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Allowlist", "Blocklist", "AllWindowsNotifications")]
        [string]$AppFilterMode = "Allowlist",

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedAppIds = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$BlockedAppIds = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$IgnoreAppIds = @()
    )

    $candidateAumid = if ($AppUserModelId) { $AppUserModelId.Trim() } else { "" }
    $candidateName  = if ($AppDisplayName) { $AppDisplayName.Trim() } else { "" }

    # Helper scriptblock for robust candidate-to-pattern matching
    $matchesRule = {
        param([string]$rulePattern)
        if ([string]::IsNullOrWhiteSpace($rulePattern)) { return $false }
        $pat = $rulePattern.Trim()

        # 1. Direct wildcard / string match against candidate AUMID or DisplayName
        if ($candidateAumid -and ($candidateAumid -like $pat)) { return $true }
        if ($candidateName -and ($candidateName -like $pat)) { return $true }

        # 2. Executable / file-stem matching if rule or candidate contains path separators
        if ($pat -match '[\\/]') {
            try {
                $patFile = [System.IO.Path]::GetFileName($pat)
                $patStem = [System.IO.Path]::GetFileNameWithoutExtension($pat)
                if ($candidateAumid -and ($candidateAumid -like $patFile -or $candidateAumid -like $patStem)) { return $true }
                if ($candidateName -and ($candidateName -like $patFile -or $candidateName -like $patStem)) { return $true }
            } catch { }
        }
        if ($candidateAumid -match '[\\/]') {
            try {
                $candFile = [System.IO.Path]::GetFileName($candidateAumid)
                $candStem = [System.IO.Path]::GetFileNameWithoutExtension($candidateAumid)
                if ($candFile -like $pat -or $candStem -like $pat) { return $true }
            } catch { }
        }

        # 3. UWP Package Family Name matching (e.g. 5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App)
        if ($candidateAumid -match '!.*$') {
            $pfn = $candidateAumid.Split('!')[0]
            if ($pfn -like $pat -or $pat -like "*$pfn*") { return $true }
        }

        # 4. Normalized case-insensitive equality
        if ($candidateName -and $candidateName.Equals($pat, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($candidateAumid -and $candidateAumid.Equals($pat, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }

        return $false
    }

    # 1. Check explicit block/ignore list first (Applies to all modes)
    $allBlocked = @()
    if ($BlockedAppIds -and $BlockedAppIds.Count -gt 0) { $allBlocked += $BlockedAppIds }
    if ($IgnoreAppIds -and $IgnoreAppIds.Count -gt 0)   { $allBlocked += $IgnoreAppIds }

    if ($allBlocked.Count -gt 0) {
        foreach ($ignore in $allBlocked) {
            if (& $matchesRule -rulePattern $ignore) {
                return $false
            }
        }
    }

    # 2. If Blocklist or AllWindowsNotifications mode is active, allow any app that isn't blocked
    if ($AppFilterMode -in @("Blocklist", "AllWindowsNotifications")) {
        return $true
    }

    # 3. Allowlist mode (Deny by default unless matched)
    if ($AllowedAppIds -and $AllowedAppIds.Count -gt 0) {
        foreach ($allowed in $AllowedAppIds) {
            if (& $matchesRule -rulePattern $allowed) {
                return $true
            }
        }
    }

    # Deny by default under Allowlist mode
    return $false
}

function Filter-Notification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $NotificationData,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $filterMode = if ($Config.AppFilterMode) { $Config.AppFilterMode } else { "Allowlist" }

    # Application filtering check
    $isAllowed = Test-IsAppAllowed `
        -AppUserModelId $NotificationData.AppUserModelId `
        -AppDisplayName $NotificationData.AppDisplayName `
        -AppFilterMode  $filterMode `
        -AllowedAppIds  $Config.AllowedAppIds `
        -BlockedAppIds  $Config.BlockedAppIds `
        -IgnoreAppIds   $Config.IgnoreAppIds

    if (-not $isAllowed) {
        Write-Verbose "[FILTER] Notification ID=$($NotificationData.Id) from App='$(if ($NotificationData.AppDisplayName) { $NotificationData.AppDisplayName } else { $NotificationData.AppUserModelId })' blocked by filter (Mode=$filterMode)."
        return $null
    }

    # Sanitize strings: truncate to prevent oversized payloads
    $maxTitleLength = 120
    $maxBodyLength  = 1000

    $cleanTitle = if ($NotificationData.Title) { $NotificationData.Title } else { "Notification" }
    if ($cleanTitle.Length -gt $maxTitleLength) {
        $cleanTitle = $cleanTitle.Substring(0, $maxTitleLength - 3) + "..."
    }

    # Determine permitted privacy fields
    $permitted = if (Get-Command "Get-PermittedPrivacyFields" -ErrorAction SilentlyContinue) {
        Get-PermittedPrivacyFields -Config $Config
    } else {
        @{
            Mode              = $Config.PrivacyMode
            IncludeDeviceName = $true
            IncludeAppName    = ($Config.PrivacyMode -in @("TitleAndApp", "TitleAndBody"))
            IncludeTitle      = $true
            IncludeBody       = ($Config.PrivacyMode -eq "TitleAndBody")
        }
    }

    $cleanBody = ""
    if ($permitted.IncludeBody -and $NotificationData.Body) {
        $cleanBody = $NotificationData.Body
        if ($cleanBody.Length -gt $maxBodyLength) {
            $cleanBody = $cleanBody.Substring(0, $maxBodyLength - 3) + "..."
        }
    }

    # Determine human-friendly app label for notification header
    $appLabel = if (-not [string]::IsNullOrWhiteSpace($NotificationData.AppDisplayName)) {
        $NotificationData.AppDisplayName
    } elseif (-not [string]::IsNullOrWhiteSpace($NotificationData.AppUserModelId)) {
        $NotificationData.AppUserModelId
    } else {
        "Windows Notification"
    }

    return [PSCustomObject]@{
        Id             = $NotificationData.Id
        AppLabel       = $appLabel
        AppUserModelId = $NotificationData.AppUserModelId
        AppDisplayName = $NotificationData.AppDisplayName
        CreationTime   = $NotificationData.CreationTime
        Title          = $cleanTitle
        Body           = $cleanBody
        PrivacyMode    = $Config.PrivacyMode
        AppFilterMode  = $filterMode
        IsAllowed      = $true
    }
}