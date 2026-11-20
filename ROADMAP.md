# Roadmap

Ideas and plans for ddns-watch. Nothing here is promised or scheduled; the order is a rough
priority. Suggestions and pull requests are welcome; please open an issue first for larger
changes. Done items move to the [CHANGELOG](CHANGELOG.md).

## Planned

### Several hostnames (one provider)
Today exactly one hostname is updated and other names are CNAMEs to it. Planned:
`HOSTNAMES=home.example.com vpn.example.com`, all at the same provider.
- The core calls the provider plugin once per name; plugins need (almost) no changes.
- State, errors and retries are kept per name; `status` and `setup` show and ask for a list.
- Estimated size: medium (about 150–250 lines plus tests).

Several names at **different** providers (each with its own settings and secrets) would need a
different config format. Only if there is real demand.

### More provider plugins
Community plugins (one file each, see [CONTRIBUTING.md](CONTRIBUTING.md)). Candidates:
Cloudflare (first example), Hetzner DNS, IONOS, INWX, DuckDNS, Porkbun.
Many dyndns2 services already work with `PROVIDER=dyndns2`; thin presets with the right URL are
welcome too.

## Ideas

- **Router discovery for UPnP (SSDP)**: today `upnp` finds the FRITZ!Box automatically; other
  routers need `UPNP_URL` or `miniupnpc` (`upnpc`). Automatic discovery would need a small UDP
  helper, as bash cannot read UDP answers.
- **Signed releases with an own key** (minisign) in addition to the GitHub build attestation,
  so a release can be checked without the GitHub CLI.
- **Distribution packages** (`.deb`), if the one-line installer is not enough.
- **Minute-exact retries** independent of the check interval (today a retry runs at the next
  check: every minute with `upnp`, every 5 minutes otherwise). Only if it turns out to matter.
- **Transactional updates with rollback** (versioned install folders). Today `update` verifies
  that the service runs and the installer can always be run again.

## Not planned

- Running several providers at the same time for moving a domain (removed in 1.0.0): create the
  records at the new provider first, then switch with `ddns-watch setup`.
- Becoming a general-purpose updater for every provider and setup: ddns-watch stays small and
  focused on home servers with their own IPv6.
