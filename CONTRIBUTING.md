# Contributing

Thanks for helping! Most contributions will be **provider plugins**: one file per DNS provider in
`providers/`.

## License and origin

ddns-watch is licensed under **GPL-3.0-or-later**. By opening a pull request you confirm that

- the code is your own, or comes from a GPL-3.0-compatible source that you name in the PR and in
  the file (with its copyright notice), and
- you publish it under GPL-3.0-or-later.

Please base provider code on the provider's **public API documentation**, not on other projects'
source code.

## Writing a provider plugin

1. Copy `providers/_template.sh` to `providers/<name>.sh` (`<name>`: lower case, digits, `-`).
2. Fill in the metadata:
   - `PROVIDER_NAME` = file name without `.sh`
   - `PROVIDER_TIER="community"` (`core` is reserved for providers the maintainers test live)
   - `PROVIDER_MAINTAINER` = your GitHub name, so users know whom to ask
   - `PROVIDER_SETTINGS`: config keys, each starting with the upper-case name + `_`
     (plugin `my-dns` → `MY_DNS_...`)
   - `PROVIDER_SECRETS`: secret names starting with the plugin name (`my-dns-token`)
   - `PROVIDER_HELP`: one short, concrete help text per setting and secret: where to find it
3. Implement `provider_config`, `provider_secrets`, `provider_update`, `provider_check`.
4. Add a mock for the provider's API to `tests/mock_api.py` and test cases to `tests/run.sh`:
   at least a successful update, "nothing to change", and a wrong key.
5. Run `tests/run.sh` and `shellcheck -S warning ddns-watch.sh providers/*.sh tests/run.sh`.

If the provider speaks the dyndns2 protocol, you may not need a plugin at all: use
`PROVIDER=dyndns2` with `DYNDNS2_URL`. A thin plugin like `providers/strato.sh` is welcome when it
saves users from looking up the URL.

## Rules for plugins

- **Secrets never on a command line, never in a message.** Pass them to `curl` via stdin
  (`-K -`, see `curl_cfg_escape`) or in a request body on stdin.
- **Only touch the A and AAAA records of `DDNS_HOSTNAME`.** Never delete or change other records.
  If the provider's answer looks wrong (e.g. an empty zone), refuse to change anything.
- `provider_check` must be **read-only**.
- No new dependencies beyond `bash`, `curl`, `dig`, `jq`, coreutils, without discussing it first.
- Keep it readable: a plugin is code that runs with access to the user's DNS key.

## Local plugins

For a provider you do not want to publish, put the file in `/etc/ddns-watch/providers.d/`.
It is only loaded if root owns the file and the folder and nobody else can write to them.
Built-in plugins always take precedence over local ones with the same name.
