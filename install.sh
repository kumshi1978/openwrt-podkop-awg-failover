#!/bin/sh
set -eu

SCRIPT_VERSION="1.3.0"
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
HEALTH_INTERVAL_SET="${HEALTH_INTERVAL+x}"; HEALTH_INTERVAL_ENV="${HEALTH_INTERVAL-}"
HEALTH_FAIL_SET="${HEALTH_FAIL_LIMIT+x}"; HEALTH_FAIL_ENV="${HEALTH_FAIL_LIMIT-}"
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
PODKOP_RETRIES="$(pick "$RETRIES_SET" "$RETRIES_ENV" PODKOP_RETRIES 5)"
HEALTH_INTERVAL="$(pick "$HEALTH_INTERVAL_SET" "$HEALTH_INTERVAL_ENV" HEALTH_INTERVAL 30)"
HEALTH_FAIL_LIMIT="$(pick "$HEALTH_FAIL_SET" "$HEALTH_FAIL_ENV" HEALTH_FAIL_LIMIT 3)"
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
for f in "$CONF" /usr/bin/podkop-awg-failover /usr/bin/podkop-late-start /usr/bin/podkop-health /etc/init.d/podkop-awg-failover /etc/init.d/podkop-late-start /etc/init.d/podkop-health; do
    [ -e "$f" ] && cp -p "$f" "$BACKUP_DIR/$(basename "$f")"
done
uci export podkop > "$BACKUP_DIR/podkop.uci" 2>/dev/null || true
uci export system > "$BACKUP_DIR/system.uci" 2>/dev/null || true
say "Backup: $BACKUP_DIR"

fix_ntp() {
    uci -q delete system.ntp.server || true
    for server in \
        0.ru.pool.ntp.org 1.ru.pool.ntp.org 2.ru.pool.ntp.org 3.ru.pool.ntp.org \
        ntp1.stratum2.ru ntp2.stratum2.ru time.cloudflare.com time.google.com
    do
        uci add_list "system.ntp.server=$server"
    done
    uci commit system
    if [ -x /etc/init.d/sysntpd ]; then
        /etc/init.d/sysntpd restart || true
        say "NTP servers updated and sysntpd restarted."
    else
        say "NTP servers updated; sysntpd is not installed."
    fi
}

fix_ntp

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
HEALTH_INTERVAL='$HEALTH_INTERVAL'
HEALTH_FAIL_LIMIT='$HEALTH_FAIL_LIMIT'
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
PODKOP_RETRIES="${PODKOP_RETRIES:-5}"
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
    singbox_running && local_dns_ready && have_default_route
}

wait_podkop_ready() {
    waited=0
    while [ "$waited" -lt 30 ]; do
        podkop_ready && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
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
    if [ "$attempt" -gt 1 ] && [ -x /etc/init.d/sing-box ]; then
        /etc/init.d/sing-box restart >/dev/null 2>&1 || true
        log "sing-box restart requested"
        sleep 5
    fi
    /etc/init.d/podkop restart
    if wait_podkop_ready; then
        log "Podkop, sing-box, DNS and routing are ready"
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
/etc/init.d/podkop-health start
log "Podkop health watchdog started"
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

cat > /usr/bin/podkop-health <<'EOF_HEALTH'
#!/bin/sh

CONF=/etc/podkop-awg-failover.conf
[ -r "$CONF" ] && . "$CONF"
[ -r /lib/functions/network.sh ] && . /lib/functions/network.sh

TAG="podkop-health"
SECTION="${PODKOP_SECTION:-main}"
MAIN="${MAIN_AWG:-awg_main}"
INTERVAL="${HEALTH_INTERVAL:-30}"
FAIL_LIMIT="${HEALTH_FAIL_LIMIT:-3}"
PODKOP_RETRIES="${PODKOP_RETRIES:-5}"
fail_count=0

log() { logger -t "$TAG" "$*"; }

have_default_route() {
    ip -4 route show default 2>/dev/null | grep -q '^default '
}

singbox_running() {
    ubus call service list '{"name":"sing-box"}' 2>/dev/null | grep -q '"running": true'
}

local_dns_ready() {
    nslookup google.com 127.0.0.1 >/dev/null 2>&1
}

podkop_ready() {
    singbox_running && local_dns_ready && have_default_route
}

wan_ipv4() {
    wan_if=""
    wan_ip=""
    command -v network_find_wan >/dev/null 2>&1 && network_find_wan wan_if
    [ -n "$wan_if" ] && network_get_ipaddr wan_ip "$wan_if"
    printf '%s' "$wan_ip"
}

is_cgnat() {
    case "$1" in
        100.*)
            second="${1#100.}"
            second="${second%%.*}"
            case "$second" in *[!0-9]*|'') return 1 ;; esac
            [ "$second" -ge 64 ] && [ "$second" -le 127 ]
            ;;
        *) return 1 ;;
    esac
}

