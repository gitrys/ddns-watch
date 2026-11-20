#!/bin/bash
# ddns-watch: keeps the A/AAAA record of one hostname pointing at this machine.
#   ddns-watch [run] [--force]    look up IPs, update the provider only if they changed
#   ddns-watch watch              run once, then again whenever IPv6 on IFACE changes (systemd)
#   ddns-watch check [PROVIDER]   test login / show records and planned changes, change nothing
#   ddns-watch providers          list the available provider plugins
#   ddns-watch --version
#
# Directories (systemd sets the *_DIRECTORY variables; DDNS_* are for tests and manual runs):
#   config    $CONFIGURATION_DIRECTORY | DDNS_CONFIG_DIR       default /etc/ddns-watch
#   secrets   $CREDENTIALS_DIRECTORY   | DDNS_CREDENTIALS_DIR  one file per secret
#   state     $STATE_DIRECTORY         | DDNS_STATE_DIR        default /var/lib/ddns-watch (also the update lock)
#   runtime   $RUNTIME_DIRECTORY       | DDNS_RUNTIME_DIR      default /run/ddns-watch (watcher lock)
#   plugins   DDNS_PROVIDERS_DIR, else ./providers next to this script, else ../lib/ddns-watch/providers;
#             local extra plugins in <config dir>/providers.d (root-owned only)
# Messages go to stdout/stderr, i.e. the systemd journal: journalctl -u ddns-watch
#
# config: KEY=value lines, '#' comments, values optionally in '' or "". Parsed, never executed.
#   PROVIDER=netcup               a provider plugin (ddns-watch providers)
#   HOSTNAME=example.com          the name whose A/AAAA records follow this machine
#   IFACE=eth0                    optional; default: interface of the default route
#   plus the provider's own settings, prefixed with its name (e.g. NETCUP_API, STRATO_USER).
#   Settings of other installed providers are ignored, so switching back and forth is easy.
#
# Provider plugins: providers/<name>.sh, see providers/_template.sh and CONTRIBUTING.md.
#
# Needs: bash, curl, dig, ip, flock, awk, sed; jq for netcup.
# https://github.com/gitrys/ddns-watch
# Copyright (C) 2026 gitrys. SPDX-License-Identifier: GPL-3.0-or-later
# This program comes with ABSOLUTELY NO WARRANTY; see LICENSE (GNU GPL v3 or later).

VERSION="1.4.0-dev"   # on main: the next version; releases set the real one

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
CONFIG_DIR="${CONFIGURATION_DIRECTORY:-${DDNS_CONFIG_DIR:-/etc/ddns-watch}}"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_DIR="${STATE_DIRECTORY:-${DDNS_STATE_DIR:-/var/lib/ddns-watch}}"
STATE="$STATE_DIR/last"
RUNTIME_DIR="${RUNTIME_DIRECTORY:-${DDNS_RUNTIME_DIR:-/run/ddns-watch}}"
# The update lock lives in the state directory: the watcher and the IPv4 timer service share it
# (same dynamic user), while the runtime directory belongs to the watcher only.
LOCKFILE="$STATE_DIR/lock"
SECRETS_DIR="${CREDENTIALS_DIRECTORY:-${DDNS_CREDENTIALS_DIR:-}}"
# Encrypted secrets (systemd-creds), one file per secret, named like the secret.
CRED_STORE="${DDNS_CRED_STORE:-$CONFIG_DIR/credentials}"
UNIT_DIR="${DDNS_UNIT_DIR:-/etc/systemd/system}"
UNITS_WITH_SECRETS="ddns-watch.service ddns-watch-ipv4.service"
MIN_SYSTEMD=250
if [[ -n "${DDNS_PROVIDERS_DIR:-}" ]]; then
    PROVIDERS_DIR="$DDNS_PROVIDERS_DIR"
elif [[ -d "$SCRIPT_DIR/providers" ]]; then
    PROVIDERS_DIR="$SCRIPT_DIR/providers"
else
    PROVIDERS_DIR="$(dirname "$SCRIPT_DIR")/lib/ddns-watch/providers"
fi
LOCAL_PROVIDERS_DIR="$CONFIG_DIR/providers.d"
DEBOUNCE_SEC="${DDNS_DEBOUNCE:-8}"   # DDNS_DEBOUNCE only for tests
WATCH_TICK="${DDNS_WATCH_TICK:-60}"   # seconds between config checks of the watcher (tests: shorter)
FORCE=0
USER_FORCE=0

# ---------------------------------------------------------------- messages

# Under systemd a "<N>" prefix sets the journal priority (3 = error, 4 = warning).
_prio() { [[ -n "${JOURNAL_STREAM:-}" ]] && printf '<%s>' "$1"; }
say()  { printf '%s\n' "$*"; }
warn() { printf '%sWARN: %s\n' "$(_prio 4)" "$*" >&2; }
err()  { printf '%sERROR: %s\n' "$(_prio 3)" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat << 'EOF'
Usage: ddns-watch [run] [--force]     update the DNS record if the IPs changed
       ddns-watch watch               keep running, react to IPv6 changes (used by systemd)
       ddns-watch check [PROVIDER]    show login, records and planned changes; change nothing
       ddns-watch providers           list the available provider plugins
       ddns-watch secrets             show which secrets are stored and readable (root)
       ddns-watch set-secret NAME     store a secret encrypted with systemd-creds (root)
       ddns-watch test-notify         send a test notification and heartbeat now (root)
       ddns-watch setup               guided setup: provider, hostname, login, network (root)
       ddns-watch status              show settings, last update, services and secrets
       ddns-watch update [--yes]      install the newest release (checksum-verified, config kept)
       ddns-watch uninstall [--purge] [--yes]   remove ddns-watch (--purge: also config, secrets, state)
       ddns-watch --version
EOF
}

is_root() { [[ "$EUID" -eq 0 || -n "${DDNS_TEST_ROOT:-}" ]]; }

# ---------------------------------------------------------------- helpers for plugins

