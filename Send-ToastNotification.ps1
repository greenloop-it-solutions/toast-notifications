#Requires -Version 5.1
<#
.SYNOPSIS
    Sends a rich, interactive Windows Toast Notification to the currently logged-in user.

.DESCRIPTION
    Supports hero images, app logos, action buttons, dynamic content (uptime, personalised
    greeting, deadline countdowns), and toast scenarios like Reminder and Alarm.

    Works when run as the current user OR as SYSTEM. In SYSTEM mode the toast is launched
    inside the active user session via token duplication from explorer.exe, making it
    compatible with local, domain, and Entra ID / Azure AD accounts.

    Images can be local file paths or public HTTPS URLs. URLs are downloaded to ProgramData
    before the toast is shown (the Windows toast engine requires local paths).

    IMAGE SIZING GUIDELINES:
      HeroImage : 364 x 180 px, ~2:1 ratio. PNG or JPG. Taller images will be cropped.
      AppLogo   : 150 x 150 px, square with subject centred. Displayed as a circle.
      Avoid WebP - it is not supported by the Windows toast engine.

    CUSTOM APP NAME (-RegisterApp):
      Use -AppId, -AppDisplayName, and -RegisterApp together to show a branded name in the
      notification header instead of "Windows PowerShell". Registration writes a Start Menu
      shortcut with the AppUserModelID stamped on it (required by Windows) and a registry
      entry under HKLM\SOFTWARE\Classes\AppUserModelId. Requires admin or SYSTEM rights.
      Safe to include on every run - skips silently if already registered.

.PARAMETER Title
    The main heading text of the notification.

.PARAMETER Message
    Body text. Separate paragraphs with `n.

.PARAMETER AppId
    The Application User Model ID (AUMID) used to identify the notification source.
    Controls the app name and icon in the header and Action Center.
    Default: Windows PowerShell AUMID. Use with -AppDisplayName and -RegisterApp for branding.

.PARAMETER AppDisplayName
    Friendly name shown in the notification header (e.g. "GreenLoop IT Solutions").
    Only takes effect when used with -RegisterApp.

.PARAMETER RegisterApp
    Registers the AppId with Windows by creating a Start Menu shortcut and registry entry.
    Requires administrator or SYSTEM rights. Safe to include on every invocation.

.PARAMETER AppLogo
    Local path or public HTTPS URL to a square PNG/JPG shown as the circular app logo.
    Recommended: 150x150 px, subject centred.

.PARAMETER HeroImage
    Local path or public HTTPS URL to a PNG/JPG shown as the wide banner at the top.
    Recommended: 364x180 px (~2:1 ratio).

.PARAMETER Attribution
    Optional small grey subtext shown at the bottom of the notification.
    Useful for adding a secondary identifier or contact info. If you are using -RegisterApp
    to brand notifications with a display name, this field may not be necessary.

.PARAMETER Duration
    How long the toast remains on screen. 'Short' (~7s) or 'Long' (~25s). Default: Long.

.PARAMETER Scenario
    Affects how Windows presents the notification.
    Options: Default, Reminder, Alarm, IncomingCall. Default: Default.

.PARAMETER Button1Text
    Label for the first action button.

.PARAMETER Button1Action
    URI or protocol launched when Button1 is clicked.
    Examples: "https://..." or "ms-settings:windowsupdate" or "shutdown /r /t 60".

.PARAMETER Button2Text
    Label for the second action button.

.PARAMETER Button2Action
    URI or protocol launched when Button2 is clicked.

.PARAMETER DismissButtonText
    Label for the dismiss button. Default: "Dismiss".

.PARAMETER Greeting
    If $true, prepends a time-based greeting with the user's first name, resolved from
    Get-LocalUser FullName with SAM username as fallback. Default: $true.

.PARAMETER ShowUptime
    If set, appends the current computer uptime to the message body.

.PARAMETER Deadline
    A [datetime] value. Appends a live countdown (e.g. "Due in 2 days 4 hours") to the message.

.EXAMPLE
    # Simple notification
    .\Send-ToastNotification.ps1 -Title "Hello!" -Message "This is a test."

.EXAMPLE
    # Branded IT reboot alert with buttons and uptime
    .\Send-ToastNotification.ps1 `
        -Title "Your computer needs to restart!" `
        -Message "For security and stability reasons, please restart as soon as possible." `
        -AppId "GreenLoop.Notifications" `
        -AppDisplayName "GreenLoop IT Solutions" `
        -RegisterApp `
        -Button1Text "Restart now"  -Button1Action "shutdown /r /t 60" `
        -Button2Text "Learn More"   -Button2Action "https://yourcompany.com/policy" `
        -DismissButtonText "Dismiss" `
        -ShowUptime `
        -HeroImage "https://yourcompany.com/images/banner.png" `
        -AppLogo   "https://yourcompany.com/images/logo.png" `
        -Attribution "GreenLoop IT Solutions" `
        -Duration Long

