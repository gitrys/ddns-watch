#!/bin/bash
# Runs ddns-watch.sh against tests/mock_api.py (Strato, netcup legacy, netcup REST).
# Needs: bash, python3, curl, jq, flock. No network access, no root, touches nothing outside tests/tmp.
# Config, secrets, state and locks live in per-case directories passed via DDNS_*_DIR.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TMP="$ROOT/tests/tmp"
PORT="${MOCK_PORT:-18799}"
MOCK="http://127.0.0.1:$PORT"
PASS=0
FAIL=0

export STRATO_URL="$MOCK/nic/update"
export NETCUP_ENDPOINT="$MOCK/legacy"
export NETCUP_REST_BASE="$MOCK/v1"
export DDNS_TEST_IPV4="203.0.113.7"
export DDNS_TEST_IPV6="2001:db8::7"
export DDNS_RELEASE_API="$MOCK/release/latest"
export DDNS_RELEASE_BASE="$MOCK/release"
export MOCK_RELEASE_DIR="$ROOT/tests/tmp/releases"

rm -rf "${TMP:?}"
mkdir -p "$TMP"
python3 -I "$ROOT/tests/mock_api.py" "$PORT" 2> "$TMP/mock.err" &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null' EXIT
for _ in $(seq 50); do curl -s "$MOCK/_state" >/dev/null && break; sleep 0.1; done

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/        /'; }
mock_reset() { curl -s -X POST -H 'Content-Type: application/json' -d "{\"mode\":\"${1:-normal}\"}" "$MOCK/_reset" >/dev/null; }
mock_state() { curl -s "$MOCK/_state" | jq -c "$1"; }

# new_case PROVIDER -> fresh config/secrets/state/runtime dirs in $D
new_case() {
    D="$TMP/case$((PASS + FAIL))"
    mkdir -p "$D/etc" "$D/creds" "$D/state" "$D/run"
    cat > "$D/etc/config" << EOF
# test config
PROVIDER="$1"
HOSTNAME='example.com'
IFACE=lo
NETCUP_CUSTOMER=12345
NETCUP_API = auto
EOF
    printf '%s' 'p"a\ss' > "$D/creds/strato-password"
    printf '%s\n' 'RESTTOKEN' > "$D/creds/netcup-api-key"
    printf '%s' 'LEGKEY' > "$D/creds/netcup-legacy-key"
    printf '%s' "LEG'PASS" > "$D/creds/netcup-legacy-password"
}

run() {
    OUT=$(DDNS_CONFIG_DIR="$D/etc" DDNS_CREDENTIALS_DIR="$D/creds" DDNS_STATE_DIR="$D/state" \
        DDNS_RUNTIME_DIR="$D/run" "$ROOT/ddns-watch.sh" "$@" 2>&1)
    RC=$?
    printf '%s\n' "$OUT" >> "$TMP/all-output.log"
}

expect() { # expect NAME CONDITION...
    local name="$1"
    shift
    if "$@"; then ok "$name"; else bad "$name" "rc=$RC output: $OUT"; fi
}
has() { [[ "$OUT" == *"$1"* ]]; }
rc_is() { [[ "$RC" == "$1" ]]; }
zone_has() { [[ "$(mock_state "[.rest[] | select(.name==\"$1\" and .type==\"$2\") | .rdata]")" == "$3" ]]; }

echo "== Strato"
mock_reset; new_case strato
run
expect "update sends both IPs, password with quote+backslash via stdin" has "good 203.0.113.7 2001:db8::7"
run
expect "second run: unchanged, no API call" has "unchanged IPv4=203.0.113.7"
expect "  ... and mock saw exactly one request" [ "$(mock_state '.log | length')" = 1 ]
expect "  state file written to state dir" [ -f "$D/state/last" ]
printf 'wrong' > "$D/creds/strato-password"
run --force
expect "wrong password -> error, rc 1" rc_is 1

echo "== netcup REST"
mock_reset; new_case netcup
run
expect "update via REST" has "good netcup-rest @.example.com"
expect "  A replaced" zone_has @ A '["203.0.113.7"]'
expect "  AAAA created" zone_has @ AAAA '["2001:db8::7"]'
expect "  CNAME untouched" zone_has www CNAME '["example.com."]'
expect "  NS untouched" zone_has @ NS '["ns1.example.net."]'
run --force
expect "force again -> nochg" has "nochg netcup-rest"
mock_reset dupe; run --force
expect "duplicate A records -> one left" zone_has @ A '["203.0.113.7"]'
mock_reset empty; run --force
expect "empty zone -> refuses to touch it" has "refusing to touch it"
sed -i "s/^NETCUP_CUSTOMER=.*/NETCUP_CUSTOMER=/" "$D/etc/config"   # REST only from here
mock_reset notfound; run check netcup
expect "check: key ok, domain not yet at netcup" has "The REST API key works"
printf 'WRONG' > "$D/creds/netcup-api-key"
mock_reset; run check netcup
expect "check: wrong key reported" has "REJECTED"

mock_reset; new_case netcup
printf '%s' 'R"E\S T$&!%' > "$D/creds/netcup-api-key"
run
expect "REST key with quote, backslash, space, \$&!% works (no escaping needed)" has "good netcup-rest"

echo "== netcup legacy fallback"
mock_reset legacy; new_case netcup
run
expect "isDnsManaged=false -> legacy API used" has "good netcup @.example.com"
expect "  legacy A updated" [ "$(mock_state '[.legacy[] | select(.hostname=="@" and .type=="A") | .destination]')" = '["203.0.113.7"]' ]

echo "== config robustness"
mock_reset; new_case nectcup
run
expect "typo in provider -> rc 1, clear error" has "unknown PROVIDER=nectcup"
expect "  no API call made" [ "$(mock_state '.log | length')" = 0 ]
new_case netcup; echo 'FOO=bar' >> "$D/etc/config"
run
expect "unknown setting -> rc 1" has "unknown setting FOO"
new_case netcup; echo "HOSTNAME=\$(touch $D/pwned)" >> "$D/etc/config"
run
expect "command substitution in config is not executed" [ ! -e "$D/pwned" ]
expect "  ... and rejected as hostname" has "not a valid domain name"
new_case netcup; echo 'just some text' >> "$D/etc/config"
run
expect "malformed line -> rc 1" has "expected KEY=value"
new_case netcup; rm -f "$D/creds/netcup-api-key" "$D/creds/netcup-legacy-key" "$D/creds/netcup-legacy-password"
run
expect "missing secrets -> clear error" has "needs the secret netcup-api-key"
new_case netcup
run --version
expect "--version" has "ddns-watch "
run bogus
expect "unknown command -> usage, rc 1" rc_is 1

echo "== providers"
mock_reset; new_case dyndns2
printf 'DYNDNS2_URL=%s/nic/update\nDYNDNS2_ALLOW_HTTP=yes\n' "$MOCK" >> "$D/etc/config"
printf '%s' 'p"a\ss' > "$D/creds/dyndns2-password"
run
expect "generic dyndns2 plugin updates (user defaults to hostname)" has "dyndns2: good 203.0.113.7"
new_case dyndns2
echo "DYNDNS2_URL=$MOCK/nic/update?x=1&y=2" >> "$D/etc/config"
run
expect "dyndns2: URL with parameters rejected" has "must be an http(s) URL without parameters"
new_case dyndns2
echo "DYNDNS2_URL=$MOCK/nic/update" >> "$D/etc/config"
run
expect "dyndns2: http:// refused without DYNDNS2_ALLOW_HTTP=yes" has "sends the password unencrypted"
mock_reset dyn500; new_case strato
run
expect "dyndns2: HTTP 500 with 'good' in the body counts as failure" eval '[[ "$RC" == 1 && "$OUT" == *"HTTP 500"* ]]'
new_case strato
run providers
expect "providers lists all built-in plugins" has "netcup"
expect "  ... strato" has "strato"
expect "  ... dyndns2" has "dyndns2"
expect "  ... but not the template" eval '[[ "$OUT" != *_template* ]]'
mock_reset; new_case strato
run
expect "settings of other providers (NETCUP_*) are ignored" has "strato: good"
new_case netcup; echo 'NETCUP_FOO=1' >> "$D/etc/config"
run
expect "unknown setting of the active provider -> error" has "unknown setting NETCUP_FOO"
new_case mine
mkdir -p "$D/etc/providers.d"
sed 's/^PROVIDER_NAME="example"/PROVIDER_NAME="mine"/' "$ROOT/providers/_template.sh" > "$D/etc/providers.d/mine.sh"
run
expect "local plugin not owned by root is refused" has "must be owned by root"

echo "== encrypted secrets (systemd-creds stub)"
# Stubs: "encryption" = base64 with the name in front; a file containing BROKEN cannot be decrypted.
STUB="$TMP/stubbin"
mkdir -p "$STUB"
cat > "$STUB/systemd-creds" << 'EOF'
#!/bin/bash
cmd="$1"; shift
name=""; args=()
for a in "$@"; do case "$a" in --name=*) name="${a#--name=}" ;; --with-key=*) ;; *) args+=("$a") ;; esac; done
case "$cmd" in
    encrypt) { printf 'STUBENC:%s:' "$name"; base64 -w0; } > "${args[1]}" ;;
    decrypt) c=$(< "${args[0]}"); [[ "$c" == "STUBENC:$name:"* ]] || exit 1; base64 -d <<< "${c#STUBENC:"$name":}" ;;
    has-tpm2) exit 1 ;;
