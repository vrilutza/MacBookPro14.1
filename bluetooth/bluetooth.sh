#!/bin/bash
# =============================================================================
# bluetooth.sh — Bluetooth troubleshooter for MacBook Pro 14,1 (BCM4350C0 UART)
#
# Use this script when Bluetooth is broken AFTER a fresh Ubuntu install or
# after following incorrect internet advice.  It cleans up common mistakes and
# fixes BlueZ config, then points to macbook_hardware_fixer.sh for firmware.
#
# Usage: sudo bash bluetooth/bluetooth.sh
#
# After running: do ONE SMC Reset to clear the chip baud rate set by macOS.
#   1. Shutdown completely (not restart)
#   2. Hold 10 s: Shift(L) + Ctrl(L) + Option(L) + Power
#   3. Release, press Power normally
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; }
fix()  { echo -e "  ${YELLOW}[FIX]${NC}  $1"; }
warn() { echo -e "  ${RED}[WARN]${NC} $1"; }
info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }
sep()  { echo -e "${BOLD}────────────────────────────────────────────────────${NC}"; }

sep
echo -e "${BOLD}  Bluetooth Troubleshooter — MacBook Pro 14,1 — BCM4350C0 UART${NC}"
sep
echo ""

if [ "$EUID" -ne 0 ]; then
    warn "Must run as root: sudo bash bluetooth/bluetooth.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/../macbook_hardware_fixer.sh"

# =============================================================================
# 1 — Remove wrong module blacklists
#     Internet advice often says "blacklist hci_uart" — this is WRONG.
#     hci_uart IS the correct driver for BCM4350C0 UART on MacBook Pro.
# =============================================================================
echo -e "${BOLD}1. Remove wrong module blacklists${NC}"

BLACKLIST_FILES=$(grep -rl "blacklist hci_uart\|blacklist btusb" /etc/modprobe.d/ 2>/dev/null || true)
if [ -n "$BLACKLIST_FILES" ]; then
    for f in $BLACKLIST_FILES; do
        fix "Removing wrong blacklist entries from: $f"
        sed -i '/blacklist hci_uart/d' "$f"
        sed -i '/blacklist btusb/d' "$f"
        if [ ! -s "$f" ]; then
            rm -f "$f"
            ok "Removed empty blacklist file: $f"
        else
            ok "Cleaned blacklist entries from: $f"
        fi
    done
else
    ok "No wrong blacklist entries found"
fi
echo ""

# =============================================================================
# 2 — Remove incompatible USB firmware symlinks
#     BCM4350C5-0a5c-*.hcd is USB firmware — it breaks the UART chip.
# =============================================================================
echo -e "${BOLD}2. Remove incompatible USB firmware links${NC}"

FIRMWARE_DIR="/lib/firmware/brcm"
for fname in BCM.hcd BCM4350C0.hcd BCM4350C5.hcd; do
    fpath="$FIRMWARE_DIR/$fname"
    if [ -L "$fpath" ]; then
        target=$(readlink "$fpath")
        if echo "$target" | grep -q "0a5c"; then
            fix "Removing incompatible USB firmware symlink: $fname → $target"
            rm -f "$fpath"
            ok "Removed: $fpath"
        else
            ok "Symlink $fname preserved (not USB firmware)"
        fi
    fi
done
echo ""

# =============================================================================
# 3 — Fix /etc/bluetooth/main.conf
#     AutoEnable must be in [Policy] section, not [General].
#     BlueZ 5.x ignores it in [General] and logs an error.
# =============================================================================
echo -e "${BOLD}3. Fix /etc/bluetooth/main.conf${NC}"

MAIN_CONF="/etc/bluetooth/main.conf"
if [ ! -f "$MAIN_CONF" ]; then
    fix "Creating minimal $MAIN_CONF"
    cat > "$MAIN_CONF" << 'EOF'
[Policy]
AutoEnable=true
ReconnectAttempts=7
ReconnectIntervals=1,2,4,8,16,32,64
EOF
    ok "main.conf created"
else
    if ! grep -q "^\[Policy\]" "$MAIN_CONF"; then
        fix "Adding missing [Policy] section with AutoEnable=true"
        printf '\n[Policy]\nAutoEnable=true\nReconnectAttempts=7\nReconnectIntervals=1,2,4,8,16,32,64\n' >> "$MAIN_CONF"
        ok "[Policy] section added"
    else
        python3 - << 'PYEOF'
import re, sys

with open('/etc/bluetooth/main.conf', 'r') as f:
    lines = f.readlines()

