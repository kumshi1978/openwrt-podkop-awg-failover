#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
installer=$root/install.sh
sh -n "$installer"
for section in WATCH LATE HEALTH; do
    awk -v marker="EOF_$section" '
        $0 == marker { exit }
        inside { print }
        index($0, "<<\047" marker "\047") { inside=1 }
    ' "$installer" >"$tmp/$section"
    test -s "$tmp/$section"
    sh -n "$tmp/$section"
    sed -n '/^maintenance_lock() {/,/^}/p' "$tmp/$section" |
        sed 's@/var/run/home-net-vpn-maintenance.lock@$TEST_LOCK@g' >"$tmp/$section.lock"
    test -s "$tmp/$section.lock"
done
export TEST_LOCK="$tmp/maintenance.lock"
for section in WATCH LATE HEALTH; do
    (
        flock -n 9
        if sh -c '. "$1"; maintenance_lock' sh "$tmp/$section.lock" 9>&-; then
            echo "lock contention did not block $section" >&2
            exit 1
        fi
    ) 9>>"$TEST_LOCK"
    test -f "$TEST_LOCK"
    sh -c '. "$1"; maintenance_lock' sh "$tmp/$section.lock"
done

# Exercise the actual installer policy block with fake service commands.
sed -n '/^# Bootstrap Podkop defaults/,/^say "Version:/p' "$installer" |
    sed '$d; s@/etc/init.d/@$TEST_INIT/@g' >"$tmp/upgrade"
export TEST_INIT="$tmp/init" TEST_CALLS="$tmp/calls"
mkdir "$TEST_INIT"
for service in podkop-awg-failover podkop-health podkop-awg-update; do
    cat >"$TEST_INIT/$service" <<'MOCK'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$1" >>"$TEST_CALLS"
case "${0##*/}:$1" in
    podkop-awg-failover:running|podkop-awg-failover:restart) exit 0 ;;
    *) exit 1 ;;
esac
MOCK
    chmod 0755 "$TEST_INIT/$service"
done
(
    PREVIOUS_VERSION=1.4.1
    APPLY_NOW=1
    say() { :; }
    die() { exit 1; }
    uci() { echo 'unexpected UCI write' >&2; exit 1; }
    . "$tmp/upgrade"
)
cat >"$tmp/expected" <<'EXPECTED'
podkop-awg-failover running
podkop-awg-failover restart
podkop-health running
podkop-awg-update running
EXPECTED
cmp "$tmp/expected" "$TEST_CALLS"
printf '%s\n' 'PASS: failover lock and upgrade policy'
