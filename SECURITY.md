# Security Policy

## Supported Versions

Security fixes are prepared for the latest version on the default branch. No release or backport policy is currently defined.

## Reporting a Vulnerability

Please do not report security vulnerabilities, exposed credentials, or notification data in a public issue. Use GitHub's private vulnerability reporting feature for this repository when available. If private reporting is unavailable, contact the repository maintainer privately through a verified contact channel listed on their GitHub profile. Do not include real notification bodies, topic names, or tokens in a report unless strictly necessary; redact them from screenshots and logs.

## Security Notes

- The application reads Windows notifications in the signed-in user's interactive session and sends selected fields to the configured ntfy server.
- `TitleOnly` is the default privacy mode. `TitleAndBody` transmits notification content; use it only after considering the sensitivity of that content and securing access to the ntfy topic.
- A private or high-entropy topic name helps reduce discovery but does not replace server-side authentication and access controls.
- The dashboard is designed to bind to loopback (`127.0.0.1`) and uses a session token. Do not expose it through a reverse proxy or network binding without reviewing the implementation and threat model.
- Keep `config.json`, `wizard_config.json`, backups, and runtime logs private. `.gitignore` excludes these local files, but review every change before publishing.
- Start with dry-run mode and enable live delivery only after reviewing the destination and privacy settings.
