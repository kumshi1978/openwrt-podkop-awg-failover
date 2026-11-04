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

# Run the installer end to end against a relocated filesystem and command fixtures.
export FIXTURE="$tmp/router" INSTALL_CALLS="$tmp/install-calls"
mkdir -p "$FIXTURE/etc/init.d" "$FIXTURE/etc/rc.d" "$FIXTURE/usr/bin" \
    "$FIXTURE/root" "$FIXTURE/tmp" "$tmp/bin"
sed -e 's@/etc/@__FIXTURE__/etc/@g' -e 's@/usr/bin/@__FIXTURE__/usr/bin/@g' \
    -e 's@/tmp/@__FIXTURE__/tmp/@g' -e 's@/root/@__FIXTURE__/root/@g' \
    -e "s@__FIXTURE__@$FIXTURE@g" "$installer" >"$tmp/install"
cat >"$FIXTURE/etc/podkop-awg-failover.conf" <<'CONF'
INSTALLED_VERSION='1.4.1'
MAIN_AWG='awg_main'
BACKUP_AWG='awg_backup'
PODKOP_SECTION='main'
CHECK_INTERVAL='23'
FAIL_LIMIT='7'
RECOVER_LIMIT='5'
CONF
printf '%s\n' 'operator update policy fixture' >"$FIXTURE/etc/podkop-awg-update.conf"
cp "$FIXTURE/etc/podkop-awg-update.conf" "$tmp/update-before"
cat >"$tmp/bin/uci" <<'MOCK'
#!/bin/sh
case "$*" in
    '-q show network') printf '%s\n' 'network.awg_main=interface' 'network.awg_backup=interface' ;;
    '-q show podkop') printf '%s\n' 'podkop.main=section' ;;
    '-q get network.awg_main.proto'|'-q get network.awg_backup.proto') echo amneziawg ;;
    'export podkop') printf '%s\n' 'interface=awg_backup' 'connection_type=vpn' 'dns_type=dot' ;;
    'export system') echo 'ntp=custom' ;;
    *) printf '%s\n' 'unexpected UCI operation' >&2; printf '%s\n' UCI_MUTATION >>"$INSTALL_CALLS"; exit 1 ;;
esac
MOCK
cat >"$tmp/bin/curl" <<'MOCK'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        case "$2" in
            *.init) printf '#!/bin/sh %s/etc/rc.common\n' "$FIXTURE" >"$2" ;;
            *) printf '%s\n' '#!/bin/sh' ':' >"$2" ;;
        esac
        exit
    fi
    shift
done
exit 1
MOCK
cat >"$FIXTURE/etc/rc.common" <<'MOCK'
#!/bin/sh
service=${1##*/}
printf '%s %s\n' "$service" "$2" >>"$INSTALL_CALLS"
case "$service:$2" in
    podkop-awg-failover:running|podkop-awg-failover:restart) exit 0 ;;
    *) exit 1 ;;
esac
MOCK
# Linux does not recursively expand a script used as a shebang argument to sh.
# Delegate the rc.common execution explicitly to its mock.
cat >"$FIXTURE/etc/init.d/podkop" <<'MOCK'
#!/bin/sh
exit 1
MOCK
printf '%s\n' '#!/bin/sh' 'echo 0' >"$tmp/bin/id"
for tool in ubus nslookup ip logger; do
    printf '%s\n' '#!/bin/sh' 'exit 1' >"$tmp/bin/$tool"
done
chmod 0755 "$tmp/bin/"* "$FIXTURE/etc/init.d/podkop"
ln -s ../init.d/podkop-awg-failover "$FIXTURE/etc/rc.d/S98podkop-awg-failover"
ls -l "$FIXTURE/etc/rc.d" >"$tmp/links-before"
PATH="$tmp/bin:$PATH" APPLY_NOW=1 sh "$tmp/install" >"$tmp/install-output"
ls -l "$FIXTURE/etc/rc.d" >"$tmp/links-after"
cmp "$tmp/links-before" "$tmp/links-after"
cmp "$tmp/expected" "$INSTALL_CALLS"
cmp "$tmp/update-before" "$FIXTURE/etc/podkop-awg-update.conf"
for setting in "INSTALLED_VERSION='1.4.2'" "MAIN_AWG='awg_main'" "BACKUP_AWG='awg_backup'" \
    "CHECK_INTERVAL='23'" "FAIL_LIMIT='7'" "RECOVER_LIMIT='5'"; do
    grep -Fx "$setting" "$FIXTURE/etc/podkop-awg-failover.conf" >/dev/null
done
printf '%s\n' 'PASS: relocated failover 1.4.1 to 1.4.2 installer upgrade'
