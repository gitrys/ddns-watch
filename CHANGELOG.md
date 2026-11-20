# Changelog

All notable changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [Semantic Versioning](https://semver.org/).

## [1.1.0] - unreleased

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
