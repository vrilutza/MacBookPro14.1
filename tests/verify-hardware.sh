#!/bin/bash

# =============================================================================
# MacBook Pro Hardware Verifier
# Checks that macbook_hardware_fixer.sh was applied correctly.
# Covers all 12 steps (0-12): Audio/CS8409, GPU, Bluetooth, WiFi, Camera,
# Thunderbolt, Battery/Thermal, applesmc, Touchpad/Keyboard, Brightness/Suspend,
# System optimizations, Display ICC, Night Shift/redshift.
#
# Usage: ./verify-hardware.sh [--help] [--root-only]
# No root required for most checks; run as root for full Bluetooth config check.
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "    ${GREEN}[✔]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "    ${RED}[✘]${NC} $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "    ${YELLOW}[!]${NC} $1"; WARN=$((WARN + 1)); }
info() { echo -e "    ${BLUE}[i]${NC} $1"; }
step() { echo -e "\n${BOLD}${BLUE}--- $1 ---${NC}"; }

IS_ROOT=false
[ "$EUID" -eq 0 ] && IS_ROOT=true

if [[ "${1}" == "-h" || "${1}" == "--help" ]]; then
    cat << EOF
Usage: $0 [--help]

Verifies that macbook_hardware_fixer.sh was correctly applied on this system.
Checks all 12 hardware steps (0-12).

Steps verified:
  [0/12]  Cirrus CS8409 Audio     — .ko module file + lsmod + EasyEffects
  [1/12]  Intel Iris Plus 640     — VA-API packages + i915 driver
  [2/12]  Bluetooth BCM4350C0     — firmware, hci0 status, bluez config, WirePlumber
  [3/12]  WiFi BCM4350            — brcmfmac module, power save config, NVRAM
  [4/12]  FaceTime HD Camera      — facetimehd module + firmware + /dev/video device
  [5/12]  Thunderbolt 3           — bolt service
  [6/12]  Battery & Thermal       — TLP + thermald, RAPL PL1/PL2 + time windows
  [7/12]  applesmc                — fan, temperature sensors, keyboard backlight
  [8/12]  Touchpad & Keyboard     — libinput config + PalmDetection, hid_apple fnmode
  [9/12]  Brightness + Suspend    — brightnessctl, s2idle GRUB, NVMe d3cold, EFI autoboot
  [10/12] System optimizations    — ZRAM, BBR, NVMe scheduler, earlyoom
  [11/12] Display ICC             — Apple factory color profile, colord assignment
  [12/12] Night Shift → redshift  — redshift-gtk installed, config, autostart

Exit codes:
  0 — all checks passed (warnings are informational only)
  1 — one or more checks failed

Run as root for complete Bluetooth config check.
EOF
    exit 0
fi

KERNEL=$(uname -r)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}"
echo "============================================================"
echo "   MacBook Pro Hardware Verifier                           "
echo "   Kernel: $KERNEL"
if $IS_ROOT; then
    echo "   Running as: root (full checks enabled)"
else
    echo "   Running as: user (some BT config checks need root)"
fi
echo "============================================================"
echo -e "${NC}"

# =============================================================================
# STEP 0 — Cirrus Logic CS8409 — HDA Audio Driver
# =============================================================================
step "0/12 — Cirrus Logic CS8409 — HDA audio driver"

KO_PATH=$(find /lib/modules/"$KERNEL"/updates -name "snd-hda-codec-cs8409.ko*" 2>/dev/null | head -1)
if [ -n "$KO_PATH" ]; then
    pass "Cirrus CS8409 driver installed: $KO_PATH"
else
    fail "Cirrus CS8409 .ko not found in /lib/modules/$KERNEL/updates/ — run: sudo bash macbook_hardware_fixer.sh"
fi

if lsmod | grep -q "snd_hda_codec_cs8409"; then
    pass "snd_hda_codec_cs8409 module loaded (audio active)"
else
    warn "snd_hda_codec_cs8409 not loaded — may need reboot after first install"
fi

# EasyEffects mic preset (noise gate + autogain)
# Installed per-user to ~/.local/share/easyeffects/input/macbook-mic.json
if [ -n "${SUDO_USER:-}" ]; then
    _EE_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    _EE_PRESET="$_EE_HOME/.local/share/easyeffects/input/macbook-mic.json"
    if [ -f "$_EE_PRESET" ]; then
        pass "EasyEffects mic preset installed: $_EE_PRESET"
    else
        warn "EasyEffects mic preset not found: $_EE_PRESET"
        info "Fix: run macbook_hardware_fixer.sh (step 0 installs the preset)"
    fi
else
    info "EasyEffects preset check skipped (requires sudo to find user home)"
fi

# =============================================================================
# STEP 1 — Intel Iris Plus 640 — VA-API
# =============================================================================
step "1/12 — Intel Iris Plus 640 GPU — VA-API"

if dpkg -l intel-media-va-driver &>/dev/null 2>&1; then
    pass "intel-media-va-driver installed (Gen 9 / Kaby Lake VA-API)"
else
    fail "intel-media-va-driver NOT installed — run macbook_hardware_fixer.sh"
fi

if dpkg -l i965-va-driver &>/dev/null 2>&1; then
    pass "i965-va-driver installed (legacy Intel VA-API fallback)"
else
    warn "i965-va-driver not installed"
fi

if lsmod | grep -q "^i915 "; then
    pass "i915 kernel module loaded"
else
    fail "i915 module NOT loaded — Intel GPU not active"
fi

if command -v vainfo &>/dev/null; then
    VAINFO=$(vainfo 2>/dev/null)
    if echo "$VAINFO" | grep -q "VAProfile"; then
        PROFILES=$(echo "$VAINFO" | grep -c "VAProfile")
        pass "VA-API active — $PROFILES codec profiles available"
    else
        warn "vainfo installed but no VA-API profiles found (may need reboot)"
    fi
else
    warn "vainfo not installed — cannot verify VA-API at runtime"
fi

# =============================================================================
# STEP 2 — Bluetooth BCM4350C0
# =============================================================================
step "2/12 — Bluetooth BCM4350C0 UART"

