#!/bin/bash
# Runs the tools ddns-watch needs (ip, dig, curl, jq, flock) under the real sandbox of a unit file,
# via systemd-run, so a too strict hardening option is caught before a release. Needs root.
#   sudo tools/sandbox-check.sh [systemd/ddns-watch.service]
#   tools/sandbox-check.sh --user [unit]   without root, in your user manager (minus the options
#                                          only the system manager has: DynamicUser, User ...)
# Copyright (C) 2026 gitrys. SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

mode=()
skip='Type|ExecStart|Restart|RestartSec|ConfigurationDirectory|StateDirectory|StateDirectoryMode|RuntimeDirectory|RuntimeDirectoryMode'
if [[ "${1:-}" == --user ]]; then
    mode=(--user)
    skip="$skip|DynamicUser|User|RemoveIPC|CapabilityBoundingSet|AmbientCapabilities|ProtectKernelModules|ProtectKernelLogs|ProtectClock|ProtectHostname|ProtectControlGroups|ProtectKernelTunables|ProtectHome|ProtectSystem|PrivateTmp|DevicePolicy"
    shift
fi
unit="${1:-$(dirname "$0")/../systemd/ddns-watch.service}"
[[ -f "$unit" ]] || { echo "no such unit file: $unit" >&2; exit 2; }

# Sandbox options of the [Service] section; directories, restart and ExecStart are left out.
props=()
while IFS= read -r line; do
    props+=(-p "$line")
done < <(awk -v skip="^($skip)=" '
    /^\[/ { s = $0; next }
    s == "[Service]" && /^[A-Za-z]+=/ && $0 !~ skip' "$unit")

iface=$(ip -4 route show default | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
fail=0
check() { # check NAME COMMAND...: the command must exit 0 inside the sandbox
    local name="$1" out rc
    shift
    out=$(systemd-run "${mode[@]}" --quiet --wait --pipe --collect "${props[@]}" "$@" 2>&1)
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ok    %s\n' "$name"
    else
        printf '  FAIL  %s (rc=%s)\n%s\n' "$name" "$rc" "$(sed 's/^/        /' <<< "$out" | head -n 5)"
        fail=1
    fi
}

echo "Sandbox of $unit (${#props[@]} options / 2), interface ${iface:-?}:"
check "ip addr"            ip -br addr show dev "${iface:-lo}"
check "ip route"           ip -4 route show default
check "ip monitor (2 s)"   sh -c 'timeout 2 ip monitor address; [ $? -eq 124 ]'
check "dig"                dig +short +time=3 +tries=1 example.com A
check "curl https"         curl -s -o /dev/null --max-time 10 https://example.com
check "jq"                 sh -c 'echo "{\"a\":1}" | jq -e .a >/dev/null'
check "flock + mktemp"     sh -c 't=$(mktemp) && flock "$t" true && rm -f "$t"'
exit "$fail"
