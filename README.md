# ddns-watch

Keeps the `A` and `AAAA` record of one hostname pointing at your Linux machine, made for home
servers with their **own public IPv6** (e.g. behind a FRITZ!Box with a daily reconnect).

- **Reacts in seconds:** the kernel reports IPv6 changes, and ddns-watch updates the DNS record
  right away. A reconnect usually changes the IPv6 prefix too, so the new IPv4 is picked up in the
  same run. A timer catches changes of the IPv4 alone.
- **Right address:** the stable IPv6 of the machine (no temporary privacy addresses); never a
  private or carrier-NAT IPv4.
- **Secrets encrypted** with `systemd-creds` (bound to the machine's TPM where available).
- **Hardened service:** own throw-away user, read-only system, syscall filter.
- **Plugins** for DNS providers: netcup, Strato and any dyndns2 service (deSEC, Dynu, No-IP ...).
- Retries, daily verification, optional notifications (ntfy & co.) and heartbeat.

## Install

Needs Linux with **systemd 250 or newer** (e.g. Ubuntu 24.04, Debian 12).

```bash
curl -fsSL https://github.com/gitrys/ddns-watch/releases/latest/download/install.sh | sudo bash
```

Nothing else is needed. The installer verifies the SHA256 checksum of the download; if the
[GitHub CLI](https://cli.github.com/) (`gh`) happens to be installed, it also verifies the build
attestation (optional). It installs missing packages after asking and starts the guided setup:

1. DNS provider
2. hostname
3. login (stored encrypted)
4. login test (read-only)
5. network: interface, where the IPv4 comes from (detected for you)
6. notifications (optional)

Nothing is changed before you confirm the summary. To read the installer first:

```bash
curl -fsSLO https://github.com/gitrys/ddns-watch/releases/latest/download/install.sh
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
sudo ddns-watch update            # install the newest release
sudo ddns-watch uninstall         # remove (--purge: also config and secrets)
ddns-watch providers              # available provider plugins
```

Only one hostname is updated. Make every other name a `CNAME` to it.

## Where things are

| What | Where |
|---|---|
| program | `/usr/local/bin/ddns-watch`, plugins in `/usr/local/lib/ddns-watch/providers/` |
| settings | `/etc/ddns-watch/config` (see [`config.example`](config.example)) |
| secrets | `/etc/ddns-watch/credentials/` (encrypted, root only) |
| state | `/var/lib/ddns-watch/` |
| services | `ddns-watch.service` (watcher), `ddns-watch-ipv4.timer` (IPv4 check) |
| log | `journalctl -u ddns-watch -u ddns-watch-ipv4` |

The config is plain `KEY=value` and is never executed. It is read on every run; only a changed
`IFACE` needs `sudo systemctl restart ddns-watch`.

## Providers

| Provider | Setting | Secret |
|---|---|---|
| `netcup` | REST API (CloudDNS); legacy API as fallback | `netcup-api-key` (CCP → Stammdaten → API → API-Keys) |
| `strato` | Strato DynDNS | `strato-password` (DynDNS password from the Strato login) |
| `dyndns2` | any dyndns2 service: `DYNDNS2_URL` | `dyndns2-password` |

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

## Errors and notifications

- A **permanent** error (key rejected, unknown hostname) stops further tries until you change the
  config or the secret, and notifies at once.
- A **temporary** error (provider down, no network) is retried after 1, 2, 5, then every 10
  minutes; notification after `NOTIFY_AFTER` minutes (default 15), and again when it works.
- Once a day the current addresses are sent even without a change (fixes records changed by hand).
- `NOTIFY_URL`: any URL that takes a text POST; headers are ntfy-compatible. Optional token:
  `sudo ddns-watch set-secret notify-token`.
- `HEARTBEAT_URL`: called after every good run (Healthchecks, Uptime Kuma push). When the calls
  stop, that service tells you the machine or the service is down.

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

## Security

- Secrets are passed to `curl` on stdin, never on a command line, and never logged.
- The service runs as a dynamic user without privileges; `systemd-analyze security ddns-watch`
  rates it about 1.1 ("OK"). It needs the network, nothing else.
- Local provider plugins in `/etc/ddns-watch/providers.d/` are only loaded if root owns them.

## Development

```bash
tests/run.sh          # Linux; needs bash, python3, curl, jq, flock. Mock APIs, no network, no root.
```

The tests run the real script against mock servers (netcup, Strato, router, release downloads)
and stubs for `systemd-creds`, `systemctl`, `dig` and `ip`. CI runs shellcheck, the tests, a
check of the systemd units and a secret scan. Releases: tag `vX.Y.Z` with a matching
`CHANGELOG.md` section.

## License

GNU General Public License v3.0 or later (GPL-3.0-or-later). See [LICENSE](LICENSE).
