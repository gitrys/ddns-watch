# shellcheck shell=bash
# ddns-watch provider plugin: any service that speaks the dyndns2 update protocol
# (GET <url>?hostname=...&myip=... with HTTP basic auth; answers "good" / "nochg" / an error word).
# Examples: deSEC, Dynu, No-IP and many registrars. Strato builds on this (providers/strato.sh).
# Copyright (C) 2026 gitrys. SPDX-License-Identifier: GPL-3.0-or-later

PROVIDER_NAME="dyndns2"
PROVIDER_TIER="core"
PROVIDER_MAINTAINER="gitrys"
PROVIDER_DESCRIPTION="any dyndns2-compatible service (update URL + user + password)"
PROVIDER_SETTINGS="DYNDNS2_URL DYNDNS2_USER"
PROVIDER_SECRETS="dyndns2-password"
PROVIDER_HELP=(
    [DYNDNS2_URL]="The provider's update URL without parameters, e.g. https://update.dedyn.io/nic/update (see your provider's DynDNS help page)."
    [DYNDNS2_USER]="DynDNS user name. Often the hostname itself (default)."
    [dyndns2-password]="DynDNS password or token from your provider's DynDNS settings."
)

# dyndns2_send URL USER PASSWORD IPV4 IPV6 -> PROVIDER_RESPONSE; returns 0 on good/nochg.
# User and password go to curl via stdin (-K -), never on the command line.
dyndns2_send() {
    local url="$1" user="$2" pass="$3" ipv4="$4" ipv6="$5" myip
    myip="${ipv4}${ipv4:+${ipv6:+,}}${ipv6}"
    say "sending myip=$myip to ${url%%\?*}"
    PROVIDER_RESPONSE=$(printf 'user = "%s:%s"\n' "$(curl_cfg_escape "$user")" "$(curl_cfg_escape "$pass")" \
        | curl --silent --show-error --max-time 30 -K - \
        "${url}?hostname=${DDNS_HOSTNAME}&myip=${myip}" \
        2>&1) || true
    [[ "$PROVIDER_RESPONSE" =~ ^(good|nochg) ]] && return 0
    # dyndns2 answers that will not get better by retrying: wrong login, unknown or invalid host,
    # blocked for abuse, client blocked, paid feature. The protocol asks clients to stop then.
    if [[ "$PROVIDER_RESPONSE" =~ ^(badauth|nohost|notfqdn|abuse|badagent|\!donator|\!yours) ]]; then
        PROVIDER_ERROR_CLASS="permanent"
    fi
    return 1
}

# dyndns2_check LABEL USER IPV4 IPV6: dyndns2 has no read API, so show public DNS instead.
dyndns2_check() {
    say "Provider: $1 (dyndns2, no read API)"
    say "Hostname: $DDNS_HOSTNAME   user: $2"
    say "Public DNS now:"
    say "  A    $(dig +short "$DDNS_HOSTNAME" A @1.1.1.1 | tr '\n' ' ')"
    say "  AAAA $(dig +short "$DDNS_HOSTNAME" AAAA @1.1.1.1 | tr '\n' ' ')"
    say "Would send: myip=${3}${3:+${4:+,}}${4}"
}

provider_config() {
    DYNDNS2_URL=$(cfg DYNDNS2_URL)
    DYNDNS2_USER=$(cfg DYNDNS2_USER "$DDNS_HOSTNAME")
    if [[ ! "$DYNDNS2_URL" =~ ^https?://[A-Za-z0-9.:_/~%-]+$ || "$DYNDNS2_URL" == *"://"*"://"* ]]; then
        err "DYNDNS2_URL=$DYNDNS2_URL in $CONFIG_FILE must be an http(s) URL without parameters"
        return 1
    fi
    if [[ "$DYNDNS2_URL" == http://* ]]; then
        warn "DYNDNS2_URL uses http://: the password is sent unencrypted"
    fi
}

provider_secrets() {
    need_secret DYNDNS2_PASS dyndns2-password
}

provider_update() {
    dyndns2_send "$DYNDNS2_URL" "$DYNDNS2_USER" "$DYNDNS2_PASS" "$1" "$2"
}

provider_check() {
    dyndns2_check "dyndns2 $DYNDNS2_URL" "$DYNDNS2_USER" "$1" "$2"
}
