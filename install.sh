#!/bin/sh
set -eu

SCRIPT_VERSION="1.2.3"
CONF="/etc/podkop-awg-failover.conf"
BACKUP_DIR="/root/podkop-awg-backup-$(date +%Y%m%d-%H%M%S)"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

oldval() {
    [ -r "$CONF" ] || return 1
    sed -n "s/^$1='\(.*\)'$/\1/p" "$CONF" | tail -n 1
}

pick() {
    if [ "$1" = "x" ]; then
        printf '%s' "$2"
        return
    fi
    v="$(oldval "$3" 2>/dev/null || true)"
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$4"
}

resolve_section_ci() {
    cfg="$1"
    requested="$2"
    wanted="$(printf '%s' "$requested" | tr 'A-Z' 'a-z')"
    found=""
    count=0
    for s in $(uci -q show "$cfg" 2>/dev/null | sed -n "s/^$cfg\.\([^.=]*\)=.*/\1/p"); do
        lower="$(printf '%s' "$s" | tr 'A-Z' 'a-z')"
        if [ "$lower" = "$wanted" ]; then
            found="$s"
            count=$((count + 1))
        fi
    done
    [ "$count" -eq 1 ] || {
        [ "$count" -eq 0 ] && die "$cfg section '$requested' not found (case-insensitive)"
        die "$cfg section '$requested' is ambiguous: multiple names differ only by letter case"
    }
    printf '%s' "$found"
}

MAIN_SET="${MAIN_AWG+x}"; MAIN_ENV="${MAIN_AWG-}"
BACKUP_SET="${BACKUP_AWG+x}"; BACKUP_ENV="${BACKUP_AWG-}"
SECTION_SET="${PODKOP_SECTION+x}"; SECTION_ENV="${PODKOP_SECTION-}"
HOST_SET="${CHECK_HOST+x}"; HOST_ENV="${CHECK_HOST-}"
INTERVAL_SET="${CHECK_INTERVAL+x}"; INTERVAL_ENV="${CHECK_INTERVAL-}"
FAIL_SET="${FAIL_LIMIT+x}"; FAIL_ENV="${FAIL_LIMIT-}"
RECOVER_SET="${RECOVER_LIMIT+x}"; RECOVER_ENV="${RECOVER_LIMIT-}"
GRACE_SET="${STARTUP_GRACE+x}"; GRACE_ENV="${STARTUP_GRACE-}"
WAIT_SET="${UPLINK_WAIT+x}"; WAIT_ENV="${UPLINK_WAIT-}"
RETRIES_SET="${PODKOP_RETRIES+x}"; RETRIES_ENV="${PODKOP_RETRIES-}"
KILL_SET="${KILL_SWITCH+x}"; KILL_ENV="${KILL_SWITCH-}"
APPLY_SET="${APPLY_NOW+x}"; APPLY_ENV="${APPLY_NOW-}"

MAIN_REQ="$(pick "$MAIN_SET" "$MAIN_ENV" MAIN_AWG awg_main)"
BACKUP_REQ="$(pick "$BACKUP_SET" "$BACKUP_ENV" BACKUP_AWG AWG_backup)"
SECTION_REQ="$(pick "$SECTION_SET" "$SECTION_ENV" PODKOP_SECTION main)"
CHECK_HOST="$(pick "$HOST_SET" "$HOST_ENV" CHECK_HOST ifconfig.me)"
CHECK_INTERVAL="$(pick "$INTERVAL_SET" "$INTERVAL_ENV" CHECK_INTERVAL 20)"
FAIL_LIMIT="$(pick "$FAIL_SET" "$FAIL_ENV" FAIL_LIMIT 3)"
RECOVER_LIMIT="$(pick "$RECOVER_SET" "$RECOVER_ENV" RECOVER_LIMIT 3)"
STARTUP_GRACE="$(pick "$GRACE_SET" "$GRACE_ENV" STARTUP_GRACE 15)"
UPLINK_WAIT="$(pick "$WAIT_SET" "$WAIT_ENV" UPLINK_WAIT 180)"
PODKOP_RETRIES="$(pick "$RETRIES_SET" "$RETRIES_ENV" PODKOP_RETRIES 3)"
KILL_SWITCH="$(pick "$KILL_SET" "$KILL_ENV" KILL_SWITCH 1)"
APPLY_NOW="$(pick "$APPLY_SET" "$APPLY_ENV" APPLY_NOW 1)"

