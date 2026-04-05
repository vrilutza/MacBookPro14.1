#!/bin/bash
# monitor_macfan_extreme.sh — MacBook Pro fan + temperature monitor
#
# This script delegates to the canonical monitor installed by macbook_hardware_fixer.sh.
# The canonical version is installed at /usr/local/bin/macbook-monitor.
#
# Run macbook_hardware_fixer.sh first to install the monitor, then call either:
#   macbook-monitor                        (if PATH includes /usr/local/bin)
#   /usr/local/bin/macbook-monitor         (full path)
#   bash fan/monitor_macfan_extreme.sh     (this wrapper)

MONITOR=/usr/local/bin/macbook-monitor

if [ -x "$MONITOR" ]; then
    exec "$MONITOR" "$@"
else
    echo "macbook-monitor not found at $MONITOR"
    echo "Run first: sudo bash macbook_hardware_fixer.sh"
    exit 1
fi
