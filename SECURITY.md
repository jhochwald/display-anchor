# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, please report them by [privately reporting a security vulnerability](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability) directly in this repository. If you prefer, you can also reach out via email (please update with your email address if applicable).

We take all security vulnerabilities seriously and will respond to reports as quickly as possible.

### What to include in your report

- A description of the vulnerability and its potential impact.
- Detailed steps to reproduce the issue.
- Any potential mitigation or workaround you might have identified.

## Application Specific Security Notes

Display Anchor is a macOS utility that requires **Accessibility** permissions to function properly. Please keep the following in mind:

- **Accessibility Permissions**: The app requires these permissions to interface with the macOS WindowServer in order to inspect window frames and restore their positions.
- **Local Data Storage**: All snapshot data—which includes display topology, window titles, and screen coordinates—is stored **strictly locally** on your machine at `~/Library/Application Support/DisplayAnchor/`.
- **No Network Requests**: The application operates entirely offline. It does not transmit telemetry, crash reports, analytics, or any personal data over the internet.
