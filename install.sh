#!/bin/bash
# ddns-watch installer.
#
#   curl -fsSL https://github.com/gitrys/ddns-watch/releases/latest/download/install.sh | sudo bash
#   sudo bash install.sh [--from ddns-watch-X.Y.Z.tar.gz] [--upgrade] [--no-setup] [--yes]
#
# Without --from it installs from the folder it is in (an unpacked release or a git checkout);
# piped from curl it downloads its own release, checks the SHA256 checksum (and the GitHub build
# attestation if the gh CLI is installed) and installs that.
#   --upgrade    keep the configuration, only replace program, plugins and units, restart
#   --no-setup   do not start "ddns-watch setup" at the end
#   --yes        no questions (install missing packages, remove an old installation's units)
#
# Installs: /usr/local/bin/ddns-watch, /usr/local/lib/ddns-watch/providers/, systemd units in
# /etc/systemd/system/, config folder /etc/ddns-watch/. Remove with: sudo ddns-watch uninstall
# https://github.com/gitrys/ddns-watch
# Copyright (C) 2026 gitrys. SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

VERSION="1.10.0-dev"   # set by the release workflow
REPO="gitrys/ddns-watch"
RELEASE_BASE="${DDNS_RELEASE_BASE:-https://github.com/$REPO/releases/download}"
PREFIX="${DDNS_PREFIX:-/usr/local}"
UNIT_DIR="${DDNS_UNIT_DIR:-/etc/systemd/system}"
CONFIG_DIR="${DDNS_CONFIG_DIR:-/etc/ddns-watch}"
MIN_SYSTEMD=250

FROM="" UPGRADE=0 SETUP=1 YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) FROM="${2:-}"; shift ;;
        --upgrade) UPGRADE=1; SETUP=0 ;;
        --no-setup) SETUP=0 ;;
        --yes|-y) YES=1 ;;
        -h|--help) sed -n '2,17p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
    shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# reload_systemd: "systemctl daemon-reload", announced first. It reruns all unit generators, and a
# network mount that does not answer (e.g. NFS "hard" to a sleeping NAS) can hold it for 90 s.
reload_systemd() {
    say "Reloading systemd (can take a while if a network mount does not answer) ..."
    systemctl daemon-reload
}

# Questions go to the terminal even when this script is piped into bash.
confirm() {
    [[ "$YES" -eq 1 ]] && return 0
    local a
    if [[ -r /dev/tty ]] && { exec 6</dev/tty; } 2>/dev/null; then
        printf '%s [y/N] ' "$1" >&2
        read -r -u 6 a || a=""
        exec 6<&-
        [[ "$a" == [yY] || "$a" == [yY][eE][sS] ]]
    else
        die "$1 -- no terminal to ask; run again with --yes"
    fi
}

TMP=""
cleanup() { [[ -n "$TMP" ]] && rm -rf -- "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------- checks

[[ "$EUID" -eq 0 || -n "${DDNS_TEST_ROOT:-}" ]] || die "please run as root: sudo bash install.sh"

v=$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 }') || true
v="${v%%[!0-9]*}"
[[ -n "$v" ]] || die "systemd not found. ddns-watch needs systemd $MIN_SYSTEMD or newer."
(( v >= MIN_SYSTEMD )) || die "systemd $v is too old. ddns-watch needs systemd $MIN_SYSTEMD or newer (e.g. Ubuntu 24.04, Debian 12)."
command -v systemd-creds >/dev/null 2>&1 || die "systemd-creds not found (part of systemd $MIN_SYSTEMD+)."

# Missing tools -> packages (Debian/Ubuntu names).
declare -A PKG=([curl]=curl [dig]=dnsutils [ip]=iproute2 [flock]=util-linux [jq]=jq [awk]=gawk
                [sed]=sed [sha256sum]=coreutils [timeout]=coreutils [tar]=tar)
missing=() pkgs=()
for t in "${!PKG[@]}"; do
    command -v "$t" >/dev/null 2>&1 || { missing+=("$t"); pkgs+=("${PKG[$t]}"); }
