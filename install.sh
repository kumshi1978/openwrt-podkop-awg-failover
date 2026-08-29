#!/bin/sh
set -eu

MAIN_AWG="${MAIN_AWG:-awg_main}"
BACKUP_AWG="${BACKUP_AWG:-AWG_backup}"
PODKOP_SECTION="${PODKOP_SECTION:-main}"
CHECK_HOST="${CHECK_HOST:-ifconfig.me}"
CHECK_INTERVAL="${CHECK_INTERVAL:-20}"
FAIL_LIMIT="${FAIL_LIMIT:-3}"
RECOVER_LIMIT="${RECOVER_LIMIT:-3}"
STARTUP_GRACE="${STARTUP_GRACE:-15}"
UPLINK_WAIT="${UPLINK_WAIT:-180}"
PODKOP_RETRIES="${PODKOP_RETRIES:-3}"
BACKUP_DIR="/root/podkop-awg-backup-$(date +%Y%m%d-%H%M%S)"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

[ "$(id -u)" = "0" ] || die "run as root"

for x in uci ubus curl nslookup ip logger; do need "$x"; done
[ -x /etc/init.d/podkop ] || die "Podkop init script not found: /etc/init.d/podkop"
[ -x /etc/init.d/sysntpd ] || say "WARN: sysntpd init script not found; NTP restart will be skipped"

uci -q get "network.$MAIN_AWG" >/dev/null || die "network interface '$MAIN_AWG' not found"
uci -q get "network.$BACKUP_AWG" >/dev/null || die "network interface '$BACKUP_AWG' not found"
[ "$(uci -q get "network.$MAIN_AWG.proto")" = "amneziawg" ] || die "$MAIN_AWG is not proto=amneziawg"
[ "$(uci -q get "network.$BACKUP_AWG.proto")" = "amneziawg" ] || die "$BACKUP_AWG is not proto=amneziawg"
uci -q get "podkop.$PODKOP_SECTION" >/dev/null || die "Podkop section '$PODKOP_SECTION' not found"

mkdir -p "$BACKUP_DIR"
for f in /usr/bin/podkop-awg-failover /usr/bin/podkop-late-start /etc/init.d/podkop-awg-failover /etc/init.d/podkop-late-start; do
    [ -e "$f" ] && cp -p "$f" "$BACKUP_DIR/$(basename "$f")"
done
uci export podkop > "$BACKUP_DIR/podkop.uci" 2>/dev/null || true
say "Backup: $BACKUP_DIR"

cat > /etc/podkop-awg-failover.conf <<EOF_CONF
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

fail_count=0
recover_count=0
current="$(uci -q get podkop.$SECTION.interface)"
if [ "$current" = "$BACKUP" ]; then active="backup"; else active="main"; fi

log() { logger -t "$TAG" "$*"; }

check_tunnel() {
    curl -4 --interface "$1" --connect-timeout 5 --max-time 10 -fsS "https://${CHECK_HOST}/ip" >/dev/null 2>&1
}

switch_podkop() {
    target="$1"
    current="$(uci -q get podkop.$SECTION.interface)"
    [ "$current" = "$target" ] && return 0
    log "switching Podkop: $current -> $target"
    uci set "podkop.$SECTION.interface=$target"
    /etc/init.d/podkop restart
    sleep 5
}

log "watchdog started: main=$MAIN backup=$BACKUP active=$active"
log "startup grace: waiting ${STARTUP_GRACE} seconds"
sleep "$STARTUP_GRACE"
log "startup grace finished, monitoring started"

while true; do
    if [ "$active" = "main" ]; then
        if check_tunnel "$MAIN"; then
            fail_count=0
        else
            fail_count=$((fail_count + 1))
            [ "$fail_count" -gt "$FAIL_LIMIT" ] && fail_count="$FAIL_LIMIT"
            log "main check failed ($fail_count/$FAIL_LIMIT)"
            if [ "$fail_count" -ge "$FAIL_LIMIT" ]; then
                if check_tunnel "$BACKUP"; then
                    log "main unavailable, backup healthy"
                    switch_podkop "$BACKUP"
                    active="backup"
                    fail_count=0
                    recover_count=0
                else
                    log "main and backup both unavailable"
                    fail_count="$FAIL_LIMIT"
                fi
            fi
        fi
    else
        if check_tunnel "$MAIN"; then
            recover_count=$((recover_count + 1))
            log "main recovery check ($recover_count/$RECOVER_LIMIT)"
            if [ "$recover_count" -ge "$RECOVER_LIMIT" ]; then
                log "main recovered"
                switch_podkop "$MAIN"
                active="main"
                recover_count=0
                fail_count=0
            fi
        else
            recover_count=0
            if ! check_tunnel "$BACKUP"; then
                log "backup currently unavailable"
            fi
        fi
    fi
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
    nslookup openwrt.org 1.1.1.1 >/dev/null 2>&1
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

# Ensure persistent/default Podkop target is MAIN, but do not commit runtime failover changes.
uci set "podkop.$SECTION.interface=$MAIN"

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

ash -n /usr/bin/podkop-awg-failover || die "watchdog syntax check failed"
ash -n /usr/bin/podkop-late-start || die "late-start syntax check failed"

# Main should be the persisted Podkop target.
uci set "podkop.$PODKOP_SECTION.interface=$MAIN_AWG"
uci commit podkop

# Watchdog must not auto-start by itself; late-start owns ordering.
/etc/init.d/podkop-awg-failover disable >/dev/null 2>&1 || true
/etc/init.d/podkop-awg-failover stop >/dev/null 2>&1 || true
/etc/init.d/podkop-late-start enable

say "Installed successfully."
say "Main AWG:    $MAIN_AWG"
say "Backup AWG:  $BACKUP_AWG"
say "Podkop sect: $PODKOP_SECTION"
say "Next: reboot, wait 2-3 minutes, then run:"
say "  logread | grep -E 'podkop-late|podkop-awg' | tail -40"