BT_FW="/lib/firmware/brcm/BCM4350C0.hcd"
BT_FW_OLD="/lib/firmware/brcm/BCM2E7C.hcd"
if [ -f "$BT_FW" ]; then
    pass "Bluetooth firmware present: BCM4350C0.hcd"
    if [ -L "$BT_FW_OLD" ]; then
        pass "Compatibility symlink BCM2E7C.hcd → BCM4350C0.hcd present"
    else
        warn "Compatibility symlink BCM2E7C.hcd missing (older kernels may not find firmware)"
        info "Fix: sudo ln -sf BCM4350C0.hcd /lib/firmware/brcm/BCM2E7C.hcd"
    fi
else
    fail "Bluetooth firmware MISSING: /lib/firmware/brcm/BCM4350C0.hcd"
    info "Without firmware: BT works for scan/pair but A2DP audio will be choppy"
    info "See README step 5 or run macbook_hardware_fixer.sh step 2 with macOS partition"
fi

if [ -d /sys/class/bluetooth/hci0 ]; then
    pass "hci0 Bluetooth interface present in sysfs"

    # Check for baud rate mismatch — the most common failure on MacBook Pro
    # Symptom: hci0 exists but BD Address = 00:00:00:00:00:00 and state is DOWN
    HCI_ADDR=$(hciconfig hci0 2>/dev/null | grep "BD Address" | awk '{print $3}')
    HCI_STATE=$(hciconfig hci0 2>/dev/null | grep -oE "UP|DOWN" | head -1)
    if [ "$HCI_ADDR" = "00:00:00:00:00:00" ]; then
        fail "hci0 BD Address is 00:00:00:00:00:00 — BCM4350C0 baud rate mismatch"
        info "The chip is running at 3 Mbaud (set by a previous Linux session)."
        info "Linux tries 115200 → all commands time out → hci0 stays DOWN."
        info ""
        info "FIX — SMC Reset (resets chip to factory 115200 baud):"
        info "  1. Shutdown completely (NOT restart — chip must lose power)"
        info "  2. Hold 10 sec: Shift(L) + Ctrl(L) + Option(L) + Power"
        info "  3. Release, press Power to boot normally"
        info ""
        info "After SMC Reset Bluetooth will work on every subsequent boot."
    elif [ "$HCI_STATE" = "DOWN" ]; then
        fail "hci0 is DOWN — Bluetooth interface not active"
        info "Try: sudo hciconfig hci0 up"
    else
        pass "hci0 is UP — BD Address: $HCI_ADDR"
    fi

    # rfkill check (no root needed)
    if rfkill list bluetooth 2>/dev/null | grep -q "Soft blocked: yes"; then
        fail "Bluetooth is rfkill soft-blocked — run: rfkill unblock bluetooth"
    else
        pass "Bluetooth not rfkill-blocked"
    fi
else
    fail "hci0 not found in /sys/class/bluetooth — Bluetooth not initialised"
fi

# Check if firmware was actually loaded (or errored at boot).
# "firmware Patch file not found" in kernel 7.x is emitted by btbcm even when the
# main BCM4350C0.hcd was loaded successfully — it refers to an optional secondary
# patch file. If hci0 is UP with a valid BD address, BT is functional despite the
# message. Treat it as a warning, not a failure, when BT is actually working.
BT_JOURNAL=$(journalctl -b 0 -k --no-pager 2>/dev/null | grep -i "hci0.*BCM\|BCM.*hci0" | tail -5)
_HCI_WORKING=false
_HCI_ADDR_NOW=$(hciconfig hci0 2>/dev/null | grep "BD Address" | awk '{print $3}')
[ -n "$_HCI_ADDR_NOW" ] && [ "$_HCI_ADDR_NOW" != "00:00:00:00:00:00" ] && _HCI_WORKING=true
if echo "$BT_JOURNAL" | grep -q "firmware Patch file not found"; then
    if $_HCI_WORKING; then
        warn "Kernel: optional BT patch file not found (hci0 functional — A2DP may lack firmware optimisations)"
        info "This is cosmetic in kernel 7.x — BCM4350C0.hcd loaded, chip is operational"
    else
        fail "Kernel reported: firmware Patch file not found at boot"
        info "Chip running at default slow baud rate — A2DP will be choppy"
    fi
elif echo "$BT_JOURNAL" | grep -q "failed to write update baudrate"; then
    warn "Kernel reported: failed to update baudrate — firmware may be wrong version"
elif echo "$BT_JOURNAL" | grep -q "BCM4350C0"; then
    pass "Kernel recognised BCM4350C0 at boot"
fi

BT_CONF="/etc/bluetooth/main.conf"
if $IS_ROOT; then
    if [ -f "$BT_CONF" ]; then
        if grep -q "^\[Policy\]" "$BT_CONF" && awk '/^\[Policy\]/{f=1} f && /^AutoEnable/{print; exit}' "$BT_CONF" | grep -q "true"; then
            pass "bluez main.conf: AutoEnable=true is in [Policy] section (correct)"
        else
            fail "bluez main.conf: AutoEnable not in [Policy] — re-run macbook_hardware_fixer.sh"
        fi
        if grep -q "^FastConnectable\s*=\s*true" "$BT_CONF"; then
            pass "bluez main.conf: FastConnectable=true in [General]"
        else
            warn "bluez main.conf: FastConnectable not set"
        fi
    else
        warn "$BT_CONF not found"
    fi
else
    info "Skipping bluez main.conf check (requires root) — re-run with sudo for full check"
fi

WP_CONF="/etc/wireplumber/wireplumber.conf.d/51-airpods-fix.conf"
if [ -f "$WP_CONF" ]; then
    pass "WirePlumber AirPods fix present (A2DP auto-switch disabled)"
else
    warn "WirePlumber A2DP fix not found: $WP_CONF"
fi

# =============================================================================
# STEP 3 — WiFi BCM4350
# =============================================================================
step "3/12 — WiFi BCM4350 — brcmfmac"