esac
EOF
cat > "$STUB/systemctl" << 'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then echo "systemd ${STUB_SYSTEMD_VERSION:-255} (255.4)"; exit 0; fi
echo "$*" >> "$STUB_SYSTEMCTL_LOG"
# "show -p Result": result of the last oneshot run (STUB_RESULT, default success)
[[ "$1" == show && "$*" == *Result* ]] && echo "${STUB_RESULT:-success}"
# "is-active": STUB_ACTIVE=no simulates a service that did not come up
[[ "$1" == is-active && "${STUB_ACTIVE:-yes}" != yes ]] && exit 3
exit 0
EOF
cat > "$STUB/gh" << 'EOF'
#!/bin/bash
# "gh attestation verify": test builds have no real attestation; STUB_GH_FAIL=1 simulates a bad one.
[[ "$1 $2" == "attestation verify" ]] || exit 2
[[ -z "${STUB_GH_FAIL:-}" ]]
EOF
chmod +x "$STUB/systemd-creds" "$STUB/systemctl" "$STUB/gh"

# run_store ARGS: like run, but secrets come from the encrypted store (no credentials directory)
run_store() {
    OUT=$(PATH="$STUB:$PATH" DDNS_TEST_ROOT=1 DDNS_CONFIG_DIR="$D/etc" DDNS_CRED_STORE="$D/store" \
        DDNS_UNIT_DIR="$D/units" DDNS_STATE_DIR="$D/state" DDNS_RUNTIME_DIR="$D/run" DDNS_PREFIX="$D/prefix" \
        STUB_SYSTEMCTL_LOG="$D/systemctl.log" "$ROOT/ddns-watch.sh" "$@" 2>&1)
    RC=$?
    printf '%s\n' "$OUT" >> "$TMP/all-output.log"
}

mock_reset; new_case netcup
run_store set-secret netcup-api-key <<< 'RESTTOKEN'
expect "set-secret stores the key encrypted" [ -f "$D/store/netcup-api-key" ]
expect "  ... not in plain text" eval '! grep -q RESTTOKEN "$D/store/netcup-api-key"'
expect "  ... store is mode 700, file 600" eval '[[ "$(stat -c %a "$D/store")" == 700 && "$(stat -c %a "$D/store/netcup-api-key")" == 600 ]]'
expect "  ... drop-in for the watcher" grep -q "^LoadCredentialEncrypted=netcup-api-key:$D/store/netcup-api-key$" "$D/units/ddns-watch.service.d/credentials.conf"
expect "  ... drop-in for the IPv4 timer service" [ -f "$D/units/ddns-watch-ipv4.service.d/credentials.conf" ]
expect "  ... daemon-reload + try-restart" grep -q "try-restart ddns-watch.service" "$D/systemctl.log"
expect "  ... reminds to keep a copy" has "password manager"
run_store
expect "run as root decrypts from the store" has "good netcup-rest"
run_store secrets
expect "secrets: ok" has "ok (encrypted)"
expect "  ... optional legacy secrets: not stored" has "not stored"
echo BROKEN > "$D/store/netcup-api-key"
run_store secrets
expect "secrets: undecryptable reported with fix" has "CANNOT DECRYPT"
run_store --force
expect "run: undecryptable -> clear hint" has "set-secret netcup-api-key"
run_store set-secret no-such-secret <<< 'x'
expect "set-secret: unknown name rejected" has "unknown secret no-such-secret"
run_store set-secret netcup-api-key <<< ''
expect "set-secret: empty value -> nothing changed" has "nothing changed"
OUT=$(PATH="$STUB:$PATH" DDNS_CONFIG_DIR="$D/etc" DDNS_CRED_STORE="$D/store" "$ROOT/ddns-watch.sh" set-secret netcup-api-key <<< 'x' 2>&1); RC=$?
expect "set-secret: needs root" has "must run as root"
OUT=$(PATH="$STUB:$PATH" STUB_SYSTEMD_VERSION=249 DDNS_TEST_ROOT=1 DDNS_CONFIG_DIR="$D/etc" DDNS_CRED_STORE="$D/store" \
    DDNS_UNIT_DIR="$D/units" "$ROOT/ddns-watch.sh" set-secret netcup-api-key <<< 'x' 2>&1); RC=$?
expect "set-secret: systemd < 250 refused" has "too old"

echo "== IPv4 sources"
# Stubs for dig and ip; DDNS_TEST_IPV4 is unset so the real source logic runs.
SRC="$TMP/srcbin"
mkdir -p "$SRC"
cat > "$SRC/dig" << 'EOF'
#!/bin/bash
case "$*" in
    *whoami.cloudflare*) [[ -n "${STUB_CF:-}" ]] && echo "\"$STUB_CF\"" ;;
    *myip.opendns.com*) [[ -n "${STUB_OPENDNS:-}" ]] && echo "$STUB_OPENDNS" ;;