.EXAMPLE
    # Deadline reminder
    .\Send-ToastNotification.ps1 `
        -Title "Software Update Required" `
        -Message "Please install the latest updates before the deadline." `
        -AppId "GreenLoop.Notifications" `
        -AppDisplayName "GreenLoop IT Solutions" `
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

    [nullable[datetime]]$Deadline = $null,

    [string]$AppDisplayName = '',

    [switch]$RegisterApp
)

# ---------------------------------------------------------------------------
# App Registration
# ---------------------------------------------------------------------------

function Register-ToastApp {
    param(
        [string]$AppId,
        [string]$AppDisplayName
    )

    # Windows REQUIRES a Start Menu shortcut with the AppUserModelID shell property
    # stamped onto it - the registry alone is not sufficient. We create the shortcut
    # using a .NET Type that calls IShellLink + IPersistFile + IPropertyStore in one
    # clean sequence, writing to the .lnk before stamping to avoid timing issues.

    $shortcutDir  = [Environment]::GetFolderPath('CommonPrograms')  # C:\ProgramData\Microsoft\Windows\Start Menu\Programs
    $shortcutPath = Join-Path $shortcutDir "$AppDisplayName.lnk"
    $regPath      = "HKLM:\SOFTWARE\Classes\AppUserModelId\$AppId"

    $shortcutOk = (Test-Path $shortcutPath)
    $regOk      = (Test-Path $regPath) -and `
                  ((Get-ItemProperty $regPath -Name 'DisplayName' -ErrorAction SilentlyContinue).DisplayName -eq $AppDisplayName)

    if ($shortcutOk -and $regOk) {
        Write-Host "AppId '$AppId' already registered - skipping." -ForegroundColor DarkGray
        return
    }

    Write-Host "Registering AppId '$AppId' as '$AppDisplayName'..." -ForegroundColor Cyan

    # ── Registry (required alongside the shortcut) ───────────────────────────
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    New-ItemProperty -Path $regPath -Name 'DisplayName'    -Value $AppDisplayName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regPath -Name 'ShowInSettings' -Value 1               -PropertyType DWord  -Force | Out-Null

    # ── Shortcut via WScript.Shell then stamp AUMID via raw binary edit ──────
    # WScript.Shell creates a valid .lnk. We then open the file as bytes and
    # inject the AppUserModelID into the StringData ExtraData block. This avoids
    # all COM/P-Invoke complexity that was failing silently before.
    $wsh      = New-Object -ComObject WScript.Shell
    $sc       = $wsh.CreateShortcut($shortcutPath)
    $sc.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell1.0\powershell.exe"
    $sc.Description      = $AppDisplayName
    $sc.WindowStyle      = 7
    $sc.Save()

    # Stamp the AppUserModelID using a .NET type that correctly calls IPropertyStore
    $typeCode = @'
using System;
using System.Runtime.InteropServices;

public static class LnkAppId {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    static extern void SHGetPropertyStoreFromParsingName(
        string pszPath, IntPtr pbc, uint flags, [In] ref Guid riid,
        [Out, MarshalAs(UnmanagedType.Interface)] out object ppv);