[ "$(id -u)" = "0" ] || die "run as root"
for x in uci ubus curl nslookup ip logger sed grep tr; do need "$x"; done
[ -x /etc/init.d/podkop ] || die "Podkop init script not found: /etc/init.d/podkop"
[ -x /etc/init.d/sysntpd ] || say "WARN: sysntpd init script not found; NTP restart will be skipped"

MAIN_AWG="$(resolve_section_ci network "$MAIN_REQ")"
BACKUP_AWG="$(resolve_section_ci network "$BACKUP_REQ")"
PODKOP_SECTION="$(resolve_section_ci podkop "$SECTION_REQ")"

[ "$(uci -q get "network.$MAIN_AWG.proto")" = "amneziawg" ] || die "$MAIN_AWG is not proto=amneziawg"
[ "$(uci -q get "network.$BACKUP_AWG.proto")" = "amneziawg" ] || die "$BACKUP_AWG is not proto=amneziawg"
[ "$(printf '%s' "$MAIN_AWG" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$BACKUP_AWG" | tr 'A-Z' 'a-z')" ] || die "main and backup AWG resolve to the same interface"

case "$KILL_SWITCH" in 0|1) ;; *) die "KILL_SWITCH must be 0 or 1" ;; esac
case "$APPLY_NOW" in 0|1) ;; *) die "APPLY_NOW must be 0 or 1" ;; esac

mkdir -p "$BACKUP_DIR"
for f in "$CONF" /usr/bin/podkop-awg-failover /usr/bin/podkop-late-start /etc/init.d/podkop-awg-failover /etc/init.d/podkop-late-start; do
    [ -e "$f" ] && cp -p "$f" "$BACKUP_DIR/$(basename "$f")"
done
uci export podkop > "$BACKUP_DIR/podkop.uci" 2>/dev/null || true
say "Backup: $BACKUP_DIR"

cat > "$CONF" <<EOF_CONF
INSTALLED_VERSION='$SCRIPT_VERSION'
MAIN_AWG='$MAIN_AWG'
BACKUP_AWG='$BACKUP_AWG'
PODKOP_SECTION='$PODKOP_SECTION'
CHECK_HOST='$CHECK_HOST'
CHECK_INTERVAL='$CHECK_INTERVAL'
FAIL_LIMIT='$FAIL_LIMIT'
RECOVER_LIMIT='$RECOVER_LIMIT'
STARTUP_GRACE='$STARTUP_GRACE'
UPLINK_WAIT='$UPLINK_WAIT'
PODKOP_RETRIES='$PODKOP_RETRIES'
KILL_SWITCH='$KILL_SWITCH'
EOF_CONF

cat > /usr/bin/podkop-awg-failover <<'EOF_WATCH'
#!/bin/sh

CONF=/etc/podkop-awg-failover.conf
[ -r "$CONF" ] && . "$CONF"

TAG="podkop-awg"
MAIN="${MAIN_AWG:-awg_main}"
BACKUP="${BACKUP_AWG:-AWG_backup}"
SECTION="${PODKOP_SECTION:-main}"
CHECK_HOST="${CHECK_HOST:-ifconfig.me}"
INTERVAL="${CHECK_INTERVAL:-20}"
FAIL_LIMIT="${FAIL_LIMIT:-3}"
RECOVER_LIMIT="${RECOVER_LIMIT:-3}"
STARTUP_GRACE="${STARTUP_GRACE:-15}"
KILL_SWITCH="${KILL_SWITCH:-1}"

fail_count=0
main_recover=0
backup_recover=0

log() { logger -t "$TAG" "$*"; }

check_tunnel() {
    curl -4 --interface "$1" --connect-timeout 5 --max-time 10 -fsS "https://${CHECK_HOST}/ip" >/dev/null 2>&1
}

restart_podkop() {
    /etc/init.d/podkop restart
    sleep 5
}

