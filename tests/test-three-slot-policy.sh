#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed -n '/^# BEGIN ORDERED THREE SLOT POLICY$/,/^# END ORDERED THREE SLOT POLICY$/p' "$root/install.sh" > "$tmp/policy"
. "$tmp/policy"
MAIN=awg_main BACKUP=awg_backup BACKUP2=awg_backup2 SECTION=main FAIL_LIMIT=2 RECOVER_LIMIT=3
selected_test=$MAIN; history=; expected_failure=0
uci() { case "$*" in *connection_type) echo vpn ;; *) echo "$selected_test" ;; esac; }
log() { :; }
check_tunnel() { case "$1" in "$MAIN") return "$h0" ;; "$BACKUP") return "$h1" ;; "$BACKUP2") return "$h2" ;; esac; }
set_vpn() { [ "$2" = "$selected_test" ]; [ "$expected_failure" = 0 ] || return 1; selected_test=$1; history="$history $1"; }
# Calls deliberately do not use errexit: status 1/2 are probe results.
step() { set +e; ordered_step; result=$?; set -e; return "$result"; }
h0=1 h1=0 h2=0
step; [ "$selected_test" = "$MAIN" ]; step; [ "$selected_test" = "$BACKUP" ]
h1=1; step; step; [ "$selected_test" = "$BACKUP2" ]
h0=0 h1=0; step; step; [ "$selected_test" = "$BACKUP2" ]; step; [ "$selected_test" = "$MAIN" ]
[ "$history" = ' awg_backup awg_backup2 awg_main' ]
h0=2 h1=1 h2=1; step; step; [ "$selected_test" = "$MAIN" ]
h0=1; step; step; [ "$selected_test" = "$MAIN" ]
h1=0 expected_failure=1
if step; then echo 'switch failure must propagate' >&2; exit 1; fi
[ "$selected_test" = "$MAIN" ]
echo 'PASS ordered failure, stable recovery, unknown, fail-closed and switch rejection'