    static Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

    // PKEY_AppUserModel_ID
    static Guid FMTID = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    const uint PID = 5;

    public static void Set(string lnkPath, string appId) {
        object storeObj;
        SHGetPropertyStoreFromParsingName(lnkPath, IntPtr.Zero, 2 /*GPS_READWRITE*/, ref IID_IPropertyStore, out storeObj);
        var store = (IPropertyStore)storeObj;

        var key = new PROPERTYKEY { fmtid = FMTID, pid = PID };
        var pv  = new PropVariant(appId);
        store.SetValue(ref key, ref pv);
        store.Commit();
        pv.Dispose();
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount([Out] out uint count);
        void GetAt(uint index, out PROPERTYKEY key);
        void GetValue([In] ref PROPERTYKEY key, [Out] out PropVariant val);
        void SetValue([In] ref PROPERTYKEY key, [In] ref PropVariant val);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant : IDisposable {
        public ushort vt;
        ushort r0, r1, r2;
        public IntPtr ptr;

        public PropVariant(string val) {
            vt = 31; r0 = r1 = r2 = 0;
            ptr = Marshal.StringToCoTaskMemUni(val);
        }
        public void Dispose() {
            if (vt == 31 && ptr != IntPtr.Zero) {
                Marshal.FreeCoTaskMem(ptr);
                ptr = IntPtr.Zero; vt = 0;
            }
        }
    }
}
'@
    try {
        if (-not ([System.Management.Automation.PSTypeName]'LnkAppId').Type) {
            Add-Type -TypeDefinition $typeCode -Language CSharp
        }
        [LnkAppId]::Set($shortcutPath, $AppId)
        Write-Host "AppId registered. Shortcut: $shortcutPath" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to stamp AppUserModelID on shortcut: $_"
        Write-Warning "The notification may still show the AppId instead of the display name."
    }
}

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
    # Priority 1: query user - reads from session manager, works from SYSTEM context too
    try {
        $quResult = query user 2>$null
        if ($quResult) {
            $activeLine = $quResult | Where-Object { $_ -match 'Active' } | Select-Object -First 1
            if ($activeLine) {
                $name = ($activeLine.Trim() -split '\s+')[0] -replace '^>'
                if ($name) { return $name.ToLower() }
            }
        }
    } catch {}

    # Priority 2: Win32_ComputerSystem (strip DOMAIN\ prefix)
    try {
        $wmiUser = (Get-WmiObject Win32_ComputerSystem).UserName
        if ($wmiUser) { return ($wmiUser -replace '.*\\').ToLower() }
    } catch {}

    # Priority 3: environment variable (unreliable under SYSTEM but fine as fallback)
    if ($env:USERNAME -and $env:USERNAME -ne 'SYSTEM') {
        return $env:USERNAME.ToLower()
    }

    return ''
}

function Get-FirstName ([string]$SamAccountName) {
    $ti = (Get-Culture).TextInfo

    if ($SamAccountName) {
        # Priority 1: Get-LocalUser FullName - works for local accounts, and on AAD/Entra
        # joined machines the SAM cache usually has the display name populated here too
        try {
            $localUser = Get-LocalUser -Name $SamAccountName -ErrorAction Stop
            if ($localUser.FullName) {
                $firstName = ($localUser.FullName.Trim() -split '\s+')[0]
                if ($firstName) { return $ti.ToTitleCase($firstName.ToLower()) }
            }
        } catch {}

        # Priority 2: Win32_UserAccount - broader coverage, works for domain cached accounts
        try {
            $wmiUser = Get-WmiObject Win32_UserAccount -Filter "Name='$SamAccountName'" -ErrorAction Stop
            if ($wmiUser -and $wmiUser.FullName) {
                $firstName = ($wmiUser.FullName.Trim() -split '\s+')[0]
                if ($firstName) { return $ti.ToTitleCase($firstName.ToLower()) }
            }
        } catch {}

        # Priority 3: fall back to title-cased SAM username
        return $ti.ToTitleCase($SamAccountName.ToLower())
    }

    return ''
}

