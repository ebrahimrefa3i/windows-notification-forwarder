<#

.SYNOPSIS

    Windows-to-iPhone ntfy Setup Wizard for NotificationForwarder (One-Click Setup).

.DESCRIPTION

    Beginner-friendly Windows GUI utility providing a one-click setup experience:

    1. Generates or configures the ntfy notification KEY (topic) and subscription URL.

    2. Configures custom device name and notification appearance/privacy settings.

    3. Provides one-click test notification delivery to iPhone.

    4. Hands off to the local Dashboard for application filtering or starts live

       push notifications and automatic Windows startup in one click.

#>



[CmdletBinding()]

param(

    [Parameter(Mandatory = $false)]

    [string]$ProjectDirectory,



    [Parameter(Mandatory = $false)]

    [switch]$NonInteractive,



    [Parameter(Mandatory = $false)]

    [switch]$RegenerateTopic,



    [Parameter(Mandatory = $false)]

    [switch]$TestConnection,



    [Parameter(Mandatory = $false)]

    [switch]$ApplyToProduction,



    [Parameter(Mandatory = $false)]

    [switch]$StartPushNotification,



    [Parameter(Mandatory = $false)]

    [string]$CustomServer,



    [Parameter(Mandatory = $false)]

    [string]$CustomTopic,



    [Parameter(Mandatory = $false)]

    [scriptblock]$CustomHttpHandler

)



# --- 1. Project Directory Resolution ---

function Get-WizardProjectDirectory {

    param([string]$ExplicitDir)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitDir) -and (Test-Path $ExplicitDir)) {

        return (Resolve-Path $ExplicitDir).Path

    }

    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot) -and (Test-Path $PSScriptRoot)) {

        return (Resolve-Path $PSScriptRoot).Path

    }

    return (Get-Location).Path

}



function Test-NotificationPermission {

    try {

        [Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null

        $listener = [Windows.UI.Notifications.Management.UserNotificationListener]::Current

        if ($null -eq $listener) {

            return @{

                Allowed = $false

                Status  = "Unavailable"

                Message = "Windows Notification Listener API is not available on this system."

            }

        }

        $status = $listener.GetAccessStatus()

        $isAllowed = ($status -eq [Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus]::Allowed)

        return @{

            Allowed = $isAllowed

            Status  = $status.ToString()

            Message = if ($isAllowed) {

                "Notification access is granted."

            } else {

                "Notification access is not allowed ($status). Please enable notifications in Windows Settings > Privacy & security > Notifications."

            }

        }

    } catch {

        return @{

            Allowed = $true

            Status  = "Unavailable"

            Message = "Notification listener check not available in current session."

        }

    }

}



$ResolvedProjectDir = Get-WizardProjectDirectory -ExplicitDir $ProjectDirectory



# Dot-source Start-Dashboard.ps1 if present to load Invoke-StartPushNotification

$dashScriptPath = Join-Path $ResolvedProjectDir "Start-Dashboard.ps1"

if (Test-Path $dashScriptPath) {

    try {

        . $dashScriptPath

    } catch { }

}



# --- 2. Topic Generation & Cryptographic Randomness ---

function New-DeviceTopic {

    [CmdletBinding()]

    param()



    # 16 bytes = 128-bit cryptographic entropy (3.4 x 10^38 combinations)

    $bytes = New-Object byte[] 16

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    $rng.GetBytes($bytes)

    $hex = [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()

    return "win-$hex"

}



function Test-ValidTopicFormat {

    param([string]$Topic)

    if ([string]::IsNullOrWhiteSpace($Topic)) { return $false }

    # ntfy topics: alphanumeric, hyphens, underscores (4-64 characters)

    return ($Topic -match '^[a-zA-Z0-9_\-]{4,64}$')

}



function Test-ValidServerUrl {

    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    return ($Url -match '^https?://[a-zA-Z0-9\-\.]+(:\d+)?(/.*)?$')

}



# --- 3. Configuration & Persistence ---

function Get-WizardConfigPath {

    param([string]$Dir)

    return (Join-Path $Dir "wizard_config.json")

}



function Get-WizardConfig {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $false)]

        [string]$Dir = $ResolvedProjectDir

    )



    $wizardCfgPath = Get-WizardConfigPath -Dir $Dir

    $prodCfgPath = Join-Path $Dir "config.json"



    # Default server resolution: inspect config.json if present, else fallback to ntfy.sh

    $defaultServer = "https://ntfy.sh"

    $existingProdTopic = $null

    $existingDeviceName = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME } else { "Windows-PC" }

    $existingPrivacyMode = "TitleOnly"

    $existingCustomFields = @{

        IncludeDeviceName = $true

        IncludeAppName    = $true

        IncludeTitle      = $true

        IncludeBody       = $false

    }



    if (Test-Path $prodCfgPath) {

        try {

            $rawProd = Get-Content -Path $prodCfgPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue

            $parsedProd = $rawProd | ConvertFrom-Json -ErrorAction SilentlyContinue

            if ($parsedProd.NtfyServer -and (Test-ValidServerUrl $parsedProd.NtfyServer)) {

                $defaultServer = $parsedProd.NtfyServer.TrimEnd('/')

            }

            if ($parsedProd.NtfyTopic -and (Test-ValidTopicFormat $parsedProd.NtfyTopic)) {

                $existingProdTopic = [string]$parsedProd.NtfyTopic

            }

            if ($parsedProd.DeviceName) {

                $existingDeviceName = [string]$parsedProd.DeviceName

            }

            if ($parsedProd.PrivacyMode) {

                $existingPrivacyMode = [string]$parsedProd.PrivacyMode

            }

            if ($parsedProd.CustomPrivacyFields) {

                $pCust = $parsedProd.CustomPrivacyFields

                $existingCustomFields = @{

                    IncludeDeviceName = if ($null -ne $pCust.IncludeDeviceName) { [bool]$pCust.IncludeDeviceName } else { $true }

                    IncludeAppName    = if ($null -ne $pCust.IncludeAppName)    { [bool]$pCust.IncludeAppName } else { $true }

                    IncludeTitle      = if ($null -ne $pCust.IncludeTitle)      { [bool]$pCust.IncludeTitle } else { $true }

                    IncludeBody       = if ($null -ne $pCust.IncludeBody)       { [bool]$pCust.IncludeBody } else { $false }

                }

            }

        } catch { }

    }



    if (Test-Path $wizardCfgPath) {

        try {

            $raw = Get-Content -Path $wizardCfgPath -Raw -Encoding UTF8 -ErrorAction Stop

            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop

            if ($parsed.DeviceTopic -and (Test-ValidTopicFormat $parsed.DeviceTopic)) {

                $server = if ($parsed.NtfyServer -and (Test-ValidServerUrl $parsed.NtfyServer)) {

                    $parsed.NtfyServer.TrimEnd('/')

                } else {

                    $defaultServer

                }

                return @{

                    DeviceTopic         = [string]$parsed.DeviceTopic

                    NtfyServer          = $server

                    LastGenerated       = [string]$parsed.LastGenerated

                    LastTested          = [string]$parsed.LastTested

                    LastTestStatus      = [string]$parsed.LastTestStatus

                    DeviceName          = $existingDeviceName

                    PrivacyMode         = $existingPrivacyMode

                    CustomPrivacyFields = $existingCustomFields

                    IsExistingInstall   = ($existingProdTopic -ne $null)

                }

            }

        } catch { }

    }



    # If production config has a valid topic, use it

    if ($existingProdTopic -and (Test-ValidTopicFormat $existingProdTopic)) {

        return @{

            DeviceTopic         = $existingProdTopic

            NtfyServer          = $defaultServer

            LastGenerated       = $null

            LastTested          = $null

            LastTestStatus      = $null

            DeviceName          = $existingDeviceName

            PrivacyMode         = $existingPrivacyMode

            CustomPrivacyFields = $existingCustomFields

            IsExistingInstall   = $true

        }

    }



    # SAFE FIRST-RUN DEFAULT: Never automatically generate a key on startup/load.

    # The user must explicitly click "Generate New Key" to create a key.

    return @{

        DeviceTopic         = ""

        NtfyServer          = $defaultServer

        LastGenerated       = $null

        LastTested          = $null

        LastTestStatus      = $null

        DeviceName          = $existingDeviceName

        PrivacyMode         = $existingPrivacyMode

        CustomPrivacyFields = $existingCustomFields

        IsExistingInstall   = $false

    }

}



