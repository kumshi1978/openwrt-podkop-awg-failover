#!/bin/sh
# OpenWrt NTP hardening helper
# v1.3.0 preparation

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

/etc/init.d/sysntpd restart || true

echo 'NTP servers updated'
uci show system.ntp