esac
exit 0
EOF
cat > "$SRC/ip" << 'EOF'
#!/bin/bash
# -6 addr: contents of $STUB_IP6_FILE. monitor: two events; before the second one the address
# file is replaced by $STUB_IP6_FILE.next (the first event changes nothing we publish).
# -br link: $STUB_LINKS. -6 route: $STUB_ROUTE6. -6 addr of a device: $STUB_IP6_FILE.<dev> if it
# exists, else $STUB_IP6_FILE.
case "$*" in
    "-br link"*) printf '%b' "${STUB_LINKS:-}" ;;
    "-6 route show default"*) printf '%b' "${STUB_ROUTE6:-}" ;;
    "-4 addr show dev"*) printf '%b' "${STUB_IP4:-}" ;;
    "-6 addr show dev"*)
        if [[ -f "${STUB_IP6_FILE:-}.$5" ]]; then cat "$STUB_IP6_FILE.$5"
        elif [[ -f "${STUB_IP6_FILE:-}" ]]; then cat "$STUB_IP6_FILE"; fi ;;
    *monitor*)
        echo "event 1"; sleep 1
        [[ -f "${STUB_IP6_FILE:-}.next" ]] && cp "$STUB_IP6_FILE.next" "$STUB_IP6_FILE"
        echo "event 2"; sleep 1 ;;
esac
exit 0
EOF
chmod +x "$SRC/dig" "$SRC/ip"
# shellcheck disable=SC2120  # called with and without arguments
run_src() {
    OUT=$(env -u DDNS_TEST_IPV4 PATH="$SRC:$PATH" DDNS_CONFIG_DIR="$D/etc" DDNS_CREDENTIALS_DIR="$D/creds" \
        DDNS_STATE_DIR="$D/state" DDNS_RUNTIME_DIR="$D/run" "$ROOT/ddns-watch.sh" "$@" 2>&1)
    RC=$?
    printf '%s\n' "$OUT" >> "$TMP/all-output.log"
}

mock_reset; new_case netcup
printf 'IPV4_SOURCE=upnp\nUPNP_URL=%s/upnp/control\n' "$MOCK" >> "$D/etc/config"
run_src
expect "upnp: router's IPv4 published" zone_has @ A '["81.2.69.142"]'
mock_reset upnp-cgnat; new_case netcup
printf 'IPV4_SOURCE=upnp\nUPNP_URL=%s/upnp/control\n' "$MOCK" >> "$D/etc/config"
run_src
expect "upnp: CGNAT address (100.64/10) is not published" zone_has @ A '["192.0.2.1"]'
expect "  ... with a hint" has "not public (DS-Lite/CGNAT?)"
expect "  ... AAAA still updated" zone_has @ AAAA '["2001:db8::7"]'
mock_reset upnp-down; new_case netcup
printf 'IPV4_SOURCE=upnp\nUPNP_URL=%s/upnp/control\n' "$MOCK" >> "$D/etc/config"
STUB_CF=81.2.69.199 run_src
expect "upnp down, no fallback: A left alone" zone_has @ A '["192.0.2.1"]'
mock_reset upnp-down; new_case netcup
printf 'IPV4_SOURCE=upnp\nUPNP_URL=%s/upnp/control\nIPV4_FALLBACK=dns\n' "$MOCK" >> "$D/etc/config"
STUB_CF=81.2.69.199 run_src
expect "upnp down + IPV4_FALLBACK=dns: DNS answer used" zone_has @ A '["81.2.69.199"]'
mock_reset; new_case netcup
echo 'IPV4_SOURCE=dns' >> "$D/etc/config"
STUB_OPENDNS=81.2.69.155 run_src
expect "dns: Cloudflare silent -> OpenDNS used" zone_has @ A '["81.2.69.155"]'
mock_reset; new_case netcup
echo 'IPV4_SOURCE=interface' >> "$D/etc/config"
STUB_IP4='    inet 192.168.1.5/24 scope global eth0\n    inet 81.2.69.177/32 scope global eth0\n' run_src
expect "interface: first public address used, private skipped" zone_has @ A '["81.2.69.177"]'
mock_reset; new_case netcup
printf '#!/bin/sh\necho 81.2.69.188\n' > "$D/myip"; chmod +x "$D/myip"
printf 'IPV4_SOURCE=command\nIPV4_COMMAND=%s\n' "$D/myip" >> "$D/etc/config"
run_src
expect "command: output of IPV4_COMMAND used" zone_has @ A '["81.2.69.188"]'
mock_reset; new_case netcup
echo 'RECORDS=AAAA' >> "$D/etc/config"
run
expect "RECORDS=AAAA: A record left alone" zone_has @ A '["192.0.2.1"]'
expect "  ... AAAA set" zone_has @ AAAA '["2001:db8::7"]'
mock_reset; new_case netcup
echo 'RECORDS=A' >> "$D/etc/config"
run
expect "RECORDS=A: no AAAA created" zone_has @ AAAA '[]'
new_case netcup; echo 'IPV4_SOURCE=fritz' >> "$D/etc/config"
run
expect "unknown IPV4_SOURCE rejected" has "must be interface, upnp, dns or command"

echo "== errors, retries, notifications, heartbeat"
fail_set() { sed -i "s/^$1=.*/$1=$2/" "$D/state/failure"; }   # fail_set KEY VALUE: move time forward
mock_reset; new_case strato
printf 'NOTIFY_URL=%s/notify\nHEARTBEAT_URL=%s/heartbeat\n' "$MOCK" "$MOCK" >> "$D/etc/config"
printf '%s' 'NTFYTOKEN' > "$D/creds/notify-token"
printf 'wrong' > "$D/creds/strato-password"
run
expect "badauth -> permanent error" eval 'grep -q "^CLASS=permanent" "$D/state/failure"'
expect "  ... notified at once, with priority high and token" \
    [ "$(mock_state '[.notify[] | select(.title=="DNS update rejected" and .priority=="high" and .auth=="Bearer NTFYTOKEN")] | length')" = 1 ]
expect "  ... no heartbeat while failing" [ "$(mock_state '.heartbeat')" = 0 ]
N=$(mock_state '.log | length')
run
expect "permanent error: no retry with unchanged config/secrets" has "not retrying"
expect "  ... provider not called again" [ "$(mock_state '.log | length')" = "$N" ]
expect "  ... no second notification" [ "$(mock_state '.notify | length')" = 1 ]
printf '%s' 'p"a\ss' > "$D/creds/strato-password"
run
expect "secret fixed -> tried again and good" has "strato: good"
expect "  ... failure cleared" [ ! -e "$D/state/failure" ]
expect "  ... recovery notified" [ "$(mock_state '[.notify[] | select(.title=="DNS update works again")] | length')" = 1 ]
expect "  ... heartbeat sent" [ "$(mock_state '.heartbeat')" = 1 ]
run
expect "heartbeat at most once a minute" [ "$(mock_state '.heartbeat')" = 1 ]

