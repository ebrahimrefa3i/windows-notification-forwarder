# Windows Notification Forwarder

Forward new Windows 10 and Windows 11 notifications to your phone with [ntfy](https://ntfy.sh). This PowerShell notification relay runs in your signed-in Windows session and lets you filter apps and choose what notification details leave your PC. Receive them on Android or iPhone (iOS) with the ntfy mobile app.

**Search terms:** Windows notifications, Windows notification forwarding, Windows notifications to phone, Windows notifications to mobile, notification to phone, notification to mobile, push notifications, Android notifications, iPhone notifications, iOS notifications, ntfy, PowerShell, notification relay.

ntfy provides mobile apps for both [Android and iOS](https://docs.ntfy.sh/subscribe/phone/). This project sends notifications to an ntfy topic; subscribe to that same topic in the ntfy app on your phone. It uses Windows PowerShell 5.1 and Windows Runtime notification APIs; PowerShell 7 is not a supported setup path.

## Features

- Forwards newly arriving Windows toast notifications to an ntfy topic over HTTPS.
- Uses an in-memory baseline so existing notifications are not sent when the forwarder starts.
- Offers allowlist/blocklist filtering and four privacy modes; `TitleOnly` is the safe default.
- Includes a setup wizard, local browser dashboard, status and recovery tools, and an optional watchdog.
- Starts in dry-run mode. Live forwarding requires an explicitly configured topic and an explicit enable action.
- Uses Windows Task Scheduler in the interactive user's session; it is not a Windows service and does not run as `SYSTEM`.

## Requirements

- Windows 10 version 1809 (build 17763) or later, including Windows 11.
- Windows PowerShell 5.1 (`powershell.exe`).
- Notifications enabled in Windows, and permission for this app to read notifications.
- An Android phone or iPhone with the ntfy app installed. A reachable ntfy server is required; the default is `https://ntfy.sh`, and a self-hosted server can be configured.
- An interactive signed-in desktop session. Forwarding cannot read notifications while no eligible user session is active.

## Quick start

1. Download or clone this repository to a folder on your Windows PC.
2. Double-click `Start.cmd` and follow the setup wizard. It checks Windows notification access and starts with safe dry-run settings.
3. In the wizard, explicitly generate or enter an ntfy topic, select a privacy mode and app filter, then review the configuration.
4. Install the ntfy app on your Android phone or iPhone, subscribe to the same topic on the same ntfy server, and allow notifications for ntfy in your phone's settings.
5. Choose **Start Push Notification** in the wizard to enable live forwarding and register the background tasks.

You can open the management dashboard later with `NotificationForwarder Dashboard.cmd`. It listens on `127.0.0.1` and opens in your browser. Use `NotificationForwarder Status.cmd` for a read-only status check. To configure manually, copy `config.example.json` to `config.json` and edit it; never publish your real `config.json`.

## Privacy and topic security

`TitleOnly` is the default and removes notification bodies before delivery. `TitleAndApp` also includes the app name; `TitleAndBody` includes message text; `Custom` follows the selected fields. Notification bodies can contain private conversations, one-time codes, and financial information. Use a private, high-entropy topic and configure ntfy access controls before forwarding bodies. A hard-to-guess topic is not a substitute for access control.

Topic generation is an explicit user action in the wizard or dashboard. The application does not silently generate, rotate, or replace a topic. Keep `config.json`, `wizard_config.json`, backups, and runtime logs private. The dashboard is intended for local use and requires its session token.

## Background controls

- Open the dashboard and switch forwarding off to pause it. The watchdog observes the pause marker and should not restart the forwarder while paused.
- Double-click `Recover NotificationForwarder.cmd` to run the recovery utility.
- To inspect, install, start, stop, or uninstall scheduled tasks, run `Register-NotificationForwarderTask.ps1` with `-Status`, `-Install`, `-Start`, `-Stop`, or `-Uninstall` respectively.
- To remove the app, uninstall its scheduled tasks, delete the local configuration and logs if desired, then unsubscribe from the topic in ntfy.

## Troubleshooting

**No notifications arrive:** Confirm forwarding is enabled, dry-run is off, and the configured topic and server match the subscription on your phone. Check that Windows notifications and listener permission are enabled, and that ntfy is allowed to show notifications in your phone's settings. Run `NotificationForwarder Status.cmd` and inspect the local `forwarder.log` without sharing it publicly.

**An app is not forwarded:** In Allowlist mode, add the app's displayed name or application ID to `AllowedAppIds`; in Blocklist mode, check `BlockedAppIds` and `IgnoreAppIds`.

**The dashboard does not open or reports unauthorized:** Start it with `NotificationForwarder Dashboard.cmd` so it can create a session token. If port 8765 is occupied, run `Start-Dashboard.ps1 -Port 8780` from PowerShell.

**Setup cannot read notifications:** Check Windows Settings > System > Notifications and grant notification access when prompted. Keep the forwarder running as the signed-in user, not as `SYSTEM`.

## Tests

Run the canonical PowerShell regression suites from the project folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_all_suites.ps1
```

The runner executes the seven suites under `tests/` in isolated test sandboxes and returns a nonzero exit code if any suite fails. Tests use mock delivery handlers and synthetic notifications.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for coding and test expectations and [SECURITY.md](SECURITY.md) for responsible vulnerability reporting. Do not include notification content, real topics, access tokens, or local configuration in issues or pull requests.

## License

No `LICENSE` file is present yet, so the repository does not currently grant an open-source license. Choose and add a license before inviting reuse or distribution.

## GitHub repository metadata suggestion

- **Repository name:** `windows-notification-forwarder`
- **Short description:** `Forward Windows 10/11 notifications to your phone (Android or iPhone) with ntfy. PowerShell 5.1 notification relay with app filters and privacy controls.`
- **Topics:** `windows`, `windows-notifications`, `notification-forwarder`, `notification-relay`, `notification-to-phone`, `notification-to-mobile`, `push-notifications`, `ntfy`, `powershell`, `mobile`, `android`, `iphone`, `ios`, `windows-10`, `windows-11`

The folder name does not need to change. Apply this repository name, description, and topic list in GitHub's repository settings after publishing.
