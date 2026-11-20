#!/bin/bash
# Builds a release into OUTDIR: ddns-watch-X.Y.Z.tar.gz, install.sh and SHA256SUMS.
# Used by .github/workflows/release.yml and by the tests.
#   tools/build-release.sh X.Y.Z OUTDIR
# Copyright (C) 2026 gitrys. SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ver="${1:-}"
out="${2:-}"
if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || -z "$out" ]]; then
    echo "usage: $0 X.Y.Z OUTDIR" >&2
    exit 1
fi
root="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
d="ddns-watch-$ver"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT

mkdir -p "$stage/$d" "$out"
for f in ddns-watch.sh install.sh providers systemd LICENSE README.md CHANGELOG.md CONTRIBUTING.md config.example; do
    cp -r "$root/$f" "$stage/$d/"
done
sed -i "s/^VERSION=\"[^\"]*\"/VERSION=\"$ver\"/" "$stage/$d/ddns-watch.sh" "$stage/$d/install.sh"
grep -q "^VERSION=\"$ver\"" "$stage/$d/ddns-watch.sh" || { echo "could not set the version" >&2; exit 1; }
chmod 755 "$stage/$d/ddns-watch.sh" "$stage/$d/install.sh"
tar -C "$stage" --owner=0 --group=0 --numeric-owner --sort=name -czf "$out/$d.tar.gz" "$d"
cp "$stage/$d/install.sh" "$out/install.sh"
(cd "$out" && sha256sum "$d.tar.gz" install.sh > SHA256SUMS)
echo "built $out/$d.tar.gz"
