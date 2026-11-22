# ddns-watch

[![CI](https://github.com/gitrys/ddns-watch/actions/workflows/ci.yml/badge.svg)](https://github.com/gitrys/ddns-watch/actions/workflows/ci.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)
[![Built with AI assistance](https://img.shields.io/badge/built%20with-AI%20assistance-8A2BE2)](#about)

Keeps the `A` and `AAAA` record of one hostname pointing at your Linux machine, made for home
servers with their **own public IPv6** (e.g. behind a FRITZ!Box with a daily reconnect).

- **Reacts in seconds:** the kernel reports IPv6 changes, and ddns-watch sends the update to your
  provider right away. A reconnect usually changes the IPv6 prefix too, so the new IPv4 is picked up
  in the same run; a timer catches changes of the IPv4 alone. (Resolvers that cached the old
  address keep it until the record's TTL runs out, 5 minutes by default for netcup.)
- **Right address:** the stable IPv6 of the machine (no temporary privacy, tentative or local-only
  addresses); never a private, carrier-NAT or other special-purpose IPv4 (documentation and
  benchmark ranges included).
- **Secrets encrypted** with `systemd-creds` (bound to the machine's TPM where available): API keys,
  passwords, and notification/heartbeat URLs entered in the setup.
- **Hardened service:** own throw-away user, read-only system, syscall filter.
- **Plugins** for DNS providers: netcup, Strato and dyndns2 services (tested with Strato; deSEC,
  Dynu, No-IP and others use the same protocol and should work).
- Retries, daily verification, optional notifications (ntfy, Gotify, Discord, Slack) and heartbeat
  ([guide](docs/notifications.md)).

## Install

Needs Linux with **systemd 250 or newer** (e.g. Ubuntu 24.04, Debian 12).

```bash
curl -fsSL https://github.com/gitrys/ddns-watch/releases/latest/download/install.sh | sudo bash
```

Nothing else is needed. The installer installs missing packages after asking and starts the
guided setup:

1. DNS provider
2. hostname
3. login, tested read-only where the provider allows it (netcup: yes; dyndns2/Strato have no such
   call, the first update at the end shows whether the password is right)
4. network interface (shows the IPv6 that would be published)
5. where the IPv4 comes from (detected for you)
6. notifications (optional)

Nothing is changed, and no secret is stored, before you confirm the summary.

**What is verified:** the installer checks the SHA256 checksum of the release it downloads, and,
if the [GitHub CLI](https://cli.github.com/) (`gh`) is installed, the GitHub build attestation
(proof that the files were built by this repository's release workflow). The checksum alone only
protects against broken downloads, since it comes from the same place. And with
`curl ... | sudo bash` the installer script itself runs before anything is checked. The careful
way: download it, verify it, read it, then run it:

```bash
curl -fsSLO https://github.com/gitrys/ddns-watch/releases/latest/download/install.sh
gh attestation verify install.sh --repo gitrys/ddns-watch   # optional, needs the GitHub CLI
less install.sh
sudo bash install.sh
```

From a git checkout: `sudo ./install.sh`.

## Use

```bash
ddns-watch status                 # settings, last update, services, errors (sudo: also secrets)
sudo ddns-watch check             # login, current records, what an update would change
sudo ddns-watch run --force       # update now
journalctl -u ddns-watch -f       # log
sudo ddns-watch setup             # change settings (guided)
sudo ddns-watch set-secret NAME   # change a key/password (e.g. netcup-api-key)
sudo ddns-watch test-notify       # send a test notification and heartbeat
sudo ddns-watch update            # install the newest release
sudo ddns-watch uninstall         # remove (--purge: also config and secrets)
ddns-watch providers              # available provider plugins
```

Only one hostname is updated. Make other names `CNAME`s to it, e.g. `www.example.com` →
`example.com`. (A CNAME is not allowed at the zone apex: if you update `home.example.com`,
`example.com` itself cannot point to it with a CNAME.) Several hostnames are on the
[roadmap](ROADMAP.md).

## Where things are

| What | Where |
|---|---|
| program | `/usr/local/bin/ddns-watch`, plugins in `/usr/local/lib/ddns-watch/providers/` |
| settings | `/etc/ddns-watch/config` (see [`config.example`](config.example)) |
| secrets | `/etc/ddns-watch/credentials/` (encrypted, root only) |
| state | `/var/lib/ddns-watch/` |
| services | `ddns-watch.service` (watcher), `ddns-watch-ipv4.timer` (IPv4 check) |
| log | `journalctl -u ddns-watch -u ddns-watch-ipv4` (the IPv4 check logs only updates, warnings and errors, not every unchanged run) |

The config is plain `KEY=value` and is never executed. It is read on every run, so changes apply
without a restart: a change of hostname, records or provider settings (zone, TTL ...) triggers an
update even if the IPs are the same, and the watcher restarts itself within a minute when
`IFACE`, `IPV4_SOURCE`, `RECORDS` or `IPV6_SUFFIX` change.

Two exceptions need `sudo ddns-watch setup` (or `sudo ddns-watch set-secret NAME`): **switching
the provider** and **adding a secret by hand**. The service only receives the secrets of the
provider that was active at the last setup / set-secret; `sudo ddns-watch status` shows
"stored, but NOT given to the service" when that is out of date. A changed `IPV4_INTERVAL` also
takes effect with the next setup run.

## Providers

| Provider | Setting | Secret |
|---|---|---|
| `netcup` | REST API (CloudDNS); legacy API as fallback | `netcup-api-key` (CCP → Stammdaten → API → API-Keys) |
| `strato` | Strato DynDNS | `strato-password` (DynDNS password from the Strato login) |
| `dyndns2` | dyndns2 services: `DYNDNS2_URL` (https only) | `dyndns2-password` |

For netcup only the A/AAAA records of the hostname are changed; every other record stays as it
is. Want another provider? See [CONTRIBUTING.md](CONTRIBUTING.md): a plugin is one file.

## IPv4 sources

| `IPV4_SOURCE` | When |
|---|---|
| `interface` | the machine has a public IPv4 itself (VPS, router in bridge mode). Instant, like IPv6. |
| `upnp` | ask the router (no login). FRITZ!Box: enable *Heimnetz → Netzwerk → Netzwerkeinstellungen → Statusinformationen über UPnP übertragen*. Other routers: set `UPNP_URL` or install `miniupnpc`. |
| `dns` | ask Cloudflare, OpenDNS, Google. Works behind any router. |
| `command` | your own program prints the IPv4 (`IPV4_COMMAND`). |

`RECORDS=AAAA` publishes IPv6 only. Use it with **DS-Lite / carrier-grade NAT**: there the IPv4
is shared and not reachable from outside (setup detects this).

**Records are only set, never deleted:** if the machine has no usable IPv4 (or IPv6) for a while,
the existing A (or AAAA) record is left as it is, so a short outage of the lookup does not take the
name offline. The same applies when you switch to `RECORDS=AAAA` or `RECORDS=A`: remove the
record that is no longer wanted by hand at your provider.

## Errors and notifications

- A **permanent** error (key rejected, unknown hostname) stops further tries until you change the
  config or the secret, and notifies at once.
- A **temporary** error (provider down, no usable address) is retried. A retry is allowed after
  1, 2, 5, then every 10 minutes; it runs at the next check after that: the IPv4 timer (every
  minute with `upnp`, every 5 minutes otherwise) or an address change. Notification after
  `NOTIFY_AFTER` minutes (default 15), and again when it works.
- Once a day the current addresses are sent even without a change (fixes records changed by hand).
- **Notification** (`NOTIFY_URL`, optional): a message to your phone when updates keep failing,
  via **ntfy** (no account needed), **Gotify**, **Discord** or **Slack** / Mattermost.
- **Heartbeat** (`HEARTBEAT_URL`, optional): a URL called after every good run, e.g. a
  Healthchecks.io check or an Uptime Kuma push monitor. When the calls stop, that service tells
  you the machine or the service is down.
- Test both: `sudo ddns-watch test-notify`.

**Step-by-step guide: [docs/notifications.md](docs/notifications.md)** (ntfy, Gotify, Discord, Slack,
Healthchecks.io, Uptime Kuma).

## Troubleshooting

```bash
ddns-watch status                          # settings, last good update, services, current error
sudo ddns-watch status                     # same, plus whether the secrets can be decrypted
sudo ddns-watch check                      # read-only: login, records at the provider, planned change
journalctl -u ddns-watch -u ddns-watch-ipv4 -n 50 --no-pager
dig +short AAAA home.example.com @1.1.1.1  # what the world sees ...
ip -6 addr show scope global               # ... and what this machine has
sudo ddns-watch run --force                # send the update now (also retries a stopped error)
```

- **"not retrying: ... rejected"**: the provider refused the key or the hostname. Fix it
  (`sudo ddns-watch set-secret ...` or `sudo ddns-watch setup`); the next run tries again.
- **"CANNOT DECRYPT"** in `sudo ddns-watch status`: see [Moving to new hardware](#moving-to-new-hardware).
- **DNS shows the old address**: resolvers cache it for the record's TTL; check the provider's
  name server directly, e.g. `dig AAAA home.example.com @<ns-of-your-provider>`.

## DNS is right, but the server is not reachable?

ddns-watch only makes the name point to the right address. Whether a connection gets through is
decided elsewhere:

- **Router firewall:** a FRITZ!Box blocks incoming IPv6 by default. Allow the ports for this
  device under *Internet → Freigaben → Portfreigaben → Gerät für Freigaben hinzufügen* (IPv6 tab).
  For IPv4 you need a port forwarding to the server.
- **Firewall on the server** (ufw, nftables, the Docker rules ...) and a service that actually
  listens on IPv6 (`ss -tlnp`).
- **DS-Lite / carrier-grade NAT:** the IPv4 is shared with other customers and cannot be reached
  from outside at all; only IPv6 works (use `RECORDS=AAAA`).
- Test from outside your network (e.g. mobile data without Wi-Fi), not from the LAN.

## Moving to new hardware

The encrypted secrets only work on the machine that encrypted them (and they stop working after
Secure Boot changes). After restoring a backup elsewhere, enter them again:

```bash
sudo ddns-watch secrets                       # shows "CANNOT DECRYPT"
sudo ddns-watch set-secret netcup-api-key
```

Keep your API key in a password manager, or create a new one at your provider.

## Moving a domain between providers

Create the records at the new provider first (other names as CNAMEs). After the registry has
switched to the new provider's name servers, run `sudo ddns-watch setup` and choose the new
provider. Settings of the old provider stay in the config and are ignored.

## Known limitations

Deliberately not handled, because they are rare or the fix would cost more than it helps:

- **Heartbeat and dual stack:** the heartbeat only shows that ddns-watch runs and reaches the
  internet. If only the IPv6 is lost while IPv4 works, the heartbeat stays green; the AAAA record is
  then kept as it was (see "Records are only set, never deleted") and the log says why.
- **Several public IPv4 on the interface** with `IPV4_SOURCE=interface`: the first public one is
  used. `IPV4_FALLBACK=dns` is only asked when none of them is public.
- **netcup records marked immutable** (only NS/SOA in practice) are not changed or deleted. If the
  A/AAAA record of your hostname were immutable, ddns-watch could not replace it.
- **No rollback for an interrupted update.** `update` checks that the service runs afterwards and
  says so loudly if not. If the program itself is broken, run the installer again:
  `curl -fsSL https://github.com/gitrys/ddns-watch/releases/latest/download/install.sh | sudo bash`
  (your config and secrets are kept).
- **Retries are not minute-exact** (see above): they happen at the next check.

## Security

- Secrets are passed to `curl` on stdin, never on a command line, and never logged.
- The service runs as a dynamic user without privileges; `systemd-analyze security ddns-watch`
  rates it about 1.1 ("OK"). It needs the network, nothing else.
- Local provider plugins in `/etc/ddns-watch/providers.d/` are only loaded if root owns them.

## Development

```bash
tests/run.sh          # Linux; needs bash, python3, curl, jq, flock. Mock APIs, no network, no root.
```

The tests run the real script against mock servers (netcup, Strato, router, notification
services, release downloads) and stubs for `systemd-creds`, `systemctl`, `dig` and `ip`. CI runs
shellcheck, the tests, a check of the systemd units (syntax and a hardening threshold), the tools
inside the units' real sandbox, a release build and a secret scan. A release (tag `vX.Y.Z` with a
matching `CHANGELOG.md` section) runs the same CI first.

## About

ddns-watch was written with the help of an AI coding assistant (Claude Code) and reviewed by the
maintainer. Every change has to pass the automated tests and CI described above. Please report
anything that looks wrong in an issue.

## License

GNU General Public License v3.0 or later (GPL-3.0-or-later). See [LICENSE](LICENSE).