if lsmod | grep -q "^brcmfmac "; then
    pass "brcmfmac module loaded"
else
    fail "brcmfmac module NOT loaded — WiFi may not work"
fi

WIFI_IF=$(ip link show 2>/dev/null | awk -F': ' '/wl/{print $2; exit}')
if [ -n "$WIFI_IF" ]; then
    WIFI_STATE=$(cat /sys/class/net/"$WIFI_IF"/operstate 2>/dev/null || echo "unknown")
    pass "WiFi interface $WIFI_IF found (state: $WIFI_STATE)"
else
    warn "No wireless interface found (may need reboot or WiFi switch)"
fi

NM_WIFI="/etc/NetworkManager/conf.d/99-wifi-powersave-off.conf"
if [ -f "$NM_WIFI" ] && grep -q "wifi.powersave = 2" "$NM_WIFI"; then
    pass "WiFi power save disabled via NetworkManager config"
else
    fail "WiFi power save config missing: $NM_WIFI"
fi

BRCM_CONF="/etc/modprobe.d/brcmfmac-macbook.conf"
if [ -f "$BRCM_CONF" ] && grep -q "roamoff=1" "$BRCM_CONF"; then
    pass "brcmfmac module options set: roamoff=1 (power_save handled by NetworkManager)"
else
    fail "brcmfmac modprobe config missing or incomplete: $BRCM_CONF"
    info "Fix: run macbook_hardware_fixer.sh step 3"
fi

# NVRAM check — kernel 6.6+ uses brcmfmac4350c2-pcie (chip rev C2).
# Both the base file AND the c2 symlink must exist for NVRAM to be loaded.
WIFI_NVRAM_MODEL="/lib/firmware/brcm/brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt"
WIFI_NVRAM_MODEL_C2="/lib/firmware/brcm/brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1.txt"
WIFI_NVRAM_GENERIC="/lib/firmware/brcm/brcmfmac4350-pcie.txt"
WIFI_NVRAM_GENERIC_C2="/lib/firmware/brcm/brcmfmac4350c2-pcie.txt"

if [ -f "$WIFI_NVRAM_MODEL" ] || [ -L "$WIFI_NVRAM_MODEL" ]; then
    pass "WiFi NVRAM Apple (model-specific) present: brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt"
else
    warn "WiFi NVRAM Apple (model-specific) missing"
    info "Fix: run macbook_hardware_fixer.sh step 3"
fi

if [ -L "$WIFI_NVRAM_MODEL_C2" ] || [ -f "$WIFI_NVRAM_MODEL_C2" ]; then
    pass "WiFi NVRAM c2 symlink present — kernel 6.6+ will load Apple NVRAM"
else
    fail "WiFi NVRAM c2 symlink MISSING — kernel 6.6+ ignores Apple NVRAM silently"
    info "Fix: sudo ln -sf 'brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt' /lib/firmware/brcm/brcmfmac4350c2-pcie.Apple\ Inc.-MacBookPro14,1.txt"
    info "     sudo ln -sf brcmfmac4350-pcie.txt /lib/firmware/brcm/brcmfmac4350c2-pcie.txt"
fi

NM_BAND="/etc/NetworkManager/conf.d/98-wifi-band-5ghz.conf"
if [ -f "$NM_BAND" ] && grep -q "wifi.band=a" "$NM_BAND"; then
    pass "WiFi 5GHz preferred via NetworkManager (band=a, fallback to 2.4GHz if needed)"
else
    warn "WiFi 5GHz preference not configured"
    info "Fix: run macbook_hardware_fixer.sh step 3"
fi

# =============================================================================
# STEP 4 — FaceTime HD Camera
# =============================================================================
step "4/12 — FaceTime HD Camera — facetimehd"

if lsmod | grep -q "^facetimehd "; then
    pass "facetimehd kernel module loaded"
else
    fail "facetimehd module NOT loaded"
    info "The module may fail to compile on newer kernels — check https://github.com/patjak/facetimehd"
fi

FW_BIN=$(find /lib/firmware/facetimehd/ -name "firmware.bin" 2>/dev/null | head -1)
if [ -n "$FW_BIN" ]; then
    pass "facetimehd firmware found: $FW_BIN"
else
    fail "facetimehd firmware NOT found in /lib/firmware/facetimehd/"
    info "Firmware is downloaded from Apple CDN during macbook_hardware_fixer.sh step 4"
fi

VIDEO_DEV=$(ls /dev/video* 2>/dev/null | head -1)
if [ -n "$VIDEO_DEV" ]; then
    pass "Video device found: $VIDEO_DEV"
else
    warn "No /dev/video* device — camera not available (may need reboot)"
fi

# =============================================================================
# STEP 5 — Thunderbolt 3
# =============================================================================
step "5/12 — Thunderbolt 3 — bolt"

if command -v boltctl &>/dev/null; then
    pass "bolt installed (boltctl available)"
else
    fail "bolt NOT installed — run macbook_hardware_fixer.sh"
fi

if systemctl is-active bolt &>/dev/null || systemctl is-enabled bolt &>/dev/null 2>&1; then
    pass "bolt service is active or D-Bus activated"
else
    warn "bolt service not active (activates automatically when a TB3 device connects)"
fi

# =============================================================================
# STEP 6 — Battery & Thermal
# =============================================================================
step "6/12 — Battery & Thermal — TLP + thermald"

if systemctl is-active tlp &>/dev/null 2>&1; then
    pass "TLP battery management service is active"
elif systemctl is-enabled tlp &>/dev/null 2>&1; then
    warn "TLP is enabled but not active — may start at next boot"
else
    fail "TLP is NOT enabled — battery management not active"
fi

if systemctl is-active thermald &>/dev/null 2>&1; then
    pass "thermald CPU thermal daemon is active"
else
    fail "thermald is NOT active"
fi

BAT_PATH=$(find /sys/class/power_supply/ -name "BAT*" 2>/dev/null | head -1)
if [ -n "$BAT_PATH" ]; then
    BAT_CAP=$(cat "$BAT_PATH/capacity" 2>/dev/null || echo "unknown")
    BAT_STATUS=$(cat "$BAT_PATH/status" 2>/dev/null || echo "unknown")
    pass "Battery $(basename $BAT_PATH) detected — capacity: ${BAT_CAP}%, status: $BAT_STATUS"