mock_reset down; new_case netcup
echo "NOTIFY_URL=$MOCK/notify" >> "$D/etc/config"
run
expect "provider down -> temporary error" eval 'grep -q "^CLASS=temporary" "$D/state/failure"'
expect "  ... no notification yet (NOTIFY_AFTER 15 min)" [ "$(mock_state '.notify | length')" = 0 ]
N=$(mock_state '.log | length')
run
expect "temporary: waits for the retry time" has "waiting to retry"
expect "  ... provider not called" [ "$(mock_state '.log | length')" = "$N" ]
fail_set NEXT 0; fail_set SINCE "$(( $(date +%s) - 3600 ))"
run
expect "retry when due" has "retry 2"
expect "  ... still failing for > 15 min -> notified" [ "$(mock_state '[.notify[] | select(.title=="DNS update failing")] | length')" = 1 ]
expect "  ... backoff grows" eval '(( $(sed -n "s/^NEXT=//p" "$D/state/failure") - $(date +%s) > 100 ))'
mock_reset; fail_set NEXT 0
run
expect "provider back -> update done" has "good netcup-rest"
expect "  ... recovery notified" [ "$(mock_state '[.notify[] | select(.title=="DNS update works again")] | length')" = 1 ]
sed -i "s/^CALLED=.*/CALLED=$(( $(date +%s) - 90000 ))/" "$D/state/last"
run
expect "once a day the record is verified even if unchanged" has "periodic verification"
sed -i -e "s/^CALLED=.*/CALLED=$(( $(date +%s) - 90000 ))/" -e "s/^IPV4=.*/IPV4=203.0.113.99/" "$D/state/last"
run
expect "  ... a change at verification time is logged as a change" eval '! grep -q "periodic verification" <<< "$OUT" && grep -q "updating netcup" <<< "$OUT"'
run --force
expect "run --force always calls the provider" has "(forced)"
JOURNAL_STREAM=1:1 run
expect "journal: 'unchanged' is debug (dropped by the IPv4 unit's LogLevelMax=notice)" has "<7>unchanged IPv4="
sed -i "s/^IPV4=.*/IPV4=203.0.113.99/" "$D/state/last"
JOURNAL_STREAM=1:1 run
expect "  ... update and provider answer are notice" eval 'grep -q "^<5>updating netcup " <<< "$OUT" && grep -q "^<5>netcup: " <<< "$OUT"'
run
expect "  ... no prefix outside the journal" eval '[[ "$OUT" == unchanged* ]]'
expect "  ... IPv4 unit keeps only notice and above" grep -qx "LogLevelMax=notice" "$ROOT/systemd/ddns-watch-ipv4.service"

echo "== test-notify, Gotify"
mock_reset; new_case netcup
run_store test-notify
expect "test-notify without URLs -> explains" has "neither NOTIFY_URL nor HEARTBEAT_URL"
printf 'NOTIFY_URL=%s/notify\nHEARTBEAT_URL=%s/heartbeat\n' "$MOCK" "$MOCK" >> "$D/etc/config"
run_store set-secret notify-token <<< 'NTFYTOKEN'
run_store test-notify
expect "test-notify (ntfy): message with bearer token" [ "$(mock_state '[.notify[] | select(.title=="ddns-watch test" and .auth=="Bearer NTFYTOKEN")] | length')" = 1 ]
expect "  ... heartbeat pinged" eval '[[ "$OUT" == *"heartbeat ping: OK"* ]] && [ "$(mock_state .heartbeat)" = 1 ]'
mock_reset; new_case netcup
echo "NOTIFY_URL=$MOCK/gotify/message" >> "$D/etc/config"
run_store set-secret notify-token <<< 'GOTKEY'
run_store test-notify
expect "Gotify detected by /message: JSON with X-Gotify-Key" eval '[[ "$OUT" == *"(gotify)"* && "$RC" == 0 ]]'
expect "  ... title, message, priority 5" [ "$(mock_state '[.gotify[] | select(.title=="ddns-watch test" and .priority==5 and (.message | test("notifications work")))] | length')" = 1 ]
run_store set-secret notify-token <<< 'WRONG'
run_store test-notify
expect "Gotify with wrong token -> test-notify fails, rc 1" eval '[[ "$OUT" == *"could not send"* && "$RC" == 1 ]]'
mock_reset; new_case strato
printf 'NOTIFY_URL=%s/gotify/message\n' "$MOCK" >> "$D/etc/config"
printf '%s' 'GOTKEY' > "$D/creds/notify-token"
printf 'wrong' > "$D/creds/strato-password"
run
expect "permanent error via Gotify -> priority 8" [ "$(mock_state '[.gotify[] | select(.title=="DNS update rejected" and .priority==8)] | length')" = 1 ]
new_case netcup; echo 'NOTIFY_TYPE=teams' >> "$D/etc/config"
run
expect "unknown NOTIFY_TYPE rejected" has "must be auto, ntfy, gotify, discord or slack"

echo "== Discord, Slack, URLs as secrets"
detect() { ( source "$ROOT/ddns-watch.sh"; NOTIFY_TYPE=auto NOTIFY_URL="$1"; notify_type ); }
expect "type detection: Discord webhook" [ "$(detect https://discord.com/api/webhooks/1/abc)" = discord ]
expect "type detection: Slack webhook" [ "$(detect https://hooks.slack.com/services/T0/B0/x)" = slack ]
expect "type detection: Gotify /message" [ "$(detect https://gotify.example.com/message)" = gotify ]
expect "type detection: anything else = ntfy" [ "$(detect https://ntfy.sh/topic)" = ntfy ]
mock_reset; new_case netcup
printf 'NOTIFY_URL=secret\nNOTIFY_TYPE=discord\nHEARTBEAT_URL=secret\n' >> "$D/etc/config"
run_store set-secret notify-url <<< "$MOCK/discord/api/webhooks/123/SECRETHOOK"
run_store set-secret heartbeat-url <<< "$MOCK/heartbeat"
run_store test-notify
expect "Discord (URL from secret): JSON content with bold title" [ "$(mock_state '[.discord[] | select(.username=="ddns-watch" and (.content | startswith("**ddns-watch test**")))] | length')" = 1 ]
expect "  ... heartbeat URL from secret" eval '[[ "$OUT" == *"heartbeat ping: OK"* ]] && [ "$(mock_state .heartbeat)" = 1 ]'
expect "  ... secret URLs listed by 'secrets'" eval 'run_store secrets; [[ "$OUT" == *notify-url*"ok (encrypted)"* && "$OUT" == *heartbeat-url* ]]'
run_store status
expect "  ... status does not show the secret URL" eval '[[ "$OUT" == *"URL stored encrypted"* && "$OUT" != *SECRETHOOK* ]]'
mock_reset; new_case strato
printf 'NOTIFY_URL=%s/discord/api/webhooks/123/SECRETHOOK\nNOTIFY_TYPE=discord\n' "$MOCK" >> "$D/etc/config"
printf 'wrong' > "$D/creds/strato-password"
run
expect "Discord: rejected update gets a :warning:" [ "$(mock_state '[.discord[] | select(.content | startswith(":warning: **DNS update rejected**"))] | length')" = 1 ]
mock_reset; new_case netcup
printf 'NOTIFY_URL=secret\nNOTIFY_TYPE=slack\n' >> "$D/etc/config"
run_store set-secret notify-url <<< "$MOCK/slack/services/T0/B0/SECRETHOOK"
run_store test-notify
expect "Slack: JSON text with bold title" [ "$(mock_state '[.slack[] | select(.text | startswith("*ddns-watch test*"))] | length')" = 1 ]
new_case netcup; printf 'NOTIFY_URL=secret\n' >> "$D/etc/config"
run_store test-notify
expect "NOTIFY_URL=secret without the secret -> clear message" has "secret notify-url missing"

