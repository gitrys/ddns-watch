# Changelog

All notable changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [Semantic Versioning](https://semver.org/).

## [1.7.0] - 2026-11-22

The installer and the commands that reload systemd say what they are waiting for.

### Changed
- Installer, `update`, `setup`, `set-secret` and `uninstall` say "Reloading systemd ..." before
  `systemctl daemon-reload`, and the installer says "Restarting ddns-watch.service ..." before the
  restart. A reload can take 90 s when a network mount does not answer (e.g. NFS to a sleeping
  NAS); before, the output simply stopped and looked stuck. ([#1](https://github.com/gitrys/ddns-watch/issues/1))

## [1.6.0] - 2026-11-22

Quieter journal and log fixes, found in the first days of live use.

### Changed
- Quieter journal: the IPv4 check (`ddns-watch-ipv4.service`, about once a minute with UPnP) now
  logs only updates, warnings and errors (`LogLevelMax=notice`), not "unchanged" or systemd's
  start/finish lines for every run. Before, that was about 4000 lines a day. Updates, provider
  answers, address changes and sent notifications are logged as notice, "unchanged" as debug.
  `ddns-watch run` in a terminal prints everything as before.

### Fixed
- Log: an address change that falls on the daily verification time (e.g. a router that reconnects
  at the same time every night) was logged as "periodic verification". It now shows as a change.
- Log: no stray blank before the closing bracket in "watch: address changed (...)".
- Priority prefixes (`<3>ERROR`, `<4>WARN` ...) appeared in plain output when `JOURNAL_STREAM` was
  only inherited (e.g. a shell started from a service, a CI runner). They are now written only
  when stdout really is the journal stream named there.

## [1.5.0] - 2026-11-20

Fixes from a second external code review.

### Fixed
- Setup: the login test now uses exactly the config that will be saved, including settings not
  asked again (e.g. `NETCUP_ZONE`, `NETCUP_API`). Before, a re-run could fail the test although the
  saved config was right.
- A custom `IPV4_INTERVAL` above 5 minutes had no effect (timer settings are lists; the drop-in
  added a second interval). The drop-in now replaces the list, and the timer is restarted.
- "No usable IPv4 and IPv6" is now a temporary error: counted, notified after `NOTIFY_AFTER`, and
  retried at once when an address is back.
- Numbers with a leading zero (`NOTIFY_AFTER=08`, `NETCUP_TTL=0300`) broke the arithmetic or the
  JSON; settings are now checked for their range and stored as plain decimals.
- If the state cannot be saved after a successful DNS update, this is reported as an error
  (no heartbeat, non-zero exit) instead of a silent success.
- netcup `NETCUP_API=auto` falls back to the legacy API only if the REST API says the domain is on
  netcup's old DNS, no longer on a rejected key, timeout or server error.
- `IPV4_SOURCE=interface` with several addresses and `IPV4_FALLBACK=dns`: the first public
  address on the interface is used; DNS is only asked when there is none.
- A secret that is stored but not handed to the service (provider switched in the config by hand)
  gives a clear message ("run sudo ddns-watch setup"), also in `sudo ddns-watch status`.

### Changed
- README: retries happen at the next check after the retry time (not minute-exact); provider
  switch needs the setup; new section "Known limitations".

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