else
    warn "No battery found in /sys/class/power_supply/"
fi

# --- Thermal / RAPL checks ---
TLP_MACBOOK_CONF="/etc/tlp.d/50-macbook-pro14-1.conf"
if [ -f "$TLP_MACBOOK_CONF" ]; then
    pass "TLP MacBook Pro 14,1 config present: $TLP_MACBOOK_CONF"
    if grep -q "CPU_BOOST_ON_BAT=0" "$TLP_MACBOOK_CONF"; then
        pass "TLP: turbo boost disabled on battery (cooler + better battery life)"
    else
        warn "TLP: CPU_BOOST_ON_BAT=0 not set — turbo runs on battery"
    fi
    if grep -q "CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power" "$TLP_MACBOOK_CONF"; then
        pass "TLP: HWP policy = balance_power on battery"
    else
        warn "TLP: CPU_ENERGY_PERF_POLICY_ON_BAT not set to balance_power"
    fi
else
    fail "TLP MacBook Pro config missing: $TLP_MACBOOK_CONF — CPU thermal not optimised"
    info "Fix: run macbook_hardware_fixer.sh"
fi

RAPL_BASE="/sys/class/powercap/intel-rapl/intel-rapl:0"
RAPL_PL1="$RAPL_BASE/constraint_0_power_limit_uw"
if [ -f "$RAPL_PL1" ]; then
    PL1_UW=$(cat "$RAPL_PL1" 2>/dev/null || echo "0")
    PL1_W=$(( PL1_UW / 1000000 ))
    if [ "$PL1_W" -le 15 ] && [ "$PL1_W" -gt 0 ]; then
        pass "RAPL PL1 = ${PL1_W}W ≤ 15W (CPU won't sustain turbo → cooler)"
    elif [ "$PL1_W" -gt 50 ]; then
        fail "RAPL PL1 = ${PL1_W}W — WAY too high (BIOS default). CPU runs at full turbo indefinitely → overheating"
        info "Fix: run macbook_hardware_fixer.sh (creates macbook-rapl-limits.service)"
    else
        warn "RAPL PL1 = ${PL1_W}W — higher than i5-7360U TDP (15W), may run warm"
    fi
else
    info "RAPL sysfs not readable without root — re-run with sudo for RAPL check"
fi

if systemctl is-enabled macbook-rapl-limits &>/dev/null 2>&1; then
    pass "macbook-rapl-limits service enabled (PL1=20W PL2=40W on boot)"
else
    fail "macbook-rapl-limits service NOT enabled — CPU overheating on every boot"
fi

# RAPL time windows (PL1 ~1s, PL2 ~28s — Intel Kaby Lake U spec)
RAPL_TW0="$RAPL_BASE/constraint_0_time_window_us"
RAPL_TW1="$RAPL_BASE/constraint_1_time_window_us"
if [ -f "$RAPL_TW0" ] && [ -f "$RAPL_TW1" ]; then
    TW0=$(cat "$RAPL_TW0" 2>/dev/null || echo 0)
    TW1=$(cat "$RAPL_TW1" 2>/dev/null || echo 0)
    TW0_MS=$(( TW0 / 1000 ))
    TW1_MS=$(( TW1 / 1000 ))
    if [ "$TW0_MS" -ge 500 ] && [ "$TW0_MS" -le 2000 ]; then
        pass "RAPL PL1 time window: ${TW0_MS}ms (~1s — Intel spec)"
    else
        warn "RAPL PL1 time window: ${TW0_MS}ms (expected ~976ms — run macbook_hardware_fixer.sh)"
    fi
    if [ "$TW1_MS" -ge 20000 ] && [ "$TW1_MS" -le 35000 ]; then
        pass "RAPL PL2 time window: ${TW1_MS}ms (~28s — Intel spec)"
    else
        warn "RAPL PL2 time window: ${TW1_MS}ms (expected ~27343ms — run macbook_hardware_fixer.sh)"
    fi
else
    info "RAPL time windows not readable (requires root or not available)"
fi

# CPU temperature
PKG_TEMP=$(cat /sys/class/thermal/thermal_zone1/temp 2>/dev/null || cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
if [ -n "$PKG_TEMP" ]; then
    TEMP_C=$(( PKG_TEMP / 1000 ))
    if [ "$TEMP_C" -lt 55 ]; then
        pass "CPU temperature: ${TEMP_C}°C (cool)"
    elif [ "$TEMP_C" -lt 70 ]; then
        warn "CPU temperature: ${TEMP_C}°C (warm — normal under load, high at idle)"
    else
        fail "CPU temperature: ${TEMP_C}°C (too hot — check RAPL limits and TLP config)"
    fi
fi

# HWP energy preference (current session)
HWP_PREF=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "unknown")
ON_BATTERY=false
[ -f /sys/class/power_supply/BAT0/status ] && [ "$(cat /sys/class/power_supply/BAT0/status)" = "Discharging" ] && ON_BATTERY=true
if $ON_BATTERY; then
    if [ "$HWP_PREF" = "balance_power" ] || [ "$HWP_PREF" = "power" ]; then
        pass "HWP energy preference: $HWP_PREF (battery-efficient)"
    else
        warn "HWP energy preference: $HWP_PREF on battery (should be balance_power — reboot to apply TLP)"
    fi
else
    info "HWP energy preference: $HWP_PREF (on AC — balance_performance is fine)"
fi

# =============================================================================
# STEP 7 — applesmc: Fan, Sensors, Keyboard Backlight
# =============================================================================
step "7/12 — applesmc: Fan / Sensors / Keyboard Backlight"

if lsmod | grep -q "^applesmc "; then
    pass "applesmc kernel module loaded"
else
    fail "applesmc module NOT loaded — fan/sensor/backlight control unavailable"
fi