set_vpn() {
    target="$1"
    current_type="$(uci -q get "podkop.$SECTION.connection_type")"
    current_if="$(uci -q get "podkop.$SECTION.interface")"
    if [ "$current_type" = "vpn" ] && [ "$current_if" = "$target" ]; then
        return 0
    fi
    log "Podkop state -> vpn via $target"
    uci set "podkop.$SECTION.connection_type=vpn"
    uci set "podkop.$SECTION.interface=$target"
    restart_podkop
}

enter_hold() {
    [ "$KILL_SWITCH" = "1" ] || return 1
    current_if="$(uci -q get "podkop.$SECTION.interface")"
    log "both AWG unavailable: entering hold mode; Podkop stays vpn via ${current_if:-unknown} (fail-closed)"
    return 0
}

current_type="$(uci -q get "podkop.$SECTION.connection_type")"
current_if="$(uci -q get "podkop.$SECTION.interface")"
if [ "$current_type" != "vpn" ]; then
    log "non-vpn Podkop state detected at watchdog start; restoring vpn via $MAIN"
    set_vpn "$MAIN"
    current_if="$MAIN"
fi

if [ "$current_if" = "$BACKUP" ]; then
    active="backup"
else
    active="main"
fi

log "watchdog started: main=$MAIN backup=$BACKUP active=$active kill_switch=$KILL_SWITCH"
log "startup grace: waiting ${STARTUP_GRACE} seconds"
sleep "$STARTUP_GRACE"
log "startup grace finished, monitoring started"

while true; do
    case "$active" in
        main)
            if check_tunnel "$MAIN"; then
                fail_count=0
            else
                fail_count=$((fail_count + 1))
                [ "$fail_count" -gt "$FAIL_LIMIT" ] && fail_count="$FAIL_LIMIT"
                log "main check failed ($fail_count/$FAIL_LIMIT)"
                if [ "$fail_count" -ge "$FAIL_LIMIT" ]; then
                    if check_tunnel "$BACKUP"; then
                        log "main unavailable, backup healthy"
                        set_vpn "$BACKUP"
                        active="backup"
                        fail_count=0
                        main_recover=0
                    else
                        log "main and backup both unavailable"
                        fail_count="$FAIL_LIMIT"
                        if enter_hold; then
                            active="hold"
                            main_recover=0
                            backup_recover=0
                        fi
                    fi
                fi
            fi
            ;;
        backup)
            main_ok=0
            backup_ok=0
            check_tunnel "$MAIN" && main_ok=1
            check_tunnel "$BACKUP" && backup_ok=1

            if [ "$main_ok" = "1" ]; then
                main_recover=$((main_recover + 1))
                log "main recovery check ($main_recover/$RECOVER_LIMIT)"
                if [ "$main_recover" -ge "$RECOVER_LIMIT" ]; then
                    log "main recovered"
                    set_vpn "$MAIN"
                    active="main"
                    main_recover=0
                    fail_count=0
                elif [ "$backup_ok" = "0" ]; then
                    if enter_hold; then
                        active="hold"
                        backup_recover=0
                        log "backup unavailable while main is still in recovery; holding VPN fail-closed"
                    fi
                fi
            else
                main_recover=0
                if [ "$backup_ok" = "0" ]; then
                    log "backup unavailable and main unavailable"
                    if enter_hold; then
                        active="hold"
                        backup_recover=0
                    fi
                fi
            fi
            ;;
        hold)
            if check_tunnel "$MAIN"; then
                main_recover=$((main_recover + 1))
                log "main recovery check while holding ($main_recover/$RECOVER_LIMIT)"
            else
                main_recover=0
            fi

            if [ "$main_recover" -ge "$RECOVER_LIMIT" ]; then
                log "main recovered; leaving hold mode"
                set_vpn "$MAIN"
                active="main"
                main_recover=0
                backup_recover=0
                fail_count=0
            else
                if check_tunnel "$BACKUP"; then
                    backup_recover=$((backup_recover + 1))
                    log "backup recovery check while holding ($backup_recover/$RECOVER_LIMIT)"
                else
                    backup_recover=0
                fi
                if [ "$backup_recover" -ge "$RECOVER_LIMIT" ]; then
                    log "backup recovered; leaving hold mode"
                    set_vpn "$BACKUP"
                    active="backup"
                    backup_recover=0
                fi
            fi
            ;;
    esac
    sleep "$INTERVAL"