echo "== IPv6 selection and watcher filter"
run_v6() {
    OUT=$(env -u DDNS_TEST_IPV6 PATH="$SRC:$PATH" STUB_IP6_FILE="$D/ip6" DDNS_DEBOUNCE=0.2 \
        DDNS_CONFIG_DIR="$D/etc" DDNS_CREDENTIALS_DIR="$D/creds" \
        DDNS_STATE_DIR="$D/state" DDNS_RUNTIME_DIR="$D/run" timeout 60 "$ROOT/ddns-watch.sh" "$@" 2>&1)
    RC=$?
    printf '%s\n' "$OUT" >> "$TMP/all-output.log"
}
V6_ADDRS='    inet6 2a03:4000:1::aaaa:1234/64 scope global temporary dynamic
    inet6 2a03:4000:1::5c1e:9b2:77a0:1/64 scope global dynamic mngtmpaddr
    inet6 2a03:4000:1::67c:16ff:fedf:a200/64 scope global dynamic mngtmpaddr
    inet6 fd00::67c:16ff:fedf:a200/64 scope global dynamic'
mock_reset; new_case netcup
printf '%s\n' "$V6_ADDRS" > "$D/ip6"
run_v6
expect "several stable IPv6: EUI-64 one chosen, temporary/ULA ignored" zone_has @ AAAA '["2a03:4000:1::67c:16ff:fedf:a200"]'
mock_reset; new_case netcup
printf '%s\n' "$V6_ADDRS" > "$D/ip6"
echo 'IPV6_SUFFIX=::5c1e:9b2:77a0:1' >> "$D/etc/config"
run_v6
expect "IPV6_SUFFIX picks that interface ID" zone_has @ AAAA '["2a03:4000:1::5c1e:9b2:77a0:1"]'
new_case netcup
echo 'IPV6_SUFFIX=2001:db8::1' >> "$D/etc/config"
run_v6
expect "IPV6_SUFFIX must be an interface ID" has "must be an interface ID"
mock_reset; new_case netcup
printf '%s\n' '    inet6 2a03:4000:1::aaaa:1234/64 scope global temporary dynamic' > "$D/ip6"
run_v6
expect "only a temporary IPv6 -> no AAAA" zone_has @ AAAA '[]'
mock_reset; new_case netcup
printf '%s\n' "$V6_ADDRS" > "$D/ip6"
printf '%s\n' '    inet6 2a03:4000:2::67c:16ff:fedf:a200/64 scope global dynamic mngtmpaddr' > "$D/ip6.next"
run_v6 watch
expect "watch: event without change -> no update run" eval '[[ "$(grep -c "address changed" <<< "$OUT")" == 1 ]]'
expect "  ... prefix change -> update" zone_has @ AAAA '["2a03:4000:2::67c:16ff:fedf:a200"]'
expect "  ... log line lists the address without a trailing blank" has "address changed (2a03:4000:2::67c:16ff:fedf:a200), running"

echo "== guided setup"
# run_setup INPUT_LINES...: answers the prompts in order (DDNS_SETUP_INPUT replaces the terminal)
run_setup() {
    printf '%s\n' "$@" > "$D/answers"
    OUT=$(env -u DDNS_TEST_IPV4 PATH="$STUB:$SRC:$PATH" DDNS_TEST_ROOT=1 DDNS_SETUP_INPUT="$D/answers" \
        DDNS_CONFIG_DIR="$D/etc" DDNS_CRED_STORE="$D/store" DDNS_UNIT_DIR="$D/units" \
        DDNS_STATE_DIR="$D/state" DDNS_RUNTIME_DIR="$D/run" STUB_SYSTEMCTL_LOG="$D/systemctl.log" \
        STUB_CF=81.2.69.109 timeout 60 "$ROOT/ddns-watch.sh" setup 2>&1)
    RC=$?
    printf '%s\n' "$OUT" >> "$TMP/all-output.log"
}
conf_has() { grep -qx "$1" "$D/etc/config"; }

mock_reset; new_case netcup; rm -f "$D/etc/config"
run_setup netcup example.com RESTTOKEN lo "" "$MOCK/notify" "" "" "" ""
[[ -n "${SHOW_SETUP:-}" ]] && printf '%s\n' "$OUT"   # SHOW_SETUP=1 tests/run.sh: see the dialog
expect "setup: fresh install completes" eval '[[ "$OUT" == *"Config written"* && "$OUT" == *"Services started"* ]]'
expect "  ... login tested against the provider" has "Login OK"
expect "  ... records shown compactly (A, CNAMEs in one line)" eval '[[ "$OUT" == *"Current records for example.com"* && "$OUT" == *"CNAME  www"* ]]'
expect "  ... progress bar and summary box" eval '[[ "$OUT" == *"Step 6 of 6"* && "$OUT" == *"Summary"* ]]'
expect "  ... first check ok -> 'ddns-watch is running.'" has "ddns-watch is running."
expect "  ... notification type detected, test sent" eval '[[ "$OUT" == *"Test notification sent"* ]] && [ "$(mock_state "[.notify[] | select(.title==\"ddns-watch test\")] | length")" = 1 ]'
expect "  ... config written" eval 'conf_has PROVIDER=netcup && conf_has HOSTNAME=example.com && conf_has IFACE=lo'
expect "  ... IPv4 source suggested: dns (no router answer)" eval 'conf_has IPV4_SOURCE=dns && conf_has IPV4_INTERVAL=300'
expect "  ... notification URL stored encrypted, config says secret" eval 'conf_has NOTIFY_URL=secret && [ -f "$D/store/notify-url" ] && ! grep -q "127.0.0.1" "$D/store/notify-url"'
expect "  ... key stored encrypted" [ -f "$D/store/netcup-api-key" ]
expect "  ... timer interval drop-in" grep -q "OnUnitActiveSec=300s" "$D/units/ddns-watch-ipv4.timer.d/interval.conf"
expect "  ... services enabled" grep -q "enable --now ddns-watch.service ddns-watch-ipv4.timer" "$D/systemctl.log"
expect "  ... config loads" eval 'DDNS_CONFIG_DIR="$D/etc" DDNS_CREDENTIALS_DIR="$D/creds" DDNS_STATE_DIR="$D/state" DDNS_RUNTIME_DIR="$D/run" "$ROOT/ddns-watch.sh" run >/dev/null 2>&1'

mock_reset; new_case netcup; rm -f "$D/etc/config"
run_setup netcup example.com WRONGKEY a
expect "setup: wrong key -> test fails, abort leaves no config" eval '[[ "$OUT" == *"did not pass"* && ! -e "$D/etc/config" ]]'

mock_reset upnp-cgnat; new_case netcup
printf 'UPNP_URL=%s/upnp/control\nNETCUP_ZONE=example.com\n' "$MOCK" >> "$D/etc/config"
run_store set-secret netcup-api-key <<< 'RESTTOKEN'
STUB_RESULT=exit-code run_setup "" "" "" "" "" "" "" ""
expect "setup: re-run keeps answers (Enter everywhere)" has "Config written"
expect "  ... first check failed -> says so, with what happens next" eval '[[ "$OUT" == *"First update failed"* && "$OUT" == *"retries automatically"* ]]'
expect "  ... router with CGNAT address -> IPv6 only suggested" conf_has RECORDS=AAAA
expect "  ... settings not asked are kept" eval 'conf_has NETCUP_ZONE=example.com && conf_has "UPNP_URL=$MOCK/upnp/control"'