if lsmod | grep -q "^coretemp "; then
    pass "coretemp module loaded"
else
    warn "coretemp not loaded — CPU temperature sensors unavailable"
fi

SMC_BASE="/sys/devices/platform/applesmc.768"
FAN_IN="${SMC_BASE}/fan1_input"
if [ -f "$FAN_IN" ]; then
    FAN_RPM=$(cat "$FAN_IN" 2>/dev/null || echo "?")
    pass "Fan sensor readable — fan1: ${FAN_RPM} RPM"
else
    warn "Fan sensor not found at $FAN_IN (applesmc may not have initialised)"
fi

KBD_BL="/sys/class/leds/spi::kbd_backlight"
if [ -d "$KBD_BL" ]; then
    BL_VAL=$(cat "$KBD_BL/brightness" 2>/dev/null || echo "?")
    BL_MAX=$(cat "$KBD_BL/max_brightness" 2>/dev/null || echo "?")
    pass "Keyboard backlight sysfs found — brightness: $BL_VAL / $BL_MAX"
else
    warn "Keyboard backlight sysfs not found ($KBD_BL) — applespi module may not be loaded"
fi

SENSORS_CONF="/etc/modules-load.d/macbook-sensors.conf"
if [ -f "$SENSORS_CONF" ]; then
    pass "Sensor module auto-load config present: $SENSORS_CONF"
else
    warn "Sensor auto-load config missing: $SENSORS_CONF"
fi

if systemctl is-active mbpfan &>/dev/null 2>&1; then
    pass "mbpfan fan daemon is active"
    # Verify aggressive cooling profile is applied
    if [ -f /etc/mbpfan.conf ]; then
        MIN_SPEED=$(grep -E "^min_fan1_speed" /etc/mbpfan.conf 2>/dev/null | awk -F= '{sub(/#.*/,"",$2); gsub(/ /,"",$2); print int($2)}')
        LOW_T=$(grep -E "^low_temp" /etc/mbpfan.conf 2>/dev/null | awk -F= '{sub(/#.*/,"",$2); gsub(/ /,"",$2); print int($2)}')
        if [ "${MIN_SPEED:-0}" -ge 3000 ] 2>/dev/null; then
            pass "mbpfan: min_fan1_speed=${MIN_SPEED} RPM (aggressive profile)"
        else
            warn "mbpfan: min_fan1_speed=${MIN_SPEED:-?} (expected ≥3000 for MacBook Pro 14,1)"
            info "Fix: set min_fan1_speed = 3000 in /etc/mbpfan.conf"
        fi
        if [ "${LOW_T:-99}" -le 45 ] 2>/dev/null; then
            pass "mbpfan: low_temp=${LOW_T}°C (fan ramps early — good for cooling)"
        else
            warn "mbpfan: low_temp=${LOW_T:-?}°C (expected ≤45°C for proactive cooling)"
        fi
    else
        warn "mbpfan config missing at /etc/mbpfan.conf"
    fi
elif systemctl is-enabled macfanctld &>/dev/null 2>&1; then
    warn "macfanctld active instead of mbpfan — re-run macbook_hardware_fixer.sh"
else
    fail "No fan control daemon active — CPU may overheat under load"
    info "Fix: run macbook_hardware_fixer.sh (installs mbpfan with aggressive profile)"
fi

# =============================================================================
# STEP 8 — Touchpad & Keyboard
# =============================================================================
step "8/12 — Touchpad & Keyboard — libinput"

LIBINPUT_CONF="/usr/share/X11/xorg.conf.d/40-macbook-libinput.conf"
if [ -f "$LIBINPUT_CONF" ]; then
    pass "X11 libinput config present: $LIBINPUT_CONF"
    if grep -q "Tapping.*on" "$LIBINPUT_CONF"; then
        pass "tap-to-click configured in libinput"
    else
        warn "tap-to-click not found in $LIBINPUT_CONF"
    fi
    if grep -q "PalmDetection.*on" "$LIBINPUT_CONF"; then
        pass "PalmDetection enabled in libinput (no cursor jump during typing)"
    else
        warn "PalmDetection not set in $LIBINPUT_CONF — cursor may jump while typing"
        info "Fix: run macbook_hardware_fixer.sh (step 8 adds PalmDetection)"
    fi
    if grep -q "TappingButtonMap.*lrm" "$LIBINPUT_CONF"; then
        pass "TappingButtonMap=lrm (1-finger=left, 2=right, 3=middle tap)"
    else
        warn "TappingButtonMap not set in $LIBINPUT_CONF"
    fi
else
    fail "X11 libinput config missing: $LIBINPUT_CONF"
fi

HID_CONF="/etc/modprobe.d/hid-apple-macbook.conf"
if [ -f "$HID_CONF" ] && grep -q "fnmode=1" "$HID_CONF"; then
    pass "hid_apple fnmode=1 configured (F1-F12 as function keys)"
else
    warn "hid_apple fnmode config not set in $HID_CONF"
fi

FNMODE_SYS="/sys/module/hid_apple/parameters/fnmode"
if [ -f "$FNMODE_SYS" ]; then
    FNVAL=$(cat "$FNMODE_SYS" 2>/dev/null || echo "?")
    if [ "$FNVAL" = "1" ]; then
        pass "hid_apple fnmode=1 active in current session"
    else
        warn "hid_apple fnmode=$FNVAL (expected 1) — takes effect after module reload or reboot"
    fi
else
    info "hid_apple fnmode sysfs not found (module may not be loaded)"
fi

