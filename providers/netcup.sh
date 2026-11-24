# shellcheck shell=bash
# shellcheck disable=SC2034  # PROVIDER_* metadata and results are read by ddns-watch
# ddns-watch provider plugin: netcup DNS (REST API "CloudDNS"; legacy CCP JSON API as fallback).
# Copyright (C) 2026 gitrys. SPDX-License-Identifier: GPL-3.0-or-later

PROVIDER_NAME="netcup"
PROVIDER_TIER="core"
PROVIDER_MAINTAINER="gitrys"
PROVIDER_DESCRIPTION="netcup DNS (REST API, legacy API as fallback)"
PROVIDER_SETTINGS="NETCUP_API NETCUP_ZONE NETCUP_CUSTOMER NETCUP_TTL"
PROVIDER_SECRETS="netcup-api-key netcup-legacy-key netcup-legacy-password"
# setup asks only for the REST key; the zone and the legacy API are rarely needed (see PROVIDER_HELP).
PROVIDER_ASK=""
PROVIDER_ASK_SECRETS="netcup-api-key"
declare -gA PROVIDER_HELP=(
    [NETCUP_API]="Which netcup API to use: auto (default: REST, legacy only if the domain is still on netcup's old DNS), rest or legacy."
    [NETCUP_ZONE]="Domain as it is named at netcup. Leave empty; only needed for multi-part TLDs (home.example.co.uk -> example.co.uk)."
    [NETCUP_CUSTOMER]="Legacy API only: your netcup customer number (digits)."
    [NETCUP_TTL]="TTL in seconds for the A/AAAA records (default 300)."
    [netcup-api-key]="CCP -> Stammdaten -> API -> section \"API-Keys\" -> \"API-Key erstellen\". Whoever has this key can change your DNS."
    [netcup-legacy-key]="Legacy API only: CCP -> Stammdaten -> API -> \"Legacy-API-Keys\"."
    [netcup-legacy-password]="Legacy API only: \"API-Passwort neu erstellen\" (shown only once)."
)

NETCUP_ENDPOINT="${NETCUP_ENDPOINT:-https://ccp.netcup.net/run/webservice/servers/endpoint.php?JSON}"

provider_config() {
    NETCUP_API=$(cfg NETCUP_API auto)
    NETCUP_API="${NETCUP_API,,}"
    NETCUP_DOMAIN=$(cfg NETCUP_ZONE)
    NETCUP_CUSTOMER=$(cfg NETCUP_CUSTOMER)
    NETCUP_TTL=$(cfg NETCUP_TTL 300)
    case "$NETCUP_API" in
        auto|rest|legacy) ;;
        *) err "NETCUP_API=$NETCUP_API in $CONFIG_FILE must be auto, rest or legacy"; return 1 ;;
    esac
    if [[ -n "$NETCUP_DOMAIN" && ! "${NETCUP_DOMAIN,,}" =~ ^([a-z0-9-]+\.)+[a-z0-9-]+\.?$ ]]; then
        err "NETCUP_ZONE=$NETCUP_DOMAIN in $CONFIG_FILE is not a valid domain name"
        return 1
    fi
    if [[ -n "$NETCUP_CUSTOMER" && ! "$NETCUP_CUSTOMER" =~ ^[0-9]+$ ]]; then
        err "NETCUP_CUSTOMER in $CONFIG_FILE must be digits only"
        return 1
    fi
    # (also turns "0300" into 300: a leading zero would be invalid JSON for the API)
    number_setting NETCUP_TTL 60 86400 "seconds" || return 1
}

provider_secrets() {
    NETCUP_TOKEN=$(read_secret netcup-api-key)
    NETCUP_APIKEY=$(read_secret netcup-legacy-key)
    NETCUP_APIPASS=$(read_secret netcup-legacy-password)
    if [[ -z "$NETCUP_TOKEN" ]] && ! netcup_legacy_complete; then
        die "provider netcup needs the secret netcup-api-key (REST API), or NETCUP_CUSTOMER plus the secrets netcup-legacy-key and netcup-legacy-password (legacy API) ($(secrets_hint netcup-api-key))"
    fi
    command -v jq >/dev/null 2>&1 || die "provider netcup needs jq (sudo apt install jq)"
    netcup_zone_host
}

provider_update() { netcup_update "$@"; }
provider_check() { netcup_check "$@"; }