done
if [[ ${#missing[@]} -gt 0 ]]; then
    say "Missing tools: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
        confirm "Install the packages ${pkgs[*]} with apt-get?" || die "please install: ${pkgs[*]}"
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    else
        die "please install them with your package manager, then run this again"
    fi
fi

# ---------------------------------------------------------------- source files

verify_sums() { # verify_sums DIR FILE...: checks FILE(s) against DIR/SHA256SUMS
    local d="$1" f
    shift
    [[ -f "$d/SHA256SUMS" ]] || die "SHA256SUMS missing next to the download"
    for f in "$@"; do
        grep -E "  \*?$f\$" "$d/SHA256SUMS" > "$d/.sum" || die "$f is not listed in SHA256SUMS"
        (cd "$d" && sha256sum -c --quiet .sum) || die "checksum of $f does not match: download corrupted or tampered with"
    done
    say "Checksum OK."
}

attest() { # attest FILE: GitHub build provenance, if the gh CLI is available
    if command -v gh >/dev/null 2>&1; then
        gh attestation verify "$1" --repo "$REPO" >/dev/null 2>&1 \
            || die "GitHub attestation check failed for $(basename "$1"): not built by $REPO's release workflow"
        say "GitHub attestation OK (built by $REPO)."
    else
        say "Note: install the GitHub CLI (gh) to also verify the build attestation."
    fi
}

unpack() { # unpack TARBALL -> SRC
    TMP=$(mktemp -d)
    tar -xzf "$1" -C "$TMP" || die "cannot unpack $1"
    SRC=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'ddns-watch-*' | head -n 1)
    [[ -n "$SRC" && -f "$SRC/ddns-watch.sh" ]] || die "$1 is not a ddns-watch release"
}

# Piped into bash there is no script file, so no folder to install from.
HERE=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
fi
if [[ -n "$FROM" ]]; then
    [[ -f "$FROM" ]] || die "no such file: $FROM"
    if [[ -f "$(dirname "$FROM")/SHA256SUMS" ]]; then
        verify_sums "$(cd "$(dirname "$FROM")" && pwd)" "$(basename "$FROM")"
    else
        say "Note: no SHA256SUMS next to $FROM, checksum not verified."
    fi
    unpack "$FROM"
elif [[ -n "$HERE" && -f "$HERE/ddns-watch.sh" && -d "$HERE/providers" && -d "$HERE/systemd" ]]; then
    SRC="$HERE"
else
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "this installer has no release version; use --from or run it inside a checkout"
    TMP=$(mktemp -d)
    name="ddns-watch-$VERSION.tar.gz"
    say "Downloading ddns-watch $VERSION ..."
    curl -fsSL --max-time 120 -o "$TMP/$name" "$RELEASE_BASE/v$VERSION/$name" || die "download failed: $RELEASE_BASE/v$VERSION/$name"
    curl -fsSL --max-time 30 -o "$TMP/SHA256SUMS" "$RELEASE_BASE/v$VERSION/SHA256SUMS" || die "download of SHA256SUMS failed"
    verify_sums "$TMP" "$name"
    attest "$TMP/$name"
    tar -xzf "$TMP/$name" -C "$TMP" || die "cannot unpack $name"
    SRC="$TMP/ddns-watch-$VERSION"
    [[ -f "$SRC/ddns-watch.sh" ]] || die "$name is not a ddns-watch release"
fi
new_version=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$SRC/ddns-watch.sh" | head -n 1)

# ---------------------------------------------------------------- older installations

# The first versions ran from a folder in the home directory with units ddns-watch.service
# (same name, other ExecStart) and ddns-ipv4.{service,timer}. They would run in parallel.
old=()
[[ -f "$UNIT_DIR/ddns-ipv4.timer" || -f "$UNIT_DIR/ddns-ipv4.service" ]] && old+=(ddns-ipv4.timer ddns-ipv4.service)
if [[ -f "$UNIT_DIR/ddns-watch.service" ]] && ! grep -q "^ExecStart=$PREFIX/bin/ddns-watch watch\$" "$UNIT_DIR/ddns-watch.service"; then
    old+=(ddns-watch.service)
    say "Found an older installation: $(grep '^ExecStart=' "$UNIT_DIR/ddns-watch.service" || true)"
fi
if [[ ${#old[@]} -gt 0 ]]; then
    say "Its units (${old[*]}) would run alongside the new version."
    confirm "Stop and remove these old units? (Its folder, config and log are kept.)" \
        || die "please remove the old units first"
    systemctl disable --now "${old[@]}" >/dev/null 2>&1 || true
    for u in "${old[@]}"; do
        rm -f -- "$UNIT_DIR/$u"
    done
    reload_systemd || true
    say "Old units removed."
fi

# ---------------------------------------------------------------- install

say "Installing ddns-watch ${new_version:-?} to $PREFIX ..."
install -d -m 755 "$PREFIX/bin" "$PREFIX/lib/ddns-watch"
install -m 755 "$SRC/ddns-watch.sh" "$PREFIX/bin/ddns-watch"
rm -rf -- "${PREFIX:?}/lib/ddns-watch/providers"
install -d -m 755 "$PREFIX/lib/ddns-watch/providers"
install -m 644 "$SRC"/providers/*.sh "$PREFIX/lib/ddns-watch/providers/"
install -d -m 755 "$UNIT_DIR"
for u in ddns-watch.service ddns-watch-ipv4.service ddns-watch-ipv4.timer; do
    sed "s|/usr/local/bin/ddns-watch|$PREFIX/bin/ddns-watch|" "$SRC/systemd/$u" > "$UNIT_DIR/$u"
    chmod 644 "$UNIT_DIR/$u"
done
install -d -m 755 "$CONFIG_DIR"
install -d -m 700 "$CONFIG_DIR/credentials"
reload_systemd

# restart_and_verify: restarts the watcher if it was enabled and checks that it really runs.
# A silently dead updater would only be noticed at the next IP change.
restart_and_verify() {
    systemctl is-enabled --quiet ddns-watch.service 2>/dev/null || return 0
    say "Restarting ddns-watch.service ..."
    systemctl restart ddns-watch.service >/dev/null 2>&1 || true
    sleep "${DDNS_VERIFY_WAIT:-3}"
    if systemctl is-active --quiet ddns-watch.service 2>/dev/null; then
        say "ddns-watch.service is running."
        return 0
    fi
    printf 'ERROR: ddns-watch.service is not running after the update. Last log lines:\n' >&2
    journalctl -u ddns-watch.service -n 15 --no-pager -o cat 2>/dev/null | sed 's/^/    /' >&2
    printf 'Check: ddns-watch status / journalctl -u ddns-watch -n 50\n' >&2
    return 1
}

if [[ "$UPGRADE" -eq 1 ]]; then
    restart_and_verify || exit 1
    say "Upgraded to ${new_version:-?}. Status: ddns-watch status"
    exit 0
fi
say "Installed."
if [[ "$SETUP" -eq 1 ]]; then
    if [[ -f "$CONFIG_DIR/config" ]] && ! confirm "A configuration exists. Run the setup again?"; then
        restart_and_verify || exit 1
        say "Kept the existing configuration. Status: ddns-watch status"
        exit 0
    fi
    say
    cleanup          # exec skips the EXIT trap, so remove the download folder now
    TMP=""
    exec "$PREFIX/bin/ddns-watch" setup
fi
say "Next: sudo ddns-watch setup"