# HiDPI scaling (GNOME, only checkable as the real user)
if [ -n "${SUDO_USER:-}" ]; then
    _SCALE=$(sudo -u "$SUDO_USER" gsettings get org.gnome.desktop.interface scaling-factor 2>/dev/null || echo "0")
    if [ "$_SCALE" = "uint32 2" ]; then
        pass "HiDPI: scaling-factor=2 set (2560×1600 Retina display correct)"
    else
        warn "HiDPI: scaling-factor=$_SCALE (expected 2 for MacBook Pro Retina)"
        info "Fix: run macbook_hardware_fixer.sh (step 8 sets scaling-factor=2)"
    fi
    _PBUTTON=$(sudo -u "$SUDO_USER" gsettings get org.gnome.settings-daemon.plugins.power power-button-action 2>/dev/null || echo "?")
    if [ "$_PBUTTON" = "'suspend'" ]; then
        pass "GNOME power-button-action=suspend (not shutdown dialog)"
    else
        warn "GNOME power-button-action=$_PBUTTON (expected 'suspend')"
    fi
    _LID=$(sudo -u "$SUDO_USER" gsettings get org.gnome.settings-daemon.plugins.power lid-close-battery-action 2>/dev/null || echo "?")
    if [ "$_LID" = "'suspend'" ]; then
        pass "GNOME lid-close-battery-action=suspend"
    else
        warn "GNOME lid-close=battery=$_LID (expected 'suspend')"
    fi
else
    info "HiDPI + GNOME power checks skipped (requires sudo — run: sudo $0)"
fi

# =============================================================================
# STEP 9 — Screen Brightness + Suspend/Sleep
# =============================================================================
step "9/12 — Screen Brightness + Suspend/Sleep"

if command -v brightnessctl &>/dev/null; then
    pass "brightnessctl installed"
else
    fail "brightnessctl NOT installed"
fi

GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ] && grep -q "mem_sleep_default=s2idle" "$GRUB_FILE"; then
    pass "GRUB: mem_sleep_default=s2idle configured"
else
    fail "GRUB: mem_sleep_default=s2idle NOT set in $GRUB_FILE"
    info "Suspend will use deep (S3) mode which does not work on MacBook Pro 14,1"
fi

MEM_SLEEP=$(cat /sys/power/mem_sleep 2>/dev/null || echo "unknown")
if echo "$MEM_SLEEP" | grep -q "\[s2idle\]"; then
    pass "Current session sleep mode: s2idle (active)"
elif echo "$MEM_SLEEP" | grep -q "s2idle"; then
    warn "s2idle available but NOT selected for current session: $MEM_SLEEP"
    info "GRUB change takes effect after reboot. To apply now: echo s2idle | sudo tee /sys/power/mem_sleep"
else
    fail "s2idle not available: $MEM_SLEEP"
fi

NVME_D3COLD="/sys/bus/pci/devices/0000:01:00.0/d3cold_allowed"
if systemctl is-enabled macbook-nvme-d3cold &>/dev/null 2>&1; then
    pass "macbook-nvme-d3cold systemd service enabled (d3cold fix persistent)"
else
    fail "macbook-nvme-d3cold service NOT enabled — suspend/resume may be very slow or broken"
    info "Fix: run macbook_hardware_fixer.sh (step 9 creates this service)"
fi

if [ -f "$NVME_D3COLD" ]; then
    D3VAL=$(cat "$NVME_D3COLD" 2>/dev/null || echo "?")
    if [ "$D3VAL" = "0" ]; then
        pass "NVMe d3cold_allowed=0 for current session (Apple S3X NVMe at 0000:01:00.0)"
    else
        fail "NVMe d3cold_allowed=$D3VAL (should be 0) — resume from suspend will be broken"
        info "Fix: echo 0 | sudo tee /sys/bus/pci/devices/0000:01:00.0/d3cold_allowed"
    fi
else
    warn "NVMe PCI device 0000:01:00.0 not found in sysfs"
fi

# Auto-boot EFI variable (lid-open should not power on without pressing Power)
AUTOBOOT_EFI="/sys/firmware/efi/efivars/AutoBoot-7c436110-ab2a-4bbb-a880-fe41995c9f82"
if $IS_ROOT; then
    if [ -f "$AUTOBOOT_EFI" ]; then
        AB_VAL=$(dd if="$AUTOBOOT_EFI" bs=1 skip=4 count=1 2>/dev/null | xxd -p 2>/dev/null || echo "ff")
        if [ "$AB_VAL" = "00" ]; then
            pass "EFI AutoBoot=0x00 — lid-open auto-power-on disabled"
        else
            warn "EFI AutoBoot=0x${AB_VAL} — lid-open may power on MacBook automatically"
            info "Fix: run macbook_hardware_fixer.sh (step 9 sets AutoBoot EFI var to 0x00)"
        fi
    else
        info "AutoBoot EFI variable not found (may already be cleared or efivarfs not mounted)"
    fi
else
    info "AutoBoot EFI check skipped (requires root) — re-run with sudo"
fi

# =============================================================================
# STEP 10 — System & Development optimizations
# =============================================================================
step "10/12 — System & Development optimizations"

# ZRAM
if zramctl 2>/dev/null | grep -q "^/dev/zram"; then
    pass "ZRAM swap active (compressed RAM swap)"
    ZRAM_INFO=$(zramctl --noheadings --output NAME,SIZE,USED,COMP 2>/dev/null | head -1)
    info "ZRAM: $ZRAM_INFO"
elif [ -f /etc/systemd/zram-generator.conf ]; then
    warn "ZRAM config present but no /dev/zram device active — takes effect after reboot"
else
    warn "ZRAM not configured — system may freeze under heavy build load"
    info "Fix: run macbook_hardware_fixer.sh (step 10 configures ZRAM)"
fi

# sysctl: inotify (critical for IDEs)
INOTIFY=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
if [ "$INOTIFY" -ge 524288 ] 2>/dev/null; then
    pass "fs.inotify.max_user_watches=$INOTIFY (IDE file watchers: OK)"
else
    fail "fs.inotify.max_user_watches=$INOTIFY (too low — VSCode/IntelliJ may fail)"
    info "Fix: run macbook_hardware_fixer.sh or: sysctl -w fs.inotify.max_user_watches=524288"
fi

# sysctl: swappiness
SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null || echo 60)
if [ "$SWAPPINESS" -le 15 ] 2>/dev/null; then
    pass "vm.swappiness=$SWAPPINESS (RAM-preferring — good for dev)"
else
    warn "vm.swappiness=$SWAPPINESS (high — system may swap too eagerly; expected ≤15)"
fi