echo "== setup: interface discoverer"
LINKS='lo               UNKNOWN 00:00:00:00:00:00\neth0             UP      52:54:00:12:34:56\ndocker0          DOWN    02:42:ac:11:00:01\nveth12ab@if3     UP      aa:bb:cc:dd:ee:ff\nbr-5f2a          UP      02:42:00:00:00:01\nwlan0            DOWN    52:54:00:65:43:21\n'
ROUTE6='default via fe80::1 dev eth0 proto ra metric 100\n'
mock_reset; new_case netcup; rm -f "$D/etc/config"
printf '%s\n' "$V6_ADDRS" > "$D/ip6.eth0"
printf '%s\n' '    inet6 2a03:4000:1::aaaa:1234/64 scope global temporary dynamic' > "$D/ip6.wlan0"
DDNS_TEST_IPV6='' STUB_LINKS="$LINKS" STUB_ROUTE6="$ROUTE6" STUB_IP6_FILE="$D/ip6" \
    run_setup netcup example.com RESTTOKEN "" "" "" "" "" ""
[[ -n "${SHOW_SETUP:-}" ]] && sed -n '/Step 4 of 6/,/Step 6 of 6/p' <<< "$OUT"
expect "discoverer: table shows the IPv6 that would be published" has "2a03:4000:1::67c:16ff:fedf:a200"
expect "  ... marks the default route" eval '[[ "$(grep "eth0" <<< "$OUT" | head -n 1)" == *"default route"* ]]'
expect "  ... adapter without stable IPv6 says so" eval '[[ "$(grep " wlan0 " <<< "$OUT")" == *"no stable public IPv6"* ]]'
expect "  ... hides lo, docker, veth and bridges" eval '! grep -Eq "^ +[0-9]+ +(lo|docker0|veth12ab|br-5f2a) " <<< "$OUT"'
expect "  ... recommends eth0, Enter takes it" eval '[[ "$(grep -E "^ +1 +eth0 " <<< "$OUT")" == *recommended* ]] && conf_has IFACE=eth0'
mock_reset; new_case netcup; rm -f "$D/etc/config"
printf '%s\n' "$V6_ADDRS" > "$D/ip6.eth0"
DDNS_TEST_IPV6='' STUB_LINKS="$LINKS" STUB_ROUTE6="$ROUTE6" STUB_IP6_FILE="$D/ip6" \
    run_setup netcup example.com RESTTOKEN 2 y "" "" "" "" ""
expect "discoverer: choose by number (2 = wlan0)" conf_has IFACE=wlan0
mock_reset; new_case netcup; rm -f "$D/etc/config"
DDNS_TEST_IPV6='' STUB_LINKS="$LINKS" STUB_ROUTE6="$ROUTE6" STUB_IP6_FILE="$D/none" \
    run_setup netcup example.com RESTTOKEN "" n "" "" "" "" ""
expect "discoverer: warns when no interface has a public IPv6" has "No interface has a stable public IPv6"

echo "== status / uninstall"
mock_reset; new_case netcup
run_store set-secret netcup-api-key <<< 'RESTTOKEN'
run_store status
expect "status before first update: never" has "Last good: never"
run_store
run_store status
expect "status shows last good update with time" has "Last good: IPv4=203.0.113.7  IPv6=2001:db8::7  via netcup  at 20"
expect "  ... services listed" has "ddns-watch-ipv4.timer"
expect "  ... secret ok" has "ok (encrypted)"
mkdir -p "$D/prefix/bin" "$D/prefix/lib/ddns-watch/providers"
touch "$D/prefix/bin/ddns-watch" "$D/prefix/lib/ddns-watch/providers/netcup.sh" "$D/units/ddns-watch.service"
run_store uninstall < /dev/null
expect "uninstall without terminal needs --yes" has "add --yes"
expect "  ... nothing removed" [ -f "$D/prefix/bin/ddns-watch" ]
run_store uninstall --yes
expect "uninstall removes the program" [ ! -e "$D/prefix/bin/ddns-watch" ]
expect "  ... and the plugins" [ ! -e "$D/prefix/lib/ddns-watch" ]
expect "  ... and units + drop-ins" eval '[[ ! -e "$D/units/ddns-watch.service" && ! -e "$D/units/ddns-watch.service.d" ]]'
expect "  ... keeps config and secrets" eval '[[ -f "$D/etc/config" && -f "$D/store/netcup-api-key" ]]'
expect "  ... disables the services" grep -q "disable --now ddns-watch.service ddns-watch-ipv4.timer" "$D/systemctl.log"
expect "  ... never touches this checkout" [ -f "$ROOT/ddns-watch.sh" ]
run_store uninstall --purge --yes
expect "uninstall --purge removes config dir" [ ! -e "$D/etc" ]
expect "  ... and state" [ ! -e "$D/state" ]

echo "== installer, releases, update"
# inst ARGS: install.sh from this checkout into a fake root ($D/prefix, $D/units, $D/etc)
inst_env() {
    env PATH="$STUB:$PATH" DDNS_TEST_ROOT=1 DDNS_PREFIX="$D/prefix" DDNS_UNIT_DIR="$D/units" \
        DDNS_CONFIG_DIR="$D/etc" DDNS_CRED_STORE="$D/etc/credentials" DDNS_STATE_DIR="$D/state" \
        STUB_SYSTEMCTL_LOG="$D/systemctl.log" DDNS_VERIFY_WAIT=0 "$@"
}
inst() { OUT=$(inst_env bash "$ROOT/install.sh" "$@" 2>&1); RC=$?; printf '%s\n' "$OUT" >> "$TMP/all-output.log"; }

new_case netcup; rm -rf "${D:?}/etc"
mkdir -p "$D/units"
printf '[Service]\nExecStart=/home/me/dyndnsrefined/dyndnsrefined.sh watch\n' > "$D/units/ddns-watch.service"
printf '[Timer]\n' > "$D/units/ddns-ipv4.timer"
inst --no-setup --yes
expect "install from checkout" has "Installed."
expect "  ... program" [ -x "$D/prefix/bin/ddns-watch" ]
expect "  ... plugins" [ -f "$D/prefix/lib/ddns-watch/providers/netcup.sh" ]
expect "  ... units point to the installed program" grep -qx "ExecStart=$D/prefix/bin/ddns-watch watch" "$D/units/ddns-watch.service"
expect "  ... credentials folder is 700" [ "$(stat -c %a "$D/etc/credentials")" = 700 ]
expect "  ... old installation's units removed" eval '[[ ! -e "$D/units/ddns-ipv4.timer" ]] && grep -q "disable --now" "$D/systemctl.log"'
OUT=$(inst_env "$D/prefix/bin/ddns-watch" providers 2>&1)
expect "  ... installed program finds its plugins" has "netcup"

