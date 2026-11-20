# Changelog

All notable changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [Semantic Versioning](https://semver.org/).

## [1.4.0] - 2026-11-20

Fixes from an external code review.

### Fixed
- A changed hostname, records setting or provider setting (zone, TTL, user ...) now triggers an
  update even if the IPs did not change (before: only at the daily verification).
- The setup no longer stores anything before you confirm the summary: secrets wait in a private
  memory-backed folder and are encrypted on "Apply"; cancelling changes nothing.
- dyndns2/Strato: the setup no longer claims "Login OK" (dyndns2 has no read-only login check);
  it says the first update will show it.
- The watcher restarts itself within a minute when `IFACE`, `IPV4_SOURCE`, `RECORDS` or
  `IPV6_SUFFIX` change (before: it kept watching the old way until restarted).
- netcup REST: a changed `NETCUP_TTL` is applied even if the IP is unchanged.
- Never published: IPv4 documentation and benchmark ranges (192.0.2.0/24, 198.51.100.0/24,
  203.0.113.0/24, 198.18.0.0/15, 192.0.0.0/24); IPv6 addresses that are tentative or failed duplicate
  address detection, the documentation prefix 2001:db8::/32 and anything outside 2000::/3.
- dyndns2: success needs HTTP 2xx and a complete `good`/`nochg` answer; HTTP errors are reported.
- CI: the hardening check could never fail (the shell ran without pipefail); a test now proves it
  fails for a weak unit.
- Upgrades check that the service is running afterwards and fail loudly if not.

### Changed
- dyndns2 requires an https update URL; `DYNDNS2_ALLOW_HTTP=yes` allows http for local tests.
- The service only gets the secrets of the active provider (plus notification/heartbeat), not
  those of providers used before.
- Releases run the complete CI first (same checks as every push). GitHub Actions are pinned to
  commit SHAs and updated by Dependabot.
- README: precise wording (what is verified, what is encrypted, what the login test can do),
  new sections Troubleshooting and "DNS is right, but the server is not reachable?".
- `main` now says `1.4.0-dev` instead of `1.0.0-dev`.

## [1.3.0] - 2026-11-20

### Added
- **Discord** and **Slack / Mattermost** notifications (`NOTIFY_TYPE=discord|slack`, detected
  automatically from the webhook URL). Rejected updates are marked with ⚠️.
- Notification and heartbeat URLs can be stored encrypted (`NOTIFY_URL=secret`,
  `HEARTBEAT_URL=secret`, secrets `notify-url` / `heartbeat-url`); the setup always does that.
  For Discord/Slack the webhook URL is the password, for ntfy the topic name works like one.
- Guide: Discord and Slack sections in [docs/notifications.md](docs/notifications.md).
- Issue templates (bug report, provider request, feature request) and `SECURITY.md` with private
  vulnerability reporting.

### Security
- Notification and heartbeat URLs are passed to curl on stdin, no longer on the command line
  (where other local users could see them in the process list).

## [1.2.0] - 2026-11-20

### Added
- **Gotify** notifications: JSON with title, message and priority (8 for rejected updates),
  token as `X-Gotify-Key`. Detected by the `/message` URL, or set `NOTIFY_TYPE=gotify`.
- `ddns-watch test-notify`: sends a test notification and a heartbeat ping and reports the result.
- Setup step 6 explains both helpers, detects the notification type and offers a test.
- Guide [docs/notifications.md](docs/notifications.md): ntfy (public and self-hosted), Gotify,
  Healthchecks.io, Uptime Kuma; linked from README and setup.

### Fixed
- The setup listed Gotify as a target although only text POSTs were sent, which Gotify rejects.

## [1.1.0] - 2026-11-20

### Changed
- `ddns-watch setup` redesigned: progress bar with the steps one below the other, colors (only on
  a terminal; `NO_COLOR` respected), aligned tables, choices by number with a recommendation,
  framed summary, clear result of the first update with what happens next.
- Setup shows the provider's records compactly (A/AAAA of the hostname, CNAMEs in one line);
  plugins can provide them with the new optional `provider_records` hook (netcup does).
- Setup no longer asks for the IPv4 check interval (60 s for upnp, otherwise 5 min;
  `IPV4_INTERVAL` in the config still overrides it).

### Fixed
- `ddns-watch status` without root said "Last good: never"; the state is only readable by root,
  so it now says so.
- `status` showed errors from before the last restart of the service; now only newer ones.

## [1.0.1] - 2026-11-20

### Fixed
- The service could not read any address: the syscall filter blocked `capset()`, which `ip`
  (iproute2) calls at start to drop its capabilities, so `ip` failed and the watcher restarted
  every 30 s. `capget`/`capset` are allowed again; with an empty capability bounding set they can
  only drop privileges.

### Added
- `tools/sandbox-check.sh`: runs `ip`, `dig`, `curl`, `jq` and `flock` under the real sandbox of
  the units (CI runs it with root; `--user` works without root).

## [1.0.0] - 2026-11-20

First release of the new structure. Not compatible with the earlier single-folder version:
install it fresh and remove the old units (the installer offers to do that).

### Added
- System-wide installation (`/usr/local`, `/etc/ddns-watch`, `/var/lib/ddns-watch`) with a
  one-line installer that verifies the SHA256 checksum and, with the `gh` CLI, the GitHub build
  attestation. `ddns-watch update` installs new releases the same way.
- Guided setup (`ddns-watch setup`): provider, hostname, login test, network detection,
  notifications, summary before anything is changed. The interface list shows, per interface,
  the IPv6 that would be published and recommends one.
- Secrets encrypted with `systemd-creds` (TPM-bound where available): `set-secret`, `secrets`.
- Hardened systemd units (dynamic user, read-only system, syscall filter;
  `systemd-analyze security`: 1.1 OK).
- Provider plugins (`providers/*.sh`): `netcup` (REST + legacy), `strato`, and a generic `dyndns2`
  plugin for deSEC, Dynu, No-IP and others. Template and rules in `CONTRIBUTING.md`.
- IPv4 sources: `interface`, `upnp` (router, no login; FRITZ!Box found automatically), `dns`
  (Cloudflare, OpenDNS, Google), `command`; never publishes private or CGNAT addresses.
  `RECORDS=A+AAAA|AAAA|A`.
- The watcher only runs the updater when a published address changes; several stable IPv6:
  EUI-64 preferred, or pick one with `IPV6_SUFFIX`.
- Error handling: permanent errors (wrong key, unknown host) stop retries and notify at once;
  temporary errors are retried after 1, 2, 5, then every 10 minutes. Daily verification.
- Optional notifications (`NOTIFY_URL`, ntfy-compatible) and heartbeat (`HEARTBEAT_URL`).
- `status`, `providers`, `uninstall [--purge]`.

### Changed
- Config is parsed (`KEY=value`), never executed. Messages go to the systemd journal.
- One provider at a time (the parallel "both" mode for moving domains was removed).
- License: GPL-3.0-or-later (was MIT).