# Optional hook (used by setup after provider_check): the zone's records as
# "name<TAB>type<TAB>value", name relative to the zone ("@" = the zone itself).
provider_records() {
    jq -r '.[] | [ ((.name // .hostname // "@") | if . == "" then "@" else . end),
                   .type, (.rdata // .destination // "") ] | @tsv' <<< "${NETCUP_RECORDS:-[]}"
}

# ---------------------------------------------------------------- netcup
#
# netcup has two DNS APIs, and which one works depends on the domain:
#   rest    new REST API (api.netcup.com/v1, "CloudDNS"), one bearer key: NETCUP_TOKEN
#   legacy  old CCP JSON API (endpoint.php?JSON): NETCUP_CUSTOMER + NETCUP_APIKEY + NETCUP_APIPASS
# NETCUP_API=auto (default) asks the REST API whether it manages the domain (isDnsManaged)
# and falls back to legacy otherwise.

netcup_legacy_complete() {
    [[ -n "${NETCUP_CUSTOMER:-}" && -n "${NETCUP_APIKEY:-}" && -n "${NETCUP_APIPASS:-}" ]]
}

# Splits DDNS_HOSTNAME into NETCUP_ZONE (domain at netcup) and NETCUP_HOST ("@" for the apex).
netcup_zone_host() {
    local fqdn="${DDNS_HOSTNAME%.}"
    fqdn="${fqdn,,}"
    NETCUP_ZONE="${NETCUP_DOMAIN:-}"
    NETCUP_ZONE="${NETCUP_ZONE%.}"
    NETCUP_ZONE="${NETCUP_ZONE,,}"
    if [[ -z "$NETCUP_ZONE" ]]; then
        NETCUP_ZONE=$(awk -F. '{ if (NF < 2) print $0; else print $(NF - 1) "." $NF }' <<< "$fqdn")
    fi
    if [[ "$fqdn" == "$NETCUP_ZONE" ]]; then
        NETCUP_HOST="@"
    elif [[ "$fqdn" == *".$NETCUP_ZONE" ]]; then
        NETCUP_HOST="${fqdn%."$NETCUP_ZONE"}"
    else
        die "HOSTNAME=$DDNS_HOSTNAME is not inside NETCUP_ZONE=$NETCUP_ZONE"
    fi
}

# netcup_call ACTION PARAM_JSON -> NETCUP_RESP on success; NETCUP_ERR / NETCUP_CODE on failure.
# The request body goes through stdin so secrets never show up in the process list.
netcup_call() {
    local body status
    NETCUP_RESP=""
    NETCUP_ERR=""
    NETCUP_CODE=""
    body=$(jq -cn --arg a "$1" --argjson p "$2" '{action: $a, param: $p}') || {
        NETCUP_ERR="could not build request for $1"
        return 1
    }
    if ! NETCUP_RESP=$(curl --silent --show-error --max-time 30 \
            -H 'Content-Type: application/json' \
            --data-binary @- "$NETCUP_ENDPOINT" <<< "$body" 2>&1); then
        NETCUP_ERR="$1: $NETCUP_RESP"
        return 1
    fi
    status=$(jq -r '.status // empty' <<< "$NETCUP_RESP" 2>/dev/null)
    if [[ "$status" != "success" ]]; then
        NETCUP_CODE=$(jq -r '.statuscode // empty' <<< "$NETCUP_RESP" 2>/dev/null)
        NETCUP_ERR=$(jq -r '"\(.statuscode // "?") \(.shortmessage // "") \(.longmessage // "")"' \
            <<< "$NETCUP_RESP" 2>/dev/null) || NETCUP_ERR=$(head -c 300 <<< "$NETCUP_RESP")
        NETCUP_ERR="$1: $NETCUP_ERR"
        return 1
    fi
    return 0
}

netcup_auth_param() {
    NC_CUST="$NETCUP_CUSTOMER" NC_KEY="$NETCUP_APIKEY" NC_SID="${NETCUP_SID:-}" \
        jq -cn --arg d "$NETCUP_ZONE" \
        '{domainname: $d, customernumber: env.NC_CUST, apikey: env.NC_KEY, apisessionid: env.NC_SID}'
}

netcup_login() {
    local p
    NETCUP_SID=""
    p=$(NC_CUST="$NETCUP_CUSTOMER" NC_KEY="$NETCUP_APIKEY" NC_PASS="$NETCUP_APIPASS" \
        jq -cn '{customernumber: env.NC_CUST, apikey: env.NC_KEY, apipassword: env.NC_PASS}')
    netcup_call login "$p" || return 1
    NETCUP_SID=$(jq -r '.responsedata.apisessionid // empty' <<< "$NETCUP_RESP")
    if [[ -z "$NETCUP_SID" ]]; then
        NETCUP_ERR="login: no apisessionid in response"
        return 1
    fi
}

netcup_logout() {
    [[ -n "${NETCUP_SID:-}" ]] || return 0
    local p
    p=$(netcup_auth_param | jq -c 'del(.domainname)')
    netcup_call logout "$p" || true
    NETCUP_SID=""
}

# Fetches the zone into NETCUP_RECORDS (JSON array).
netcup_fetch_records() {
    NETCUP_RECORDS="[]"
    if ! netcup_call infoDnsRecords "$(netcup_auth_param)"; then
        # 5029 = zone exists but has no records yet: start from an empty list.
        [[ "$NETCUP_CODE" == "5029" ]] && return 0
        return 1
    fi
    NETCUP_RECORDS=$(jq -c '.responsedata.dnsrecords // []' <<< "$NETCUP_RESP")
}

# Prints the records that must be sent so NETCUP_HOST has exactly one A (ipv4) and one AAAA (ipv6).
# Empty ipv4 / ipv6 leaves that record type alone.
netcup_plan() {
    jq -c --arg host "$NETCUP_HOST" --arg v4 "$1" --arg v6 "$2" '
        [ ( if $v4 != "" then {type: "A", ip: $v4} else empty end ),
          ( if $v6 != "" then {type: "AAAA", ip: $v6} else empty end ) ] as $want
        | . as $recs
        | [ $want[] as $w
            | [ $recs[] | select((.hostname | ascii_downcase) == ($host | ascii_downcase) and .type == $w.type) ] as $m
            | if ($m | length) == 0 then
                {hostname: $host, type: $w.type, priority: "", destination: $w.ip, deleterecord: false}
              else
                ( if $m[0].destination != $w.ip
                  then ($m[0] | {id, hostname, type, priority, destination: $w.ip, deleterecord: false})
                  else empty end ),
                ( $m[1:][] | {id, hostname, type, priority, destination, deleterecord: true} )
              end
          ]' <<< "$NETCUP_RECORDS"
}

netcup_describe() {
    jq -r '.[] | "  \(if .deleterecord then "delete" elif .id then "update" else "create" end) \(.hostname) \(.type) -> \(.destination)"' <<< "$1"
}

netcup_legacy_update() {
    local ipv4="$1" ipv6="$2" changes p rc=1
    say "Updating netcup (legacy API) zone $NETCUP_ZONE host $NETCUP_HOST A=${ipv4:-keep} AAAA=${ipv6:-keep}"
    if ! netcup_login; then
        PROVIDER_RESPONSE="$NETCUP_ERR"
        return 1
    fi
    if netcup_fetch_records; then
        changes=$(netcup_plan "$ipv4" "$ipv6")
        if [[ "$changes" == "[]" ]]; then
            PROVIDER_RESPONSE="nochg netcup $NETCUP_HOST.$NETCUP_ZONE already ${ipv4:-} ${ipv6:-}"
            rc=0
        else
            netcup_describe "$changes"
            p=$(netcup_auth_param | jq -c --argjson r "$changes" '. + {dnsrecordset: {dnsrecords: $r}}')
            if netcup_call updateDnsRecords "$p"; then
                PROVIDER_RESPONSE="good netcup $NETCUP_HOST.$NETCUP_ZONE ${ipv4:-} ${ipv6:-}"
                rc=0
            else
                PROVIDER_RESPONSE="$NETCUP_ERR"
            fi
        fi
    else
        PROVIDER_RESPONSE="$NETCUP_ERR"
    fi
    netcup_logout
    return "$rc"
}

netcup_legacy_check() {
    local changes
    echo "netcup legacy API   zone: $NETCUP_ZONE   host: $NETCUP_HOST   customer: $NETCUP_CUSTOMER"
    if ! netcup_login; then
        echo "Login FAILED: $NETCUP_ERR"
        return 1
    fi
    echo "Login OK"
    if ! netcup_fetch_records; then
        echo "Reading zone FAILED: $NETCUP_ERR"
        echo "(Expected while $NETCUP_ZONE is not yet in this netcup account.)"
        netcup_logout
        return 1
    fi
    echo "Records in zone $NETCUP_ZONE:"
    jq -r '.[] | "  \(.hostname)\t\(.type)\t\(.destination)"' <<< "$NETCUP_RECORDS"
    changes=$(netcup_plan "$1" "$2")
    if [[ "$changes" == "[]" ]]; then
        echo "Nothing to change for A=${1:-keep} AAAA=${2:-keep}"
    else
        echo "An update would send:"
        netcup_describe "$changes"
    fi
    netcup_logout
}

# ---------------------------------------------------------------- netcup REST API (CloudDNS)

# netcup applies a changeset synchronously and may take 20-30 s, hence the long curl timeout below.
NETCUP_REST_BASE="${NETCUP_REST_BASE:-https://api.netcup.com/v1}"

# rest_call METHOD PATH [JSON_BODY] -> REST_RESP (body), REST_HTTP; REST_ERR / REST_CODE on failure.
# The bearer key goes to curl via stdin (-K -), never on the command line.
rest_call() {
    local out ok
    REST_RESP=""
    REST_HTTP=""
    REST_ERR=""
    REST_CODE=""
    local args=(--silent --show-error --max-time 120 -X "$1" -H 'Accept: application/json' -K - -w '\n%{http_code}')
    if [[ -n "${3:-}" ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$3")
    fi
    if ! out=$(printf 'header = "Authorization: Bearer %s"\n' "$(curl_cfg_escape "$NETCUP_TOKEN")" \
            | curl "${args[@]}" "$NETCUP_REST_BASE$2" 2>&1); then
        # (Without an answer, -w still appends "\n000": drop it, it is no HTTP status.)
        REST_ERR="$1 $2: ${out%$'\n'000}"
        return 1
    fi
    REST_HTTP="${out##*$'\n'}"
    REST_RESP="${out%$'\n'*}"
    ok=$(jq -r 'if type == "object" and .success == false then "no" else "yes" end' <<< "${REST_RESP:-null}" 2>/dev/null) || ok="no"
    if [[ ! "$REST_HTTP" =~ ^2 || "$ok" != "yes" ]]; then
        REST_CODE=$(jq -r '[.errors[]?.code // empty] | join(",")' <<< "$REST_RESP" 2>/dev/null)
        REST_ERR="$(jq -r '[.errors[]? | "\(.code // "") \(.message // "")"] | join("; ")' <<< "$REST_RESP" 2>/dev/null)"
        [[ -n "$REST_ERR" ]] || REST_ERR=$(head -c 300 <<< "$REST_RESP")
        REST_ERR="$1 $2: HTTP $REST_HTTP $REST_ERR"
        return 1
    fi
}

# Looks up the zone: NETCUP_DOMAIN_ID, NETCUP_DNS_MANAGED (true/false).
rest_find_domain() {
    NETCUP_DOMAIN_ID=""
    NETCUP_DNS_MANAGED=""
    if ! rest_call GET "/domain?fqdn=$NETCUP_ZONE"; then
        if [[ "$REST_CODE" == *resourceDoesNotExist* || "$REST_HTTP" == "404" ]]; then
            REST_ERR="domain $NETCUP_ZONE is not (yet) in this netcup account"
        fi
        return 1
    fi
    NETCUP_DOMAIN_ID=$(jq -r --arg z "$NETCUP_ZONE" '[.result[]? | select((.fqdn | ascii_downcase | rtrimstr(".")) == $z)][0].id // empty' <<< "$REST_RESP")
    NETCUP_DNS_MANAGED=$(jq -r --arg z "$NETCUP_ZONE" '[.result[]? | select((.fqdn | ascii_downcase | rtrimstr(".")) == $z)][0].isDnsManaged // false' <<< "$REST_RESP")
    if [[ -z "$NETCUP_DOMAIN_ID" ]]; then
        REST_ERR="domain $NETCUP_ZONE is not (yet) in this netcup account"
        return 1
    fi
}

# Reads the records of the zone's active revision into NETCUP_RECORDS (read-only, creates nothing).
rest_fetch_records() {
    local rev
    NETCUP_RECORDS="[]"
    rest_call GET "/domain/$NETCUP_DOMAIN_ID/dns/revision" || return 1
    rev=$(jq -r '[.result[]? | select(.state == "active")][0].identifier // empty' <<< "$REST_RESP")
    if [[ -z "$rev" ]]; then
        REST_ERR="no active DNS revision found for $NETCUP_ZONE"
        return 1
    fi
    rest_call GET "/domain/$NETCUP_DOMAIN_ID/dns/revision/$rev/record" || return 1
    NETCUP_RECORDS=$(jq -c '.result // []' <<< "$REST_RESP")
    if [[ "$NETCUP_RECORDS" == "[]" ]]; then
        REST_ERR="zone $NETCUP_ZONE returned no records at all — refusing to touch it"
        return 1
    fi
}

# Prints the changeset body that makes NETCUP_HOST have exactly one A (ipv4) and one AAAA (ipv6),
# or "{}" if nothing has to change. Empty ipv4 / ipv6 leaves that type alone. Only A/AAAA of
# that one name are ever deleted; every other record stays untouched.
rest_plan() {
    jq -c --arg host "$NETCUP_HOST" --arg v4 "$1" --arg v6 "$2" --argjson ttl "$NETCUP_TTL" '
        def isname: if $host == "@" then (.name == "@" or .name == "") else (.name | ascii_downcase) == $host end;
        [ ( if $v4 != "" then {type: "A", ip: $v4} else empty end ),
          ( if $v6 != "" then {type: "AAAA", ip: $v6} else empty end ) ] as $want
        | . as $recs
        | [ $want[] as $w
            | [ $recs[] | select(isname and .type == $w.type and (.immutable | not)) ] as $m
            | if ($m | length) == 1 and $m[0].rdata == $w.ip and (($m[0].ttl // $ttl) == $ttl) then empty
              else {
                create: [{name: $host, type: $w.type, rdata: $w.ip, ttl: $ttl}],
                delete: [ $m[] | {name: $host, type, rdata, ttl: (.ttl // $ttl)} ]
              } end
          ]
        | if length == 0 then {}
          else {autoCommit: true, strict: true, create: (map(.create[])), delete: (map(.delete[]))} end
    ' <<< "$NETCUP_RECORDS"
}

rest_describe() {
    jq -r '(.delete[]? | "  delete \(.name) \(.type) \(.rdata)"), (.create[]? | "  create \(.name) \(.type) -> \(.rdata) (ttl \(.ttl))")' <<< "$1"
}

netcup_rest_update() {
    local ipv4="$1" ipv6="$2" body
    say "Updating netcup (REST API) zone $NETCUP_ZONE host $NETCUP_HOST A=${ipv4:-keep} AAAA=${ipv6:-keep}"
    if [[ -z "$NETCUP_DOMAIN_ID" ]] && ! rest_find_domain; then
        PROVIDER_RESPONSE="$REST_ERR"
        return 1
    fi
    if ! rest_fetch_records; then
        PROVIDER_RESPONSE="$REST_ERR"
        return 1
    fi
    body=$(rest_plan "$ipv4" "$ipv6")
    if [[ "$body" == "{}" ]]; then
        PROVIDER_RESPONSE="nochg netcup-rest $NETCUP_HOST.$NETCUP_ZONE already ${ipv4:-} ${ipv6:-}"
        return 0
    fi
    rest_describe "$body"
    if ! rest_call POST "/domain/$NETCUP_DOMAIN_ID/changeset" "$body"; then
        PROVIDER_RESPONSE="$REST_ERR"
        return 1
    fi
    PROVIDER_RESPONSE="good netcup-rest $NETCUP_HOST.$NETCUP_ZONE ${ipv4:-} ${ipv6:-}"
}

netcup_rest_check() {
    local body
    echo "netcup REST API (CloudDNS)   zone: $NETCUP_ZONE   host: $NETCUP_HOST"
    if [[ -z "$NETCUP_DOMAIN_ID" ]] && ! rest_find_domain; then
        echo "Domain lookup FAILED: $REST_ERR"
        return 1
    fi
    echo "Domain found: id $NETCUP_DOMAIN_ID, isDnsManaged=$NETCUP_DNS_MANAGED"
    if ! rest_fetch_records; then
        echo "Reading records FAILED: $REST_ERR"
        return 1
    fi
    echo "Records in zone $NETCUP_ZONE:"
    jq -r '.[] | "  \(if .name == "" then "@" else .name end)\t\(.type)\t\(.rdata)\tttl=\(.ttl // "-")\(if .immutable then "  (immutable)" else "" end)"' <<< "$NETCUP_RECORDS"
    body=$(rest_plan "$1" "$2")
    if [[ "$body" == "{}" ]]; then
        echo "Nothing to change for A=${1:-keep} AAAA=${2:-keep}"
    else
        echo "An update would send:"
        rest_describe "$body"
    fi
}

# ---------------------------------------------------------------- netcup: pick the API

# Sets NETCUP_USE=rest|legacy. In auto mode the REST key is tried first.
netcup_select_api() {
    local note=""
    NETCUP_DOMAIN_ID=""
    case "$NETCUP_API" in
        rest)
            [[ -n "${NETCUP_TOKEN:-}" ]] || { NETCUP_SELECT_ERR="NETCUP_API=rest but no secret netcup-api-key"; return 1; }
            NETCUP_USE=rest
            return 0
            ;;
        legacy)
            netcup_legacy_complete || { NETCUP_SELECT_ERR="NETCUP_API=legacy but legacy credentials incomplete"; return 1; }
            NETCUP_USE=legacy
            return 0
            ;;
    esac
    if [[ -n "${NETCUP_TOKEN:-}" ]]; then
        if rest_find_domain; then
            if [[ "$NETCUP_DNS_MANAGED" == "true" ]]; then
                NETCUP_USE=rest
                return 0
            fi
            note="REST API: domain is on netcup's legacy DNS (isDnsManaged=false)"
        else
            # Only "the REST API confirms the domain is not managed there" may switch to the legacy
            # API. A rejected key, a timeout or a server error is reported as what it is.
            NETCUP_SELECT_ERR="REST API: $REST_ERR"
            return 1
        fi
    fi
    if netcup_legacy_complete; then
        NETCUP_USE=legacy
        [[ -n "$note" ]] && say "netcup: $note -> using legacy API"
        return 0
    fi
    NETCUP_SELECT_ERR="${note:-no REST key and no legacy credentials}"
    return 1
}

netcup_update() {
    REST_HTTP="" REST_CODE="" NETCUP_CODE=""
    if ! netcup_select_api; then
        PROVIDER_RESPONSE="netcup: $NETCUP_SELECT_ERR"
        netcup_classify_error
        return 1
    fi
    case "$NETCUP_USE" in
        rest) netcup_rest_update "$1" "$2" ;;
        legacy) netcup_legacy_update "$1" "$2" ;;
    esac || { netcup_classify_error; return 1; }
}

# Errors that retrying will not fix: key rejected, domain not in this account, legacy login
# rejected (4013 = validation error, e.g. wrong customer number / key / password).
netcup_classify_error() {
    if [[ "$REST_HTTP" =~ ^(401|403)$ || "$REST_CODE" == *authenticationError* \
        || "$REST_CODE" == *resourceDoesNotExist* || "$NETCUP_CODE" == 4013 \
        || "$PROVIDER_RESPONSE" == *"not (yet) in this netcup account"* ]]; then
        PROVIDER_ERROR_CLASS="permanent"
    fi
}

netcup_check() {
    echo "Provider: netcup   NETCUP_API=$NETCUP_API   REST key: $([[ -n "${NETCUP_TOKEN:-}" ]] && echo set || echo none)   legacy: $(netcup_legacy_complete && echo set || echo none)"
    if ! netcup_select_api; then
        echo "No usable netcup API: $NETCUP_SELECT_ERR"
        if [[ -n "${NETCUP_TOKEN:-}" ]]; then
            if [[ "$REST_CODE" == *authenticationError* ]]; then
                echo "-> The REST API key was REJECTED. Check the secret netcup-api-key."
            elif [[ "$REST_CODE" == *resourceDoesNotExist* || "$REST_HTTP" =~ ^(200|404)$ ]]; then
                echo "-> The REST API key works. The domain is just not at netcup yet — that is expected before the transfer."
            fi
        fi
        return 1
    fi
    echo "Using: $NETCUP_USE"
    case "$NETCUP_USE" in
        rest) netcup_rest_check "$1" "$2" ;;
        legacy) netcup_legacy_check "$1" "$2" ;;
    esac
}