diagnose_network() {
    ipaddr="$(wan_ipv4)"
    if [ -n "$ipaddr" ]; then
        log "WAN IPv4 detected: $ipaddr"
        if is_cgnat "$ipaddr"; then
            log "CGNAT detected (100.64.0.0/10)"
        else
            log "CGNAT not detected on WAN IPv4"
        fi
    else
        log "WAN IPv4 not detected"
    fi

    active="$(uci -q get "podkop.$SECTION.interface")"
    [ -n "$active" ] || active="$MAIN"
    public_ip="$(curl -4 --interface "$active" --connect-timeout 5 --max-time 10 -fsS https://ifconfig.me/ip 2>/dev/null || true)"
    if [ -n "$public_ip" ]; then
        log "AWG public IP via $active: $public_ip"
    else
        log "AWG public IP via $active is unavailable"
    fi
}

recover_podkop() {
    log "recovery started after $FAIL_LIMIT failed health checks"
    /etc/init.d/podkop-awg-failover stop >/dev/null 2>&1 || true
    attempt=1
    while [ "$attempt" -le "$PODKOP_RETRIES" ]; do
        log "recovery attempt $attempt/$PODKOP_RETRIES"
        if [ -x /etc/init.d/sing-box ]; then
            /etc/init.d/sing-box restart >/dev/null 2>&1 || true
            sleep 5
        fi
        /etc/init.d/podkop restart >/dev/null 2>&1 || true
        waited=0
        while [ "$waited" -lt 30 ]; do
            if podkop_ready; then
                /etc/init.d/podkop-awg-failover start >/dev/null 2>&1 || true
                log "recovery completed; failover watchdog restarted"
                diagnose_network
                return 0
            fi
            sleep 5
            waited=$((waited + 5))
        done
        attempt=$((attempt + 1))
    done
    /etc/init.d/podkop-awg-failover start >/dev/null 2>&1 || true
    log "recovery failed after $PODKOP_RETRIES attempts; will retry after further health checks"
    return 1
}

log "health watchdog started: interval=${INTERVAL}s fail_limit=$FAIL_LIMIT"
diagnose_network

while true; do
    if podkop_ready; then
        [ "$fail_count" -gt 0 ] && log "health check recovered"
        fail_count=0
    else
        fail_count=$((fail_count + 1))
        [ "$fail_count" -gt "$FAIL_LIMIT" ] && fail_count="$FAIL_LIMIT"
        log "health check failed ($fail_count/$FAIL_LIMIT): sing-box, local DNS or routing is not ready"
        if [ "$fail_count" -ge "$FAIL_LIMIT" ]; then
            recover_podkop || true
            fail_count=0
        fi
    fi
    sleep "$INTERVAL"
done
EOF_HEALTH
chmod +x /usr/bin/podkop-health

cat > /etc/init.d/podkop-health <<'EOF_INIT_HEALTH'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/podkop-health
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF_INIT_HEALTH
chmod +x /etc/init.d/podkop-health

sh -n /usr/bin/podkop-awg-failover || die "watchdog syntax check failed"
sh -n /usr/bin/podkop-late-start || die "late-start syntax check failed"
sh -n /usr/bin/podkop-health || die "health watchdog syntax check failed"

# Persist only the normal/default state. Runtime failover/hold changes are not committed.
uci set "podkop.$PODKOP_SECTION.connection_type=vpn"
uci set "podkop.$PODKOP_SECTION.interface=$MAIN_AWG"
uci commit podkop

/etc/init.d/podkop-awg-failover disable >/dev/null 2>&1 || true
/etc/init.d/podkop-awg-failover stop >/dev/null 2>&1 || true
/etc/init.d/podkop-health disable >/dev/null 2>&1 || true
/etc/init.d/podkop-health stop >/dev/null 2>&1 || true
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
say "  logread | grep -E 'podkop-health|podkop-late|podkop-awg' | tail -60"
