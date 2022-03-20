#!/bin/sh
set -e

usage() {
    cat 1>&2 <<EOF
Usage: $(basename "$0") <mega url>

Downloads files from mega with a different, random IP per file.

By default, this script attempts to find an interface with a suitable IPv6 block
(a /64 or bigger subnet with global scope), picking the biggest block in case
multiple are available. A specific interface can be chosen with the MEGA_INTERFACE
environment variable.

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

check_deps "megadl:megatools (https://megatools.megous.com, download from https://megatools.megous.com/builds/experimental)" \
    "jq:jq" \
    "ip:iproute2";

if [ ! -z "$MEGA_INTERFACE" ]; then
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
else
    interface_info="$(ip -j -6 address | jq '.[].addr_info[] | select(.family == "inet6") | select(.scope == "global")' | jq -s 'select(.[].prefixlen <= 64) | sort_by(.prefixlen)[0]')"
    if [ -z "$interface_info" ]; then
        echo "Unable to find a suitable network interface" 1>&2;
        exit 1;
    fi
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

echo "Using block $base_address/$prefix_len"

ID="[-a-z0-9]+"
FOLDER_PATTERN="^https?://mega.nz/folder/$ID#$ID$"
FILE_PATTERN="^https?://mega.nz/file/$ID#$ID$"
FOLDER_IN_FOLDER_PATTERN="^https?://mega.nz/folder/$ID#$ID/folder/\K($ID)$"
FILE_IN_FOLDER_PATTERN="^https?://mega.nz/folder/$ID#$ID/file/$ID$"

log() {
    echo "[$(basename $0)] $@" 1>&2;
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

download_file() {
    addr="$(rand_ip)";
    url="$1"
    shift
    log "Downloading $url with IP '$addr'";
    # for testing
    [ ! -z "$DRY_RUN" ] && return 0;
    megadl "--netif=$addr" "$url" "$@";
}

matches() {
    echo "$target" | grep -iP "$1" > /dev/null && echo 1 || echo 0;
}

parse_megals_files() {
    folder=
    while read line; do
        if [ -z "$line" ]; then
            [ -z "$folder" ] && echo "Unexpected empty line, should have only one between folders" 1>&2 && exit 1;
            folder=""
        elif echo "$line" | grep -qP "^\/.+\:$"; then
            folder="$(echo "$line" | grep -oP "^/\K(.+)(?=:$)")"
        elif echo "$line" | grep -qP "^\-[-e][-pt][-si]\s"; then
            [ -z "$folder" ] && echo "Should have been inside a folder" 1>&2 && exit 1;
            # example file line
            # ----    1    1416686 08Sep2021 02:37:04 H:3X5xQKwC AI_Dottovu.mp3
            #   1     2       3        4        5          6           7

            # take everything starting from 7th column, preserving original whitespace
            path="$folder/$(echo "$line" | perl -lane 'print "@F[6..$#F]"')"
            id="$(echo "$line" | awk '{ print $6 }' | grep -oP "^H:\K(.+)$")"
            echo "$path";
            echo "$id";
        elif echo "$line" | grep -qP "^[dribx][-e][-pt][-si]\s"; then
            : # this is a folder/root/inbox/rubbish/unsupported entry, ignore it
        elif echo "$line" | grep -qP "^FLAGS\s+VERS\s+SIZE\s+DATE\s+HANDLE\s+NAME$"; then
            : # this is the first line naming the fields, ignore it
        else
            echo "Unable to parse line '$line'" 1>&2;
            exit 1;
        fi
    done
}

parse_megals_files_from_folder() {
    target_folder_id="$1"
    target_folder=
    folder=
    # see above function for explanations
    while read line; do
        if [ -z "$line" ]; then
            [ -z "$folder" ] && echo "Unexpected empty line, should have only one between folders" 1>&2 && exit 1;
            folder="";
        elif echo "$line" | grep -qP "^\/.+\:$"; then
            folder="$(echo "$line" | grep -oP "^/\K(.+)(?=:$)")"
        elif echo "$line" | grep -qP "^d[-e][-pt][-si]\s"; then
            [ -z "$folder" ] && echo "Should have been inside a folder" 1>&2 && exit 1;
            path="$folder/$(echo "$line" | perl -lane 'print "@F[6..$#F]"')"
            id="$(echo "$line" | awk '{ print $6 }' | grep -oP "^H:\K(.+)$")"
            if [ "$id" = "$target_folder_id" ]; then
                log "Found target folder: '$path' ($id)"
                target_folder="$path"
            fi
        elif echo "$line" | grep -qP "^\-[-e][-pt][-si]\s"; then
            # if folder doesn't start with target_folder, do nothing
            [ -z "$target_folder" -o "$folder" = "${folder#$target_folder}" ] && continue;
            path="$folder/$(echo "$line" | perl -lane 'print "@F[6..$#F]"')"
            id="$(echo "$line" | awk '{ print $6 }' | grep -oP "^H:\K(.+)$")"
            echo "$path";
            echo "$id";
        elif echo "$line" | grep -qP "^[ribx][-e][-pt][-si]\s"; then
            : # this is a root/inbox/rubbish/unsupported entry, ignore it
        elif echo "$line" | grep -qP "^FLAGS\s+VERS\s+SIZE\s+DATE\s+HANDLE\s+NAME$"; then
            : # this is the first line naming the fields, ignore it
        else
            echo "Unable to parse line '$line'" 1>&2;
            exit 1;
        fi
    done
}

if [ $# -eq 0 ]; then
    usage;
    exit 1;
fi

target="$1"

download_folder() {
    parser="$1";
    shift;
    [ -z "$parser" ] && echo "Usage: download_folder <parser> [parser arguments]" && exit 1;

    check_deps \
        "mega-login:MEGAcmd (https://github.com/meganz/MEGAcmd)" \
        "mega-ls:MEGAcmd (https://github.com/meganz/MEGAcmd)" \
        "mega-quit:MEGAcmd (https://github.com/meganz/MEGAcmd)";

    mega-login "$target";
    raw="$(mega-ls --show-handles -l -r)";
    mega-quit;

    echo "$raw" | "$parser" "$@" | while read path; do
        read id;
        dir="$(dirname "$path")";
        mkdir -p "$dir";
        download_file "$target/file/$id" "--path=$dir";
    done
}

if [ "$(matches "$FOLDER_PATTERN")" = "1" ]; then
    log "Matched folder";
    download_folder "parse_megals_files";
elif [ "$(matches "$FILE_PATTERN")" = "1" ]; then
    log "Matched file";
    download_file "$target";
elif [ "$(matches "$FOLDER_IN_FOLDER_PATTERN")" = "1" ]; then
    log "Matched folder in a folder";
    id="$(echo "$target" | grep -ioP "$FOLDER_IN_FOLDER_PATTERN")"
    download_folder "parse_megals_files_from_folder" "$id"
elif [ "$(matches "$FILE_IN_FOLDER_PATTERN")" = "1" ]; then
    log "Matched file in a folder";
    download_file "$target";
else
    echo "Unknown url '$target'" 1>&2;
    usage;
    exit 1;
fi

