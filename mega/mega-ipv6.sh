#!/bin/sh
set -e

usage() {
    cat 1>&2 <<EOF
Usage: $(basename "$0") <mega url>

Downloads files from mega with a different, random IP per file.

By default, this script looks up IP addresses from the 'he-ipv6' interface, but
a different one can be chosen with the MEGA_INTERFACE environment variable.

All addresses in the prefix of the interface must route to it, and it should be
able to open connections from any of them.

Supported URL formats:
  - https://mega.nz/file/<id>#<key>
  - https://mega.nz/folder/<id>#<key>
  - https://mega.nz/folder/<id>#<key>/file/<file id>

Currently, this script only supports using an interface with an IPv6 /48 or /64 block.
EOF
}

check_deps() {
    fail=0
    for dep in "$@"; do
        cmd="$(echo "$dep" | cut -d: -f1)"
        pkg="$(echo "$dep" | cut -d: -f2-)"
        if ! command -v "$cmd" > /dev/null 2>&1; then
            fail=1;
            echo "Missing dependency '$cmd' from package '$pkg'" 1>&2;
        fi
    done
    [ "$fail" = "0" ] || exit 1;
}

check_deps "megadl:megatools (https://megatools.megous.com)"

if [ -z "$__internal_prefix" -o -z "$__internal_parts" ]; then
    check_deps "jq:jq" "ip:iproute2"
    
    interface=${MEGA_INTERFACE:-he-ipv6}
    if ! ip address show dev "$interface" >/dev/null 2>&1; then
        echo "Unable to find interface '$interface'" 1>&2;
        exit 1;
    fi
    
    jq_query=".[] | select(.ifname == \"$interface\") | .addr_info[] | select(.family == \"inet6\") | select(.scope == \"global\")"
    interface_info="$(ip -j -6 address show dev "$interface" | jq "$jq_query")"

    if [ -z "$interface_info" ]; then
        echo "No routable IPv6 blocks assigned to interface '$interface'" 1>&2;
        exit 1;
    fi

    base_address="$(echo "$interface_info" | jq .local --raw-output)"
    prefix_len="$(echo "$interface_info" | jq .prefixlen --raw-output)"

    if [ "$prefix_len" = "48" ]; then
        prefix="$(echo "$base_address" | cut -d: -f1-3)"
        parts=5
    elif [ "$prefix_len" = "64" ]; then
        prefix="$(echo "$base_address" | cut -d: -f1-4)"
        parts=4
    else
        echo "Unsupported prefix length $prefix_len" 1>&2;
        exit 1;
    fi
    export __internal_prefix="$prefix";
    export __internal_parts="$parts";
else
    prefix="$__internal_prefix";
    parts="$__internal_parts";
fi

FOLDER_PATTERN="^https?://mega.nz/folder/[a-z0-9]+#[a-z0-9]+$"
FILE_PATTERN="^https?://mega.nz/file/[a-z0-9]+#[a-z0-9]+$"
FILE_IN_FOLDER_PATTERN="^https?://mega.nz/folder/[a-z0-9]+#[a-z0-9]+/file/[a-z0-9]+$"

log() {
    echo "[$(basename $0)] $@";
}

rand_part() {
    head -c 2 /dev/urandom | xxd -ps;
}

rand_ip() {
    printf "%s" "$prefix";
    n=0
    while [ "$n" -lt "$parts" ]; do
        n=$((n + 1))
        printf ":%s" "$(rand_part)";
    done
}

download() {
    addr="$(rand_ip)";
    log "Downloading $1 with IP '$addr'";
    # for testing
    [ ! -z "$DRY_RUN" ] && return 0;
    megadl "--netif=$addr" "$1";
}

matches() {
    echo "$target" | grep -iP "$1" > /dev/null && echo 1 || echo 0;
}

if [ $# -eq 0 ]; then
    usage;
    exit 1;
fi

if [ "$1" = "__internal_folder_download" ]; then
    download "$2/file/$3";
    exit 0;
fi
target="$1"

if [ "$(matches "$FOLDER_PATTERN")" = "1" ]; then
    log "Matched folder, using a different IP per file";
    check_deps \
        "mega-login:MEGAcmd (https://github.com/meganz/MEGAcmd)" \
        "mega-ls:MEGAcmd (https://github.com/meganz/MEGAcmd)" \
        "mega-quit:MEGAcmd (https://github.com/meganz/MEGAcmd)";
    mega-login "$target";
    mega-ls --show-handles | grep -oP "<H:\K(\S+)(?=>)" | xargs -n 1 -i "$0" "__internal_folder_download" "$target" {};
    mega-quit;
elif [ "$(matches "$FILE_PATTERN")" = "1" ]; then
    log "Matched file";
    download "$target";
elif [ "$(matches "$FILE_IN_FOLDER_PATTERN")" = "1" ]; then
    log "Matched file in a folder";
    download "$target";
else
    echo "Unknown url '$target'" 1>&2;
    usage;
    exit 1;
fi

