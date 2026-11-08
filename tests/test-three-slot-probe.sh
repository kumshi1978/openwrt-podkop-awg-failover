#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed -n '/^ordered_probe() {/,/^}/p' "$root/install.sh" > "$tmp/probe"
. "$tmp/probe"
dns_ready() { return 0; }
curl() {
    case "$scenario:$*" in
        fallback:*ifconfig.me*) printf '\n429'; return 22 ;;
        rate:*) printf '\n429'; return 22 ;;
        timeout:*) printf '\n000'; return 28 ;;
        malformed:*) printf '<html>\n200'; return 0 ;;
        *) printf '203.0.113.8\n200' ;;
    esac
}
awg() { if [ "$scenario" = stale ]; then echo 'peer 1';else printf 'peer %s\n' "$(date +%s)";fi; }
probe() { set +e; ordered_probe awg_backup2; result=$?; set -e; }
scenario=fallback;probe;[ "$result" = 0 ]
scenario=rate;probe;[ "$result" = 2 ]
scenario=timeout;probe;[ "$result" = 1 ]
scenario=malformed;probe;[ "$result" = 2 ]
scenario=stale;probe;[ "$result" = 1 ]
echo 'PASS IP fallback, provider-unknown, transport failure, invalid body and stale handshake'
