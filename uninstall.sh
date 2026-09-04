#!/bin/sh
set -eu
/etc/init.d/podkop-late-start stop 2>/dev/null || true
/etc/init.d/podkop-late-start disable 2>/dev/null || true
/etc/init.d/podkop-awg-failover stop 2>/dev/null || true
/etc/init.d/podkop-awg-failover disable 2>/dev/null || true
/etc/init.d/podkop-health stop 2>/dev/null || true
/etc/init.d/podkop-health disable 2>/dev/null || true
/etc/init.d/podkop-awg-update stop 2>/dev/null || true
/etc/init.d/podkop-awg-update disable 2>/dev/null || true
for rc_link in \
    /etc/rc.d/S[0-9][0-9]podkop-late-start \
    /etc/rc.d/S[0-9][0-9][0-9]podkop-late-start \
    /etc/rc.d/K[0-9][0-9]podkop-late-start \
    /etc/rc.d/K[0-9][0-9][0-9]podkop-late-start
do
    [ -e "$rc_link" ] || [ -L "$rc_link" ] || continue
    rm -f "$rc_link"
done
rm -f /etc/init.d/podkop-late-start /etc/init.d/podkop-awg-failover /etc/init.d/podkop-health /etc/init.d/podkop-awg-update
rm -f /usr/bin/podkop-late-start /usr/bin/podkop-awg-failover /usr/bin/podkop-health /usr/bin/podkop-awg-update
rm -f /etc/podkop-awg-failover.conf /etc/podkop-awg-update.conf
/etc/init.d/podkop restart 2>/dev/null || true
echo "Removed failover/late-start/health/update scripts. Podkop and AWG interface definitions were not deleted."
