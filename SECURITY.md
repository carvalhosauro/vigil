# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities.

Report privately to **gustavo.carvalho@pigz.com.br**, or use GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository.

Include: affected version, a description, and reproduction steps. You can expect
an acknowledgement within a few days.

## Supported versions

Vigil is pre-1.0. Only the latest released version receives security fixes until
a stable `1.0` is published.

## Handling of secrets

Vigil never stores credentials in configuration files. Secrets (e.g. the Telegram
token) are provided via environment variables and are never logged. See RFC-0003.