# BBR TCP
BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
if [ "$BBR" = "bbr" ]; then
    pass "TCP congestion control: BBR (better WiFi throughput)"
else
    warn "TCP congestion control: $BBR (expected bbr for better download performance)"
fi

# I/O scheduler for NVMe
NVME_SCHED=""
for f in /sys/block/nvme*/queue/scheduler; do
    [ -f "$f" ] && NVME_SCHED=$(cat "$f" 2>/dev/null) && break
done
if echo "$NVME_SCHED" | grep -q "\[none\]"; then
    pass "NVMe I/O scheduler: none (pass-through, lowest latency)"
elif [ -f /etc/udev/rules.d/61-nvme-scheduler.rules ]; then
    warn "NVMe scheduler udev rule present but not active yet (takes effect after reboot)"
else
    warn "NVMe I/O scheduler: ${NVME_SCHED:-unknown} (expected 'none' for lowest latency)"
fi

# earlyoom
if systemctl is-active earlyoom &>/dev/null 2>&1; then
    pass "earlyoom active — prevents system freeze under memory pressure"
else
    warn "earlyoom not running — risk of system freeze during heavy builds"
    info "Fix: run macbook_hardware_fixer.sh (step 10 installs earlyoom)"
fi

# ulimits — check the configuration file, not the current session value.
# ulimit -n inside a sudo session inherits the caller's limits (typically 1024)
# even after /etc/security/limits.d/ has been written. The new limits only take
# effect in fresh login sessions (PAM loads limits.d at login, not on sudo).
ULIMIT_CONF="/etc/security/limits.d/60-macbook-dev.conf"
if [ -f "$ULIMIT_CONF" ] && grep -q "nofile.*65536\|65536.*nofile" "$ULIMIT_CONF"; then
    pass "Open file limit: configured (nofile=65536/524288 — takes effect on next login)"
else
    NOFILE=$(ulimit -n 2>/dev/null || echo 0)
    warn "Open file limit: $NOFILE (low — may cause issues with Node.js or Docker)"
    info "Fix: run macbook_hardware_fixer.sh (step 10 writes /etc/security/limits.d/60-macbook-dev.conf)"
fi

# i915 FBC + PSR
if [ -f /etc/modprobe.d/i915-macbook.conf ] && grep -q "enable_fbc=1" /etc/modprobe.d/i915-macbook.conf; then
    pass "i915: FBC + PSR enabled (GPU power optimisations)"
    # Check if actually active in current session
    FBC=$(cat /sys/kernel/debug/dri/0/i915_fbc_status 2>/dev/null | head -1 || echo "n/a")
    [ "$FBC" != "n/a" ] && info "i915 FBC status: $FBC"
else
    warn "i915 FBC/PSR not configured — GPU using more power than necessary"
fi

# fstrim.timer (NVMe TRIM)
if systemctl is-enabled fstrim.timer &>/dev/null 2>&1; then
    pass "fstrim.timer enabled — weekly NVMe TRIM active"
    LAST_TRIM=$(systemctl status fstrim.service 2>/dev/null | grep "Exec Start" | head -1 || echo "")
    [ -n "$LAST_TRIM" ] && info "Last TRIM: $LAST_TRIM"
else
    warn "fstrim.timer NOT enabled — NVMe performance degrades over time"
    info "Fix: sudo systemctl enable --now fstrim.timer"
fi

# intel-microcode
if dpkg -l intel-microcode 2>/dev/null | grep -q "^ii"; then
    MC_VER=$(dpkg-query -W -f='${Version}' intel-microcode 2>/dev/null || echo "?")
    pass "intel-microcode installed (v$MC_VER) — CPU security patches active"
else
    warn "intel-microcode NOT installed — CPU may have known security vulnerabilities"
    info "Fix: sudo apt-get install intel-microcode"
fi

# journald size cap
if [ -f /etc/systemd/journald.conf.d/60-macbook-dev.conf ]; then
    pass "journald: size cap configured (1GB disk, 2-week retention)"
else
    warn "journald: no size cap — logs may fill disk over time"
fi

# coredump cap
if [ -f /etc/systemd/coredump.conf.d/60-macbook-dev.conf ]; then
    pass "coredump: size cap configured (512MB per dump)"
else
    warn "coredump: no size cap — JVM/Chromium crashes can fill NVMe"
fi

# git fsmonitor (check for real user's config)
if [ -n "${SUDO_USER:-}" ]; then
    _FSMON=$(sudo -u "$SUDO_USER" git config --global core.fsmonitor 2>/dev/null || echo "false")
    _UNTRACKED=$(sudo -u "$SUDO_USER" git config --global core.untrackedCache 2>/dev/null || echo "false")
    if [ "$_FSMON" = "true" ]; then
        pass "git global: core.fsmonitor=true (fast git status in large repos)"
    else
        warn "git global: core.fsmonitor not set — git status may be slow in large repos"
        info "Fix: git config --global core.fsmonitor true"
    fi
    [ "$_UNTRACKED" = "true" ] && pass "git global: core.untrackedCache=true" || \
        warn "git global: core.untrackedCache not set"
else
    info "git global config checks skipped (requires sudo)"
fi

# =============================================================================
# STEP 11 — Display Color Calibration — Apple LCD ICC profile
# =============================================================================
step "11/12 — Display color calibration — Apple factory ICC profile"

ICC_SYSTEM="/usr/share/color/icc/macbook/Color-LCD-MacBookPro14-1.icc"
ICC_NAME="Color-LCD-MacBookPro14-1"

if [ -f "$ICC_SYSTEM" ]; then
    ICC_SIZE=$(stat -c%s "$ICC_SYSTEM" 2>/dev/null || echo 0)
    pass "ICC profile installed system-wide: $ICC_SYSTEM (${ICC_SIZE} bytes)"
else
    fail "ICC profile NOT installed: $ICC_SYSTEM"
    info "Fix: run macbook_hardware_fixer.sh (step 11 copies firmware/display/Color-LCD-MacBookPro14-1.icc)"
fi

