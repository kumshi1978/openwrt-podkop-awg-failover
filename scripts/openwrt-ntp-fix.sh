#!/bin/sh
# OpenWrt NTP hardening helper
# v1.3.1

set -eu

uci -q delete system.ntp.server || true
uci add_list system.ntp.server='0.ru.pool.ntp.org'
uci add_list system.ntp.server='1.ru.pool.ntp.org'
uci add_list system.ntp.server='2.ru.pool.ntp.org'
uci add_list system.ntp.server='3.ru.pool.ntp.org'
uci add_list system.ntp.server='ntp1.stratum2.ru'
uci add_list system.ntp.server='ntp2.stratum2.ru'
uci add_list system.ntp.server='time.cloudflare.com'
uci add_list system.ntp.server='time.google.com'

uci commit system

if [ -x /etc/init.d/sysntpd ]; then
    /etc/init.d/sysntpd restart >/dev/null 2>&1 &
    ntp_pid=$!
    waited=0
    while kill -0 "$ntp_pid" 2>/dev/null; do
        if [ "$waited" -ge 45 ]; then
            kill "$ntp_pid" 2>/dev/null || true
            wait "$ntp_pid" 2>/dev/null || true
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$ntp_pid" 2>/dev/null || true
fi

echo 'NTP servers updated'
uci show system.ntp
