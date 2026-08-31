#!/bin/sh
set -eu
/etc/init.d/podkop-late-start stop 2>/dev/null || true
/etc/init.d/podkop-late-start disable 2>/dev/null || true
/etc/init.d/podkop-awg-failover stop 2>/dev/null || true
/etc/init.d/podkop-awg-failover disable 2>/dev/null || true
/etc/init.d/podkop-health stop 2>/dev/null || true
/etc/init.d/podkop-health disable 2>/dev/null || true
rm -f /etc/init.d/podkop-late-start /etc/init.d/podkop-awg-failover /etc/init.d/podkop-health
rm -f /usr/bin/podkop-late-start /usr/bin/podkop-awg-failover /usr/bin/podkop-health
rm -f /etc/podkop-awg-failover.conf
/etc/init.d/podkop restart 2>/dev/null || true
echo "Removed failover/late-start/health scripts. Podkop and AWG interface definitions were not deleted."