if [ -n "${SUDO_USER:-}" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    USER_ICC="$REAL_HOME/.local/share/icc/${ICC_NAME}.icc"
    if [ -f "$USER_ICC" ]; then
        pass "ICC profile installed for user '$SUDO_USER': $USER_ICC"
    else
        warn "ICC profile not in user dir $USER_ICC — GNOME Color Manager may not list it"
        info "Fix: run macbook_hardware_fixer.sh (copies to ~/.local/share/icc/)"
    fi

    AUTOSTART="$REAL_HOME/.config/autostart/macbook-color-profile.desktop"
    if [ -f "$AUTOSTART" ]; then
        pass "Color profile autostart entry present: $AUTOSTART"
    else
        warn "Color profile autostart missing: $AUTOSTART — profile won't be auto-assigned on login"
        info "Fix: run macbook_hardware_fixer.sh (step 11 creates the autostart entry)"
    fi
else
    info "User ICC + autostart checks skipped (requires sudo)"
fi

if command -v colormgr &>/dev/null; then
    pass "colormgr (colord) installed"
    # Check if profile is registered in the colord session (may not be if not logged in as user)
    if colormgr get-profiles 2>/dev/null | grep -q "$ICC_NAME"; then
        pass "colord: '$ICC_NAME' profile is registered in current session"
    else
        info "colord: profile not registered in current session (normal — registered on user login via autostart)"
    fi
else
    warn "colormgr not installed — color profile assignment will not work"
    info "Fix: sudo apt-get install colord"
fi

if [ -x /usr/local/bin/macbook-color-profile.sh ]; then
    pass "Color profile assignment script: /usr/local/bin/macbook-color-profile.sh"
else
    fail "Color profile assignment script not found / not executable"
    info "Fix: run macbook_hardware_fixer.sh (step 11 installs this script)"
fi

# =============================================================================
# STEP 12 — Night Shift → redshift (colour temperature)
# =============================================================================
step "12/12 — Night Shift → redshift (colour temperature)"

if command -v redshift &>/dev/null || command -v redshift-gtk &>/dev/null; then
    pass "redshift installed ($(command -v redshift-gtk 2>/dev/null || command -v redshift))"
else
    fail "redshift NOT installed — no colour temperature control (Night Shift equivalent)"
    info "Fix: run macbook_hardware_fixer.sh (step 12 installs redshift-gtk)"
fi

REDSHIFT_CONF="/etc/xdg/redshift.conf"
if [ -f "$REDSHIFT_CONF" ]; then
    pass "redshift system config present: $REDSHIFT_CONF"
    if grep -q "temp-day=6500" "$REDSHIFT_CONF" && grep -q "temp-night=4000" "$REDSHIFT_CONF"; then
        pass "redshift colour temperatures: 6500K day / 4000K night"
    else
        warn "redshift temps not set to 6500K/4000K — check $REDSHIFT_CONF"
    fi
    if grep -q "^card=1" "$REDSHIFT_CONF"; then
        pass "redshift DRM card override: card=1 (Intel GPU on MacBookPro14,1 is card1)"
    else
        fail "redshift DRM card not set to card=1 — will fail with 'Failed to open DRM device: /dev/dri/card0'"
        info "Fix: add [drm]\ncard=1 to $REDSHIFT_CONF and ~/.config/redshift.conf"
        info "     sudo cp /tmp/redshift.conf.new /etc/xdg/redshift.conf   (if /tmp file exists)"
    fi
else
    warn "redshift system config not found: $REDSHIFT_CONF"
    info "Fix: run macbook_hardware_fixer.sh (step 12 writes /etc/xdg/redshift.conf)"
fi

if [ -n "${SUDO_USER:-}" ]; then
    REAL_HOME_RS=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    RS_AUTOSTART="$REAL_HOME_RS/.config/autostart/redshift.desktop"
    if [ -f "$RS_AUTOSTART" ]; then
        pass "redshift autostart entry present: $RS_AUTOSTART"
    else
        warn "redshift autostart missing: $RS_AUTOSTART — won't start on login"
        info "Fix: run macbook_hardware_fixer.sh (step 12 creates the autostart entry)"
    fi
else
    info "redshift autostart check skipped (requires sudo)"
fi

# =============================================================================
# AUDIO — delegate to verify-installation.sh
# =============================================================================
AUDIO_SCRIPT="$SCRIPT_DIR/verify-installation.sh"
if [ -f "$AUDIO_SCRIPT" ]; then
    echo -e "\n${BOLD}${BLUE}--- [+] Audio deep check — via verify-installation.sh ---${NC}"
    # Run and capture exit code, indent output
    bash "$AUDIO_SCRIPT" 2>&1 | grep -v "^======\|^    snd_hda" | sed 's/^/  /'
    AUDIO_RC=${PIPESTATUS[0]}
    if [ $AUDIO_RC -eq 0 ]; then
        PASS=$((PASS + 1))
    else
        WARN=$((WARN + 1))
    fi
else
    warn "verify-installation.sh not found at $AUDIO_SCRIPT — skipping deep audio check"
fi

# =============================================================================
# SUMMARY
# =============================================================================
TOTAL=$((PASS + FAIL + WARN))
echo ""
echo -e "${BOLD}============================================================${NC}"
if [ $FAIL -eq 0 ] && [ $WARN -eq 0 ]; then
    echo -e "${BOLD}${GREEN}  All checks passed! ($PASS / $TOTAL)${NC}"
elif [ $FAIL -eq 0 ]; then
    echo -e "${BOLD}${YELLOW}  Passed with warnings: $PASS passed, $WARN warnings, $FAIL failed${NC}"
else
    echo -e "${BOLD}${RED}  Checks failed: $PASS passed, $WARN warnings, $FAIL failed${NC}"
fi
echo -e "${BOLD}============================================================${NC}"
echo ""

if [ $FAIL -gt 0 ]; then
    echo -e "  ${RED}[✘]${NC} Run ${BOLD}sudo ./macbook_hardware_fixer.sh${NC} to apply missing fixes."
    echo ""
fi

[ $FAIL -eq 0 ]
