# Security policy

## Supported versions

Security fixes are provided for the latest release. Please update before
reporting an issue unless the issue prevents updating safely.

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting](https://github.com/ludoroo/forestr/security/advisories/new)
for suspected security issues. Do not post exploit details, credentials, or
private repository content in a public issue.

Include the Forestr version, operating system, Bash version, affected backend
(Git or Worktrunk), reproduction steps, and expected impact. Use a disposable
repository for reproduction and redact sensitive paths or logs.

This is a personal project; response times are best-effort. Please coordinate
public disclosure with the maintainer so a fix can be made available first.

## Trust and permissions

Forestr runs locally with your user account's permissions and can create and
remove worktrees. Worktrunk hooks remain enabled, so only operate on repositories
and hook configurations you trust. Once removal is approved and queued, closing
the popup does not cancel it.
