# Security policy

ddns-watch handles keys that can change your DNS. Please report security problems privately.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting**:
[Report a vulnerability](https://github.com/gitrys/ddns-watch/security/advisories/new)
(repository → *Security* → *Report a vulnerability*). Please do **not** open a public issue.

Helpful details: affected version (`ddns-watch --version`), what an attacker needs (local user,
network position, ...), what they can achieve, and steps to reproduce. Never include real keys,
passwords or webhook URLs.

The aim is to answer within a week. Fixes are released as a new version with a note in the
[CHANGELOG](CHANGELOG.md); you are credited unless you prefer not to be.

## Supported versions

Only the **latest release** gets fixes. Update with:

```bash
sudo ddns-watch update
```

## Scope

In scope, for example: reading the stored secrets without root, secrets in logs, process lists
or files, escaping the systemd sandbox, tampering with downloads or updates, changing DNS records
other than the configured A/AAAA records.

Out of scope: problems of the DNS providers' APIs themselves, and attacks that already require
root on the machine (root can read the secrets by design).
