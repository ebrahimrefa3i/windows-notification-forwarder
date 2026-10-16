# Contributing

Thanks for your interest in Windows Notification Forwarder. Contributions should preserve the project's focus on forwarding Windows notifications to ntfy from an interactive Windows user session.

## Before proposing a change

- Keep scripts compatible with Windows PowerShell 5.1 and avoid external runtime dependencies.
- Preserve safe defaults: an empty destination, dry-run enabled, and live forwarding disabled until a user explicitly enables it.
- Do not silently create or replace a destination topic.
- Keep notification bodies, topic names, access tokens, and machine-specific data out of logs, test output, issues, and commits.
- Resolve paths from the project location and quote paths so installations in folders with spaces work.
- Update the README and example configuration when behavior or supported setup changes.

## Run the regression suites

From the project folder on Windows, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_all_suites.ps1
```

The canonical runner executes all seven scripts under `tests/` and reports failures with a nonzero exit code. Include the result in your pull request description. Do not attach production configuration or unredacted logs.

## Pull requests

Keep changes focused and describe the user-visible behavior, any compatibility impact, and how you verified the change. Add or update regression coverage for behavior changes. There is no license file yet; do not assume the project has granted rights for redistribution.