done
EOF_WATCH
chmod +x /usr/bin/podkop-awg-failover

cat > /etc/init.d/podkop-awg-failover <<'EOF_INIT_WATCH'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/podkop-awg-failover
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF_INIT_WATCH
chmod +x /etc/init.d/podkop-awg-failover

cat > /usr/bin/podkop-late-start <<'EOF_LATE'
#!/bin/sh

CONF=/etc/podkop-awg-failover.conf
[ -r "$CONF" ] && . "$CONF"

TAG="podkop-late"
UPLINK_WAIT="${UPLINK_WAIT:-180}"
PODKOP_RETRIES="${PODKOP_RETRIES:-3}"
SECTION="${PODKOP_SECTION:-main}"
MAIN="${MAIN_AWG:-awg_main}"

log() { logger -t "$TAG" "$*"; }

have_default_route() {
    ip -4 route show default 2>/dev/null | grep -q '^default '
}

external_dns_ready() {
    nslookup openwrt.org >/dev/null 2>&1
}

singbox_running() {
    ubus call service list '{"name":"sing-box"}' 2>/dev/null | grep -q '"running": true'
}

local_dns_ready() {
    nslookup google.com 127.0.0.1 >/dev/null 2>&1
}

podkop_ready() {
    singbox_running && local_dns_ready
}

log "late-start initiated"

elapsed=0
while ! have_default_route; do
    if [ "$elapsed" -ge "$UPLINK_WAIT" ]; then
        log "no IPv4 default route within ${UPLINK_WAIT}s"
        exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
log "default route is ready"

elapsed=0
while ! external_dns_ready; do
    if [ "$elapsed" -ge 60 ]; then
        log "external DNS is still unavailable"
        exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
log "external DNS is available"

uci set "podkop.$SECTION.connection_type=vpn"
uci set "podkop.$SECTION.interface=$MAIN"

attempt=1
while [ "$attempt" -le "$PODKOP_RETRIES" ]; do
    log "restarting Podkop, attempt $attempt/$PODKOP_RETRIES"
    /etc/init.d/podkop restart
    sleep 15
    if podkop_ready; then
        log "Podkop and sing-box are ready"
        break
    fi
    log "Podkop readiness check failed"
    attempt=$((attempt + 1))
done

if ! podkop_ready; then
    log "Podkop failed to become ready"
    exit 1
fi

if [ -x /etc/init.d/sysntpd ]; then
    /etc/init.d/sysntpd restart
    log "NTP restarted"
fi

/etc/init.d/podkop-awg-failover start
log "AWG failover watchdog started"
log "late-start completed successfully"
exit 0
EOF_LATE
chmod +x /usr/bin/podkop-late-start

cat > /etc/init.d/podkop-late-start <<'EOF_INIT_LATE'
#!/bin/sh /etc/rc.common
START=98
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/podkop-late-start
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF_INIT_LATE
chmod +x /etc/init.d/podkop-late-start

sh -n /usr/bin/podkop-awg-failover || die "watchdog syntax check failed"
sh -n /usr/bin/podkop-late-start || die "late-start syntax check failed"

# Persist only the normal/default state. Runtime failover/hold changes are not committed.
uci set "podkop.$PODKOP_SECTION.connection_type=vpn"
uci set "podkop.$PODKOP_SECTION.interface=$MAIN_AWG"
uci commit podkop

/etc/init.d/podkop-awg-failover disable >/dev/null 2>&1 || true
/etc/init.d/podkop-awg-failover stop >/dev/null 2>&1 || true
/etc/init.d/podkop-late-start enable

if [ "$APPLY_NOW" = "1" ]; then
    /etc/init.d/podkop-late-start restart
    say "Installed/updated and applied now."
else
    say "Installed/updated. APPLY_NOW=0, so changes will activate on next boot."
fi

say "Version:       $SCRIPT_VERSION"
say "Main AWG:      $MAIN_AWG"
say "Backup AWG:    $BACKUP_AWG"
say "Podkop sect:   $PODKOP_SECTION"
say "Kill switch:   $KILL_SWITCH (hold/fail-closed mode)"
say "Backup:        $BACKUP_DIR"
say "Status:"
say "  logread | grep -E 'podkop-late|podkop-awg' | tail -40"
