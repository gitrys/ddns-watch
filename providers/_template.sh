# shellcheck shell=bash
# ddns-watch provider plugin TEMPLATE. Copy to providers/<name>.sh and fill in.
# Files starting with "_" are never loaded. See CONTRIBUTING.md for the rules.
# Copyright (C) <year> <your name>. SPDX-License-Identifier: GPL-3.0-or-later
#
# What the core gives you:
#   DDNS_HOSTNAME   the validated, lower-case hostname to update
#   cfg KEY [DEF]   a setting from the config file (only keys listed in PROVIDER_SETTINGS)
#   need_secret VAR NAME   load secret NAME into VAR, exit with a clear message if missing
#   read_secret NAME       print secret NAME, empty if missing (for optional secrets)
#   curl_cfg_escape S      escape S for a curl config passed on stdin (-K -)
#   say / warn / err / die messages (stdout/stderr = systemd journal)
#   provider_use NAME      build on another plugin (e.g. "provider_use dyndns2")
#
# Rules: never put secrets on a command line or into a message; pass them to curl via stdin.
# Only touch the A/AAAA records of DDNS_HOSTNAME.

PROVIDER_NAME="example"                 # must equal the file name without .sh: [a-z0-9-]
PROVIDER_TIER="community"               # core = tested live by the maintainers; community = mock-tested
PROVIDER_MAINTAINER="your-github-name"
PROVIDER_DESCRIPTION="Example DNS (one line)"
PROVIDER_SETTINGS="EXAMPLE_ZONE"        # config keys; every key starts with the upper-case name + "_"
PROVIDER_SECRETS="example-api-token"    # secret names: [a-z0-9-], start with the plugin name
PROVIDER_HELP=(                         # one short help text per setting and secret (shown by the installer)
    [EXAMPLE_ZONE]="Zone at Example DNS. Leave empty to use the last two labels of the hostname."
    [example-api-token]="Example dashboard -> API tokens -> create a token with DNS edit rights."
)

# Optional: rate limits of the provider, in seconds.
# PROVIDER_MIN_INTERVAL=60        # at most one update per minute
# PROVIDER_MAX_INTERVAL=2592000   # the provider drops names not updated for 30 days: refresh before

EXAMPLE_API="${EXAMPLE_API:-https://api.example.invalid/v1}"   # env override only for tests

# Read and validate settings. Return 1 after err "..." if something is wrong. No network, no secrets.
provider_config() {
    EXAMPLE_ZONE=$(cfg EXAMPLE_ZONE)
}

# Load the secrets (need_secret exits with a clear message if one is missing).
provider_secrets() {
    need_secret EXAMPLE_TOKEN example-api-token
}

# provider_update IPV4 IPV6 (either may be empty = leave that record alone).
# Set PROVIDER_RESPONSE to a short result ("good ..." / "nochg ..." / error text); return 0 on success.
# On errors that retrying cannot fix (key rejected, unknown host, blocked) also set
# PROVIDER_ERROR_CLASS=permanent: then ddns-watch stops retrying and notifies the user at once.
# Anything else counts as temporary and is retried after 1, 2, 5, then every 10 minutes.
provider_update() {
    PROVIDER_RESPONSE="not implemented"
    return 1
}

# provider_check IPV4 IPV6: read-only. Test the login, show the current records and what an
# update would change. Must not change anything.
provider_check() {
    say "Provider: example"
    return 1
}