in_policy = False
found = False
new_lines = []
for line in lines:
    stripped = line.strip()
    if stripped == '[Policy]':
        in_policy = True
    elif stripped.startswith('[') and stripped != '[Policy]':
        in_policy = False
    if in_policy and re.match(r'\s*#\s*AutoEnable\s*=', line):
        new_lines.append('AutoEnable=true\n')
        found = True
        continue
    if in_policy and re.match(r'\s*AutoEnable\s*=', line):
        found = True
    new_lines.append(line)

# Insert after [Policy] if not found at all
if not found:
    result = []
    for line in new_lines:
        result.append(line)
        if line.strip() == '[Policy]':
            result.append('AutoEnable=true\n')
    new_lines = result

with open('/etc/bluetooth/main.conf', 'w') as f:
    f.writelines(new_lines)
PYEOF
        ok "AutoEnable=true set in [Policy]"
    fi

    # Comment out any AutoEnable in [General] (incorrect location)
    if grep -A 20 "^\[General\]" "$MAIN_CONF" | grep -q "^AutoEnable=true"; then
        fix "Commenting out AutoEnable from [General] (wrong location)"
        sed -i '/^\[General\]/,/^\[/{s/^AutoEnable=true/#AutoEnable=true/}' "$MAIN_CONF"
        ok "AutoEnable disabled in [General]"
    fi
fi
echo ""

# =============================================================================
# 4 — Enable and start bluetooth service
# =============================================================================
echo -e "${BOLD}4. Bluetooth service${NC}"

systemctl is-enabled bluetooth &>/dev/null || { fix "Enabling bluetooth.service"; systemctl enable bluetooth; }
ok "bluetooth.service enabled"

if ! systemctl is-active bluetooth &>/dev/null; then
    fix "Starting bluetooth.service"
    systemctl start bluetooth
fi
ok "bluetooth.service active"
echo ""

# =============================================================================
# 5 — Firmware: delegate to macbook_hardware_fixer.sh
#     This script does NOT install firmware — the main fixer does.
# =============================================================================
echo -e "${BOLD}5. Bluetooth firmware status${NC}"

BT_FW="/lib/firmware/brcm/BCM4350C0.hcd"
if [ -f "$BT_FW" ]; then
    ok "BCM4350C0.hcd already installed: $BT_FW"
    if [ -L "/lib/firmware/brcm/BCM2E7C.hcd" ]; then
        ok "BCM2E7C.hcd symlink present (older kernel compat)"
    else
        fix "Adding BCM2E7C.hcd compatibility symlink"
        ln -sf BCM4350C0.hcd /lib/firmware/brcm/BCM2E7C.hcd
        ok "Symlink created"
    fi
else
    warn "BCM4350C0.hcd NOT installed — A2DP audio will be choppy without it"
    info "Fix: sudo bash macbook_hardware_fixer.sh  (step 2 installs the firmware)"
fi
echo ""

# =============================================================================
# 6 — Update initramfs
# =============================================================================
echo -e "${BOLD}6. Update initramfs${NC}"
fix "Running update-initramfs -u ..."
update-initramfs -u 2>&1 | tail -1
ok "initramfs updated"
echo ""

# =============================================================================
# Summary
# =============================================================================
sep
echo -e "${BOLD}${GREEN}  Done!${NC}"
sep
echo ""

if ! [ -f "$BT_FW" ]; then
    echo -e "  ${YELLOW}Next step:${NC} install the full firmware stack:"
    echo -e "    sudo bash macbook_hardware_fixer.sh"
    echo ""
fi

echo -e "  ${BOLD}Required — ONE-TIME SMC Reset${NC} (clears macOS 3 Mbaud baud rate):"
echo ""
echo -e "  1. Shutdown completely (NOT restart)"
echo -e "  2. Hold 10 s: ${YELLOW}Shift(L) + Ctrl(L) + Option(L) + Power${NC}"
echo -e "  3. Release all keys, press Power normally"
echo ""
echo -e "  After boot, verify: ${BOLD}hciconfig hci0${NC}  →  should show UP RUNNING"
echo ""

echo -e "  ${BOLD}What NOT to do on this Mac:${NC}"
echo -e "  ${RED}✗${NC} blacklist hci_uart   (hci_uart IS the correct driver)"
echo -e "  ${RED}✗${NC} modprobe btusb       (chip is UART, not USB)"
echo -e "  ${RED}✗${NC} BCM4350C5-0a5c-*.hcd firmware (USB firmware breaks UART chip)"
echo ""
sep