# number_setting VAR MIN MAX UNIT: checks that VAR holds a whole number in MIN..MAX and stores it
# as plain decimal ("08" -> 8; bash would read a leading 0 as octal and fail on 08/09).
number_setting() {
    local v="${!1}"
    if [[ ! "$v" =~ ^[0-9]{1,7}$ ]] || (( 10#$v < $2 || 10#$v > $3 )); then
        err "$1=$v in $CONFIG_FILE must be a number of $4 between $2 and $3"
        return 1
    fi
    printf -v "$1" '%d' "$((10#$v))"
}

# cfg KEY [DEFAULT] -> the setting from the config file, or DEFAULT.
cfg() {
    local v="${CFG[$1]:-}"
    printf '%s' "${v:-${2:-}}"
}

# read_secret NAME -> the secret's value, empty if missing.
# Under systemd the decrypted secrets are in $CREDENTIALS_DIRECTORY. When run by hand (check, run),
# root decrypts them from the encrypted store with systemd-creds, in memory only.
read_secret() {
    [[ "$1" =~ ^[a-z0-9-]+$ ]] || return 0
    local v
    if [[ -n "${PENDING_SECRETS:-}" && -r "$PENDING_SECRETS/$1" ]]; then
        # Entered in the running setup but not applied yet (memory-backed, deleted on exit).
        v=$(< "$PENDING_SECRETS/$1")
    elif [[ -n "$SECRETS_DIR" ]]; then
        [[ -r "$SECRETS_DIR/$1" ]] || return 0
        v=$(< "$SECRETS_DIR/$1")
    elif [[ -f "$CRED_STORE/$1" ]] && is_root; then
        v=$(systemd-creds decrypt --name="$1" "$CRED_STORE/$1" - 2>/dev/null) || return 0
    else
        return 0
    fi
    printf '%s' "$v"
}

secrets_hint() {
    if [[ -n "${CREDENTIALS_DIRECTORY:-}" ]]; then
        # Running as the service: systemd hands over only the secrets listed in the drop-in, which
        # setup / set-secret write for the provider active at that time.
        printf 'the service was not given this secret. After switching PROVIDER in the config, run: sudo ddns-watch setup (or: sudo ddns-watch set-secret %s)' "${1:-NAME}"
    elif [[ -n "$SECRETS_DIR" ]]; then
        printf 'looked in %s' "$SECRETS_DIR"
    elif ! is_root; then
        printf 'run as root to read the encrypted secrets, e.g. sudo ddns-watch check'
    else
        printf 'not stored or not decryptable; store it with: ddns-watch set-secret %s; see ddns-watch secrets' "${1:-NAME}"
    fi
}

# need_secret VAR NAME: loads secret NAME into VAR; exits with a clear message if it is missing.
need_secret() {
    local v
    v=$(read_secret "$2")
    [[ -n "$v" ]] || die "provider $PROVIDER needs the secret $2 ($(secrets_hint "$2"))"
    printf -v "$1" '%s' "$v"
}

# Escapes a value for a double-quoted string in a curl config file (-K -). Plugins pass secrets to
# curl that way (stdin), so they never show up in the process list.
curl_cfg_escape() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

# ---------------------------------------------------------------- provider plugins

valid_provider_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; }

# provider_file NAME -> path of the plugin. Built-in plugins win over local ones.
provider_file() {
    valid_provider_name "$1" || return 1
    local f
    for f in "$PROVIDERS_DIR/$1.sh" "$LOCAL_PROVIDERS_DIR/$1.sh"; do
        if [[ -f "$f" ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

list_providers() {
    local f n
    for f in "$PROVIDERS_DIR"/*.sh "$LOCAL_PROVIDERS_DIR"/*.sh; do
        [[ -f "$f" ]] || continue
        n="$(basename "$f" .sh)"
        valid_provider_name "$n" && printf '%s\n' "$n"
    done | sort -u
}

# A local plugin runs with access to the secrets: accept it only if root owns it and its folder,
# and nobody else can write to either.
trusted_local_file() {
    local p owner mode
    for p in "$1" "$(dirname "$1")"; do
        read -r owner mode < <(stat -c '%u %a' "$p" 2>/dev/null) || return 1
        [[ "$owner" == 0 ]] || return 1
        (( (8#$mode & 8#022) == 0 )) || return 1
    done
}

# provider_use NAME: lets a plugin build on another one (e.g. strato on dyndns2).
# The caller sets its own metadata and provider_* functions afterwards.
provider_use() {
    local f
    f=$(provider_file "$1") || die "provider plugin $PROVIDER needs plugin $1, which is not installed"
    # shellcheck source=/dev/null
    source "$f"
}

load_provider() {
    local name="$1" f fn
    if ! f=$(provider_file "$name"); then
        err "unknown PROVIDER=$name in $CONFIG_FILE (available: $(list_providers | paste -sd ' ')); no update done"
        return 1
    fi
    PROVIDER_LOCAL=0
    if [[ "$f" == "$LOCAL_PROVIDERS_DIR/"* ]]; then
        if ! trusted_local_file "$f"; then
            err "$f must be owned by root and not writable by group or others (same for its folder); not loading it"
            return 1
        fi
        PROVIDER_LOCAL=1
    fi
    unset -f provider_config provider_secrets provider_update provider_check
    PROVIDER_NAME="" PROVIDER_TIER="" PROVIDER_MAINTAINER="" PROVIDER_DESCRIPTION=""
    PROVIDER_SETTINGS="" PROVIDER_SECRETS="" PROVIDER_MIN_INTERVAL="" PROVIDER_MAX_INTERVAL=""
    PROVIDER_ASK="-" PROVIDER_ASK_SECRETS="-"   # "-" = ask all settings / the first secret
    PROVIDER_LOGIN_CHECK="yes"   # "no" = provider_check cannot verify the login (setup says so)
    declare -gA PROVIDER_HELP=()
    # shellcheck source=/dev/null
    source "$f"
    if [[ "$PROVIDER_NAME" != "$name" ]]; then
        err "$f: PROVIDER_NAME must be \"$name\""
        return 1
    fi
    for fn in provider_config provider_secrets provider_update provider_check; do
        if ! declare -F "$fn" >/dev/null; then
            err "$f does not define $fn"
            return 1
        fi
    done
}

# True if KEY belongs to another installed provider (left over after switching providers).
other_provider_key() {
    local n p
    while IFS= read -r n; do
        [[ "$n" == "$PROVIDER" ]] && continue
        p="${n^^}"
        p="${p//-/_}_"
        [[ "$1" == "$p"* ]] && return 0
    done < <(list_providers)
    return 1
}

# ---------------------------------------------------------------- config

CORE_KEYS=" IFACE PROVIDER HOSTNAME RECORDS IPV4_SOURCE IPV4_FALLBACK UPNP_URL IPV4_COMMAND IPV6_SUFFIX NOTIFY_URL NOTIFY_TYPE NOTIFY_AFTER HEARTBEAT_URL IPV4_INTERVAL "

# parse_config -> associative array CFG. Nothing is expanded or executed.
parse_config() {
    local line key val n=0
    declare -gA CFG=()
    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "missing $CONFIG_FILE"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            err "$CONFIG_FILE line $n: expected KEY=value"
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val#"${val%%[![:space:]]*}"}"
        if [[ "$val" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ || "$val" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
            val="${BASH_REMATCH[1]}"
        else
            # Unquoted: " #" starts a comment.
            [[ "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && val="${BASH_REMATCH[1]}"
            [[ "$val" == \#* ]] && val=""
            val="${val%"${val##*[![:space:]]}"}"
        fi
        if [[ "$val" == *[[:cntrl:]]* ]]; then
            err "$CONFIG_FILE line $n: control characters in $key"
            return 1
        fi
        CFG[$key]="$val"
    done < "$CONFIG_FILE"
}

detect_iface() {
    local d
    d=$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
    d="${d%%@*}"
    if [[ -z "$d" ]]; then
        d=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
        d="${d%%@*}"
    fi
    printf '%s\n' "$d"
}

# load_config [PROVIDER] reads and validates the config and loads the provider plugin
# (PROVIDER overrides the one in the config, for "check"). Returns 1 with a message on errors.
load_config() {
    local key
    parse_config || return 1
    PROVIDER="${1:-${CFG[PROVIDER]:-}}"
    PROVIDER="${PROVIDER,,}"
    DDNS_HOSTNAME="${CFG[HOSTNAME]:-}"
    DDNS_HOSTNAME="${DDNS_HOSTNAME%.}"
    DDNS_HOSTNAME="${DDNS_HOSTNAME,,}"
    IFACE="${CFG[IFACE]:-}"

    if [[ -z "$PROVIDER" ]]; then
        err "no PROVIDER in $CONFIG_FILE (available: $(list_providers | paste -sd ' '))"
        return 1
    fi
    if [[ ! "$DDNS_HOSTNAME" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        err "HOSTNAME=${CFG[HOSTNAME]:-} in $CONFIG_FILE is not a valid domain name like example.com"
        return 1
    fi
    if [[ -z "$IFACE" ]]; then
        IFACE=$(detect_iface)
    fi
    if [[ -z "$IFACE" ]]; then
        err "no IFACE in $CONFIG_FILE and no default route"
        return 1
    fi
    if [[ ! "$IFACE" =~ ^[A-Za-z0-9_.:@-]{1,15}$ ]]; then
        err "IFACE=$IFACE in $CONFIG_FILE is not a valid interface name"
        return 1
    fi

    RECORDS="${CFG[RECORDS]:-A+AAAA}"
    RECORDS="${RECORDS^^}"
    case "$RECORDS" in
        A+AAAA|AAAA+A) RECORDS="A+AAAA" ;;
        A|AAAA) ;;
        *) err "RECORDS=${CFG[RECORDS]} in $CONFIG_FILE must be A+AAAA, AAAA or A"; return 1 ;;
    esac
    IPV4_SOURCE="${CFG[IPV4_SOURCE]:-dns}"
    IPV4_SOURCE="${IPV4_SOURCE,,}"
    case "$IPV4_SOURCE" in
        interface|upnp|dns|command) ;;
        *) err "IPV4_SOURCE=$IPV4_SOURCE in $CONFIG_FILE must be interface, upnp, dns or command"; return 1 ;;
    esac
    IPV4_FALLBACK="${CFG[IPV4_FALLBACK]:-none}"
    IPV4_FALLBACK="${IPV4_FALLBACK,,}"
    case "$IPV4_FALLBACK" in
        none|dns) ;;
        *) err "IPV4_FALLBACK=$IPV4_FALLBACK in $CONFIG_FILE must be none or dns"; return 1 ;;
    esac
    UPNP_URL="${CFG[UPNP_URL]:-}"
    if [[ -n "$UPNP_URL" && ! "$UPNP_URL" =~ ^https?://[A-Za-z0-9.:_/~%-]+$ ]]; then
        err "UPNP_URL=$UPNP_URL in $CONFIG_FILE must be an http(s) URL (the router's WANIPConnection control URL)"
        return 1
    fi
    NOTIFY_URL="${CFG[NOTIFY_URL]:-}"
    HEARTBEAT_URL="${CFG[HEARTBEAT_URL]:-}"
    # "secret" = the URL is stored encrypted (secrets notify-url / heartbeat-url).
    for key in NOTIFY_URL HEARTBEAT_URL; do
        if [[ -n "${!key}" && "${!key}" != secret && ! "${!key}" =~ ^https?://[A-Za-z0-9.:_/~%?=\&+-]+$ ]]; then
            err "$key=${!key} in $CONFIG_FILE must be an http(s) URL or \"secret\""
            return 1
        fi
    done
    NOTIFY_TYPE="${CFG[NOTIFY_TYPE]:-auto}"
    NOTIFY_TYPE="${NOTIFY_TYPE,,}"
    case "$NOTIFY_TYPE" in
        auto|ntfy|gotify|discord|slack) ;;
        *) err "NOTIFY_TYPE=$NOTIFY_TYPE in $CONFIG_FILE must be auto, ntfy, gotify, discord or slack"; return 1 ;;
    esac
    NOTIFY_AFTER="${CFG[NOTIFY_AFTER]:-15}"
    number_setting NOTIFY_AFTER 0 99999 "minutes" || return 1
    IPV4_INTERVAL="${CFG[IPV4_INTERVAL]:-}"
    if [[ -n "$IPV4_INTERVAL" ]]; then
        number_setting IPV4_INTERVAL 10 86400 "seconds" || return 1
    fi
    IPV6_SUFFIX="${CFG[IPV6_SUFFIX]:-}"
    IPV6_SUFFIX_X=""
    if [[ -n "$IPV6_SUFFIX" ]]; then
        IPV6_SUFFIX_X=$(expand_ipv6 "$IPV6_SUFFIX")
        if [[ "$IPV6_SUFFIX" != ::* || -z "$IPV6_SUFFIX_X" || "${IPV6_SUFFIX_X:0:20}" != "0000:0000:0000:0000:" ]]; then
            err "IPV6_SUFFIX=$IPV6_SUFFIX in $CONFIG_FILE must be an interface ID like ::67c:16ff:fedf:a200"
            return 1
        fi
        IPV6_SUFFIX_X="${IPV6_SUFFIX_X:20}"
    fi
    IPV4_COMMAND="${CFG[IPV4_COMMAND]:-}"
    if [[ "$IPV4_SOURCE" == command ]]; then
        if [[ ! "$IPV4_COMMAND" =~ ^/[A-Za-z0-9._/-]+$ || ! -x "$IPV4_COMMAND" ]]; then
            err "IPV4_SOURCE=command needs IPV4_COMMAND=/absolute/path/to/an/executable (no arguments) in $CONFIG_FILE"
            return 1
        fi
    fi

    load_provider "$PROVIDER" || return 1
    for key in "${!CFG[@]}"; do
        [[ "$CORE_KEYS" == *" $key "* ]] && continue
        [[ " $PROVIDER_SETTINGS " == *" $key "* ]] && continue
        other_provider_key "$key" && continue
        err "$CONFIG_FILE: unknown setting $key (provider $PROVIDER knows: ${PROVIDER_SETTINGS:-none})"
        return 1
    done
    provider_config
}

# Loads the secrets the active provider needs (exits with a clear message if one is missing).
load_secrets() {
    provider_secrets
}

# ---------------------------------------------------------------- state

ensure_dirs() {
    local d
    for d in "$STATE_DIR" "$@"; do
        [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null || die "cannot create $d (run as root or via systemd)"
    done
}

load_state() {
    LAST_IPV4=""
    LAST_IPV6=""
    LAST_PROVIDER=""
    LAST_UPDATED=""
    LAST_CALLED=""
    LAST_APPLIED=""
    if [[ -f "$STATE" ]]; then
        LAST_IPV4=$(sed -n 's/^IPV4=//p' "$STATE" | tail -n 1)
        LAST_IPV6=$(sed -n 's/^IPV6=//p' "$STATE" | tail -n 1)
        LAST_PROVIDER=$(sed -n 's/^PROVIDER=//p' "$STATE" | tail -n 1)
        LAST_UPDATED=$(sed -n 's/^UPDATED=//p' "$STATE" | tail -n 1)
        LAST_CALLED=$(sed -n 's/^CALLED=//p' "$STATE" | tail -n 1)
        [[ "$LAST_CALLED" =~ ^[0-9]+$ ]] || LAST_CALLED=""
        LAST_APPLIED=$(sed -n 's/^APPLIED=//p' "$STATE" | tail -n 1)
    fi
}

# A short hash of the settings that decide WHAT is written to DNS: provider, hostname, records and
# the provider's own settings (zone, TTL, ...). A change forces an update even if the IPs did not
# change. (Secrets are not part of it; see config_fingerprint for that.)
dns_fingerprint() {
    local k
    {
        printf '%s\n' "$PROVIDER" "$DDNS_HOSTNAME" "$RECORDS"
        for k in $PROVIDER_SETTINGS; do printf '%s=%s\n' "$k" "$(cfg "$k")"; done
    } | sha256sum | cut -c1-16
}

# write_state IPV4 IPV6 [CALLED]: returns 1 (with a message) if the state could not be saved.
write_state() {
    local tmp
    if ! tmp=$(mktemp "$STATE_DIR/last.XXXXXX" 2>/dev/null); then
        err "cannot save the state in $STATE_DIR"
        return 1
    fi
    if ! printf 'IPV4=%s\nIPV6=%s\nPROVIDER=%s\nUPDATED=%s\nCALLED=%s\nAPPLIED=%s\n' \
            "$1" "$2" "$PROVIDER" "$(date -Iseconds)" "${3:-$(date +%s)}" "$(dns_fingerprint)" > "$tmp" \
        || ! chmod 600 "$tmp" || ! mv "$tmp" "$STATE"; then
        rm -f "$tmp"
        err "cannot save the state in $STATE"
        return 1
    fi
}

# ---------------------------------------------------------------- IP addresses

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
}

# True for addresses that must never be published: private, CGNAT (DS-Lite / carrier NAT),
# loopback, link-local, "this network", multicast and reserved.
is_nonpublic_ipv4() {
    local a b c
    IFS=. read -r a b c _ <<< "$1"
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 0      # this net, private, loopback, multicast/reserved
    (( a == 100 && b >= 64 && b <= 127 )) && return 0                # shared address space (CGNAT, DS-Lite)
    (( a == 169 && b == 254 )) && return 0                           # link-local
    (( a == 172 && b >= 16 && b <= 31 )) && return 0                 # private
    (( a == 192 && b == 168 )) && return 0                           # private
    (( a == 192 && b == 0 && (c == 0 || c == 2) )) && return 0       # IETF protocol assignments, TEST-NET-1
    (( a == 198 && (b == 18 || b == 19) )) && return 0               # benchmarking
    (( a == 198 && b == 51 && c == 100 )) && return 0                # TEST-NET-2
    (( a == 203 && b == 0 && c == 113 )) && return 0                 # TEST-NET-3
    return 1
}

# Public IPv4 directly on the interface (VPS, router in bridge mode, PPPoE on this machine).
ipv4_from_interface() {
    ip -4 addr show dev "$IFACE" scope global 2>/dev/null \
        | awk '/inet / { a = $2; sub(/\/.*/, "", a); print a }'
}

# Asks the router via standard UPnP IGD (WANIPConnection#GetExternalIPAddress), no login.
# URL: UPNP_URL, else the FRITZ!Box default on the default gateway; then "upnpc -s" if installed.
ipv4_from_upnp() {
    local url="$UPNP_URL" gw resp ip
    if [[ -z "$url" ]]; then
        gw=$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')
        [[ -n "$gw" ]] && url="http://$gw:49000/igdupnp/control/WANIPConn1"
    fi
    if [[ -n "$url" ]]; then
        resp=$(curl --silent --max-time 5 -X POST \
            -H 'Content-Type: text/xml; charset="utf-8"' \
            -H 'SOAPAction: "urn:schemas-upnp-org:service:WANIPConnection:1#GetExternalIPAddress"' \
            --data-binary '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetExternalIPAddress xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"/></s:Body></s:Envelope>' \
            "$url" 2>/dev/null) || resp=""
        ip=$(sed -n 's/.*<NewExternalIPAddress>\([0-9.]*\)<\/NewExternalIPAddress>.*/\1/p' <<< "$resp" | head -n 1)
        if [[ -n "$ip" ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    fi
    if command -v upnpc >/dev/null 2>&1; then
        upnpc -s 2>/dev/null | sed -n 's/^ExternalIPAddress = \([0-9.]*\).*/\1/p' | head -n 1
    fi
}

# Asks public DNS services what our address is, one after another (always over IPv4).
ipv4_from_dns() {
    local raw
    raw=$(dig -4 +short +time=3 +tries=1 TXT CH whoami.cloudflare @1.0.0.1 2>/dev/null | tr -d '"')
    is_ipv4 "$raw" || raw=$(dig -4 +short +time=3 +tries=1 A myip.opendns.com @208.67.222.222 2>/dev/null | head -n 1)
    is_ipv4 "$raw" || raw=$(dig -4 +short +time=3 +tries=1 TXT o-o.myaddr.l.google.com @216.239.32.10 2>/dev/null | tr -d '"' | head -n 1)
    printf '%s\n' "$raw"
}

ipv4_from_command() {
    timeout 20 "$IPV4_COMMAND" 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

# get_ipv4 -> the public IPv4 to publish, or nothing. Uses IPV4_SOURCE (+ IPV4_FALLBACK=dns).
# DDNS_TEST_IPV4 / DDNS_TEST_IPV6 replace the lookups (used by tests/run.sh; "none" = no address).
get_ipv4() {
    [[ "$RECORDS" == AAAA ]] && return 0
    if [[ -n "${DDNS_TEST_IPV4:-}" ]]; then
        [[ "$DDNS_TEST_IPV4" == "none" ]] || printf '%s\n' "$DDNS_TEST_IPV4"
        return 0
    fi
    local ip src="$IPV4_SOURCE" c found=""
    ip=$("ipv4_from_$src")
    if [[ "$src" == interface ]]; then
        # The interface may have several addresses: take the first public one.
        for c in $ip; do
            if is_ipv4 "$c" && ! is_nonpublic_ipv4 "$c"; then
                found="$c"
                break
            fi
        done
        if [[ -z "$found" && -n "$ip" && "$IPV4_FALLBACK" != dns ]]; then
            warn "no public IPv4 on $IFACE (only: $(tr '\n' ' ' <<< "$ip")); not publishing an A record"
        fi
        ip="$found"
    fi
    # Fallback only when the chosen source gave no usable address at all.
    if ! is_ipv4 "$ip" && [[ "$IPV4_FALLBACK" == dns && "$src" != dns ]]; then
        src=dns
        ip=$(ipv4_from_dns)
    fi
    is_ipv4 "$ip" || return 0
    if is_nonpublic_ipv4 "$ip"; then
        warn "IPv4 from $src is $ip, which is not public (DS-Lite/CGNAT?); not publishing it. Consider RECORDS=AAAA."
        return 0
    fi
    printf '%s\n' "$ip"
}

get_ipv6() {
    [[ "$RECORDS" == A ]] && return 0
    if [[ -n "${DDNS_TEST_IPV6:-}" ]]; then
        [[ "$DDNS_TEST_IPV6" == "none" ]] || printf '%s\n' "$DDNS_TEST_IPV6"
        return 0
    fi
    local cands c x
    # Stable, usable global unicast only: no temporary (privacy), deprecated, tentative (duplicate
    # address detection still running) or dadfailed addresses; no ULA (fc00::/7), link-local,
    # documentation prefix (2001:db8::/32) or anything outside 2000::/3.
    cands=$(ip -6 addr show dev "$IFACE" scope global 2>/dev/null | awk '
        /inet6 / {
            addr = tolower($2)
            sub(/\/.*/, "", addr)
            if ($0 ~ /deprecated|temporary|tentative|dadfailed/) next
            if (addr !~ /^[23]/) next
            if (addr ~ /^2001:0?db8:/) next
            print addr
        }
    ')
    [[ -n "$cands" ]] || return 0
    if [[ -n "$IPV6_SUFFIX" ]]; then
        for c in $cands; do
            x=$(expand_ipv6 "$c")
            if [[ "${x:20}" == "$IPV6_SUFFIX_X" ]]; then
                printf '%s\n' "$c"
                return 0
            fi
        done
        warn "no stable IPv6 on $IFACE ends in $IPV6_SUFFIX (have: $(paste -sd ' ' <<< "$cands"))"
        return 0
    fi
    # Several stable addresses: prefer the EUI-64 one (interface ID xxxx:xxff:fexx:xxxx, derived from
    # the MAC, so it survives prefix changes predictably), else the first one. Deterministic.
    for c in $cands; do
        x=$(expand_ipv6 "$c")
        if [[ "${x:27:2}" == ff && "${x:30:2}" == fe ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    head -n 1 <<< "$cands"
}

# expand_ipv6 ADDR -> 8 groups of 4 hex digits (e.g. 2001:0db8:0000:...); empty if invalid.
expand_ipv6() {
    local a="${1,,}" head tail g out=() i n
    [[ "$a" =~ ^[0-9a-f:]+$ ]] || return 0
    if [[ "$a" == *::* ]]; then
        head="${a%%::*}"
        tail="${a#*::}"
    else
        head="$a"
        tail=""
    fi
    local -a h=() t=()
    [[ -n "$head" ]] && IFS=: read -ra h <<< "$head"
    [[ -n "$tail" ]] && IFS=: read -ra t <<< "$tail"
    n=$((8 - ${#h[@]} - ${#t[@]}))
    if [[ "$a" == *::* ]]; then (( n >= 1 )) || return 0; else (( n == 0 )) || return 0; fi
    for g in "${h[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 0; out+=("$(printf '%04x' "0x$g")"); done
    for ((i = 0; i < n; i++)); do out+=("0000"); done
    for g in "${t[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 0; out+=("$(printf '%04x' "0x$g")"); done
    (IFS=:; printf '%s\n' "${out[*]}")
}


# ---------------------------------------------------------------- secret management (systemd-creds)
#
# Secrets are stored encrypted in $CRED_STORE/<name> (systemd-creds, key "auto": TPM2 + host key if a
# TPM exists, else the host key). A drop-in per unit passes them to the service with
# LoadCredentialEncrypted=, so the service only ever sees them decrypted in $CREDENTIALS_DIRECTORY.
# On other hardware (or after Secure Boot changes) they cannot be decrypted: enter them again.

# Core secrets the current config uses (for listings).
core_secrets_in_use() {
    [[ -n "${NOTIFY_URL:-}" ]] && echo notify-token
    [[ "${NOTIFY_URL:-}" == secret ]] && echo notify-url
    [[ "${HEARTBEAT_URL:-}" == secret ]] && echo heartbeat-url
    return 0
}

# all_secret_names -> "secret provider" per line, for every installed plugin.
all_secret_names() {
    local n s
    printf '%s core\n' notify-token notify-url heartbeat-url
    while IFS= read -r n; do
        (
            load_provider "$n" >/dev/null 2>&1 || exit 0
            for s in $PROVIDER_SECRETS; do
                printf '%s %s\n' "$s" "$n"
            done
        )
    done < <(list_providers)
}

check_systemd_version() {
    local v
    v=$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 }')
    v="${v%%[!0-9]*}"
    [[ -n "$v" ]] || die "systemd not found; ddns-watch needs systemd $MIN_SYSTEMD or newer"
    (( v >= MIN_SYSTEMD )) || die "systemd $v is too old; ddns-watch needs systemd $MIN_SYSTEMD or newer (e.g. Ubuntu 24.04, Debian 12)"
    command -v systemd-creds >/dev/null 2>&1 || die "systemd-creds not found"
}

# One drop-in per unit that loads the stored secrets the service may need: those of the active
# provider plus the notification/heartbeat ones. Keys of other providers (e.g. after switching)
# are not given to the service. Without a readable config yet, all stored secrets are listed.
write_cred_dropin() {
    local unit dir tmp f name wanted=""
    wanted=$(
        load_config >/dev/null 2>&1 || exit 0
        # shellcheck disable=SC2086
        printf ' %s ' $PROVIDER_SECRETS notify-token notify-url heartbeat-url
    )
    for unit in $UNITS_WITH_SECRETS; do
        dir="$UNIT_DIR/$unit.d"
        mkdir -p "$dir" || die "cannot create $dir"
        tmp=$(mktemp "$dir/.credentials.XXXXXX") || die "cannot write to $dir"
        {
            printf '# Written by ddns-watch (setup / set-secret). Do not edit; run them again instead.\n[Service]\n'
            for f in "$CRED_STORE"/*; do
                [[ -f "$f" ]] || continue
                name="$(basename "$f")"
                [[ "$name" =~ ^[a-z0-9-]+$ ]] || continue
                [[ -z "$wanted" || "$wanted" == *" $name "* ]] || continue
                printf 'LoadCredentialEncrypted=%s:%s\n' "$name" "$f"
            done
        } > "$tmp"
        chmod 644 "$tmp"
        mv "$tmp" "$dir/credentials.conf"
    done
}

set_secret() {
    local name="${1:-}" provider help value tmp key="the host key"
    is_root || die "set-secret must run as root: sudo ddns-watch set-secret ${name:-NAME}"
    [[ "$name" =~ ^[a-z0-9-]+$ ]] || die "usage: ddns-watch set-secret NAME   (names: ddns-watch secrets)"
    provider=$(all_secret_names | awk -v n="$name" '$1 == n { print $2; exit }')
    if [[ -z "$provider" ]]; then
        die "unknown secret $name. Known: $(all_secret_names | awk '{ print $1 }' | paste -sd ' ')"
    fi
    check_systemd_version
    if [[ "$provider" == core ]]; then
        case "$name" in
            notify-token) help="Optional access token for the notification service (ntfy access token, Gotify app token)." ;;
            notify-url) help="The notification URL, kept secret (Discord/Slack webhook, ntfy topic). Set NOTIFY_URL=secret in the config." ;;
            heartbeat-url) help="The heartbeat URL, kept secret. Set HEARTBEAT_URL=secret in the config." ;;
        esac
    else
        help=$(load_provider "$provider" >/dev/null 2>&1 && printf '%s' "${PROVIDER_HELP[$name]:-}")
    fi

    if [[ -t 0 ]]; then
        [[ -n "$help" ]] && say "$name ($provider): $help"
        IFS= read -r -s -p "Enter $name (input hidden, Enter = cancel): " value
        printf '\n' >&2
    else
        IFS= read -r value || true
    fi
    value="${value%$'\r'}"
    [[ -n "$value" ]] || die "no value entered; nothing changed"
    store_secret "$name" "$value" || die "systemd-creds encrypt failed; nothing changed"
    value=""

    write_cred_dropin
    systemctl daemon-reload 2>/dev/null || warn "systemctl daemon-reload failed"
    systemctl try-restart ddns-watch.service 2>/dev/null || true

    systemd-creds has-tpm2 >/dev/null 2>&1 && key="this machine's TPM and host key"
    say "Stored $name encrypted in $CRED_STORE/$name (bound to $key)."
    say "Keep a copy in your password manager: after a hardware change you have to enter it again."
}

# store_secret NAME VALUE: encrypts VALUE into $CRED_STORE/NAME (atomically). Returns 1 on failure.
store_secret() {
    local tmp
    mkdir -p "$CRED_STORE" || return 1
    chmod 700 "$CRED_STORE"
    tmp="$CRED_STORE/.$1.tmp"
    if ! printf '%s' "$2" | systemd-creds encrypt --with-key=auto --name="$1" - "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$CRED_STORE/$1"
}

secret_stored_ok() {
    [[ -f "$CRED_STORE/$1" ]] && systemd-creds decrypt --name="$1" "$CRED_STORE/$1" - >/dev/null 2>&1
}

show_secrets() {
    local s state
    is_root || die "secrets must run as root: sudo ddns-watch secrets"
    load_config || exit 1
    say "Provider $PROVIDER uses: ${PROVIDER_SECRETS:-no secrets}   (store: $CRED_STORE)"
    for s in $PROVIDER_SECRETS $(core_secrets_in_use); do
        if [[ ! -f "$CRED_STORE/$s" ]]; then
            state="not stored"
        elif systemd-creds decrypt --name="$s" "$CRED_STORE/$s" - >/dev/null 2>&1; then
            state="ok (encrypted)"
        else
            state="CANNOT DECRYPT (new hardware or Secure Boot change?) -> ddns-watch set-secret $s"
        fi
        printf '  %-26s %s\n' "$s" "$state"
    done
}

# ---------------------------------------------------------------- update

# Everything that may exit (bad config, missing secrets) runs inside this subshell,
# under a lock so the watcher and the timer never update at the same time.
update_once() {
    ensure_dirs
    (
        flock 9
        load_config || exit 1
        _update_once_locked
    ) 9>"$LOCKFILE"
}

_update_once_locked() {
    load_secrets
    load_state

    local ipv4 ipv6
    ipv4=$(get_ipv4 || true)
    ipv6=$(get_ipv6 || true)

    if [[ -z "$ipv4" && -z "$ipv6" ]]; then
        err "no usable IPv4 and no usable IPv6; skipping update (network down?)"
        # Count it like a temporary error, so a long outage is notified (if a message can still
        # get out). No retry delay: as soon as an address is back, the next run updates.
        # A pending permanent error is kept as it is.
        load_failure
        if [[ "$FAIL_CLASS" != permanent ]]; then
            record_failure temporary "no usable IPv4 or IPv6 address (network down?)" \
                "$(date +%s)" "$(config_fingerprint)" nowait
        fi
        return 1
    fi
    [[ -n "$ipv4" || "$RECORDS" == AAAA ]] || warn "no public IPv4 (source: $IPV4_SOURCE); continuing with IPv6 only"
    [[ -n "$ipv6" || "$RECORDS" == A ]] || warn "no stable global IPv6 on $IFACE; continuing with IPv4 only"

    local now why="" fprint verify_every
    now=$(date +%s)
    fprint=$(config_fingerprint)
    load_failure
    [[ "$USER_FORCE" -eq 1 ]] && why="forced"

    # A permanent error (wrong key, unknown host ...): no retries until config/secrets change.
    if [[ "$FAIL_CLASS" == permanent && "$USER_FORCE" -ne 1 ]]; then
        if [[ "$fprint" == "$FAIL_FPRINT" ]]; then
            err "not retrying: $PROVIDER rejected the last update ($FAIL_MSG). Fix the config or the secret, or run: ddns-watch run --force"
            return 1
        fi
        FORCE=1
        why="config or secrets changed after an error"
    fi
    # A temporary error: retry when due, otherwise wait (unless the user forces it).
    if [[ "$FAIL_CLASS" == temporary && "$USER_FORCE" -ne 1 ]]; then
        if (( now < FAIL_NEXT )); then
            say "waiting to retry at $(date -d "@$FAIL_NEXT" '+%T') (failed $FAIL_COUNT times: $FAIL_MSG)"
            return 1
        fi
        FORCE=1
        why="retry $((FAIL_COUNT + 1))"
    fi

    if [[ -n "$LAST_PROVIDER" && "$LAST_PROVIDER" != "$PROVIDER" ]]; then
        FORCE=1
        why="provider changed $LAST_PROVIDER -> $PROVIDER"
    elif [[ -f "$STATE" && "$LAST_APPLIED" != "$(dns_fingerprint)" ]]; then
        FORCE=1
        why="DNS settings changed (hostname, records or provider settings)"
    fi

    # Once a day (or the provider's maximum interval, if shorter) send the current addresses even if
    # nothing changed: catches records changed by hand or lost updates, and keeps hosts at providers
    # that expire inactive names alive.
    verify_every="$VERIFY_INTERVAL"
    if [[ -n "$PROVIDER_MAX_INTERVAL" ]] && (( PROVIDER_MAX_INTERVAL < verify_every )); then
        verify_every="$PROVIDER_MAX_INTERVAL"
    fi
    if [[ "$FORCE" -ne 1 && -n "$LAST_CALLED" ]] && (( now - LAST_CALLED >= verify_every )); then
        FORCE=1
        why="periodic verification"
    fi

    if [[ "$FORCE" -ne 1 ]]; then
        if [[ "$ipv4" == "$LAST_IPV4" && "$ipv6" == "$LAST_IPV6" ]]; then
            say "unchanged IPv4=${ipv4:-none} IPv6=${ipv6:-none}"
            heartbeat
            return 0
        fi
        if [[ -n "$ipv4" && -z "$ipv6" && "$ipv4" == "$LAST_IPV4" ]]; then
            say "unchanged IPv4=$ipv4 (no IPv6 this run)"
            heartbeat
            return 0
        fi
        if [[ -z "$ipv4" && -n "$ipv6" && "$ipv6" == "$LAST_IPV6" ]]; then
            say "unchanged IPv6=$ipv6 (no IPv4 this run)"
            heartbeat
            return 0
        fi
    fi

    # Provider rate limit (plugin metadata), unless the user forces it.
    if [[ -n "$PROVIDER_MIN_INTERVAL" && -n "$LAST_CALLED" && "$USER_FORCE" -ne 1 ]] \
        && (( now - LAST_CALLED < PROVIDER_MIN_INTERVAL )); then
        say "$PROVIDER allows one update per ${PROVIDER_MIN_INTERVAL}s; next run will send it"
        return 0
    fi

    say "updating $PROVIDER for $DDNS_HOSTNAME: IPv4=${ipv4:-none} IPv6=${ipv6:-none}${why:+ ($why)}"
    PROVIDER_RESPONSE=""
    PROVIDER_ERROR_CLASS="temporary"
    if provider_update "$ipv4" "$ipv6"; then
        say "$PROVIDER: $PROVIDER_RESPONSE"
        clear_failure
        if ! write_state "$ipv4" "$ipv6" "$now"; then
            # The DNS record is right, but without the state the next run calls the provider
            # again. Not a full success: no heartbeat, non-zero exit (visible in systemctl).
            err "DNS was updated, but the local state could not be saved (disk full? permissions?)"
            return 1
        fi
        heartbeat
        return 0
    fi
    [[ "$PROVIDER_ERROR_CLASS" == permanent ]] || PROVIDER_ERROR_CLASS="temporary"
    err "$PROVIDER update failed ($PROVIDER_ERROR_CLASS): $PROVIDER_RESPONSE"
    record_failure "$PROVIDER_ERROR_CLASS" "$PROVIDER_RESPONSE" "$now" "$fprint"
    return 1
}

# ---------------------------------------------------------------- failures, notifications, heartbeat

FAILURE="$STATE_DIR/failure"
HEARTBEAT_STAMP="$STATE_DIR/heartbeat"
VERIFY_INTERVAL=86400

load_failure() {
    FAIL_CLASS="" FAIL_SINCE="" FAIL_COUNT=0 FAIL_NEXT=0 FAIL_MSG="" FAIL_FPRINT="" FAIL_NOTIFIED=0
    [[ -f "$FAILURE" ]] || return 0
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            CLASS) FAIL_CLASS="$v" ;;
            SINCE) FAIL_SINCE="$v" ;;
            COUNT) FAIL_COUNT="$v" ;;
            NEXT) FAIL_NEXT="$v" ;;
            MSG) FAIL_MSG="$v" ;;
            FPRINT) FAIL_FPRINT="$v" ;;
            NOTIFIED) FAIL_NOTIFIED="$v" ;;
        esac
    done < "$FAILURE"
    [[ "$FAIL_COUNT" =~ ^[0-9]+$ ]] || FAIL_COUNT=0
    [[ "$FAIL_NEXT" =~ ^[0-9]+$ ]] || FAIL_NEXT=0
    [[ "$FAIL_SINCE" =~ ^[0-9]+$ ]] || FAIL_SINCE=0
}

save_failure() {
    local tmp
    tmp=$(mktemp "$STATE_DIR/failure.XXXXXX") || return 0
    printf 'CLASS=%s\nSINCE=%s\nCOUNT=%s\nNEXT=%s\nMSG=%s\nFPRINT=%s\nNOTIFIED=%s\n' \
        "$FAIL_CLASS" "$FAIL_SINCE" "$FAIL_COUNT" "$FAIL_NEXT" "${FAIL_MSG//$'\n'/ }" "$FAIL_FPRINT" "$FAIL_NOTIFIED" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$FAILURE"
}

# A short hash of the config and the active provider's secrets: a permanent error is only retried
# after one of them changed. (Only the hash is stored, never the secrets.)
config_fingerprint() {
    local s
    {
        cat "$CONFIG_FILE"
        for s in $PROVIDER_SECRETS; do
            read_secret "$s"
            printf '\n'
        done
    } | sha256sum | cut -c1-16
}

# record_failure CLASS MESSAGE NOW FINGERPRINT [nowait]: remembers the error, sets the earliest time
# for the next try (1, 2, 5, then every 10 min; "nowait": at once) and notifies (permanent: at once;
# temporary: after NOTIFY_AFTER). The try itself happens at the next run (timer or address event).
record_failure() {
    local delays=(60 120 300 600)
    load_failure
    [[ "$FAIL_SINCE" -gt 0 ]] || FAIL_SINCE="$3"
    FAIL_CLASS="$1"
    FAIL_MSG="$2"
    FAIL_FPRINT="$4"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    local i=$((FAIL_COUNT - 1))
    (( i < ${#delays[@]} )) || i=$((${#delays[@]} - 1))
    FAIL_NEXT=$(($3 + delays[i]))
    [[ "${5:-}" == nowait ]] && FAIL_NEXT="$3"
    if [[ "$FAIL_NOTIFIED" -ne 1 ]]; then
        if [[ "$FAIL_CLASS" == permanent ]]; then
            notify "DNS update rejected" high "warning" \
                "ddns-watch on $(hostname): $PROVIDER rejected the update for $DDNS_HOSTNAME: $FAIL_MSG. No more retries until the config or the secrets change. Check: ddns-watch status" \
                && FAIL_NOTIFIED=1
        elif (( $3 - FAIL_SINCE >= NOTIFY_AFTER * 60 )); then
            notify "DNS update failing" default "warning" \
                "ddns-watch on $(hostname): updating $DDNS_HOSTNAME at $PROVIDER fails since $(date -d "@$FAIL_SINCE" '+%F %R') ($FAIL_COUNT attempts): $FAIL_MSG" \
                && FAIL_NOTIFIED=1
        fi
    fi
    save_failure
}

clear_failure() {
    [[ -f "$FAILURE" ]] || return 0
    load_failure
    if [[ "$FAIL_NOTIFIED" -eq 1 ]]; then
        notify "DNS update works again" default "white_check_mark" \
            "ddns-watch on $(hostname): $DDNS_HOSTNAME is up to date again at $PROVIDER (after $FAIL_COUNT failed attempts)." || true
    fi
    rm -f "$FAILURE"
}

# notify_type -> ntfy | gotify. NOTIFY_TYPE=auto (default) detects Gotify by its /message endpoint.
URL_RE='^https?://[A-Za-z0-9.:_/~%?=&+-]+$'

# effective_url KEY SECRET: the URL from the config, or - when the config says "secret" - from the
# encrypted secret (for webhook URLs that work like a password: Discord, Slack, ntfy topics,
# Healthchecks UUIDs). Prints nothing if unset or invalid.
effective_url() {
    local v="${!1:-}"
    [[ "$v" == secret ]] && v=$(read_secret "$2")
    [[ "$v" =~ $URL_RE ]] && printf '%s' "$v"
}

# notify_type -> ntfy | gotify | discord | slack. NOTIFY_TYPE=auto (default) detects it by the URL.
notify_type() {
    case "${NOTIFY_TYPE:-auto}" in
        ntfy|gotify|discord|slack) printf '%s\n' "$NOTIFY_TYPE"; return ;;
    esac
    local u
    u=$(effective_url NOTIFY_URL notify-url)
    if [[ "$u" =~ ://([a-z]+\.)?discord(app)?\.com/api/webhooks/ ]]; then echo discord
    elif [[ "$u" =~ ://hooks\.slack\.com/ ]]; then echo slack
    elif [[ "$u" =~ /message(\?|$) ]]; then echo gotify
    else echo ntfy; fi
}

json_escape() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "${s//$'\r'/}"
}

# notify TITLE PRIORITY(default|high) TAGS MESSAGE: sends the message to NOTIFY_URL.
#   ntfy (and any webhook that takes a text body): text POST, ntfy headers Title/Priority/Tags,
#        optional secret notify-token as "Authorization: Bearer".
#   gotify:  JSON {title, message, priority} to .../message, secret notify-token as X-Gotify-Key.
#   discord: JSON {username, content} to a Discord webhook URL.
#   slack:   JSON {text} to a Slack (or Mattermost) incoming webhook URL.
# URL and token go to curl on stdin (curl config), never on the command line.
notify() {
    [[ -n "$NOTIFY_URL" ]] || return 1
    local url token type cfg body ctype prefix="" ok=1
    url=$(effective_url NOTIFY_URL notify-url)
    if [[ -z "$url" ]]; then
        warn "NOTIFY_URL is not a valid URL$([[ "$NOTIFY_URL" == secret ]] && printf ' (secret notify-url missing or invalid)')"
        return 1
    fi
    type=$(notify_type)
    token=$(read_secret notify-token)
    [[ "$2" == high ]] && prefix=":warning: "
    cfg="url = \"$(curl_cfg_escape "$url")\""
    ctype="application/json"
    case "$type" in
        gotify)
            [[ -n "$token" ]] && cfg+=$'\n'"header = \"X-Gotify-Key: $(curl_cfg_escape "$token")\""
            body="{\"title\":\"$(json_escape "$1")\",\"message\":\"$(json_escape "$4")\",\"priority\":$([[ "$2" == high ]] && echo 8 || echo 5)}"
            ;;
        discord)
            body="{\"username\":\"ddns-watch\",\"content\":\"$(json_escape "$prefix**$1**"$'\n'"$4")\"}"
            ;;
        slack)
            body="{\"text\":\"$(json_escape "$prefix*$1*"$'\n'"$4")\"}"
            ;;
        *)
            [[ -n "$token" ]] && cfg+=$'\n'"header = \"Authorization: Bearer $(curl_cfg_escape "$token")\""
            cfg+=$'\n'"header = \"Title: $(curl_cfg_escape "$1")\""$'\n'"header = \"Priority: $2\""$'\n'"header = \"Tags: $3\""
            body="$4"
            ctype="text/plain; charset=utf-8"
            ;;
    esac
    if printf '%s\n' "$cfg" | curl --silent --show-error --fail --max-time 15 -K - \
        -H "Content-Type: $ctype" --data-binary "$body" >/dev/null 2>&1; then
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        say "notification sent ($type): $1"
        return 0
    fi
    warn "could not send the notification ($type)"
    return 1
}

heartbeat_ping() {
    local url
    url=$(effective_url HEARTBEAT_URL heartbeat-url)
    [[ -n "$url" ]] || return 1
    printf 'url = "%s"\n' "$(curl_cfg_escape "$url")" | curl --silent --fail --max-time 10 -K - -o /dev/null 2>/dev/null
}

# Pings HEARTBEAT_URL after a good run (at most once a minute). If the pings stop, the external
# monitor (Healthchecks, Uptime Kuma ...) raises the alarm: this machine or the service is down.
heartbeat() {
    [[ -n "$HEARTBEAT_URL" ]] || return 0
    local now last=0
    now=$(date +%s)
    [[ -f "$HEARTBEAT_STAMP" ]] && last=$(< "$HEARTBEAT_STAMP")
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last >= 60 )) || return 0
    if heartbeat_ping; then
        printf '%s\n' "$now" > "$HEARTBEAT_STAMP"
    else
        warn "heartbeat to HEARTBEAT_URL failed"
    fi
}

# test-notify: sends a test notification and a heartbeat ping now and reports the result.
test_notify() {
    local rc=0
    is_root || die "test-notify must run as root (it reads the encrypted token): sudo ddns-watch test-notify"
    load_config || exit 1
    if [[ -z "$NOTIFY_URL" && -z "$HEARTBEAT_URL" ]]; then
        die "neither NOTIFY_URL nor HEARTBEAT_URL is set (sudo ddns-watch setup, or see docs/notifications.md)"
    fi
    if [[ -n "$NOTIFY_URL" ]]; then
        notify "ddns-watch test" default "white_check_mark" \
            "Test message from ddns-watch on $(hostname) for $DDNS_HOSTNAME. If you can read this, notifications work." \
            || rc=1
    else
        say "notification: not configured (NOTIFY_URL)"
    fi
    if [[ -n "$HEARTBEAT_URL" ]]; then
        if heartbeat_ping; then say "heartbeat ping: OK"; else err "heartbeat ping to HEARTBEAT_URL failed"; rc=1; fi
    else
        say "heartbeat: not configured (HEARTBEAT_URL)"
    fi
    return "$rc"
}

check_provider() {
    local configured ipv4 ipv6
    if [[ -n "${1:-}" ]] && ! valid_provider_name "${1,,}"; then
        usage >&2
        exit 1
    fi
    parse_config || exit 1
    configured="${CFG[PROVIDER]:-none}"
    load_config "${1:-}" || exit 1
    load_secrets
    ipv4=$(get_ipv4 || true)
    ipv6=$(get_ipv6 || true)
    say "Configured provider: $configured   checking: $PROVIDER ($PROVIDER_TIER$([[ "$PROVIDER_LOCAL" -eq 1 ]] && printf ', LOCAL plugin from %s' "$LOCAL_PROVIDERS_DIR"))"
    say "This machine: IPv4=${ipv4:-none} IPv6=${ipv6:-none} (iface $IFACE)"
    say
    provider_check "$ipv4" "$ipv6"
}

show_providers() {
    local n
    while IFS= read -r n; do
        (
            load_provider "$n" 2>/dev/null || { printf '%-12s (broken plugin)\n' "$n"; exit 0; }
            printf '%-12s %-9s %s  (maintainer: %s)\n' "$n" "$PROVIDER_TIER" "$PROVIDER_DESCRIPTION" "$PROVIDER_MAINTAINER"
        )
    done < <(list_providers)
}

# ---------------------------------------------------------------- guided setup

# Look: colors only on a terminal (and not with NO_COLOR), Unicode symbols only with a UTF-8 locale.
setup_style() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        S_B=$'\e[1m' S_D=$'\e[2m' S_R=$'\e[0m' S_C=$'\e[36m' S_G=$'\e[32m' S_Y=$'\e[33m' S_RED=$'\e[31m'
    else
        S_B="" S_D="" S_R="" S_C="" S_G="" S_Y="" S_RED=""
    fi
    if [[ "$(locale charmap 2>/dev/null)" == UTF-8 ]]; then
        S_OK="✔" S_BAD="✘" S_STAR="★" S_ARROW="›" S_BULLET="•" S_DONE="━━━━" S_TODO="────"
        S_TL="╭" S_TR="╮" S_BL="╰" S_BR="╯" S_H="─" S_V="│"
    else
        S_OK="+" S_BAD="x" S_STAR="*" S_ARROW=">" S_BULLET="-" S_DONE="====" S_TODO="----"
        S_TL="+" S_TR="+" S_BL="+" S_BR="+" S_H="-" S_V="|"
    fi
}

s_ok()   { printf '  %s%s%s %s\n' "$S_G" "$S_OK" "$S_R" "$*"; }
s_bad()  { printf '  %s%s%s %s\n' "$S_RED" "$S_BAD" "$S_R" "$*"; }
s_warn() { printf '  %s!%s %s\n' "$S_Y" "$S_R" "$*"; }
s_info() { # dim, wrapped at 78 columns
    local line
    while IFS= read -r line; do
        printf '  %s%s%s\n' "$S_D" "$line" "$S_R"
    done < <(printf '%s\n' "$*" | fold -s -w 76)
}

# s_box COLOR LINE...: a frame of fixed width around plain-text lines (longer ones are cut).
s_box() {
    local color="$1" w=64 line rule="" j
    shift
    for ((j = 0; j < w; j++)); do rule+="$S_H"; done
    printf '  %s%s%s%s%s\n' "$color" "$S_TL" "$rule" "$S_TR" "$S_R"
    for line in "$@"; do
        (( ${#line} > w - 4 )) && line="${line:0:$((w - 7))}..."
        printf '  %s%s%s  %-*s  %s%s%s\n' "$color" "$S_V" "$S_R" "$((w - 4))" "$line" "$color" "$S_V" "$S_R"
    done
    printf '  %s%s%s%s%s\n' "$color" "$S_BL" "$rule" "$S_BR" "$S_R"
}

# step N TITLE: progress bar (done green, current cyan, rest dim) and title, one below the other.
step() {
    local i bar=""
    for i in 1 2 3 4 5 6; do
        if (( i < $1 )); then bar+="${S_G}${S_DONE}${S_R} "
        elif (( i == $1 )); then bar+="${S_C}${S_DONE}${S_R} "
        else bar+="${S_D}${S_TODO}${S_R} "; fi
    done
    printf '\n %s\n %sStep %s of 6%s  %s%s%s\n\n' "$bar" "$S_D" "$1" "$S_R" "$S_B" "$2" "$S_R"
}

# Prompts read from the terminal (also when the installer runs as "curl ... | sudo bash").
# DDNS_SETUP_INPUT replaces the terminal in tests.
setup_open_input() {
    local src="${DDNS_SETUP_INPUT:-/dev/tty}"
    # (The redirect of stderr must not be on exec itself: that would silence stderr for good.)
    { exec 7<"$src"; } 2>/dev/null || die "setup is interactive and needs a terminal. For automation: write $CONFIG_FILE yourself and store secrets with: ddns-watch set-secret NAME < file"
}

# ask PROMPT DEFAULT -> REPLY_VALUE (Enter keeps DEFAULT)
ask() {
    local v
    printf '  %s%s%s %s' "$S_C" "$S_ARROW" "$S_R" "$1" >&2
    [[ -n "$2" ]] && printf ' %s[%s]%s' "$S_D" "$2" "$S_R" >&2
    printf ' ' >&2
    IFS= read -r -u 7 v || v=""
    v="${v%$'\r'}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    REPLY_VALUE="${v:-$2}"
    [[ -n "${DDNS_SETUP_INPUT:-}" ]] && printf '%s\n' "$REPLY_VALUE" >&2
    return 0
}

# ask_secret PROMPT -> REPLY_VALUE (hidden input; empty = keep / skip)
ask_secret() {
    local v
    printf '  %s%s%s %s ' "$S_C" "$S_ARROW" "$S_R" "$1" >&2
    if [[ -z "${DDNS_SETUP_INPUT:-}" ]]; then
        IFS= read -r -s -u 7 v || v=""
        [[ -n "$v" ]] && printf '%s' "${S_D}(entered)${S_R}" >&2
        printf '\n' >&2
    else
        IFS= read -r -u 7 v || v=""
        printf '(hidden)\n' >&2
    fi
    REPLY_VALUE="${v%$'\r'}"
}

# ask_yes PROMPT DEFAULT(y|n) -> returns 0 for yes
ask_yes() {
    local d="$2" hint="y/N"
    [[ "$d" == y ]] && hint="Y/n"
    while true; do
        ask "$1" "$hint"
        [[ "$REPLY_VALUE" == "$hint" ]] && REPLY_VALUE=""
        case "${REPLY_VALUE,,}" in
            "") [[ "$d" == y ]]; return ;;
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
        s_info "Please answer y or n."
    done
}

# Network interfaces worth offering: no loopback and no virtual ones (Docker, bridges, libvirt).
# Prints "name<TAB>state".
list_ifaces() {
    ip -br link 2>/dev/null | awk '
        { n = $1; sub(/@.*/, "", n) }
        n == "lo" || n ~ /^(docker|br-|veth|virbr|vnet|cni|flannel|cali|tap)/ { next }
        { print n "\t" $2 }'
}

# Step 4: one numbered line per interface with the IPv6 that would really be published (same
# choice as get_ipv6). Sets IFACE_LIST (names) and IFACE_RECOMMENDED.
show_iface_table() {
    local default_if name state v6 i=0 first_v6="" st note
    default_if=$(detect_iface)
    IFACE_LIST=() IFACE_V6=()
    IFACE_RECOMMENDED=""
    while IFS=$'\t' read -r name state; do
        [[ -n "$name" ]] || continue
        IFACE_LIST+=("$name")
        v6=$(IFACE="$name" get_ipv6 2>/dev/null)
        IFACE_V6+=("$v6")
        [[ -n "$v6" && "$name" == "$default_if" ]] && IFACE_RECOMMENDED="$name"
        [[ -n "$v6" && -z "$first_v6" ]] && first_v6="$name"
    done < <(list_ifaces)
    [[ -n "$IFACE_RECOMMENDED" ]] || IFACE_RECOMMENDED="${first_v6:-$default_if}"

    printf '    %s#  %-12s %-6s %-40s %s%s\n' "$S_D" "Name" "State" "IPv6 that will be published" "Note" "$S_R"
    for name in "${IFACE_LIST[@]}"; do
        i=$((i + 1))
        v6="${IFACE_V6[i - 1]}"
        state=$(list_ifaces | awk -v n="$name" '$1 == n { print $2 }')
        st="$S_D"; [[ "$state" == UP ]] && st="$S_G"
        note=""
        [[ "$name" == "$default_if" ]] && note="default route"
        [[ "$name" == "$IFACE_RECOMMENDED" ]] && note="${S_Y}${S_STAR} recommended${S_R}${note:+  ${S_D}$note${S_R}}"
        printf '    %s%-2s%s %-12s %s%-6s%s ' "$S_C" "$i" "$S_R" "$name" "$st" "$state" "$S_R"
        if [[ -n "$v6" ]]; then printf '%-40s ' "$v6"; else printf '%s%-40s%s ' "$S_D" "none (no stable public IPv6)" "$S_R"; fi
        printf '%s\n' "$note"
    done
    if [[ -z "$first_v6" ]]; then
        echo
        s_warn "No interface has a stable public IPv6, so only the A record (IPv4) can be kept"
        s_warn "up to date, unless one appears later."
    fi
}

# Secrets entered in the setup are kept in a private, memory-backed folder until "Apply" (the login
# test and the notification test read them from there), so cancelling changes nothing.
pending_open() {
    local base="${DDNS_PENDING_BASE:-/run}"
    PENDING_SECRETS=$( (umask 077; mktemp -d "$base/ddns-watch-setup.XXXXXX") 2>/dev/null \
        || (umask 077; mktemp -d) ) || die "cannot create a private temporary folder"
    chmod 700 "$PENDING_SECRETS"
}

pending_secret() { # pending_secret NAME VALUE
    (umask 077; printf '%s' "$2" > "$PENDING_SECRETS/$1") || die "cannot write to $PENDING_SECRETS"
}

pending_close() {
    [[ -n "${PENDING_SECRETS:-}" && -d "$PENDING_SECRETS" ]] && rm -rf -- "${PENDING_SECRETS:?}"
    PENDING_SECRETS=""
}

# Encrypts all pending secrets into the store (on "Apply").
pending_commit() {
    local f
    for f in "$PENDING_SECRETS"/*; do
        [[ -f "$f" ]] || continue
        store_secret "$(basename "$f")" "$(< "$f")" || die "systemd-creds encrypt failed for $(basename "$f")"
    done
}

# setup_url_secret KEY SECRET PROMPT: asks for a URL and stores it encrypted (config: KEY=secret).
# Enter keeps a stored one, "none" removes it. Sets KEY to "secret" or "".
setup_url_secret() {
    local key="$1" secret="$2" prompt="$3" old="${OLD[$1]:-}" def="none"
    [[ "$old" == secret ]] && def="keep stored"
    [[ -n "$old" && "$old" != secret ]] && def="$old"
    while true; do
        ask "$prompt" "$def"
        case "$REPLY_VALUE" in
            none|"") printf -v "$key" '%s' ""; set_new "$key" ""; return ;;
            "keep stored") printf -v "$key" '%s' secret; set_new "$key" secret; return ;;
        esac
        [[ "$REPLY_VALUE" =~ $URL_RE ]] && break
        s_info "That is not an http(s) URL. Enter = $def"
    done
    pending_secret "$secret" "$REPLY_VALUE"
    REPLY_VALUE=""
    printf -v "$key" '%s' secret
    set_new "$key" secret
}

# Writes the config atomically. Keys not asked in this run but present before are kept.
setup_write_config() {
    local tmp
    mkdir -p "$CONFIG_DIR" || die "cannot create $CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"
    tmp=$(mktemp "$CONFIG_DIR/.config.XXXXXX") || die "cannot write $CONFIG_DIR"
    {
        printf '# ddns-watch configuration, written by "ddns-watch setup" on %s.\n' "$(date '+%F %R')"
        printf '# Edit freely (KEY=value); changes apply on the next run. To switch the provider\n'
        printf '# use "sudo ddns-watch setup" (it hands the new provider'"'"'s secret to the service).\n'
        setup_render_config
    } > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

# The config as it will be saved: the answers of this run, then every earlier setting that was not
# asked again (e.g. NETCUP_ZONE). The login test uses exactly this, so test and result match.
setup_render_config() {
    local key
    for key in "${NEW_KEYS[@]}"; do
        [[ -n "${NEW[$key]:-}" ]] && printf '%s=%s\n' "$key" "${NEW[$key]}"
    done
    for key in $(printf '%s\n' "${!OLD[@]}" | sort); do
        [[ -v "NEW[$key]" ]] && continue
        printf '%s=%s\n' "$key" "${OLD[$key]}"
    done
}

# setup_login_test: read-only check with the answers so far. Output of the check goes to
# $SETUP_CHECK_LOG, the zone's records (if the plugin can list them) to $SETUP_RECORDS.
setup_login_test() {
    local tmpconf key rc=0
    tmpconf=$(mktemp)
    # The interface is chosen only later (step 4); the login test does not need it.
    { setup_render_config; [[ -v "NEW[IFACE]" || -n "${OLD[IFACE]:-}" ]] || printf 'IFACE=lo\n'; } > "$tmpconf"
    (
        CONFIG_FILE="$tmpconf"
        load_config && load_secrets && provider_check "" "" || exit 1
        if declare -F provider_records >/dev/null; then provider_records > "$SETUP_RECORDS"; fi
    ) > "$SETUP_CHECK_LOG" 2>&1 || rc=1
    rm -f "$tmpconf"
    return "$rc"
}

# Shows the A/AAAA records of the hostname, CNAMEs pointing to it in one line, the rest counted.
setup_show_records() {
    local host="$DDNS_HOSTNAME" rel zone cnames others
    zone=$(awk -F. '{ print $(NF - 1) "." $NF }' <<< "$host")
    rel="${host%."$zone"}"
    [[ "$host" == "$zone" ]] && rel="@"
    printf '  %sCurrent records for %s%s\n' "$S_D" "$host" "$S_R"
    awk -F'\t' -v r="$rel" '($1 == r || ($1 == "" && r == "@")) && ($2 == "A" || $2 == "AAAA") { printf "    %-10s %-6s %s\n", r, $2, $3 }' "$SETUP_RECORDS"
    cnames=$(awk -F'\t' '$2 == "CNAME" { print $1 }' "$SETUP_RECORDS" | paste -sd ',' | sed 's/,/, /g')
    [[ -n "$cnames" ]] && printf '    %s%-10s %-6s %s%s\n' "$S_D" "+$(awk -F'\t' '$2 == "CNAME"' "$SETUP_RECORDS" | wc -l)" "CNAME" "$cnames" "$S_R"
    others=$(awk -F'\t' '$2 != "A" && $2 != "AAAA" && $2 != "CNAME" { print $2 }' "$SETUP_RECORDS" | sort -u | paste -sd ',' | sed 's/,/, /g')
    [[ -n "$others" ]] && s_info "  (+$(awk -F'\t' '$2 != "A" && $2 != "AAAA" && $2 != "CNAME"' "$SETUP_RECORDS" | wc -l) more: $others)"
    return 0
}

setup() {
    is_root || die "setup must run as root: sudo ddns-watch setup"
    check_systemd_version
    setup_style
    setup_open_input

    declare -gA OLD=() NEW=()
    NEW_KEYS=()
    if [[ -f "$CONFIG_FILE" ]] && parse_config 2>/dev/null; then
        for k in "${!CFG[@]}"; do OLD[$k]="${CFG[$k]}"; done
    fi
    set_new() { [[ -v "NEW[$1]" ]] || NEW_KEYS+=("$1"); NEW[$1]="$2"; }
    SETUP_CHECK_LOG=$(mktemp) SETUP_RECORDS=$(mktemp)
    pending_open
    trap 'rm -f "$SETUP_CHECK_LOG" "$SETUP_RECORDS"; pending_close' EXIT

    echo
    s_box "$S_C" "$(printf '%-*s%s' "$((60 - ${#VERSION} - 1))" "ddns-watch setup" "v$VERSION")" \
        "Keeps the DNS record of one name pointing at this machine."
    echo
    printf '  Have ready:  %s the hostname (e.g. home.example.com)\n' "$S_BULLET"
    printf '               %s the login for your DNS provider (e.g. netcup API key)\n' "$S_BULLET"
    echo
    s_info "Enter accepts the suggestion in [brackets]. Ctrl+C cancels at any time;"
    s_info "nothing is changed before you confirm the summary."

    # ---- 1 provider
    step 1 "DNS provider"
    printf '  %sWhere is the DNS of your domain hosted?%s\n\n' "$S_B" "$S_R"
    local n names=() i=0 default_p=""
    while IFS= read -r n; do
        names+=("$n")
        i=$((i + 1))
        [[ "$n" == "${OLD[PROVIDER]:-}" ]] && default_p="$i"
        (load_provider "$n" 2>/dev/null && printf '    %s%-2s%s %-9s %s\n' "$S_C" "$i" "$S_R" "$n" "$PROVIDER_DESCRIPTION")
    done < <(list_providers)
    echo
    while true; do
        ask "Provider (number or name)" "$default_p"
        if [[ "$REPLY_VALUE" =~ ^[0-9]+$ ]] && (( REPLY_VALUE >= 1 && REPLY_VALUE <= ${#names[@]} )); then
            REPLY_VALUE="${names[REPLY_VALUE - 1]}"
        fi
        provider_file "${REPLY_VALUE,,}" >/dev/null && break
        s_info "Please type a number or one of: ${names[*]}"
    done
    set_new PROVIDER "${REPLY_VALUE,,}"
    PROVIDER="${NEW[PROVIDER]}"
    load_provider "$PROVIDER" || die "provider plugin $PROVIDER is broken"
    s_ok "$PROVIDER"

    # ---- 2 hostname
    step 2 "Hostname"
    s_info "The name whose A/AAAA records follow this machine. Other names: CNAMEs to it."
    echo
    while true; do
        ask "Hostname" "${OLD[HOSTNAME]:-}"
        REPLY_VALUE="${REPLY_VALUE%.}"
        REPLY_VALUE="${REPLY_VALUE,,}"
        [[ "$REPLY_VALUE" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && break
        s_info "That is not a valid domain name. Example: home.example.com"
    done
    set_new HOSTNAME "$REPLY_VALUE"
    DDNS_HOSTNAME="$REPLY_VALUE"
    s_ok "$DDNS_HOSTNAME"

    # ---- 3 login (+ read-only test)
    step 3 "Login"
    local key s ask_keys ask_secrets
    ask_keys="$PROVIDER_SETTINGS"
    [[ "$PROVIDER_ASK" != "-" ]] && ask_keys="$PROVIDER_ASK"
    ask_secrets="${PROVIDER_SECRETS%% *}"
    [[ "$PROVIDER_ASK_SECRETS" != "-" ]] && ask_secrets="$PROVIDER_ASK_SECRETS"
    for key in $ask_keys; do
        printf '  %s%s%s\n' "$S_B" "$key" "$S_R"
        s_info "${PROVIDER_HELP[$key]:-}"
        ask "$key" "${OLD[$key]:-}"
        set_new "$key" "$REPLY_VALUE"
        echo
    done
    for s in $ask_secrets; do
        printf '  %s%s%s\n' "$S_B" "$s" "$S_R"
        s_info "${PROVIDER_HELP[$s]:-}"
        s_info "It is stored encrypted on this machine."
        while true; do
            if secret_stored_ok "$s"; then
                ask_secret "$s, hidden ${S_D}[Enter = keep the stored one]${S_R}"
                [[ -z "$REPLY_VALUE" ]] && break
            else
                ask_secret "$s, hidden"
                if [[ -z "$REPLY_VALUE" ]]; then
                    s_info "This is needed. (Ctrl+C to cancel)"
                    continue
                fi
            fi
            pending_secret "$s" "$REPLY_VALUE"
            REPLY_VALUE=""
            break
        done
    done
    echo
    s_info "Testing the login (read-only, changes nothing) ..."
    local login_ok=1
    while ! setup_login_test; do
        s_bad "The login test did not pass:"
        sed 's/^/      /' "$SETUP_CHECK_LOG" | tail -n 12
        echo
        ask "[r]e-enter the secret, [c]ontinue anyway, [a]bort" "r"
        case "${REPLY_VALUE,,}" in
            c*) login_ok=0; break ;;
            a*) die "aborted; nothing was changed" ;;
        esac
        s="${ask_secrets%% *}"
        ask_secret "$s, hidden"
        [[ -n "$REPLY_VALUE" ]] && { pending_secret "$s" "$REPLY_VALUE"; }
        REPLY_VALUE=""
        s_info "Testing again ..."
    done
    if [[ "$login_ok" -eq 0 ]]; then
        s_warn "Continuing without a working login: updates will fail until it is fixed."
    elif [[ "$PROVIDER_LOGIN_CHECK" == no ]]; then
        # e.g. dyndns2: there is no read-only call that checks the password.
        s_warn "Login not checked: $PROVIDER can only verify it by sending a real update."
        s_info "  The first update at the end of the setup shows whether it works."
        sed 's/^/      /' "$SETUP_CHECK_LOG" | head -n 8
    elif [[ -s "$SETUP_RECORDS" ]]; then
        s_ok "Login OK"
        echo
        setup_show_records
    else
        s_ok "Login OK"
        sed 's/^/      /' "$SETUP_CHECK_LOG" | head -n 8
    fi

    # ---- 4 interface
    step 4 "Network interface"
    s_info "The IPv6 is read from this interface. Temporary and local-only addresses are skipped."
    echo
    RECORDS="A+AAAA" IPV4_SOURCE=dns UPNP_URL="${OLD[UPNP_URL]:-}"
    IPV6_SUFFIX="${OLD[IPV6_SUFFIX]:-}" IPV6_SUFFIX_X=""
    if [[ -n "$IPV6_SUFFIX" ]]; then
        IPV6_SUFFIX_X=$(expand_ipv6 "$IPV6_SUFFIX")
        IPV6_SUFFIX_X="${IPV6_SUFFIX_X:20}"
    fi
    show_iface_table
    echo
    local det="${OLD[IFACE]:-$IFACE_RECOMMENDED}"
    while true; do
        ask "Interface (number or name)" "$det"
        if [[ "$REPLY_VALUE" =~ ^[0-9]+$ ]] && (( REPLY_VALUE >= 1 && REPLY_VALUE <= ${#IFACE_LIST[@]} )); then
            REPLY_VALUE="${IFACE_LIST[REPLY_VALUE - 1]}"
        fi
        [[ "$REPLY_VALUE" =~ ^[A-Za-z0-9_.:@-]{1,15}$ ]] && ip link show dev "$REPLY_VALUE" >/dev/null 2>&1 && break
        s_info "No interface named \"$REPLY_VALUE\". Type a number or a name from the list above."
    done
    set_new IFACE "$REPLY_VALUE"
    IFACE="$REPLY_VALUE"
    local v6 sug_rec="A+AAAA"
    v6=$(get_ipv6)
    if [[ -n "$v6" ]]; then
        s_ok "$IFACE  ${S_D}$S_BULLET  $v6${S_R}"
    else
        s_warn "$IFACE has no stable public IPv6 right now."
        ask_yes "Publish an AAAA (IPv6) record anyway, once one appears?" n && sug_rec="A+AAAA" || sug_rec="A"
    fi

    # ---- 5 IPv4
    step 5 "IPv4 address"
    s_info "Your router gets the public IPv4. Where should ddns-watch ask for it?"
    echo
    local v4i v4u v4d sug="" srcs=(upnp dns interface none) how ans col
    v4i=$(ipv4_from_interface | head -n 1)
    v4u=$(ipv4_from_upnp)
    v4d=$(ipv4_from_dns)
    if is_ipv4 "$v4i" && ! is_nonpublic_ipv4 "$v4i"; then sug=interface
    elif is_ipv4 "$v4u" && ! is_nonpublic_ipv4 "$v4u"; then sug=upnp
    elif is_ipv4 "$v4u"; then sug=none     # router has only a private/CGNAT IPv4 (DS-Lite)
    elif is_ipv4 "$v4d"; then sug=dns
    else sug=none; fi
    [[ "$sug_rec" == A && "$sug" == none ]] && sug=dns
    printf '    %s#  %-10s %-38s %s%s\n' "$S_D" "Source" "How" "Answer now" "$S_R"
    for i in 0 1 2 3; do
        case "${srcs[i]}" in
            upnp) how="ask the router (local, every 60 s)"; ans="${v4u:-no answer}" ;;
            dns) how="ask public DNS services (every 5 min)"; ans="${v4d:-no answer}" ;;
            interface) how="public IPv4 on $IFACE"; ans="${v4i:-none}"
                is_ipv4 "$v4i" && is_nonpublic_ipv4 "$v4i" && ans="none ($v4i is private)" ;;
            none) how="no A record, IPv6 only"; ans="" ;;
        esac
        [[ "${srcs[i]}" == upnp ]] && is_ipv4 "$v4u" && is_nonpublic_ipv4 "$v4u" && ans="$v4u (not public: DS-Lite/CGNAT)"
        col="$S_D"; is_ipv4 "${ans%% *}" && ! is_nonpublic_ipv4 "${ans%% *}" && col="$S_G"
        printf '    %s%-2s%s %-10s %-38s %s%-30s%s' "$S_C" "$((i + 1))" "$S_R" "${srcs[i]}" "$how" "$col" "$ans" "$S_R"
        [[ "${srcs[i]}" == "$sug" ]] && printf ' %s%s recommended%s' "$S_Y" "$S_STAR" "$S_R"
        printf '\n'
    done
    echo
    local def_src="${OLD[IPV4_SOURCE]:-$sug}"
    [[ -n "${OLD[RECORDS]:-}" && "${OLD[RECORDS]}" == AAAA && -z "${OLD[IPV4_SOURCE]:-}" ]] && def_src=none
    while true; do
        ask "IPv4 source (number or name)" "$def_src"
        [[ "$REPLY_VALUE" =~ ^[1-4]$ ]] && REPLY_VALUE="${srcs[REPLY_VALUE - 1]}"
        case "${REPLY_VALUE,,}" in interface|upnp|dns|none|command) break ;; esac
        s_info "Please type 1-4 or upnp, dns, interface, none."
    done
    local src="${REPLY_VALUE,,}" interval=""
    if [[ "$src" == none ]]; then
        [[ "$sug_rec" == A ]] && die "neither IPv4 nor IPv6: nothing to publish"
        sug_rec="AAAA"
        s_ok "none  ${S_D}$S_BULLET  IPv6 only (AAAA)${S_R}"
    else
        set_new IPV4_SOURCE "$src"
        case "$src" in upnp) interval=60 ;; *) interval=300 ;; esac
        interval="${OLD[IPV4_INTERVAL]:-$interval}"
        set_new IPV4_INTERVAL "$interval"
        s_ok "$src  ${S_D}$S_BULLET  checked every $interval s${S_R}"
        s_info "  Reconnects usually change the IPv6 prefix too, so a new IPv4 is caught at once."
    fi
    set_new RECORDS "$sug_rec"

    # ---- 6 notifications
    step 6 "Notifications ${S_D}(optional)${S_R}"
    s_info "Two optional helpers; Enter skips them. Step-by-step guide: $NOTIFY_GUIDE"
    echo
    printf '  %sMessage when updates keep failing%s\n' "$S_B" "$S_R"
    s_info "ntfy: https://ntfy.sh/<long-secret-topic>  |  Gotify: https://gotify.example.com/message"
    s_info "Discord: channel webhook URL  |  Slack / Mattermost: incoming webhook URL"
    s_info "The URL is stored encrypted, like a password (for Discord/Slack it IS one)."
    NOTIFY_TYPE="${OLD[NOTIFY_TYPE]:-auto}"
    setup_url_secret NOTIFY_URL notify-url "Notification URL"
    if [[ -n "$NOTIFY_URL" ]]; then
        s_ok "$(notify_type)"
        case "$(notify_type)" in
            ntfy|gotify)
                ask_secret "Access token (ntfy: protected topic, Gotify: app token), hidden ${S_D}[Enter = none / keep]${S_R}"
                [[ -n "$REPLY_VALUE" ]] && pending_secret notify-token "$REPLY_VALUE"
                REPLY_VALUE=""
                ;;
        esac
    else
        s_info "  skipped"
    fi
    echo
    printf '  %sHeartbeat: alarm when this machine goes quiet%s\n' "$S_B" "$S_R"
    s_info "A URL called after every good run. If the calls stop, that service warns you, e.g. a"
    s_info "Healthchecks.io check (period 5 min) or an Uptime Kuma push monitor."
    setup_url_secret HEARTBEAT_URL heartbeat-url "Heartbeat URL"
    [[ -z "$HEARTBEAT_URL" ]] && s_info "  skipped"
    if [[ -n "$NOTIFY_URL$HEARTBEAT_URL" ]] && ask_yes "Send a test now?" y; then
        if [[ -n "$NOTIFY_URL" ]]; then
            if notify "ddns-watch test" default "white_check_mark" \
                "Test message from the ddns-watch setup on $(hostname). Notifications work." >/dev/null 2>&1; then
                s_ok "Test notification sent  ${S_D}(check your phone / channel)${S_R}"
            else
                s_bad "Test notification failed: check the URL and the token (sudo ddns-watch test-notify later)"
            fi
        fi
        if [[ -n "$HEARTBEAT_URL" ]]; then
            if heartbeat_ping; then s_ok "Heartbeat ping OK"; else s_bad "Heartbeat ping failed: check the URL"; fi
        fi
    fi

    # ---- summary
    local keyinfo="host key" rec_txt="A + AAAA" v4_txt
    systemd-creds has-tpm2 >/dev/null 2>&1 && keyinfo="TPM + host key"
    [[ "$sug_rec" == AAAA ]] && rec_txt="AAAA only"
    [[ "$sug_rec" == A ]] && rec_txt="A only"
    v4_txt="${NEW[IPV4_SOURCE]:-none}"
    [[ -n "$interval" ]] && v4_txt+=" every $interval s"
    printf '\n %sSummary%s\n\n' "$S_B" "$S_R"
    s_box "$S_C" \
        "$(printf '%-12s %s' Provider "$PROVIDER")" \
        "$(printf '%-12s %s' Hostname "$DDNS_HOSTNAME")" \
        "$(printf '%-12s %s' Records "$rec_txt")" \
        "$(printf '%-12s %s' Interface "$IFACE${v6:+ -> $v6}")" \
        "$(printf '%-12s %s' IPv4 "$v4_txt")" \
        "$(printf '%-12s %s' Notify "$([[ -n "$NOTIFY_URL" ]] && echo "$(notify_type), URL encrypted" || echo none)")" \
        "$(printf '%-12s %s' Heartbeat "$([[ -n "$HEARTBEAT_URL" ]] && echo "URL encrypted" || echo none)")" \
        "$(printf '%-12s %s' Secrets "encrypted ($keyinfo)")"
    echo
    ask_yes "Apply and start ddns-watch?" y || { echo; s_info "Cancelled. Nothing was changed (config and secrets as before)."; return 0; }

    # ---- apply
    printf '\n %sApplying%s\n\n' "$S_B" "$S_R"
    pending_commit
    pending_close
    s_ok "Secrets stored         ${S_D}encrypted in $CRED_STORE${S_R}"
    setup_write_config
    load_config || die "the new config does not load (see above); please report this as a bug"
    s_ok "Config written         ${S_D}$CONFIG_FILE${S_R}"
    write_cred_dropin
    if [[ -n "$interval" ]]; then
        # Timer settings are lists: a plain OnUnitActiveSec= in a drop-in would ADD a second
        # interval (the shorter one wins). An empty assignment clears the list - and with it
        # OnBootSec, so both are set again.
        mkdir -p "$UNIT_DIR/ddns-watch-ipv4.timer.d"
        printf '# Written by "ddns-watch setup".\n[Timer]\nOnBootSec=\nOnUnitActiveSec=\nOnBootSec=2min\nOnUnitActiveSec=%ss\n' \
            "$interval" > "$UNIT_DIR/ddns-watch-ipv4.timer.d/interval.conf"
    fi
    systemctl daemon-reload
    if systemctl enable --now ddns-watch.service ddns-watch-ipv4.timer >/dev/null 2>&1; then
        systemctl restart ddns-watch.service 2>/dev/null || true
        # A running timer keeps its old schedule until it is restarted.
        systemctl restart ddns-watch-ipv4.timer 2>/dev/null || true
        s_ok "Services started       ${S_D}ddns-watch.service, ddns-watch-ipv4.timer${S_R}"
    else
        s_bad "Could not start the services (see: systemctl status ddns-watch)"
    fi

    local since out result
    since=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl start ddns-watch-ipv4.service >/dev/null 2>&1
    # The service's own result decides; the journal lines are only shown.
    result=$(systemctl show -p Result --value ddns-watch-ipv4.service 2>/dev/null)
    out=$(journalctl -u ddns-watch-ipv4.service --since "$since" --no-pager -o cat 2>/dev/null \
        | grep -v -e '^Start' -e '^Finish' -e '^Deactivated' -e 'Failed' -e 'Main process' | tail -n 4)
    if [[ "$result" == success ]]; then
        s_ok "First check            ${S_D}$(tail -n 1 <<< "${out:-done (details: ddns-watch status)}")${S_R}"
        echo
        s_box "$S_G" "ddns-watch is running."
    else
        s_bad "First update failed"
        echo
        if [[ -n "$out" ]]; then
            s_info "  journalctl -u ddns-watch-ipv4 (last lines):"
            sed 's/^/      /' <<< "$out"
        fi
        echo
        printf '  %sWhat now%s\n' "$S_B" "$S_R"
        printf '    %s The service retries automatically (1, 2, 5, then every 10 min).\n' "$S_BULLET"
        printf '    %s Check:  ddns-watch status    Log:  journalctl -u ddns-watch -n 30\n' "$S_BULLET"
        printf '    %s Your DNS records were not changed.\n' "$S_BULLET"
    fi
    echo
    printf '  %sNext%s\n' "$S_B" "$S_R"
    printf '    %-32s %s%s%s\n' "ddns-watch status" "$S_D" "how it is doing" "$S_R"
    printf '    %-32s %s%s%s\n' "journalctl -u ddns-watch -f" "$S_D" "live log" "$S_R"
    printf '    %-32s %s%s%s\n' "sudo ddns-watch setup" "$S_D" "change settings" "$S_R"
    printf '    %-32s %s%s%s\n' "(other names)" "$S_D" "CNAMEs to $DDNS_HOSTNAME at your provider" "$S_R"
    echo
    s_warn "Keep your API key in a password manager. After a hardware change:"
    printf '    sudo ddns-watch set-secret %s\n' "${ask_secrets%% *}"
}

# ---------------------------------------------------------------- status / uninstall

PREFIX="${DDNS_PREFIX:-/usr/local}"
UNITS="ddns-watch.service ddns-watch-ipv4.service ddns-watch-ipv4.timer"

unit_state() {
    local a e
    a=$(systemctl is-active "$1" 2>/dev/null) || true
    e=$(systemctl is-enabled "$1" 2>/dev/null) || true
    printf '%s, %s' "${a:-unknown}" "${e:-not installed}"
}

show_status() {
    local ipv4 ipv6 s state last_err latest
    say "ddns-watch $VERSION"
    if is_root && [[ -z "${DDNS_NO_UPDATE_CHECK:-}" ]]; then
        latest=$(latest_version)
        if [[ -n "$latest" ]] && version_lt "$VERSION" "$latest"; then
            say "Update available: $latest  ->  sudo ddns-watch update"
        fi
    fi
    if ! load_config; then
        say "Config: BROKEN (see error above) -> fix $CONFIG_FILE"
        return 1
    fi
    say "Provider:  $PROVIDER ($PROVIDER_TIER$([[ "$PROVIDER_LOCAL" -eq 1 ]] && printf ', local plugin'))   hostname: $DDNS_HOSTNAME   iface: $IFACE"
    say "Records:   $RECORDS   IPv4 source: $IPV4_SOURCE$([[ "$IPV4_FALLBACK" == dns ]] && printf " (fallback dns)")"

    ipv4=$(get_ipv4 || true)
    ipv6=$(get_ipv6 || true)
    load_state
    say "Now:       IPv4=${ipv4:-none}  IPv6=${ipv6:-none}"
    if [[ -f "$STATE" ]]; then
        say "Last good: IPv4=${LAST_IPV4:-none}  IPv6=${LAST_IPV6:-none}  via ${LAST_PROVIDER:-?}  at ${LAST_UPDATED:-unknown}"
        if [[ "$ipv4" != "$LAST_IPV4" || "$ipv6" != "$LAST_IPV6" ]]; then
            say "           -> differs from now: the next run will update (or the last update failed)"
        fi
    elif ! is_root; then
        # The service keeps its state in /var/lib/private (DynamicUser), readable by root only.
        say "Last good: unknown here (only root can read it: sudo ddns-watch status)"
    else
        say "Last good: never (no successful update yet)"
    fi

    say "Services:"
    for s in $UNITS; do
        printf '  %-26s %s\n' "$s" "$(unit_state "$s")"
    done
    # Only errors since the watcher was last (re)started; older ones are history.
    local started
    started=$(systemctl show -p ActiveEnterTimestamp --value ddns-watch.service 2>/dev/null)
    if [[ -n "$started" && "$started" != "n/a" ]]; then
        last_err=$(journalctl -u ddns-watch.service -u ddns-watch-ipv4.service -p err -n 1 -q --no-pager \
            -o short-iso --since "$(date -d "$started" '+%F %T' 2>/dev/null || echo today)" 2>/dev/null) || true
        [[ -n "$last_err" ]] && say "Last error: $last_err"
    fi
    load_failure
    if [[ -n "$FAIL_CLASS" ]]; then
        say "FAILING:   since $(date -d "@$FAIL_SINCE" "+%F %T"), $FAIL_COUNT attempts, $FAIL_CLASS: $FAIL_MSG"
        if [[ "$FAIL_CLASS" == permanent ]]; then
            say "           no retries until the config or a secret changes (or: ddns-watch run --force)"
        else
            say "           next retry after $(date -d "@$FAIL_NEXT" "+%T")"
        fi
    fi
    [[ -n "$NOTIFY_URL" ]] && say "Notify:    $([[ "$NOTIFY_URL" == secret ]] && echo "URL stored encrypted" || echo "$NOTIFY_URL") (type ${NOTIFY_TYPE}, after $NOTIFY_AFTER min of errors)"
    [[ -n "$HEARTBEAT_URL" ]] && say "Heartbeat: $([[ "$HEARTBEAT_URL" == secret ]] && echo "URL stored encrypted" || echo "$HEARTBEAT_URL")"

    if is_root; then
        say "Secrets:"
        for s in $PROVIDER_SECRETS $(core_secrets_in_use); do
            if [[ ! -f "$CRED_STORE/$s" ]]; then
                state="not stored"
            elif ! systemd-creds decrypt --name="$s" "$CRED_STORE/$s" - >/dev/null 2>&1; then
                state="CANNOT DECRYPT -> ddns-watch set-secret $s"
            elif ! grep -qs "^LoadCredentialEncrypted=$s:" "$UNIT_DIR/ddns-watch.service.d/credentials.conf"; then
                # Stored, but not handed to the service (e.g. PROVIDER changed by hand).
                state="stored, but NOT given to the service -> sudo ddns-watch setup"
            else
                state="ok (encrypted)"
            fi
            printf '  %-26s %s\n' "$s" "$state"
        done
    else
        say "Secrets:   run as root to check them (sudo ddns-watch status)"
    fi
}

# uninstall [--purge] [--yes]: removes program, plugins and units. --purge also removes the config,
# the encrypted secrets and the state. Only fixed install paths are touched, never this checkout.
uninstall() {
    local purge=0 yes=0 a answer u
    for a in "$@"; do
        case "$a" in
            --purge) purge=1 ;;
            --yes|-y) yes=1 ;;
            *) usage >&2; exit 1 ;;
        esac
    done
    is_root || die "uninstall must run as root: sudo ddns-watch uninstall"
    [[ "$PREFIX" == /* && "$PREFIX" != "/" ]] || die "invalid install prefix $PREFIX"
    [[ "$UNIT_DIR" == /* && "$UNIT_DIR" != "/" ]] || die "invalid unit directory $UNIT_DIR"

    say "This removes:"
    say "  services:  $UNITS"
    say "  program:   $PREFIX/bin/ddns-watch, $PREFIX/lib/ddns-watch/"
    if [[ "$purge" -eq 1 ]]; then
        say "  config:    $CONFIG_DIR/ (settings, encrypted secrets, local plugins)"
        say "  state:     $STATE_DIR/"
        say "  The DNS record at your provider is not changed."
    else
        say "Kept: $CONFIG_DIR/ (settings, encrypted secrets) and $STATE_DIR/. Use --purge to remove them too."
    fi
    if [[ "$yes" -ne 1 ]]; then
        [[ -t 0 ]] || die "not a terminal: add --yes to confirm"
        read -r -p "Continue? [y/N] " answer
        [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || { say "Cancelled, nothing changed."; return 0; }
    fi

    systemctl disable --now ddns-watch.service ddns-watch-ipv4.timer 2>/dev/null || true
    systemctl stop ddns-watch-ipv4.service 2>/dev/null || true
    for u in $UNITS; do
        rm -f -- "$UNIT_DIR/$u"
        rm -rf -- "${UNIT_DIR:?}/$u.d"
    done
    systemctl daemon-reload 2>/dev/null || true
    rm -f -- "$PREFIX/bin/ddns-watch"
    rm -rf -- "${PREFIX:?}/lib/ddns-watch"
    if [[ "$purge" -eq 1 ]]; then
        rm -rf -- "${CONFIG_DIR:?}" "${STATE_DIR:?}"
        # DynamicUser keeps the real state under /var/lib/private.
        [[ "$STATE_DIR" == /var/lib/ddns-watch ]] && rm -rf -- /var/lib/private/ddns-watch
    fi
    say "ddns-watch removed$([[ "$purge" -eq 1 ]] && printf ' completely')."
}

# ---------------------------------------------------------------- updates of ddns-watch itself

REPO="gitrys/ddns-watch"
RELEASE_BASE="${DDNS_RELEASE_BASE:-https://github.com/$REPO/releases/download}"
RELEASE_API="${DDNS_RELEASE_API:-https://api.github.com/repos/$REPO/releases/latest}"
NOTIFY_GUIDE="https://github.com/$REPO/blob/main/docs/notifications.md"

# latest_version -> newest release version (without "v"), empty if unknown. Cached for a day.
latest_version() {
    local cache="$STATE_DIR/latest-version" v=""
    if [[ -f "$cache" && -n "$(find "$cache" -mmin -1440 2>/dev/null)" ]]; then
        v=$(< "$cache")
    else
        v=$(curl -fsSL --max-time 8 -H 'Accept: application/vnd.github+json' "$RELEASE_API" 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([0-9][0-9.]*\)".*/\1/p' | head -n 1)
        [[ -n "$v" && -w "$STATE_DIR" ]] && printf '%s\n' "$v" > "$cache"
    fi
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "$v"
}

# version_lt A B: true if version A is older than B (numeric x.y.z; "-dev" counts as older).
version_lt() {
    local a="${1%%-*}" b="${2%%-*}"
    if [[ "$a" == "$b" ]]; then
        [[ "$1" == *-* && "$2" != *-* ]]
        return
    fi
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" == "$a" ]]
}

# update [--yes]: downloads the newest release, checks it and installs it (config is kept).
self_update() {
    local yes=0 latest tmp name answer
    [[ "${1:-}" == --yes || "${1:-}" == -y ]] && yes=1
    is_root || die "update must run as root: sudo ddns-watch update"
    rm -f "$STATE_DIR/latest-version"
    latest=$(latest_version)
    [[ -n "$latest" ]] || die "could not find the latest release of $REPO"
    if ! version_lt "$VERSION" "$latest"; then
        say "ddns-watch $VERSION is up to date (latest release: $latest)."
        return 0
    fi
    say "Update available: $VERSION -> $latest (changes: https://github.com/$REPO/releases/tag/v$latest)"
    if [[ "$yes" -ne 1 ]]; then
        [[ -t 0 ]] || die "not a terminal: add --yes to confirm"
        read -r -p "Install it now? [y/N] " answer
        [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || { say "Nothing changed."; return 0; }
    fi
    tmp=$(mktemp -d) || die "cannot create a temporary folder"
    name="ddns-watch-$latest.tar.gz"
    if ! curl -fsSL --max-time 120 -o "$tmp/$name" "$RELEASE_BASE/v$latest/$name" \
        || ! curl -fsSL --max-time 30 -o "$tmp/SHA256SUMS" "$RELEASE_BASE/v$latest/SHA256SUMS"; then
        rm -rf -- "$tmp"
        die "download failed"
    fi
    # Verify before running anything from the download.
    if ! (cd "$tmp" && grep -E "  \*?$name\$" SHA256SUMS | sha256sum -c --quiet -) 2>/dev/null; then
        rm -rf -- "$tmp"
        die "checksum of $name does not match: download corrupted or tampered with"
    fi
    say "Checksum OK."
    if command -v gh >/dev/null 2>&1; then
        gh attestation verify "$tmp/$name" --repo "$REPO" >/dev/null 2>&1 \
            || { rm -rf -- "$tmp"; die "GitHub attestation check failed: $name was not built by $REPO"; }
        say "GitHub attestation OK."
    fi
    tar -xzf "$tmp/$name" -C "$tmp" "ddns-watch-$latest/install.sh" 2>/dev/null \
        || { rm -rf -- "$tmp"; die "$name is not a ddns-watch release"; }
    bash "$tmp/ddns-watch-$latest/install.sh" --from "$tmp/$name" --upgrade --yes
    local rc=$?
    rm -rf -- "$tmp"
    return "$rc"
}

# The addresses read locally (no network): the stable IPv6, plus the interface IPv4 if that is the
# IPv4 source. The watcher only acts when this changes.
local_addresses() {
    get_ipv6
    if [[ "$IPV4_SOURCE" == interface && "$RECORDS" != AAAA ]]; then
        get_ipv4
    fi
}

watch_loop() {
    ensure_dirs "$RUNTIME_DIR"
    # A broken config at start: wait a minute before systemd restarts us, instead of a 5 s loop.
    if ! load_config; then
        sleep 60
        exit 1
    fi
    exec 8>"$RUNTIME_DIR/watch.lock"
    # Wait a little: after a self-restart the old process may still be on its way out.
    if ! flock -w 5 8; then
        say "watch: another watcher is already running"
        exit 0
    fi

    # Config and secrets are re-read on every update, so they may change while we run.
    say "watch: starting (provider=$PROVIDER iface=$IFACE debounce=${DEBOUNCE_SEC}s)"
    [[ "$PROVIDER_LOCAL" -eq 1 ]] && warn "provider $PROVIDER is a local plugin from $LOCAL_PROVIDERS_DIR (not part of ddns-watch)"
    update_once || true
    local fam=(-6) what=IPv6
    if [[ "$IPV4_SOURCE" == interface && "$RECORDS" != AAAA ]]; then
        fam=()
        what="IPv4 and IPv6"
    fi
    [[ "$RECORDS" == A && "$IPV4_SOURCE" != interface ]] && say "watch: RECORDS=A without IPV4_SOURCE=interface: only the timer catches changes"
    say "watch: monitoring $what on $IFACE"

    # The kernel reports every address event, including privacy-address renewals and lifetime
    # refreshes (every few minutes). Only run the updater when an address we publish changed.
    # Every WATCH_TICK seconds without an event, check whether settings that decide WHAT we watch
    # changed (IFACE, IPV4_SOURCE, RECORDS, IPV6_SUFFIX); if so, start over with the new config.
    local seen now rc mon_pid watch_fp
    seen=$(local_addresses)
    watch_fp=$(watch_fingerprint)
    # (8>&-: the monitor must not inherit the watcher lock, or a restarted watcher finds it taken.)
    exec 3< <(exec ip "${fam[@]}" monitor address dev "$IFACE" 8>&-)
    mon_pid=$!
    while true; do
        if IFS= read -r -t "$WATCH_TICK" -u 3 _; then
            while IFS= read -r -t "$DEBOUNCE_SEC" -u 3 _; do
                :
            done
            now=$(local_addresses)
            [[ "$now" == "$seen" ]] && continue
            say "watch: address changed ($(tr '\n' ' ' <<< "$now")), running updater"
            seen="$now"
            update_once || true
            continue
        else
            rc=$? # (here, not after "fi": after fi $? would be 0)
        fi
        if (( rc <= 128 )); then
            break # end of input: ip monitor exited
        fi
        now=$(watch_fingerprint)
        # (Empty = config unreadable right now, e.g. while being saved: try again next tick.)
        if [[ -n "$now" && "$now" != "$watch_fp" ]]; then
            say "watch: configuration changed (interface, IPv4 source, records or IPv6 suffix): restarting the watcher"
            kill "$mon_pid" 2>/dev/null
            exec 3<&- 8>&-
            exec "$SELF" watch
        fi
    done

    err "watch: ip monitor exited"
    return 1
}

# The settings the watcher itself depends on. Empty if the config cannot be read right now.
watch_fingerprint() {
    (
        load_config >/dev/null 2>&1 || exit 0
        printf '%s|%s|%s|%s\n' "$IFACE" "$IPV4_SOURCE" "$RECORDS" "$IPV6_SUFFIX"
    )
}

main() {
    case "${1:-run}" in
        run)
            case "${2:-}" in
                "") ;;
                --force) FORCE=1; USER_FORCE=1 ;;
                *) usage >&2; exit 1 ;;
            esac
            update_once
            ;;
        --force|now|fire)
            FORCE=1
            USER_FORCE=1
            update_once
            ;;
        watch)
            watch_loop
            ;;
        check)
            check_provider "${2:-}"
            ;;
        secrets)
            show_secrets
            ;;
        set-secret)
            set_secret "${2:-}"
            ;;
        setup)
            setup
            ;;
        status)
            show_status
            ;;
        test-notify)
            test_notify
            ;;
        update)
            self_update "${2:-}"
            ;;
        uninstall)
            shift
            uninstall "$@"
            ;;
        providers)
            show_providers
            ;;
        --version|version)
            say "ddns-watch $VERSION"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

# Only run when executed, not when sourced (the tests source this file to lint plugins).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