REL="$MOCK_RELEASE_DIR"
"$ROOT/tools/build-release.sh" 9.9.9 "$REL/v9.9.9" >/dev/null
"$ROOT/tools/build-release.sh" 9.9.10 "$REL/v9.9.10" >/dev/null
expect "release build: tarball, installer, checksums" eval '[[ -f "$REL/v9.9.9/ddns-watch-9.9.9.tar.gz" && -f "$REL/v9.9.9/install.sh" && -f "$REL/v9.9.9/SHA256SUMS" ]]'
expect "  ... version stamped" grep -q '^VERSION="9.9.9"' "$REL/v9.9.9/install.sh"

new_case netcup
inst --from "$REL/v9.9.9/ddns-watch-9.9.9.tar.gz" --no-setup --yes
expect "install --from release tarball (checksum checked)" has "Checksum OK."
OUT=$(inst_env "$D/prefix/bin/ddns-watch" --version 2>&1)
expect "  ... installed version 9.9.9" has "ddns-watch 9.9.9"
mkdir -p "$D/bad"; cp "$REL/v9.9.9/ddns-watch-9.9.9.tar.gz" "$D/bad/"
sed 's/^[0-9a-f]\{8\}/00000000/' "$REL/v9.9.9/SHA256SUMS" > "$D/bad/SHA256SUMS"
inst --from "$D/bad/ddns-watch-9.9.9.tar.gz" --no-setup --yes
expect "tampered checksum -> refused" has "does not match"

new_case netcup
OUT=$(inst_env bash -s -- --no-setup --yes < "$REL/v9.9.9/install.sh" 2>&1); RC=$?
expect "piped install (curl | bash) downloads + verifies its release" eval '[[ "$OUT" == *"Checksum OK."* && -x "$D/prefix/bin/ddns-watch" ]]'
expect "  ... and the attestation (gh present)" has "GitHub attestation OK"
OUT=$(STUB_GH_FAIL=1 inst_env bash -s -- --no-setup --yes < "$REL/v9.9.9/install.sh" 2>&1); RC=$?
expect "failed attestation -> refused" has "attestation check failed"
mock_reset normal 2>/dev/null; curl -s -X POST -H 'Content-Type: application/json' -d '{"release":"9.9.10"}' "$MOCK/_reset" >/dev/null
OUT=$(inst_env "$D/prefix/bin/ddns-watch" update --yes 2>&1); RC=$?
expect "update: newer release installed" eval '[[ "$OUT" == *"Upgraded to 9.9.10"* ]]'
OUT=$(inst_env "$D/prefix/bin/ddns-watch" --version 2>&1)
expect "  ... now 9.9.10" has "ddns-watch 9.9.10"
OUT=$(inst_env "$D/prefix/bin/ddns-watch" update --yes 2>&1)
expect "update: already up to date" has "is up to date"
mock_reset

new_case netcup
cat >> "$D/etc/config" << 'EOF'
NETCUP_TTL=600        # comment after a value
NETCUP_ZONE="example.com" # quoted, then comment
EOF
run --force
expect "config: comments after values are ignored" has "good netcup-rest"

echo "== review fixes (state changes, filters, setup, install)"
nonpub() { ( source "$ROOT/ddns-watch.sh"; is_nonpublic_ipv4 "$1" ); }
expect "IPv4 filter: documentation nets are not public" eval 'nonpub 192.0.2.5 && nonpub 198.51.100.5 && nonpub 203.0.113.5 && nonpub 198.18.0.1 && nonpub 192.0.0.8'
expect "  ... normal public addresses are" eval '! nonpub 81.2.69.142 && ! nonpub 1.1.1.1'
mock_reset; new_case netcup
printf '%s\n' '    inet6 2a03:4000:1::67c:16ff:fedf:a200/64 scope global tentative dynamic' \
    '    inet6 2a03:4000:1::67c:16ff:fedf:a201/64 scope global dadfailed tentative' \
    '    inet6 2001:db8:1::67c:16ff:fedf:a200/64 scope global dynamic' \
    '    inet6 2a03:4000:1::1234/64 scope global dynamic mngtmpaddr' > "$D/ip6"
run_v6
expect "IPv6: tentative, dadfailed and 2001:db8::/32 are skipped" zone_has @ AAAA '["2a03:4000:1::1234"]'

mock_reset; new_case netcup
run
echo 'NETCUP_TTL=600' >> "$D/etc/config"
run
expect "changed provider setting (TTL) forces an update although the IPs are the same" has "DNS settings changed"
expect "  ... and netcup gets the new TTL" [ "$(mock_state '[.rest[] | select(.name=="@" and .type=="A") | .ttl]')" = '[600]' ]
run
expect "  ... next run: unchanged again" has "unchanged"
mock_reset; new_case strato
run
echo 'STRATO_USER=example.com' >> "$D/etc/config"
run
expect "changed provider setting (strato) forces an update" has "DNS settings changed"

mock_reset; new_case netcup; rm -f "$D/etc/config"
run_setup netcup example.com RESTTOKEN lo "" "" "" n
expect "setup cancelled at the summary: no secret stored" eval '[[ "$OUT" == *"Nothing was changed"* && ! -e "$D/store/netcup-api-key" && ! -e "$D/etc/config" ]]'
mock_reset; new_case netcup; rm -f "$D/etc/config"
run_setup netcup example.com WRONGKEY a
expect "setup aborted after a failed login: no secret stored" [ ! -e "$D/store/netcup-api-key" ]
mock_reset; new_case strato; rm -f "$D/etc/config"
run_setup strato example.com "" 'p"a\ss' lo "" "" "" ""
expect "setup with strato: does not claim 'Login OK'" eval '[[ "$OUT" == *"Login not checked"* && "$OUT" != *"Login OK"* ]]'

mock_reset; new_case netcup
run_store set-secret netcup-api-key <<< 'RESTTOKEN'
run_store set-secret strato-password <<< 'old-strato-pass'
expect "drop-in: active provider's key is loaded" grep -q '^LoadCredentialEncrypted=netcup-api-key:' "$D/units/ddns-watch.service.d/credentials.conf"
expect "  ... other providers' keys are not given to the service" eval '! grep -q strato-password "$D/units/ddns-watch.service.d/credentials.conf"'

mock_reset; new_case netcup
printf '%s\n' "$V6_ADDRS" > "$D/ip6"
( sleep 1.2; echo 'IPV6_SUFFIX=::5c1e:9b2:77a0:1' >> "$D/etc/config" ) &
CHANGER=$!
DDNS_WATCH_TICK=0.3 run_v6 watch
wait "$CHANGER"   # only this job: a plain "wait" would also wait for the mock server
expect "watcher restarts itself when a watched setting changes" has "configuration changed"
expect "  ... and then uses it" zone_has @ AAAA '["2a03:4000:1::5c1e:9b2:77a0:1"]'

new_case netcup; rm -rf "${D:?}/etc"
inst --no-setup --yes
STUB_ACTIVE=no inst --upgrade --yes
expect "upgrade: service not running afterwards -> error, rc 1" eval '[[ "$RC" == 1 && "$OUT" == *"is not running after the update"* ]]'
inst --upgrade --yes
expect "upgrade: running service is confirmed" has "ddns-watch.service is running"