function Get-UptimeString {
    $uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $parts = @()
    if ($uptime.Days  -gt 0) { $parts += "$($uptime.Days) day$(if($uptime.Days -ne 1){'s'})" }
    if ($uptime.Hours -gt 0) { $parts += "$($uptime.Hours) hour$(if($uptime.Hours -ne 1){'s'})" }
    if ($parts.Count -eq 0)  { $parts += 'less than an hour' }
    return $parts -join ' '
}

function Get-DeadlineString ([datetime]$dl) {
    $diff = $dl - (Get-Date)
    if ($diff.TotalMinutes -lt 0) { return 'Deadline has passed' }
    $parts = @()
    $days = [math]::Floor($diff.TotalDays)
    if ($days  -gt 0) { $parts += "$days day$(if($days -ne 1){'s'})" }
    if ($diff.Hours -gt 0) { $parts += "$($diff.Hours) hour$(if($diff.Hours -ne 1){'s'})" }
    if ($parts.Count -eq 0) { $parts += 'less than an hour' }
    return 'Due in ' + ($parts -join ' ')
}


function Resolve-ImagePath ([string]$Path) {
    # Returns a local file path - downloads URL to temp file if needed.
    # Pre-size images before use: HeroImage 364x180px, AppLogo 150x150px (square, centred).
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    if ($Path -match '^https?://') {
        try {
            $ext = [System.IO.Path]::GetExtension(([uri]$Path).AbsolutePath)
            if (-not $ext) { $ext = '.png' }
            $temp = [System.IO.Path]::Combine($env:ProgramData, "ToastImg_$([System.IO.Path]::GetRandomFileName())$ext")
            Write-Host "Downloading image: $Path" -ForegroundColor Cyan
            Invoke-WebRequest -Uri $Path -OutFile $temp -UseBasicParsing -ErrorAction Stop
            Write-Host "Saved to: $temp" -ForegroundColor Cyan
            return $temp
        } catch {
            Write-Warning "Failed to download image '$Path': $_"
            return $null
        }
    }

    if (Test-Path $Path) { return $Path }

    Write-Warning "Image not found: $Path"
    return $null
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
        [string]$ResolvedDisplayName = ''
    )

    # --- Greeting ---
    $greetingXml = ''
    if ($Greeting) {
        $greetText = "$(Get-Greeting)$(if($ResolvedDisplayName){" $ResolvedDisplayName"})"
        $greetingXml = "<text hint-style='captionSubtle'>$([System.Security.SecurityElement]::Escape($greetText))</text>"
    }

    # --- Message body ---
    $messageXml = ''
    foreach ($line in ($Message -split "`n")) {
        if ($line.Trim()) {
            $messageXml += "<text>$([System.Security.SecurityElement]::Escape($line.Trim()))</text>"
        }
    }

    if ($ShowUptime) {
        $uptimeStr = "Computer uptime: $(Get-UptimeString)"
        $messageXml += "<text hint-style='baseSubtle'><b>$([System.Security.SecurityElement]::Escape($uptimeStr))</b></text>"
    }

    if ($Deadline) {
        $dlStr = Get-DeadlineString -dl $Deadline
        $messageXml += "<text hint-style='baseSubtle'><b>$([System.Security.SecurityElement]::Escape($dlStr))</b></text>"
    }

    # --- Images (already resolved to local paths) ---
    $heroXml = ''
    if ($HeroImage) {
        $heroUri = 'file:///' + $HeroImage.Replace('\', '/')
        $heroXml = "<image placement='hero' src='$heroUri'/>"
    }

    $logoXml = ''
    if ($AppLogo) {
        $logoUri = 'file:///' + $AppLogo.Replace('\', '/')
        $logoXml = "<image placement='appLogoOverride' hint-crop='circle' src='$logoUri'/>"
    }

    # --- Attribution ---
    $attribXml = ''
    if ($Attribution) {
        $attribXml = "<text placement='attribution'>$([System.Security.SecurityElement]::Escape($Attribution))</text>"
    }

    # --- Buttons ---
    $buttonXmls = @()
    if ($Button1Text -and $Button1Action) {
        $buttonXmls += "<action content='$([System.Security.SecurityElement]::Escape($Button1Text))' arguments='$([System.Security.SecurityElement]::Escape($Button1Action))' activationType='protocol'/>"
    }
    if ($Button2Text -and $Button2Action) {
        $buttonXmls += "<action content='$([System.Security.SecurityElement]::Escape($Button2Text))' arguments='$([System.Security.SecurityElement]::Escape($Button2Action))' activationType='protocol'/>"
    }
    $buttonXmls += "<action content='$([System.Security.SecurityElement]::Escape($DismissButtonText))' arguments='dismiss' activationType='system'/>"

    $actionsXml = "<actions>" + ($buttonXmls -join '') + "</actions>"

    # --- Scenario ---
    $scenarioAttr = if ($Scenario -ne 'Default') { " scenario='$($Scenario.ToLower())'" } else { '' }

    # --- Assemble ---
    $xml  = "<toast duration='$Duration'$scenarioAttr>"
    $xml += "<visual><binding template='ToastGeneric'>"
    $xml += $heroXml + $logoXml + $greetingXml
    $xml += "<text hint-style='title'>$([System.Security.SecurityElement]::Escape($Title))</text>"
    $xml += $messageXml + $attribXml
    $xml += "</binding></visual>"
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

function Get-ActiveSessionId {
    try {
        $quResult = query session 2>$null
        foreach ($line in $quResult) {
            if ($line -match 'Active') {
                $parts = $line.Trim() -split '\s+'
                $id = $parts | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
                if ($id) { return [int]$id }
            }
        }
    } catch {}
    return $null
}

function Send-ToastAsLoggedInUser {
    param([string]$ToastXml, [string]$AppId)

    Write-Host "Running as SYSTEM - dispatching toast to user session..." -ForegroundColor Yellow

    $sessionId = Get-ActiveSessionId
    if ($null -eq $sessionId) {
        Write-Warning "Could not find an active user session. Cannot send toast."
        return
    }
    Write-Host "Found active session ID: $sessionId" -ForegroundColor Cyan

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

    # Use CreateProcessAsUser via P/Invoke to launch powershell in the user's session.
    # This works for local, domain, AND Entra ID accounts because we duplicate the token
    # directly from explorer.exe - no username/SID resolution needed at all.
    $code = @'
using System;
using System.Runtime.InteropServices;

public class ProcessLauncher {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr proc, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attr, int impersonation, int type, out IntPtr newToken);
    [DllImport("userenv.dll",  SetLastError=true)] static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);
    [DllImport("userenv.dll",  SetLastError=true)] static extern bool DestroyEnvironmentBlock(IntPtr env);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr token, string app, string cmd, IntPtr procAttr, IntPtr threadAttr,
        bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string reserved,desk,title; public int x,y,cx,cy,xc,yc,fill; public int flags; public short show,reserved2; public IntPtr reserved3,stdin,stdout,stderr; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr process,thread; public uint pid,tid; }

    public static int Launch(uint pid, string cmd) {
        IntPtr hProc = OpenProcess(0x400 | 0x10, false, pid); // QUERY_INFO | VM_READ
        if (hProc == IntPtr.Zero) return -1;
        IntPtr hToken = IntPtr.Zero, hDup = IntPtr.Zero;
        try {
            if (!OpenProcessToken(hProc, 0x0002 | 0x0004 | 0x0008, out hToken)) return -2; // DUPLICATE|QUERY|IMPERSONATE
            if (!DuplicateTokenEx(hToken, 0x10000000, IntPtr.Zero, 2, 1, out hDup)) return -3;
            IntPtr env = IntPtr.Zero;
            CreateEnvironmentBlock(out env, hDup, false);
            var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si); si.desk = "winsta0\\default";
            PROCESS_INFORMATION pi;
            uint flags = 0x00000010 | 0x00000400; // CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT
            if (!CreateProcessAsUser(hDup, null, cmd, IntPtr.Zero, IntPtr.Zero, false, flags, env, null, ref si, out pi)) {
                if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
                return -4;
            }
            WaitForSingleObject(pi.process, 15000);
            CloseHandle(pi.process); CloseHandle(pi.thread);
            if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
            return 0;
        } finally {
            if (hToken != IntPtr.Zero) CloseHandle(hToken);
            if (hDup   != IntPtr.Zero) CloseHandle(hDup);
            CloseHandle(hProc);
        }
    }
}
'@

    # Only add the type once per session
    if (-not ([System.Management.Automation.PSTypeName]'ProcessLauncher').Type) {
        Add-Type -TypeDefinition $code -Language CSharp
    }

    # Find explorer.exe in the target session to borrow its token
    $explorer = Get-WmiObject Win32_Process -Filter "Name='explorer.exe'" |
        Where-Object { $_.SessionId -eq $sessionId } |
        Select-Object -First 1

    if (-not $explorer) {
        Write-Warning "No explorer.exe found in session $sessionId. Cannot inject process."
        Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Host "Using explorer.exe PID $($explorer.ProcessId) as token source" -ForegroundColor Cyan

    $psCmd = "powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tempScript`""
    $result = [ProcessLauncher]::Launch([uint32]$explorer.ProcessId, $psCmd)

    if ($result -ne 0) {
        Write-Warning "CreateProcessAsUser failed with code $result"
    } else {
        Write-Host "Toast dispatched successfully." -ForegroundColor Green
    }

    # Give the process time to show the toast before cleaning up the script
    Start-Sleep -Seconds 2
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Register custom AppId if requested
if ($RegisterApp) {
    if (-not $AppDisplayName) { $AppDisplayName = $AppId }
    Register-ToastApp -AppId $AppId -AppDisplayName $AppDisplayName
}

# Resolve username (SAM format) then attempt to get first name from AD
$samUsername    = Get-LoggedInUsername
$displayName    = Get-FirstName -SamAccountName $samUsername
Write-Host "Resolved user: $samUsername -> Display name: $displayName" -ForegroundColor Cyan

# Download any URL images to temp local files (toast engine requires local paths)
$resolvedHero = Resolve-ImagePath $HeroImage
$resolvedLogo = Resolve-ImagePath $AppLogo

$toastXml = Build-ToastXml `
    -Title               $Title `
    -Message             $Message `
    -AppLogo             $(if ($resolvedLogo) { $resolvedLogo } else { '' }) `
    -HeroImage           $(if ($resolvedHero) { $resolvedHero } else { '' }) `
    -Attribution         $Attribution `
    -Duration            $Duration `
    -Scenario            $Scenario `
    -Button1Text         $Button1Text `
    -Button1Action       $Button1Action `
    -Button2Text         $Button2Text `
    -Button2Action       $Button2Action `
    -DismissButtonText   $DismissButtonText `
    -Greeting            $Greeting `
    -ShowUptime          ([bool]$ShowUptime) `
    -Deadline            $Deadline `
    -ResolvedDisplayName $displayName

if (Test-IsSystem) {
    # In SYSTEM mode the scheduled task runs in the user session and needs the temp image
    # files to still exist on disk - so we do NOT clean them up here. They will persist
    # in the user's TEMP across sessions but are small and harmless.
    Send-ToastAsLoggedInUser -ToastXml $toastXml -AppId $AppId
} else {
    Send-Toast -ToastXml $toastXml -AppId $AppId
    # Clean up temp images only in user-context mode where we know the toast has rendered
    Start-Sleep -Seconds 10
    @($resolvedHero, $resolvedLogo) | Where-Object { $_ -and $_.StartsWith($env:ProgramData) } | ForEach-Object {
        Remove-Item $_ -Force -ErrorAction SilentlyContinue
        Write-Host "Cleaned up temp image: $_" -ForegroundColor DarkGray
    }
}