function Set-WizardConfig {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $true)]

        [string]$Dir,



        [Parameter(Mandatory = $true)]

        [hashtable]$Config

    )



    $wizardCfgPath = Get-WizardConfigPath -Dir $Dir

    $json = $Config | ConvertTo-Json -Depth 4

    [System.IO.File]::WriteAllText($wizardCfgPath, $json, [System.Text.Encoding]::UTF8)

}



function Generate-NewWizardKey {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $false)]

        [string]$Dir = $ResolvedProjectDir

    )



    $current = Get-WizardConfig -Dir $Dir

    $newTopic = New-DeviceTopic

    $current.DeviceTopic = $newTopic

    $current.LastGenerated = [DateTime]::UtcNow.ToString("o")

    $current.LastTested = $null

    $current.LastTestStatus = $null

    Set-WizardConfig -Dir $Dir -Config $current

    return $current

}



function Regenerate-WizardTopic {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $false)]

        [string]$Dir = $ResolvedProjectDir

    )

    return Generate-NewWizardKey -Dir $Dir

}



# --- 4. Production Forwarder Safe Integration ---

function Apply-WizardTopicToProduction {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $false)]

        [string]$Dir = $ResolvedProjectDir,



        [Parameter(Mandatory = $true)]

        [string]$Topic

    )



    if (-not (Test-ValidTopicFormat $Topic)) {

        return @{

            Success = $false

            Error   = "Invalid topic format. Topic must be 4-64 alphanumeric characters, hyphens, or underscores."

        }

    }



    $prodCfgPath = Join-Path $Dir "config.json"

    $backupPath = Join-Path $Dir "config.json.bak"

    $tempPath = Join-Path $Dir "config.json.tmp"



    if (-not (Test-Path $prodCfgPath)) {

        $examplePath = Join-Path $Dir "config.example.json"

        if (Test-Path $examplePath) {

            Copy-Item -Path $examplePath -Destination $prodCfgPath -Force

        } else {

            return @{

                Success = $false

                Error   = "Production configuration file '$prodCfgPath' was not found."

            }

        }

    }



    try {

        $raw = Get-Content -Path $prodCfgPath -Raw -Encoding UTF8 -ErrorAction Stop

        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop



        Copy-Item -Path $prodCfgPath -Destination $backupPath -Force



        $parsed.NtfyTopic = $Topic



        $newJson = $parsed | ConvertTo-Json -Depth 5

        [System.IO.File]::WriteAllText($tempPath, $newJson, [System.Text.Encoding]::UTF8)

        Move-Item -Path $tempPath -Destination $prodCfgPath -Force



        $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {

            $cmd = $_.CommandLine

            $cmd -and ($cmd -like "*NotificationForwarder.ps1*") -and ($cmd -notlike "*Watchdog.ps1*") -and ($cmd -notlike "*Test-*")

        })



        return @{

            Success      = $true

            NeedsRestart = ($procs.Count -gt 0)

            ProcessId    = if ($procs.Count -gt 0) { $procs[0].ProcessId } else { $null }

            BackupPath   = $backupPath

        }

    } catch {

        return @{

            Success = $false

            Error   = $_.Exception.Message

        }

    }

}



function Save-WizardSettingsToProduction {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $false)]

        [string]$Dir = $ResolvedProjectDir,



        [Parameter(Mandatory = $true)]

        [string]$Topic,



        [Parameter(Mandatory = $false)]

        [string]$DeviceName = "",



        [Parameter(Mandatory = $false)]

        [string]$PrivacyMode = "TitleOnly",



        [Parameter(Mandatory = $false)]

        [hashtable]$CustomPrivacyFields = $null

    )



    if (-not (Test-ValidTopicFormat $Topic)) {

        return @{

            Success = $false

            Error   = "Invalid topic format. Topic must be 4-64 alphanumeric characters, hyphens, or underscores."

        }

    }



    $prodCfgPath = Join-Path $Dir "config.json"

    $backupPath = Join-Path $Dir "config.json.bak"

    $tempPath = Join-Path $Dir "config.json.tmp"



    if (-not (Test-Path $prodCfgPath)) {

        $examplePath = Join-Path $Dir "config.example.json"

        if (Test-Path $examplePath) {

            Copy-Item -Path $examplePath -Destination $prodCfgPath -Force

        }

    }



    try {

        $raw = Get-Content -Path $prodCfgPath -Raw -Encoding UTF8 -ErrorAction Stop

        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop



        # Check if existing backup is identical to avoid redundant backup churn

        $shouldBackup = $true

        if (Test-Path $backupPath) {

            try {

                if ([System.IO.File]::ReadAllText($prodCfgPath).Trim() -eq [System.IO.File]::ReadAllText($backupPath).Trim()) {

                    $shouldBackup = $false

                }

            } catch { }

        }

        if ($shouldBackup) {

            Copy-Item -Path $prodCfgPath -Destination $backupPath -Force

        }



        # Safe property setter for PSCustomObject

        $setProp = {

            param($obj, [string]$name, $val)

            if ($obj.PSObject.Properties[$name]) {

                $obj.$name = $val

            } else {

                $obj | Add-Member -MemberType NoteProperty -Name $name -Value $val

            }

        }



        & $setProp $parsed "NtfyTopic" $Topic

        if (-not [string]::IsNullOrWhiteSpace($DeviceName)) {

            & $setProp $parsed "DeviceName" $DeviceName.Trim()

        }

        & $setProp $parsed "PrivacyMode" $PrivacyMode

        if ($CustomPrivacyFields) {

            & $setProp $parsed "CustomPrivacyFields" $CustomPrivacyFields

        }



        $newJson = $parsed | ConvertTo-Json -Depth 5

        [System.IO.File]::WriteAllText($tempPath, $newJson, [System.Text.Encoding]::UTF8)

        Move-Item -Path $tempPath -Destination $prodCfgPath -Force



        # Also update wizard_config.json

        $wizCfg = Get-WizardConfig -Dir $Dir

        $wizCfg.DeviceTopic = $Topic

        Set-WizardConfig -Dir $Dir -Config $wizCfg



        return @{ Success = $true }

    } catch {

        return @{ Success = $false; Error = $_.Exception.Message }

    }

}



# --- 5. Clipboard Integration ---

function Set-WizardClipboardText {

    param([string]$Text)



    if ([string]::IsNullOrEmpty($Text)) { return $false }



    try {

        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

        [System.Windows.Forms.Clipboard]::SetText($Text)

        return $true

    } catch {

        try {

            $process = Start-Process -FilePath "powershell.exe" `
                -ArgumentList "-NoProfile", "-STA", "-Command", "[System.Windows.Forms.Clipboard]::SetText('$Text')" `
                -WindowStyle Hidden -PassThru -Wait

            return ($process.ExitCode -eq 0)

        } catch {

            return $false

        }

    }

}



