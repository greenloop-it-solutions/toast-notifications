# Send-ToastNotification.ps1

A PowerShell script for sending rich, interactive Windows toast notifications to the currently logged-in user. Designed for IT teams and MSPs to deliver branded, actionable alerts from SYSTEM context — compatible with local, domain, and **Entra ID / Azure AD** accounts.

---

## Features

- **Works as SYSTEM or as the current user** — in SYSTEM context, the notification is delivered into the active user session via token duplication from `explorer.exe`. No scheduled task username resolution required, making it fully compatible with Entra ID accounts.
- **Personalised greeting** — displays "Good morning/afternoon/evening \[First Name\]" using the user's full name from `Get-LocalUser`, falling back to the SAM username.
- **Action buttons** — up to two clickable buttons that open URLs or run protocol handlers, plus a configurable dismiss button.
- **Dynamic content** — live computer uptime and deadline countdowns embedded in the message body.
- **Hero image and app logo** — accepts local file paths or public HTTPS URLs (downloaded to ProgramData automatically).
- **Custom app branding** — register a custom AppId to show your company name in the notification header instead of "Windows PowerShell".
- **Toast scenarios** — Default, Reminder, Alarm, IncomingCall.

---

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later
- Administrator or SYSTEM rights required for `-RegisterApp` and SYSTEM-mode dispatch

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Title` | String | *(required)* | Main heading text |
| `-Message` | String | *(required)* | Body text. Separate paragraphs with `` `n `` |
| `-AppId` | String | Windows PowerShell AUMID | Application User Model ID for the notification source |
| `-AppDisplayName` | String | | Friendly name shown in the header. Use with `-RegisterApp` |
| `-RegisterApp` | Switch | | Registers the AppId with Windows (requires admin/SYSTEM). Safe to include on every run |
| `-AppLogo` | String | | Local path or HTTPS URL to a square PNG/JPG logo. Displayed as a circle |
| `-HeroImage` | String | | Local path or HTTPS URL to a PNG/JPG banner image |
| `-Attribution` | String | | Optional small grey subtext at the bottom of the notification |
| `-Duration` | String | `Long` | `Short` (~7s) or `Long` (~25s) |
| `-Scenario` | String | `Default` | `Default`, `Reminder`, `Alarm`, or `IncomingCall` |
| `-Button1Text` | String | | Label for the first action button |
| `-Button1Action` | String | | URI or protocol for Button1 (e.g. `https://...`, `ms-settings:windowsupdate`) |
| `-Button2Text` | String | | Label for the second action button |
| `-Button2Action` | String | | URI or protocol for Button2 |
| `-DismissButtonText` | String | `Dismiss` | Label for the dismiss button |
| `-Greeting` | Bool | `$true` | Prepend a personalised time-based greeting |
| `-ShowUptime` | Switch | | Append current computer uptime to the message |
| `-Deadline` | DateTime | | Append a countdown to the specified date/time |

---

## Image Sizing Guidelines

Pre-size your images before use — the script does not resize images automatically.

| Image | Recommended Size | Notes |
|---|---|---|
| `HeroImage` | 364 × 180 px | ~2:1 ratio. PNG or JPG. Taller images will be cropped by Windows |
| `AppLogo` | 150 × 150 px | Square with subject centred. Always displayed as a circle |

> **Avoid WebP** — the Windows toast engine does not support it, even if the file has a `.png` extension. This is common with images served from WordPress and similar platforms.

---

## Custom App Branding

By default, notifications appear under "Windows PowerShell" in the header and Action Center. To show your own company name, use `-RegisterApp` alongside `-AppId` and `-AppDisplayName`.

Registration creates:
- A registry key at `HKLM\SOFTWARE\Classes\AppUserModelId\<AppId>`
- A Start Menu shortcut at `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\<AppDisplayName>.lnk` with the AppUserModelID property stamped on it (required by Windows)

**Requires administrator or SYSTEM rights.** Safe to include on every invocation — skips silently if already registered.

Before re-registering after a failed attempt, clean up previous entries:

```powershell
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\GreenLoop IT Solutions.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item 'HKLM:\SOFTWARE\Classes\AppUserModelId\GreenLoop.Notifications' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\SOFTWARE\Classes\AppUserModelId\GreenLoop.Notifications' -Recurse -Force -ErrorAction SilentlyContinue
```

---

## Examples

### Simple notification

```powershell
.\Send-ToastNotification.ps1 -Title "Hello!" -Message "This is a test."
```

### Branded IT reboot alert

```powershell
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
```

### Deadline reminder

```powershell
.\Send-ToastNotification.ps1 `
    -Title "Software Update Required" `
    -Message "Please install the latest updates before the deadline." `
    -AppId "GreenLoop.Notifications" `
    -AppDisplayName "GreenLoop IT Solutions" `
    -Deadline (Get-Date).AddDays(3) `
    -Button1Text "Update Now" -Button1Action "ms-settings:windowsupdate" `
    -Scenario Reminder
```

### Uptime check with no buttons

```powershell
.\Send-ToastNotification.ps1 `
    -Title "System Health Check" `
    -Message "Your device has been running for a while." `
    -AppId "GreenLoop.Notifications" `
    -AppDisplayName "GreenLoop IT Solutions" `
    -ShowUptime `
    -Duration Short
```

---

## How SYSTEM Mode Works

When run as SYSTEM (e.g. from an RMM tool, scheduled task, or Intune script):

1. The active user session is identified via `query session`
2. `explorer.exe` running in that session is located via WMI
3. Its process token is duplicated using `OpenProcessToken` + `DuplicateTokenEx`
4. `CreateProcessAsUser` launches PowerShell in the user's session using the duplicated token
5. The toast is shown from within the user's own session context

This approach works for **local accounts, domain accounts, and Entra ID / Azure AD accounts** because it bypasses all username and SID resolution entirely.

---

## Notes

- Images served from WordPress or CDNs are sometimes WebP format regardless of file extension. If your logo or banner isn't displaying, download it and verify the actual format.
- The `-Attribution` field is optional. If you are already branding notifications via `-RegisterApp`, it may not be needed.
- Temp image files downloaded from URLs are stored in `C:\ProgramData` and cleaned up automatically after the toast is shown (user-context mode only).