echo "== second review fixes"
# B: the login test sees settings that the setup does not ask again (here NETCUP_API=rest)
mock_reset legacy; new_case netcup
sed -i -e 's/^NETCUP_API.*/NETCUP_API=rest/' -e '/^NETCUP_CUSTOMER=/d' "$D/etc/config"
run_store set-secret netcup-api-key <<< 'RESTTOKEN'
run_setup "" "" "" "" "" "" "" ""
expect "B: setup login test uses the merged config (NETCUP_API=rest kept)" eval '[[ "$OUT" == *"Login OK"* && "$OUT" != *"did not pass"* ]]'
# C: timer drop-in replaces the interval list and the timer is restarted
mock_reset; new_case netcup; rm -f "$D/etc/config"
run_setup netcup example.com RESTTOKEN lo "" "" "" ""
expect "C: timer drop-in clears the list first" eval 'grep -qx "OnUnitActiveSec=" "$D/units/ddns-watch-ipv4.timer.d/interval.conf" && grep -qx "OnBootSec=2min" "$D/units/ddns-watch-ipv4.timer.d/interval.conf"'
expect "  ... and the timer is restarted" grep -q "restart ddns-watch-ipv4.timer" "$D/systemctl.log"
# F: no address at all -> temporary error, notified later, retried at once when an address is back
mock_reset; new_case netcup
echo "NOTIFY_URL=$MOCK/notify" >> "$D/etc/config"
DDNS_TEST_IPV4=none DDNS_TEST_IPV6=none run
expect "F: no usable address -> temporary error recorded" eval 'grep -q "^CLASS=temporary" "$D/state/failure" && grep -q "no usable" "$D/state/failure"'
fail_set SINCE "$(( $(date +%s) - 3600 ))"
DDNS_TEST_IPV4=none DDNS_TEST_IPV6=none run
expect "  ... long outage -> notified" [ "$(mock_state '[.notify[] | select(.title=="DNS update failing")] | length')" = 1 ]
run
expect "  ... address back -> updated at once, no waiting" eval '[[ "$OUT" == *"good netcup-rest"* && "$OUT" != *"waiting to retry"* && ! -e "$D/state/failure" ]]'
# H: leading zeros
mock_reset; new_case netcup
printf 'NOTIFY_URL=%s/notify\nNOTIFY_AFTER=08\nNETCUP_TTL=0300\n' "$MOCK" >> "$D/etc/config"
run
expect "H: NETCUP_TTL=0300 works (sent as 300)" has "good netcup-rest"
DDNS_TEST_IPV4=none DDNS_TEST_IPV6=none run
fail_set SINCE "$(( $(date +%s) - 3600 ))"
DDNS_TEST_IPV4=none DDNS_TEST_IPV6=none run
expect "  ... NOTIFY_AFTER=08 does not break the arithmetic" eval '[[ "$OUT" != *"value too great"* ]] && [ "$(mock_state "[.notify[]] | length")" = 1 ]'
new_case netcup; echo 'NETCUP_TTL=5' >> "$D/etc/config"
run
expect "  ... out-of-range values are rejected" has "between 60 and 86400"
# J: state cannot be saved
mock_reset; new_case netcup
run    # creates the lock file and a first state
chmod 500 "$D/state"   # lock file still writable, but no new file can be created
run --force
chmod 700 "$D/state"
expect "J: DNS updated but state not saved -> error, rc 1" eval '[[ "$RC" == 1 && "$OUT" == *"could not be saved"* && "$OUT" == *"netcup-rest @.example.com"* ]]'
# I: a rejected REST key is reported, no silent switch to the legacy API
mock_reset; new_case netcup
printf 'WRONG' > "$D/creds/netcup-api-key"
run --force
expect "I: wrong REST key -> REST error, legacy API not tried" eval '[[ "$RC" == 1 && "$OUT" == *"REST API"* && "$OUT" != *"using legacy API"* ]] && ! mock_state ".log[]" | grep -q legacy'
# A: several interface addresses with a DNS fallback configured
mock_reset; new_case netcup
printf 'IPV4_SOURCE=interface\nIPV4_FALLBACK=dns\n' >> "$D/etc/config"
STUB_CF=81.2.69.199 STUB_IP4='    inet 81.2.69.142/32 scope global eth0\n    inet 81.2.69.143/32 scope global eth0\n' run_src
expect "A: first public interface address used, not the DNS fallback" zone_has @ A '["81.2.69.142"]'
mock_reset; new_case netcup
printf 'IPV4_SOURCE=interface\nIPV4_FALLBACK=dns\n' >> "$D/etc/config"
STUB_CF=81.2.69.199 STUB_IP4='    inet 192.168.1.50/24 scope global eth0\n' run_src
expect "  ... only a private address on the interface -> DNS fallback used" zone_has @ A '["81.2.69.199"]'
# G: secret not handed to the service
mock_reset; new_case netcup
run_store set-secret netcup-api-key <<< 'RESTTOKEN'
run_store set-secret strato-password <<< 'p"a\ss'
sed -i 's/^PROVIDER=.*/PROVIDER=strato/' "$D/etc/config"
run_store status
expect "G: status says the new provider's secret is not given to the service" has "NOT given to the service"
mkdir -p "$D/svc-creds"
OUT=$(CREDENTIALS_DIRECTORY="$D/svc-creds" DDNS_CONFIG_DIR="$D/etc" DDNS_STATE_DIR="$D/state" DDNS_RUNTIME_DIR="$D/run" \
    timeout 30 "$ROOT/ddns-watch.sh" run 2>&1); RC=$?
expect "  ... and the service explains what to do" has "the service was not given this secret"

echo "== plugin interface"
plugin_lint() ( # plugin_lint NAME: source the core, load the plugin, check the rules from CONTRIBUTING.md
    # shellcheck source=/dev/null
    source "$ROOT/ddns-watch.sh"
    load_provider "$1" || exit 1
    local p k
    p="${1^^}"; p="${p//-/_}_"
    [[ "$PROVIDER_TIER" == core || "$PROVIDER_TIER" == community ]] || { echo "bad PROVIDER_TIER"; exit 1; }
    [[ -n "$PROVIDER_MAINTAINER" && -n "$PROVIDER_DESCRIPTION" ]] || { echo "maintainer/description missing"; exit 1; }
    for k in $PROVIDER_SETTINGS; do
        [[ "$k" == "$p"* ]] || { echo "setting $k must start with $p"; exit 1; }
        [[ -n "${PROVIDER_HELP[$k]:-}" ]] || { echo "no help text for $k"; exit 1; }
    done
    for k in $PROVIDER_SECRETS; do
        [[ "$k" =~ ^[a-z0-9-]+$ && "$k" == "$1"* ]] || { echo "secret $k must start with $1"; exit 1; }
        [[ -n "${PROVIDER_HELP[$k]:-}" ]] || { echo "no help text for $k"; exit 1; }
    done
)
for f in "$ROOT"/providers/[a-z0-9]*.sh; do
    n="$(basename "$f" .sh)"
    OUT=$(plugin_lint "$n" 2>&1); RC=$?
    expect "plugin $n follows the rules" rc_is 0
done

echo "== secrets"
LEAK=$(grep -nE "RESTTOKEN|LEG'PASS|LEGKEY|p\"a|NTFYTOKEN|GOTKEY|SECRETHOOK" "$TMP/all-output.log" || true)
expect "no secret in any output" [ -z "$LEAK" ]

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