# --- 6. Test Notification Delivery ---

function Send-WizardTestNotification {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $true)]

        [string]$Server,



        [Parameter(Mandatory = $true)]

        [string]$Topic,



        [Parameter(Mandatory = $false)]

        [string]$DeviceName = "Windows-PC",



        [Parameter(Mandatory = $false)]

        [scriptblock]$CustomHttpHandler

    )



    if (-not (Test-ValidServerUrl $Server)) {

        return @{

            Success = $false

            Error   = "Invalid server URL. Must start with http:// or https://"

        }

    }



    if (-not (Test-ValidTopicFormat $Topic)) {

        return @{

            Success = $false

            Error   = "Invalid topic name. Topic must be 4-64 alphanumeric characters, hyphens, or underscores."

        }

    }



    $cleanServer = $Server.TrimEnd('/')

    $targetUrl = "$cleanServer/$Topic"

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    $payloadText = "Test notification from Windows at $timestamp. Check your iPhone to confirm notifications are working."



    $headers = @{

        "Title"    = "Windows Connection Test"

        "Priority" = "3"

        "Tags"     = "white_check_mark,bell"

    }



    if ($CustomHttpHandler) {

        try {

            $mockResponse = & $CustomHttpHandler -Url $targetUrl -Headers $headers -Body $payloadText

            $status = if ($mockResponse -and $mockResponse.StatusCode) { [int]$mockResponse.StatusCode } else { 200 }

            return @{

                Success    = ($status -eq 200)

                StatusCode = $status

                Message    = "Test notification delivered successfully! Check your iPhone for the 'Windows Connection Test' message."

            }

        } catch {

            $rawErr = $_.Exception.Message

            $cleanErr = $rawErr

            if (-not [string]::IsNullOrEmpty($Topic)) {

                $cleanErr = $cleanErr.Replace($Topic, "<redacted-topic>")

            }

            $cleanErr = [regex]::Replace($cleanErr, "https?://\S+", "<redacted-url>")

            return @{

                Success    = $false

                StatusCode = $null

                Error      = "Delivery failed: $cleanErr"

            }

        }

    }



    try {

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls



        $response = Invoke-RestMethod -Uri $targetUrl `
            -Method Post `
            -Headers $headers `
            -Body $payloadText `
            -ContentType "text/plain; charset=utf-8" `
            -TimeoutSec 10 `
            -ResponseHeadersVariable respHeaders `
            -ErrorAction Stop



        return @{

            Success    = $true

            StatusCode = 200

            Message    = "Test notification delivered successfully! Check your iPhone for the 'Windows Connection Test' message."

        }

    } catch {

        $status = $null

        if ($_.Exception.Response) {

            try { $status = [int]$_.Exception.Response.StatusCode } catch { }

        }



        $rawErr = $_.Exception.Message

        $cleanErr = $rawErr

        if (-not [string]::IsNullOrEmpty($Topic)) {

            $cleanErr = $cleanErr.Replace($Topic, "<redacted-topic>")

        }

        $cleanErr = [regex]::Replace($cleanErr, "https?://\S+", "<redacted-url>")



        $hint = if ($status -eq 404) {

            "Delivery failed: ntfy server returned 404 Not Found."

        } elseif ($cleanErr -match "timed out|Timeout") {

            "Delivery failed: Connection timed out. Check your computer's internet connection."

        } else {

            "Delivery failed: $cleanErr"

        }



        return @{

            Success    = $false

            StatusCode = $status

            Error      = $hint

        }

    }

}



# --- 7. Interactive Setup Wizard GUI ---

function Show-WizardGui {

    [CmdletBinding()]

    param(

        [Parameter(Mandatory = $false)]

        [string]$Dir = $ResolvedProjectDir

    )



    Add-Type -AssemblyName System.Windows.Forms

    Add-Type -AssemblyName System.Drawing



    # Single instance protection

    $script:wizardMutex = $null

    $createdNew = $false

    try {

        $script:wizardMutex = [System.Threading.Mutex]::new($true, "Local\NotificationForwarder_SetupWizard_SingleInstance", [ref]$createdNew)

        if (-not $createdNew) {

            [System.Windows.Forms.MessageBox]::Show(

                "The NotificationForwarder Setup Wizard is already open in another window.",

                "NotificationForwarder Setup",

                [System.Windows.Forms.MessageBoxButtons]::OK,

                [System.Windows.Forms.MessageBoxIcon]::Information

            ) | Out-Null

            return

        }

    } catch { }



    $cfg = Get-WizardConfig -Dir $Dir



    function Add-WizardSectionTitle {

        param(

            [System.Windows.Forms.Control]$Panel,

            [string]$Text

        )

        $heading = New-Object System.Windows.Forms.Label

        $heading.Location = New-Object System.Drawing.Point(24, 16)

        $heading.Size = New-Object System.Drawing.Size(($Panel.Width - 48), 28)

        $heading.Text = $Text

        $heading.Font = New-Object System.Drawing.Font("Segoe UI", 12.0, [System.Drawing.FontStyle]::Bold)

        $heading.Anchor = "Top, Left, Right"

        $heading.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        $heading.TabStop = $false

        $Panel.Controls.Add($heading)

    }



    # Form Window

    $form = New-Object System.Windows.Forms.Form

    $form.Text = "NotificationForwarder - One-Click Setup"

    $form.Size = New-Object System.Drawing.Size(960, 990)

    $form.StartPosition = "CenterScreen"

    $form.FormBorderStyle = "Sizable"

    $form.MinimumSize = New-Object System.Drawing.Size(760, 760)

    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $form.AutoScroll = $true

    $form.MaximizeBox = $true

    $form.MinimizeBox = $true

    $form.BackColor = [System.Drawing.Color]::FromArgb(239, 239, 239)

    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)



    # Header Panel

    $headerPanel = New-Object System.Windows.Forms.Panel

    $headerPanel.Location = New-Object System.Drawing.Point(28, 24)

    $headerPanel.Size = New-Object System.Drawing.Size(868, 94)

    $headerPanel.Anchor = "Top, Left, Right"

    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

    $form.Controls.Add($headerPanel)



    $lblTitle = New-Object System.Windows.Forms.Label

    $lblTitle.Location = New-Object System.Drawing.Point(24, 14)

    $lblTitle.Size = New-Object System.Drawing.Size(820, 36)

    $lblTitle.Text = "NotificationForwarder"

    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 21.0, [System.Drawing.FontStyle]::Bold)

    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $headerPanel.Controls.Add($lblTitle)



    $lblSubtitle = New-Object System.Windows.Forms.Label

    $lblSubtitle.Location = New-Object System.Drawing.Point(26, 57)

    $lblSubtitle.Size = New-Object System.Drawing.Size(820, 24)

    $lblSubtitle.Text = "Connect your iPhone, choose what notifications include, and start forwarding."

    $lblSubtitle.Font = New-Object System.Drawing.Font("Segoe UI", 10.0)

    $lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $headerPanel.Controls.Add($lblSubtitle)



    # ========================================================

    # Step 1: Your Notification KEY (Destination Topic)

    # ========================================================

    $grpStep1 = New-Object System.Windows.Forms.Panel

    $grpStep1.Location = New-Object System.Drawing.Point(28, 138)

    $grpStep1.Size = New-Object System.Drawing.Size(868, 195)

    $grpStep1.Anchor = "Top, Left, Right"

    $grpStep1.BackColor = [System.Drawing.Color]::White

    $form.Controls.Add($grpStep1)

    Add-WizardSectionTitle -Panel $grpStep1 -Text "01   Notification key"



    $lblTopicDesc = New-Object System.Windows.Forms.Label

    $lblTopicDesc.Location = New-Object System.Drawing.Point(24, 53)

    $lblTopicDesc.Size = New-Object System.Drawing.Size(820, 23)

    $lblTopicDesc.Text = "Your private ntfy channel. Click Generate New Key to create a key, or enter an existing topic. No remote registration is needed beforehand:"

    $lblTopicDesc.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

    $lblTopicDesc.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $grpStep1.Controls.Add($lblTopicDesc)



    $txtTopic = New-Object System.Windows.Forms.TextBox

    $txtTopic.Location = New-Object System.Drawing.Point(24, 84)

    $txtTopic.Size = New-Object System.Drawing.Size(676, 40)

    $txtTopic.ReadOnly = $false

    $txtTopic.Font = New-Object System.Drawing.Font("Consolas", 12.0, [System.Drawing.FontStyle]::Bold)

    $txtTopic.BackColor = [System.Drawing.Color]::FromArgb(239, 239, 239)

    $txtTopic.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $txtTopic.BorderStyle = "None"

    $txtTopic.Text = $cfg.DeviceTopic

    $grpStep1.Controls.Add($txtTopic)



    # Copy Topic Button

    $btnCopyTopic1 = New-Object System.Windows.Forms.Button

    $btnCopyTopic1.Location = New-Object System.Drawing.Point(712, 82)

    $btnCopyTopic1.Size = New-Object System.Drawing.Size(132, 44)

    $btnCopyTopic1.Text = "Copy key"

    $btnCopyTopic1.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

    $btnCopyTopic1.BackColor = [System.Drawing.Color]::FromArgb(35, 76, 226)

    $btnCopyTopic1.ForeColor = [System.Drawing.Color]::White

    $btnCopyTopic1.FlatStyle = "Flat"

    $btnCopyTopic1.FlatAppearance.BorderSize = 0

    $grpStep1.Controls.Add($btnCopyTopic1)



    # Copy Subscription URL Button

    $btnCopyUrl = New-Object System.Windows.Forms.Button

    $btnCopyUrl.Location = New-Object System.Drawing.Point(24, 140)

    $btnCopyUrl.Size = New-Object System.Drawing.Size(198, 40)

    $btnCopyUrl.Text = "Copy subscription URL"

    $btnCopyUrl.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

    $btnCopyUrl.BackColor = [System.Drawing.Color]::FromArgb(35, 76, 226)

    $btnCopyUrl.ForeColor = [System.Drawing.Color]::White

    $btnCopyUrl.FlatStyle = "Flat"

    $btnCopyUrl.FlatAppearance.BorderSize = 0

    $grpStep1.Controls.Add($btnCopyUrl)



    # Regenerate Topic Button

    $btnRegen = New-Object System.Windows.Forms.Button

    $btnRegen.Location = New-Object System.Drawing.Point(234, 140)

    $btnRegen.Size = New-Object System.Drawing.Size(182, 40)

    $btnRegen.Text = "Generate New Key"

    $btnRegen.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

    $btnRegen.BackColor = [System.Drawing.Color]::FromArgb(35, 76, 226)

    $btnRegen.ForeColor = [System.Drawing.Color]::White

    $btnRegen.FlatStyle = "Flat"

    $btnRegen.FlatAppearance.BorderSize = 0

    $grpStep1.Controls.Add($btnRegen)



    # Inline Status Label for Step 1

    $lblStep1Status = New-Object System.Windows.Forms.Label

    $lblStep1Status.Location = New-Object System.Drawing.Point(438, 143)

    $lblStep1Status.Size = New-Object System.Drawing.Size(406, 34)

    $lblStep1Status.Text = if ($cfg.IsExistingInstall) {

        "Existing topic loaded from config.json"

    } elseif ([string]::IsNullOrWhiteSpace($cfg.DeviceTopic)) {

        "Not configured. Click ''Generate New Key'' to create your unique topic."

    } else {

        "Topic ready. Copy and enter it in ntfy on your iPhone."

    }

    $lblStep1Status.Font = New-Object System.Drawing.Font("Segoe UI", 9.0, [System.Drawing.FontStyle]::Bold)

    $lblStep1Status.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $grpStep1.Controls.Add($lblStep1Status)



    # ========================================================

    # Step 2: Device Name & Notification Privacy

    # ========================================================

    $grpStep2 = New-Object System.Windows.Forms.Panel

    $grpStep2.Location = New-Object System.Drawing.Point(28, 351)

    $grpStep2.Size = New-Object System.Drawing.Size(868, 318)

    $grpStep2.Anchor = "Top, Left, Right"

    $grpStep2.BackColor = [System.Drawing.Color]::White

    $form.Controls.Add($grpStep2)

    Add-WizardSectionTitle -Panel $grpStep2 -Text "02   Device and privacy"



    $lblDevName = New-Object System.Windows.Forms.Label

    $lblDevName.Location = New-Object System.Drawing.Point(24, 57)

    $lblDevName.Size = New-Object System.Drawing.Size(160, 24)

    $lblDevName.Text = "Device name"

    $lblDevName.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

    $lblDevName.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $grpStep2.Controls.Add($lblDevName)



    $txtDeviceName = New-Object System.Windows.Forms.TextBox

    $txtDeviceName.Location = New-Object System.Drawing.Point(200, 53)

    $txtDeviceName.Size = New-Object System.Drawing.Size(620, 36)

    $txtDeviceName.Font = New-Object System.Drawing.Font("Segoe UI", 10.0, [System.Drawing.FontStyle]::Bold)

    $txtDeviceName.BackColor = [System.Drawing.Color]::FromArgb(239, 239, 239)

    $txtDeviceName.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $txtDeviceName.BorderStyle = "None"

    $txtDeviceName.Text = $cfg.DeviceName

    $grpStep2.Controls.Add($txtDeviceName)



    $lblPrivacy = New-Object System.Windows.Forms.Label

    $lblPrivacy.Location = New-Object System.Drawing.Point(24, 101)

    $lblPrivacy.Size = New-Object System.Drawing.Size(820, 24)

    $lblPrivacy.Text = "What should each notification include?"

    $lblPrivacy.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

    $lblPrivacy.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $grpStep2.Controls.Add($lblPrivacy)



    $rbTitleOnly = New-Object System.Windows.Forms.RadioButton

    $rbTitleOnly.Location = New-Object System.Drawing.Point(24, 130)

    $rbTitleOnly.Size = New-Object System.Drawing.Size(820, 25)

    $rbTitleOnly.Text = "Title only    -    Recommended; notification body stays private"

    $rbTitleOnly.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

    $rbTitleOnly.Checked = ($cfg.PrivacyMode -eq "TitleOnly")

    $grpStep2.Controls.Add($rbTitleOnly)



    $rbTitleAndBody = New-Object System.Windows.Forms.RadioButton

    $rbTitleAndBody.Location = New-Object System.Drawing.Point(24, 159)

    $rbTitleAndBody.Size = New-Object System.Drawing.Size(820, 25)

    $rbTitleAndBody.Text = "Title and body    -    Send the complete notification message"

    $rbTitleAndBody.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

    $rbTitleAndBody.Checked = ($cfg.PrivacyMode -eq "TitleAndBody")

    $grpStep2.Controls.Add($rbTitleAndBody)



    $rbCustom = New-Object System.Windows.Forms.RadioButton

    $rbCustom.Location = New-Object System.Drawing.Point(24, 188)

    $rbCustom.Size = New-Object System.Drawing.Size(820, 25)

    $rbCustom.Text = "Choose specific fields"

    $rbCustom.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

    $rbCustom.Checked = ($cfg.PrivacyMode -eq "Custom")

    $grpStep2.Controls.Add($rbCustom)



    # Custom Checkboxes

    $pnlCustom = New-Object System.Windows.Forms.Panel

    $pnlCustom.Location = New-Object System.Drawing.Point(48, 215)

    $pnlCustom.Size = New-Object System.Drawing.Size(380, 26)

    $pnlCustom.BackColor = [System.Drawing.Color]::White

    $grpStep2.Controls.Add($pnlCustom)



    $chkDev = New-Object System.Windows.Forms.CheckBox

    $chkDev.Location = New-Object System.Drawing.Point(0, 2)

    $chkDev.Size = New-Object System.Drawing.Size(95, 20)

    $chkDev.Text = "Device"

    $chkDev.Font = New-Object System.Drawing.Font("Segoe UI", 8.0)

    $chkDev.Checked = $cfg.CustomPrivacyFields.IncludeDeviceName

    $chkDev.Enabled = $rbCustom.Checked

    $pnlCustom.Controls.Add($chkDev)



    $chkApp = New-Object System.Windows.Forms.CheckBox

    $chkApp.Location = New-Object System.Drawing.Point(95, 2)

    $chkApp.Size = New-Object System.Drawing.Size(90, 20)

    $chkApp.Text = "App"

    $chkApp.Font = New-Object System.Drawing.Font("Segoe UI", 8.0)

    $chkApp.Checked = $cfg.CustomPrivacyFields.IncludeAppName

    $chkApp.Enabled = $rbCustom.Checked

    $pnlCustom.Controls.Add($chkApp)



    $chkTitle = New-Object System.Windows.Forms.CheckBox

    $chkTitle.Location = New-Object System.Drawing.Point(185, 2)

    $chkTitle.Size = New-Object System.Drawing.Size(90, 20)

    $chkTitle.Text = "Title"

    $chkTitle.Font = New-Object System.Drawing.Font("Segoe UI", 8.0)

    $chkTitle.Checked = $cfg.CustomPrivacyFields.IncludeTitle

    $chkTitle.Enabled = $rbCustom.Checked

    $pnlCustom.Controls.Add($chkTitle)



    $chkBody = New-Object System.Windows.Forms.CheckBox

    $chkBody.Location = New-Object System.Drawing.Point(275, 2)

    $chkBody.Size = New-Object System.Drawing.Size(95, 20)

    $chkBody.Text = "Body"

    $chkBody.Font = New-Object System.Drawing.Font("Segoe UI", 8.0)

    $chkBody.Checked = $cfg.CustomPrivacyFields.IncludeBody

    $chkBody.Enabled = $rbCustom.Checked

    $pnlCustom.Controls.Add($chkBody)



    # Live Preview Box

    $pnlPrev = New-Object System.Windows.Forms.Panel

    $pnlPrev.Location = New-Object System.Drawing.Point(24, 254)

    $pnlPrev.Size = New-Object System.Drawing.Size(820, 48)

    $pnlPrev.BackColor = [System.Drawing.Color]::FromArgb(239, 239, 239)

    $pnlPrev.BorderStyle = "None"

    $grpStep2.Controls.Add($pnlPrev)



    $lblPrevTitle = New-Object System.Windows.Forms.Label

    $lblPrevTitle.Location = New-Object System.Drawing.Point(12, 5)

    $lblPrevTitle.Size = New-Object System.Drawing.Size(790, 16)

    $lblPrevTitle.Text = "Preview on iPhone"

    $lblPrevTitle.Font = New-Object System.Drawing.Font("Segoe UI", 8.0, [System.Drawing.FontStyle]::Bold)

    $lblPrevTitle.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $pnlPrev.Controls.Add($lblPrevTitle)



    $lblPrevContent = New-Object System.Windows.Forms.Label

    $lblPrevContent.Location = New-Object System.Drawing.Point(12, 22)

    $lblPrevContent.Size = New-Object System.Drawing.Size(790, 19)

    $lblPrevContent.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

    $lblPrevContent.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $pnlPrev.Controls.Add($lblPrevContent)



    # Update Preview Logic

    $updatePreviewAction = {

        $d = if ($txtDeviceName.Text.Trim()) { $txtDeviceName.Text.Trim() } else { "Windows-PC" }

        $app = "WhatsApp"

        $title = "New Message"

        $body = "Meeting is at 3 PM today."



        $parts = [System.Collections.ArrayList]::new()

        if ($rbTitleOnly.Checked) {

            $parts.Add("[$d] $app`: $title") | Out-Null

        } elseif ($rbTitleAndBody.Checked) {

            $parts.Add("[$d] $app`: $title - $body") | Out-Null

        } else {

            $sub = ""

            if ($chkDev.Checked) { $sub += "[$d] " }

            if ($chkApp.Checked) { $sub += "$app`: " }

            if ($chkTitle.Checked) { $sub += "$title " }

            if ($chkBody.Checked) { $sub += "- $body" }

            $parts.Add($sub.Trim()) | Out-Null

        }

        $lblPrevContent.Text = $parts[0]

    }



    $rbTitleOnly.Add_CheckedChanged({

        $chkDev.Enabled = $rbCustom.Checked

        $chkApp.Enabled = $rbCustom.Checked

        $chkTitle.Enabled = $rbCustom.Checked

        $chkBody.Enabled = $rbCustom.Checked

        & $updatePreviewAction

    })

    $rbTitleAndBody.Add_CheckedChanged({

        $chkDev.Enabled = $rbCustom.Checked

        $chkApp.Enabled = $rbCustom.Checked

        $chkTitle.Enabled = $rbCustom.Checked

        $chkBody.Enabled = $rbCustom.Checked

        & $updatePreviewAction

    })

    $rbCustom.Add_CheckedChanged({

        $chkDev.Enabled = $rbCustom.Checked

        $chkApp.Enabled = $rbCustom.Checked

        $chkTitle.Enabled = $rbCustom.Checked

        $chkBody.Enabled = $rbCustom.Checked

        & $updatePreviewAction

    })

    $txtDeviceName.Add_TextChanged($updatePreviewAction)

    $chkDev.Add_CheckedChanged($updatePreviewAction)

    $chkApp.Add_CheckedChanged($updatePreviewAction)

    $chkTitle.Add_CheckedChanged($updatePreviewAction)

    $chkBody.Add_CheckedChanged($updatePreviewAction)

    & $updatePreviewAction



    # ========================================================

    # Step 3: Connect iPhone & Test Connection

    # ========================================================

    $grpStep3 = New-Object System.Windows.Forms.Panel

    $grpStep3.Location = New-Object System.Drawing.Point(28, 687)

    $grpStep3.Size = New-Object System.Drawing.Size(425, 230)

    $grpStep3.Anchor = "Top, Left"

    $grpStep3.BackColor = [System.Drawing.Color]::White

    $form.Controls.Add($grpStep3)

    Add-WizardSectionTitle -Panel $grpStep3 -Text "03   Connect and test"



    $lblSteps = New-Object System.Windows.Forms.Label

    $lblSteps.Location = New-Object System.Drawing.Point(24, 56)

    $lblSteps.Size = New-Object System.Drawing.Size(377, 58)

    $lblSteps.Text = "1. Install ntfy from App Store on your iPhone.`n2. Tap '+', enter your KEY, and tap Subscribe.`n3. Click 'Send Test Notification' to verify delivery."

    $lblSteps.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

    $lblSteps.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $grpStep3.Controls.Add($lblSteps)



    $btnSendTest = New-Object System.Windows.Forms.Button

    $btnSendTest.Location = New-Object System.Drawing.Point(24, 121)

    $btnSendTest.Size = New-Object System.Drawing.Size(377, 42)

    $btnSendTest.Text = "Send test notification"

    $btnSendTest.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

    $btnSendTest.BackColor = [System.Drawing.Color]::FromArgb(35, 76, 226)

    $btnSendTest.ForeColor = [System.Drawing.Color]::White

    $btnSendTest.FlatStyle = "Flat"

    $btnSendTest.FlatAppearance.BorderSize = 0

    $grpStep3.Controls.Add($btnSendTest)



    $lblTestResult = New-Object System.Windows.Forms.Label

    $lblTestResult.Location = New-Object System.Drawing.Point(24, 174)

    $lblTestResult.Size = New-Object System.Drawing.Size(377, 42)

    $lblTestResult.Text = "Ready. After subscribing in the ntfy app, click 'Send Test Notification'."

    $lblTestResult.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)

    $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $grpStep3.Controls.Add($lblTestResult)



    # ========================================================

    # Step 4: Finish Setup & Start Actions

    # ========================================================

    $grpStep4 = New-Object System.Windows.Forms.Panel

    $grpStep4.Location = New-Object System.Drawing.Point(471, 687)

    $grpStep4.Size = New-Object System.Drawing.Size(425, 230)

    $grpStep4.Anchor = "Top, Left"

    $grpStep4.BackColor = [System.Drawing.Color]::White

    $form.Controls.Add($grpStep4)

    Add-WizardSectionTitle -Panel $grpStep4 -Text "04   Start forwarding"



    $lblFinishDesc = New-Object System.Windows.Forms.Label

    $lblFinishDesc.Location = New-Object System.Drawing.Point(24, 54)

    $lblFinishDesc.Size = New-Object System.Drawing.Size(377, 38)

    $lblFinishDesc.Text = "Choose apps in the Dashboard, or start forwarding now."

    $lblFinishDesc.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

    $lblFinishDesc.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $grpStep4.Controls.Add($lblFinishDesc)



    # Primary Action: Continue to Dashboard

    $btnDashboard = New-Object System.Windows.Forms.Button

    $btnDashboard.Location = New-Object System.Drawing.Point(24, 98)

    $btnDashboard.Size = New-Object System.Drawing.Size(377, 42)

    $btnDashboard.Text = "Continue to dashboard - Choose apps"

    $btnDashboard.Font = New-Object System.Drawing.Font("Segoe UI", 9.0, [System.Drawing.FontStyle]::Bold)

    $btnDashboard.BackColor = [System.Drawing.Color]::FromArgb(35, 76, 226)

    $btnDashboard.ForeColor = [System.Drawing.Color]::White

    $btnDashboard.FlatStyle = "Flat"

    $btnDashboard.FlatAppearance.BorderSize = 0

    $grpStep4.Controls.Add($btnDashboard)



    # Secondary Action: Start Push Notification (One-Click)

    $btnStartPush = New-Object System.Windows.Forms.Button

    $btnStartPush.Location = New-Object System.Drawing.Point(24, 148)

    $btnStartPush.Size = New-Object System.Drawing.Size(377, 42)

    $btnStartPush.Text = "Start push notifications"

    $btnStartPush.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

    $btnStartPush.BackColor = [System.Drawing.Color]::FromArgb(35, 76, 226)

    $btnStartPush.ForeColor = [System.Drawing.Color]::White

    $btnStartPush.FlatStyle = "Flat"

    $btnStartPush.FlatAppearance.BorderSize = 0

    $grpStep4.Controls.Add($btnStartPush)



    $lblActionStatus = New-Object System.Windows.Forms.Label

    $lblActionStatus.Location = New-Object System.Drawing.Point(24, 198)

    $lblActionStatus.Size = New-Object System.Drawing.Size(377, 23)

    $lblActionStatus.Text = "Runs quietly when Windows starts."

    $lblActionStatus.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)

    $lblActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    $grpStep4.Controls.Add($lblActionStatus)



    # ========================================================

    # EVENT HANDLERS

    # ========================================================



    # Helper: Copy Topic Action

    $handleCopyTopic = {

        $topicToCopy = $txtTopic.Text.Trim()

        $copied = Set-WizardClipboardText -Text $topicToCopy

        if ($copied) {

            $lblStep1Status.Text = "KEY copied to clipboard!"

            $lblStep1Status.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        } else {

            $lblStep1Status.Text = "Could not access clipboard. Please copy manually."

            $lblStep1Status.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        }

    }

    $btnCopyTopic1.Add_Click($handleCopyTopic)



    # Copy URL Action

    $btnCopyUrl.Add_Click({

        $currentCfg = Get-WizardConfig -Dir $Dir

        $server = $currentCfg.NtfyServer.TrimEnd('/')

        $subUrl = "$server/$($txtTopic.Text.Trim())"

        $copied = Set-WizardClipboardText -Text $subUrl

        if ($copied) {

            $lblStep1Status.Text = "Subscription URL copied: $subUrl"

            $lblStep1Status.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        } else {

            $lblStep1Status.Text = "Could not access clipboard."

            $lblStep1Status.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        }

    })



    # Explicit Generate New Key Action (with confirmation if overwriting existing key)

    $btnRegen.Add_Click({

        $currentTopic = $txtTopic.Text.Trim()

        if (-not [string]::IsNullOrWhiteSpace($currentTopic)) {

            $confirm = [System.Windows.Forms.MessageBox]::Show(

                "Generating a new key will replace your current notification topic.`n`nAny phones, devices, or subscriptions listening to the old key will STOP receiving notifications until updated with the new key.`n`nDo you want to proceed?",

                "Generate New Key",

                [System.Windows.Forms.MessageBoxButtons]::YesNo,

                [System.Windows.Forms.MessageBoxIcon]::Warning

            )

            if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {

                return

            }

        }

        $newCfg = Generate-NewWizardKey -Dir $Dir

        $txtTopic.Text = $newCfg.DeviceTopic

        $lblStep1Status.Text = "New key generated locally! Click ''Copy key'' and enter it in ntfy on your iPhone."

        $lblStep1Status.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        $lblTestResult.Text = "Key generated. Subscribe to this topic on your iPhone before sending a test notification."

        $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

    })



    # Send Test Notification Action

    $btnSendTest.Add_Click({

        $btnSendTest.Enabled = $false

        $btnSendTest.Text = "Sending..."

        $lblTestResult.Text = "Connecting to ntfy server..."

        $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        $form.Refresh()



        $topicVal = $txtTopic.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($topicVal)) {

            $btnSendTest.Enabled = $true

            $btnSendTest.Text = "Send Test Notification"

            $lblTestResult.Text = "Cannot send test: Notification key is empty. Please click ''Generate New Key'' first."

            $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

            return

        }

        $currentCfg = Get-WizardConfig -Dir $Dir

        $devName = if ($txtDeviceName.Text.Trim()) { $txtDeviceName.Text.Trim() } else { "Windows-PC" }

        $res = Send-WizardTestNotification `
            -Server $currentCfg.NtfyServer `
            -Topic $topicVal `
            -DeviceName $devName



        $btnSendTest.Enabled = $true

        $btnSendTest.Text = "Send Test Notification"



        if ($res.Success) {

            $lblTestResult.Text = "Success (HTTP $($res.StatusCode))! Test notification delivered.`nPlease check your iPhone."

            $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)



            $currentCfg.LastTested = [DateTime]::UtcNow.ToString("o")

            $currentCfg.LastTestStatus = "Success (HTTP $($res.StatusCode))"

            Set-WizardConfig -Dir $Dir -Config $currentCfg

        } else {

            $lblTestResult.Text = "$($res.Error)"

            $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)



            $currentCfg.LastTested = [DateTime]::UtcNow.ToString("o")

            $currentCfg.LastTestStatus = "Failed: $($res.Error)"

            Set-WizardConfig -Dir $Dir -Config $currentCfg

        }

    })



    # Save settings helper

    $saveSettingsInternal = {

        $pMode = if ($rbTitleOnly.Checked) { "TitleOnly" } elseif ($rbTitleAndBody.Checked) { "TitleAndBody" } else { "Custom" }

        $custFields = @{

            IncludeDeviceName = $chkDev.Checked

            IncludeAppName    = $chkApp.Checked

            IncludeTitle      = $chkTitle.Checked

            IncludeBody       = $chkBody.Checked

        }

        $saveRes = Save-WizardSettingsToProduction `
            -Dir $Dir `
            -Topic $txtTopic.Text.Trim() `
            -DeviceName $txtDeviceName.Text.Trim() `
            -PrivacyMode $pMode `
            -CustomPrivacyFields $custFields

        return $saveRes

    }



    # Continue to Dashboard Action

    $btnDashboard.Add_Click({

        $btnDashboard.Enabled = $false

        $lblActionStatus.Text = "Saving configuration and launching Dashboard..."

        $lblActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        $form.Refresh()



        $saveRes = & $saveSettingsInternal

        if (-not $saveRes.Success) {

            [System.Windows.Forms.MessageBox]::Show("Failed to save configuration: $($saveRes.Error)", "Configuration Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)

            $btnDashboard.Enabled = $true

            return

        }



        # Launch Dashboard

        $dashScript = Join-Path $Dir "Start-Dashboard.ps1"

        try {

            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$dashScript`" -OpenBrowser -ProjectDir `"$Dir`"" -WorkingDirectory $Dir -WindowStyle Hidden

            $lblActionStatus.Text = "Dashboard opened in your browser. Choose applications, then start forwarding."

            $lblActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        } catch {

            [System.Windows.Forms.MessageBox]::Show("Could not launch Dashboard automatically. Run 'NotificationForwarder Dashboard.cmd' manually.", "Note", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)

        }

        $btnDashboard.Enabled = $true

    })



    # Start Push Notification Action (One-Click)

    $btnStartPush.Add_Click({

        $topicVal = $txtTopic.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($topicVal)) {

            [System.Windows.Forms.MessageBox]::Show(

                "Notification Key is required before starting live forwarding.`n`nPlease click ''Generate New Key'' or enter a valid topic first.",

                "Setup Required",

                [System.Windows.Forms.MessageBoxButtons]::OK,

                [System.Windows.Forms.MessageBoxIcon]::Warning

            )

            return

        }



        # Check Windows notification permission

        $perm = Test-NotificationPermission

        if (-not $perm.Allowed -and $perm.Status -ne "Unavailable") {

            $ans = [System.Windows.Forms.MessageBox]::Show(

                "Windows Notification access is not Allowed ($($perm.Status)).`n`nPlease ensure notifications are enabled in Windows Settings > Privacy & security > Notifications.`n`nWould you like to proceed anyway?",

                "Notification Permission",

                [System.Windows.Forms.MessageBoxButtons]::YesNo,

                [System.Windows.Forms.MessageBoxIcon]::Warning

            )

            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {

                $lblActionStatus.Text = "Setup paused: Notification permission required."

                return

            }

        }



        $maskedTopic = if ($topicVal.Length -gt 8) {

            $topicVal.Substring(0, 4) + "..." + $topicVal.Substring($topicVal.Length - 4)

        } else { "***" }



        $pMode = if ($rbTitleOnly.Checked) { "TitleOnly" } elseif ($rbTitleAndBody.Checked) { "TitleAndBody" } else { "Custom" }

        $devName = if ($txtDeviceName.Text.Trim()) { $txtDeviceName.Text.Trim() } else { "Windows-PC" }



        $confirm = [System.Windows.Forms.MessageBox]::Show(

            "Activate Live Notification Forwarding?`n`n" +

            "Review Configuration:`n" +

            "  Device Name:   $devName`n" +

            "  Privacy Mode:  $pMode`n" +

            "  Destination:   $maskedTopic`n`n" +

            "This will:`n" +

            "1. Enable live notification forwarding in config.json`n" +

            "2. Register Windows scheduled tasks for automatic startup at logon`n" +

            "3. Start the background forwarder daemon and hidden watchdog supervisor`n`n" +

            "Do you want to proceed?",

            "Start Push Notification Confirmation",

            [System.Windows.Forms.MessageBoxButtons]::YesNo,

            [System.Windows.Forms.MessageBoxIcon]::Question

        )

        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {

            return

        }



        $btnStartPush.Enabled = $false

        $btnStartPush.Text = "Starting..."

        $lblActionStatus.Text = "Validating settings, registering startup tasks, and starting forwarder & watchdog..."

        $lblActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        $form.Refresh()



        $saveRes = & $saveSettingsInternal

        if (-not $saveRes.Success) {

            [System.Windows.Forms.MessageBox]::Show("Failed to save configuration: $($saveRes.Error)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)

            $btnStartPush.Enabled = $true

            $btnStartPush.Text = "Start push notifications"

            return

        }



        # Execute Invoke-StartPushNotification

        $startRes = if (Get-Command "Invoke-StartPushNotification" -ErrorAction SilentlyContinue) {

            Invoke-StartPushNotification -ProjectDir $Dir

        } else {

            # Direct recovery if function not available

            $recScript = Join-Path $Dir "Recover-NotificationForwarder.ps1"

            & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $recScript -ProjectDir $Dir -NonInteractive -PassThru

        }



        $btnStartPush.Enabled = $true

        $btnStartPush.Text = "Start push notifications"



        if ($startRes.Success) {

            $msg = "Live Notification Forwarder is ACTIVE!`n`n" +

                   "Process ID: $($startRes.ProcessId)`n" +

                   "Automatic Startup: Configured for Windows logon`n" +

                   "Watchdog Supervisor: Active (supervises every 1 minute)`n`n" +

                   "You can manage applications and settings at any time using 'NotificationForwarder Dashboard.cmd'."

            [System.Windows.Forms.MessageBox]::Show($msg, "NotificationForwarder - Live", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)

            $lblActionStatus.Text = "Live push notifications are active (PID $($startRes.ProcessId)) and configured for automatic startup."

            $lblActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        } else {

            $err = if ($startRes.Error) { $startRes.Error } else { "Failed to start service." }

            [System.Windows.Forms.MessageBox]::Show("Service Startup Issue: $err", "Startup Notice", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)

            $lblActionStatus.Text = "Startup issue: $err"

            $lblActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(33, 33, 33)

        }

    })



    function Set-WizardPalette {

        param([System.Windows.Forms.Control]$Control)

        $ink = [System.Drawing.Color]::FromArgb(33, 33, 33)

        $page = [System.Drawing.Color]::FromArgb(239, 239, 239)

        $action = [System.Drawing.Color]::FromArgb(35, 76, 226)



        if ($Control -is [System.Windows.Forms.Button]) {

            $Control.BackColor = $action

            $Control.ForeColor = [System.Drawing.Color]::White

            $Control.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

            $Control.UseVisualStyleBackColor = $false

            $Control.FlatAppearance.BorderSize = 0

            $Control.FlatAppearance.BorderColor = $action

            $Control.FlatAppearance.MouseOverBackColor = $action

            $Control.FlatAppearance.MouseDownBackColor = $action

        } elseif ($Control -is [System.Windows.Forms.TextBox]) {

            $Control.BackColor = $page

            $Control.ForeColor = $ink

            $Control.BorderStyle = [System.Windows.Forms.BorderStyle]::None

        } else {

            $Control.ForeColor = $ink

            if (($Control -is [System.Windows.Forms.RadioButton] -or $Control -is [System.Windows.Forms.CheckBox]) -and $Control.Parent) {

                $Control.BackColor = $Control.Parent.BackColor

            }

        }



        foreach ($child in $Control.Controls) {

            Set-WizardPalette -Control $child

        }

    }



    function Set-WizardCornerRadius {

        param(

            [Parameter(Mandatory = $true)]

            [System.Windows.Forms.Control]$Control,



            [Parameter(Mandatory = $true)]

            [int]$Radius

        )



        $cornerRadius = [Math]::Max(1, $Radius)

        $updateRegion = {

            param($Sender, $EventArgs)



            if ($Sender.Width -lt 2 -or $Sender.Height -lt 2) { return }



            $diameter = [Math]::Min(($cornerRadius * 2), [Math]::Min($Sender.Width, $Sender.Height))

            $path = New-Object System.Drawing.Drawing2D.GraphicsPath

            [void]$path.AddArc(0, 0, $diameter, $diameter, 180, 90)

            [void]$path.AddArc(($Sender.Width - $diameter), 0, $diameter, $diameter, 270, 90)

            [void]$path.AddArc(($Sender.Width - $diameter), ($Sender.Height - $diameter), $diameter, $diameter, 0, 90)

            [void]$path.AddArc(0, ($Sender.Height - $diameter), $diameter, $diameter, 90, 90)

            $path.CloseFigure()



            $previousRegion = $Sender.Region

            $Sender.Region = [System.Drawing.Region]::new($path)

            if ($previousRegion) { $previousRegion.Dispose() }

            $path.Dispose()

        }.GetNewClosure()



        $Control.Add_SizeChanged($updateRegion)

        & $updateRegion $Control $null

    }



    $updateWizardLayout = {

        $fullWidth = [Math]::Max(680, ($form.ClientSize.Width - 56))

        $columnWidth = [Math]::Floor(($fullWidth - 18) / 2)

        $secondColumnX = 28 + $columnWidth + 18



        $headerPanel.Width = $fullWidth

        $grpStep1.Width = $fullWidth

        $grpStep2.Width = $fullWidth

        $grpStep3.Width = $columnWidth

        $grpStep4.Width = $columnWidth

        $grpStep4.Left = $secondColumnX



        $lblTitle.Width = $fullWidth - 48

        $lblSubtitle.Width = $fullWidth - 52



        $lblTopicDesc.Width = $fullWidth - 48

        $txtTopic.Width = $fullWidth - 192

        $btnCopyTopic1.Left = $fullWidth - 156

        $lblStep1Status.Width = $fullWidth - 462



        $lblDevName.Width = 160

        $txtDeviceName.Width = $fullWidth - 224

        $lblPrivacy.Width = $fullWidth - 48

        $rbTitleOnly.Width = $fullWidth - 48

        $rbTitleAndBody.Width = $fullWidth - 48

        $rbCustom.Width = $fullWidth - 48

        $pnlPrev.Width = $fullWidth - 48

        $lblPrevTitle.Width = $pnlPrev.Width - 24

        $lblPrevContent.Width = $pnlPrev.Width - 24



        $lblSteps.Width = $columnWidth - 48

        $btnSendTest.Width = $columnWidth - 48

        $lblTestResult.Width = $columnWidth - 48



        $lblFinishDesc.Width = $columnWidth - 48

        $btnDashboard.Width = $columnWidth - 48

        $btnStartPush.Width = $columnWidth - 48

        $lblActionStatus.Width = $columnWidth - 48

    }.GetNewClosure()

    $form.Add_SizeChanged($updateWizardLayout)

    & $updateWizardLayout



    Set-WizardPalette -Control $form



    # Round the main cards and interactive controls so the setup screen feels softer.

    Set-WizardCornerRadius -Control $headerPanel -Radius 16

    Set-WizardCornerRadius -Control $grpStep1 -Radius 20

    Set-WizardCornerRadius -Control $grpStep2 -Radius 20

    Set-WizardCornerRadius -Control $grpStep3 -Radius 20

    Set-WizardCornerRadius -Control $grpStep4 -Radius 20

    Set-WizardCornerRadius -Control $pnlPrev -Radius 14

    Set-WizardCornerRadius -Control $txtTopic -Radius 10

    Set-WizardCornerRadius -Control $txtDeviceName -Radius 10

    foreach ($wizardButton in @($btnCopyTopic1, $btnCopyUrl, $btnRegen, $btnSendTest, $btnDashboard, $btnStartPush)) {

        Set-WizardCornerRadius -Control $wizardButton -Radius 13

    }



    # Show Modal Form

    $form.Add_Shown({

        $form.Activate()

        $txtTopic.SelectAll()

    })



    [void]$form.ShowDialog()

    $form.Dispose()

}



