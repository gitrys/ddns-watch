# shellcheck shell=bash
# ddns-watch provider plugin: Strato DynDNS (dyndns2 with Strato's update URL).
# Copyright (C) 2026 gitrys. SPDX-License-Identifier: GPL-3.0-or-later

provider_use dyndns2

PROVIDER_NAME="strato"
PROVIDER_TIER="core"
PROVIDER_MAINTAINER="gitrys"
PROVIDER_DESCRIPTION="Strato DynDNS"
PROVIDER_SETTINGS="STRATO_USER"
PROVIDER_SECRETS="strato-password"
PROVIDER_HELP=(
    [STRATO_USER]="Strato DynDNS user name. Usually the domain itself (default: HOSTNAME)."
    [strato-password]="The DynDNS password set in the Strato customer login (domain settings -> DynDNS)."
)

STRATO_URL="${STRATO_URL:-https://dyndns.strato.com/nic/update}"

provider_config() {
    STRATO_USER=$(cfg STRATO_USER "$DDNS_HOSTNAME")
}

provider_secrets() {
    need_secret STRATO_PASS strato-password
}

provider_update() {
    dyndns2_send "$STRATO_URL" "$STRATO_USER" "$STRATO_PASS" "$1" "$2"
}

provider_check() {
    dyndns2_check "strato" "$STRATO_USER" "$1" "$2"
}
