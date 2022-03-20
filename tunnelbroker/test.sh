#!/bin/sh

die() {
    echo "$@" 1>&2;
    exit 1;
}

[ $# -gt 0 ] || die "Usage: $(basename $0) <PREFIX>";
PREFIX="$1"
echo "$PREFIX" | grep -iP "^[a-f0-9]{1,4}(:[a-f0-9]{1,4})*$" > /dev/null || die "Invalid prefix '$PREFIX'"


ip -6 route
echo 
echo
# google.com
ip -6 route get "2800:3f0:4001:81f::200e"
echo
echo

p() {
    if [ "$#" -gt 0 ]; then
        printf "Testing with address %s... " "$1"
        ping6 -c 1 -W 1 google.com -I "$1" 2>&1 > /dev/null && echo "Ok" || echo "Fail"
    else
        printf "Testing with default address... "
        ping6 -c 1 -W 1 google.com 2>&1 > /dev/null && echo "Ok" || echo "Fail"
    fi
}

p
p "${PREFIX}::6969"
p "${PREFIX}:dead:beef::6969"