# --- 8. Execution Entry Point ---

if ($NonInteractive) {

    # Non-interactive CLI / Test Automation Mode

    $cfg = Get-WizardConfig -Dir $ResolvedProjectDir



    if ($RegenerateTopic) {

        $cfg = Regenerate-WizardTopic -Dir $ResolvedProjectDir

    }



    if ($CustomServer) {

        $cfg.NtfyServer = $CustomServer

        Set-WizardConfig -Dir $ResolvedProjectDir -Config $cfg

    }



    if ($CustomTopic) {

        $cfg.DeviceTopic = $CustomTopic

        Set-WizardConfig -Dir $ResolvedProjectDir -Config $cfg

    }



    $testResult = $null

    if ($TestConnection) {

        $testResult = Send-WizardTestNotification `
            -Server $cfg.NtfyServer `
            -Topic $cfg.DeviceTopic `
            -CustomHttpHandler $CustomHttpHandler

    }



    $applyResult = $null

    if ($ApplyToProduction) {

        $applyResult = Apply-WizardTopicToProduction `
            -Dir $ResolvedProjectDir `
            -Topic $cfg.DeviceTopic

    }



    $startPushResult = $null

    if ($StartPushNotification) {

        if (Get-Command "Invoke-StartPushNotification" -ErrorAction SilentlyContinue) {

            $startPushResult = Invoke-StartPushNotification -ProjectDir $ResolvedProjectDir

        }

    }



    $serverTrimmed = $cfg.NtfyServer.TrimEnd('/')

    $subUrl = "$serverTrimmed/$($cfg.DeviceTopic)"



    return @{

        Config               = $cfg

        TestResult           = $testResult

        ApplyResult          = $applyResult

        StartPushResult      = $startPushResult

        SubscriptionUrl      = $subUrl

    }

} else {

    # Interactive GUI Mode

    Show-WizardGui -Dir $ResolvedProjectDir

}

