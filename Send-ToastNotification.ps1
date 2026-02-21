#Requires -Version 5.1
<#
.SYNOPSIS
    Sends a rich, interactive Windows Toast Notification to the currently logged-in user.

.DESCRIPTION
    Supports hero images, app logos, action buttons, dynamic variables (uptime, username,
    computer name, deadline countdowns), and scenarios like reminder, alarm, and incomingCall.
    Works when run as the current user OR as SYSTEM (dispatches via scheduled task into the
    user's interactive session).

.PARAMETER Title
    Main bold heading text.

.PARAMETER Message
    Body text. Supports multiple paragraphs separated by `n.

.PARAMETER AppId
    AppId for the notifier. Use a registered AppId to show a custom app name/icon.
    Defaults to Windows PowerShell.

.PARAMETER AppLogo
    Path to a PNG/JPG to use as the circular app logo on the left of the notification.

.PARAMETER HeroImage
    Path to a PNG/JPG to use as the large hero image at the top.

.PARAMETER Attribution
    Small grey attribution text at the bottom (e.g. "IT Department").

.PARAMETER Duration
    'Short' (7s) or 'Long' (25s). Default: Long.

.PARAMETER Scenario
    Toast scenario: 'Default', 'Reminder', 'Alarm', 'IncomingCall'. Default: Default.

.PARAMETER Button1Text
    Label for the first action button.

.PARAMETER Button1Action
    Protocol or file to launch when Button1 is clicked (e.g. "https://..." or a .exe path).

.PARAMETER Button2Text
    Label for the second action button.

.PARAMETER Button2Action
    Protocol or file to launch when Button2 is clicked.

.PARAMETER DismissButtonText
    Label for the dismiss/snooze button. Default: "Dismiss".

.PARAMETER Greeting
    If set, prepends a time-based greeting ("Good morning/afternoon/evening") with the
    current username before the title. Default: $true.

.PARAMETER ShowUptime
    If set, appends a "Computer uptime: X days Y hours" line to the message. Default: $false.

.PARAMETER Deadline
    A [datetime] value. If set, appends a countdown like "Due in 2 days 4 hours" to the message.

.EXAMPLE
    # Simple notification
    .\Send-ToastNotification.ps1 -Title "Hello!" -Message "This is a test."

.EXAMPLE
    # IT reboot alert with buttons and uptime
    .\Send-ToastNotification.ps1 `
        -Title "Your computer needs to restart!" `
        -Message "For security and stability reasons, please restart as soon as possible." `
        -Button1Text "Restart now"  -Button1Action "shutdown /r /t 60" `
        -Button2Text "Learn More"   -Button2Action "https://yourcompany.com/policy" `
        -DismissButtonText "Dismiss" `
        -ShowUptime `
        -HeroImage "C:\IT\banner.jpg" `
        -AppLogo  "C:\IT\logo.png" `
        -Attribution "IT Department" `
        -Duration Long

.EXAMPLE
    # Deadline reminder
    .\Send-ToastNotification.ps1 `
        -Title "Software Update Required" `
        -Message "Please install the latest updates before the deadline." `
        -Deadline (Get-Date).AddDays(3) `
        -Button1Text "Update Now" -Button1Action "ms-settings:windowsupdate" `
        -Scenario Reminder
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string]$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe',

    [string]$AppLogo = '',

    [string]$HeroImage = '',

    [string]$Attribution = '',

    [ValidateSet('Short','Long')]
    [string]$Duration = 'Long',

    [ValidateSet('Default','Reminder','Alarm','IncomingCall')]
    [string]$Scenario = 'Default',

    [string]$Button1Text = '',
    [string]$Button1Action = '',

    [string]$Button2Text = '',
    [string]$Button2Action = '',

    [string]$DismissButtonText = 'Dismiss',

    [bool]$Greeting = $true,

    [switch]$ShowUptime,

    [nullable[datetime]]$Deadline = $null
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-IsSystem {
    return ([Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem
}

function Get-Greeting {
    $hour = (Get-Date).Hour
    if    ($hour -lt 12) { return 'Good morning' }
    elseif($hour -lt 18) { return 'Good afternoon' }
    else                  { return 'Good evening' }
}

function Get-LoggedInUsername {
    # Priority 1: query user (reads directly from session manager - works from SYSTEM too)
    try {
        $quResult = query user 2>$null
        if ($quResult) {
            # Find the Active session line; columns: USERNAME  SESSIONNAME  ID  STATE ...
            $activeLine = $quResult | Where-Object { $_ -match 'Active' } | Select-Object -First 1
            if ($activeLine) {
                # Username is always the first token, strip any leading >
                $name = ($activeLine.Trim() -split '\s+')[0] -replace '^>'
                if ($name -and $name -ne '') {
                    $ti = (Get-Culture).TextInfo
                    return $ti.ToTitleCase($name.ToLower())
                }
            }
        }
    } catch {}

    # Priority 2: Win32_ComputerSystem (strip DOMAIN\ prefix)
    try {
        $wmiUser = (Get-WmiObject Win32_ComputerSystem).UserName
        if ($wmiUser) {
            $name = $wmiUser -replace '.*\\'
            $ti = (Get-Culture).TextInfo
            return $ti.ToTitleCase($name.ToLower())
        }
    } catch {}

    # Priority 3: environment variable (only reliable when NOT running as SYSTEM)
    if ($env:USERNAME -and $env:USERNAME -ne 'SYSTEM') {
        $ti = (Get-Culture).TextInfo
        return $ti.ToTitleCase($env:USERNAME.ToLower())
    }

    return ''
}

function Get-UptimeString {
    $uptime = (Get-Date) - (gcim Win32_OperatingSystem).LastBootUpTime
    $parts = @()
    if ($uptime.Days  -gt 0) { $parts += "$($uptime.Days) day$(if($uptime.Days -ne 1){'s'})" }
    if ($uptime.Hours -gt 0) { $parts += "$($uptime.Hours) hour$(if($uptime.Hours -ne 1){'s'})" }
    if ($parts.Count -eq 0)  { $parts += "less than an hour" }
    return ($parts -join ' ')
}

function Get-DeadlineString ([datetime]$Deadline) {
    $diff = $Deadline - (Get-Date)
    if ($diff.TotalMinutes -lt 0) { return 'Deadline has passed' }
    $parts = @()
    if ([math]::Floor($diff.TotalDays)  -gt 0) { $parts += "$([math]::Floor($diff.TotalDays)) day$(if([math]::Floor($diff.TotalDays) -ne 1){'s'})" }
    if ($diff.Hours -gt 0)                      { $parts += "$($diff.Hours) hour$(if($diff.Hours -ne 1){'s'})" }
    if ($parts.Count -eq 0)                     { $parts += "less than an hour" }
    return "Due in " + ($parts -join ' ')
}

function Build-ToastXml {
    param(
        [string]$Title,
        [string]$Message,
        [string]$AppLogo,
        [string]$HeroImage,
        [string]$Attribution,
        [string]$Duration,
        [string]$Scenario,
        [string]$Button1Text,
        [string]$Button1Action,
        [string]$Button2Text,
        [string]$Button2Action,
        [string]$DismissButtonText,
        [bool]$Greeting,
        [bool]$ShowUptime,
        [nullable[datetime]]$Deadline,
        [string]$ResolvedUsername = ''
    )

    # --- Dynamic text assembly ---
    $greetingXml = ''
    if ($Greeting) {
        $user = $ResolvedUsername
        $greetText = "$(Get-Greeting)$(if($user){" $user"})"
        $greetingXml = "<text hint-style='captionSubtle'>$([System.Security.SecurityElement]::Escape($greetText))</text>"
    }

    # Build message lines
    $messageLines = $Message -split "`n"
    $messageXml = ''
    foreach ($line in $messageLines) {
        if ($line.Trim() -ne '') {
            $messageXml += "<text>$([System.Security.SecurityElement]::Escape($line.Trim()))</text>"
        }
    }

    if ($ShowUptime) {
        $uptimeStr = "Computer uptime: $(Get-UptimeString)"
        $messageXml += "<text hint-style='baseSubtle'><b>$([System.Security.SecurityElement]::Escape($uptimeStr))</b></text>"
    }

    if ($Deadline) {
        $dlStr = Get-DeadlineString -Deadline $Deadline
        $messageXml += "<text hint-style='baseSubtle'><b>$([System.Security.SecurityElement]::Escape($dlStr))</b></text>"
    }

    # --- Image elements ---
    # Accepts local file paths OR http/https URLs
    function Resolve-ImageUri ([string]$Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if ($Path -match '^https?://') { return $Path }
        if (Test-Path $Path) { return 'file:///' + $Path.Replace('\\', '/') }
        Write-Warning "Image not found and is not a URL, skipping: $Path"
        return $null
    }

    $heroXml = ''
    $heroUri = Resolve-ImageUri $HeroImage
    if ($heroUri) { $heroXml = "<image placement='hero' src='$heroUri'/>" }

    $logoXml = ''
    $logoUri = Resolve-ImageUri $AppLogo
    if ($logoUri) { $logoXml = "<image placement='appLogoOverride' hint-crop='circle' src='$logoUri'/>" }

    # --- Attribution ---
    $attribXml = ''
    if ($Attribution) {
        $attribXml = "<text placement='attribution'>$([System.Security.SecurityElement]::Escape($Attribution))</text>"
    }

    # --- Actions / Buttons ---
    $actionsXml = ''
    $buttonXmls = @()

    if ($Button1Text -and $Button1Action) {
        $escapedAction = [System.Security.SecurityElement]::Escape($Button1Action)
        $escapedLabel  = [System.Security.SecurityElement]::Escape($Button1Text)
        $buttonXmls += "<action content='$escapedLabel' arguments='$escapedAction' activationType='protocol'/>"
    }

    if ($Button2Text -and $Button2Action) {
        $escapedAction = [System.Security.SecurityElement]::Escape($Button2Action)
        $escapedLabel  = [System.Security.SecurityElement]::Escape($Button2Text)
        $buttonXmls += "<action content='$escapedLabel' arguments='$escapedAction' activationType='protocol'/>"
    }

    # Always add a dismiss button
    $dismissLabel = [System.Security.SecurityElement]::Escape($DismissButtonText)
    $buttonXmls += "<action content='$dismissLabel' arguments='dismiss' activationType='system'/>"

    if ($buttonXmls.Count -gt 0) {
        $actionsXml = "<actions>" + ($buttonXmls -join '') + "</actions>"
    }

    # --- Scenario ---
    $scenarioAttr = ''
    if ($Scenario -ne 'Default') {
        $scenarioAttr = " scenario='$($Scenario.ToLower())'"
    }

    # --- Assemble final XML ---
    $xml = "<toast duration='$Duration'$scenarioAttr>"
    $xml += "<visual>"
    $xml += "<binding template='ToastGeneric'>"
    $xml += $heroXml
    $xml += $logoXml
    $xml += $greetingXml
    $xml += "<text hint-style='title'>$([System.Security.SecurityElement]::Escape($Title))</text>"
    $xml += $messageXml
    $xml += $attribXml
    $xml += "</binding>"
    $xml += "</visual>"
    $xml += $actionsXml
    $xml += "</toast>"

    return $xml
}

# ---------------------------------------------------------------------------
# Send Toast (current user context)
# ---------------------------------------------------------------------------

function Send-Toast {
    param([string]$ToastXml, [string]$AppId)

    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    $xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xmlDoc.LoadXml($ToastXml)

    $toast    = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId)
    $notifier.Show($toast)

    Write-Host "Toast notification sent successfully." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# SYSTEM mode: dispatch into logged-in user's session via scheduled task
# ---------------------------------------------------------------------------

function Send-ToastAsLoggedInUser {
    param([string]$ToastXml, [string]$AppId)

    Write-Host "Running as SYSTEM - dispatching toast to user session..." -ForegroundColor Yellow

    $loggedInUser = (Get-WmiObject Win32_ComputerSystem).UserName
    if (-not $loggedInUser) {
        Write-Warning "No logged-in user found. Cannot send toast."
        return
    }
    Write-Host "Targeting user: $loggedInUser" -ForegroundColor Cyan

    # Escape for embedding in a single-quoted PS string
    $escapedXml   = $ToastXml.Replace("'", "''")
    $escapedAppId = $AppId.Replace("'", "''")

    $tempScript = "$env:ProgramData\ToastNotification_temp.ps1"

    $scriptLines = @(
        '$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]',
        '$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]',
        "`$xml = '$escapedXml'",
        '$xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument',
        '$xmlDoc.LoadXml($xml)',
        '$toast = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)',
        "`$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$escapedAppId')",
        '$notifier.Show($toast)'
    )

    $scriptLines | Out-File -FilePath $tempScript -Encoding UTF8 -Force

    $taskName  = 'ToastNotification_' + [System.IO.Path]::GetRandomFileName().Replace('.','')
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tempScript`""
    $principal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null

    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 5

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue

    Write-Host "Toast dispatched successfully." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Resolve the real logged-in username once, regardless of execution context
$resolvedUser = Get-LoggedInUsername
Write-Host "Resolved username: $resolvedUser" -ForegroundColor Cyan

$toastXml = Build-ToastXml `
    -Title             $Title `
    -Message           $Message `
    -AppLogo           $AppLogo `
    -HeroImage         $HeroImage `
    -Attribution       $Attribution `
    -Duration          $Duration `
    -Scenario          $Scenario `
    -Button1Text       $Button1Text `
    -Button1Action     $Button1Action `
    -Button2Text       $Button2Text `
    -Button2Action     $Button2Action `
    -DismissButtonText $DismissButtonText `
    -Greeting          $Greeting `
    -ShowUptime        ([bool]$ShowUptime) `
    -Deadline          $Deadline `
    -ResolvedUsername  $resolvedUser

if (Test-IsSystem) {
    Send-ToastAsLoggedInUser -ToastXml $toastXml -AppId $AppId
} else {
    Send-Toast -ToastXml $toastXml -AppId $AppId
}
