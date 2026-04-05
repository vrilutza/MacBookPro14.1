#!/bin/bash

# =============================================================================
# MacBook Pro Hardware Verifier
# Checks that macbook_hardware_fixer.sh was applied correctly.
# Covers all 10 steps (0-10): Audio/CS8409, GPU, Bluetooth, WiFi, Camera,
# Thunderbolt, Battery/Thermal, applesmc, Touchpad/Keyboard, Brightness/Suspend.
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

pass() { echo -e "    ${GREEN}[✔]${NC} $1"; ((PASS++)); }
fail() { echo -e "    ${RED}[✘]${NC} $1"; ((FAIL++)); }
warn() { echo -e "    ${YELLOW}[!]${NC} $1"; ((WARN++)); }
info() { echo -e "    ${BLUE}[i]${NC} $1"; }
step() { echo -e "\n${BOLD}${BLUE}--- $1 ---${NC}"; }

IS_ROOT=false
[ "$EUID" -eq 0 ] && IS_ROOT=true

if [[ "${1}" == "-h" || "${1}" == "--help" ]]; then
    cat << EOF
Usage: $0 [--help]

Verifies that macbook_hardware_fixer.sh was correctly applied on this system.
Checks all 10 hardware steps (0-10).

Steps verified:
  [0/10] Cirrus CS8409 Audio  — .ko module file + lsmod
  [1/10] Intel Iris Plus 640  — VA-API packages + i915 driver
  [2/10] Bluetooth BCM4350C0  — firmware, hci0 status, bluez config, WirePlumber
  [3/10] WiFi BCM4350         — brcmfmac module, power save config
  [4/10] FaceTime HD Camera   — facetimehd module + firmware + /dev/video device
  [5/10] Thunderbolt 3        — bolt service
  [6/10] Battery & Thermal    — TLP + thermald services
  [7/10] applesmc             — fan, temperature sensors, keyboard backlight
  [8/10] Touchpad & Keyboard  — libinput config, hid_apple fnmode
  [9/10] Brightness + Suspend — brightnessctl, s2idle GRUB, NVMe d3cold service
  [10/10] System optimizations — ZRAM, BBR, NVMe scheduler, earlyoom

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
step "0/10 — Cirrus Logic CS8409 — HDA audio driver"

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

# =============================================================================
# STEP 1 — Intel Iris Plus 640 — VA-API
# =============================================================================
step "1/10 — Intel Iris Plus 640 GPU — VA-API"

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
step "2/10 — Bluetooth BCM4350C0 UART"

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

# Check if firmware was actually loaded (or errored at boot)
BT_JOURNAL=$(journalctl -b 0 -k --no-pager 2>/dev/null | grep -i "hci0.*BCM\|BCM.*hci0" | tail -5)
if echo "$BT_JOURNAL" | grep -q "firmware Patch file not found"; then
    fail "Kernel reported: firmware Patch file not found at boot"
    info "Chip running at default slow baud rate — A2DP will be choppy"
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
step "3/10 — WiFi BCM4350 — brcmfmac"

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
if [ -f "$BRCM_CONF" ] && grep -q "power_save=0" "$BRCM_CONF"; then
    pass "brcmfmac module options set: power_save=0 roamoff=1"
else
    fail "brcmfmac modprobe config missing or incomplete: $BRCM_CONF"
fi

# =============================================================================
# STEP 4 — FaceTime HD Camera
# =============================================================================
step "4/10 — FaceTime HD Camera — facetimehd"

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
step "5/10 — Thunderbolt 3 — bolt"

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
step "6/10 — Battery & Thermal — TLP + thermald"

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
    pass "macbook-rapl-limits service enabled (PL1=15W PL2=25W on boot)"
else
    fail "macbook-rapl-limits service NOT enabled — CPU overheating on every boot"
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
step "7/10 — applesmc: Fan / Sensors / Keyboard Backlight"

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
step "8/10 — Touchpad & Keyboard — libinput"

LIBINPUT_CONF="/usr/share/X11/xorg.conf.d/40-macbook-libinput.conf"
if [ -f "$LIBINPUT_CONF" ]; then
    pass "X11 libinput config present: $LIBINPUT_CONF"
    if grep -q "Tapping.*on" "$LIBINPUT_CONF"; then
        pass "tap-to-click configured in libinput"
    else
        warn "tap-to-click not found in $LIBINPUT_CONF"
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
step "9/10 — Screen Brightness + Suspend/Sleep"

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

# =============================================================================
# STEP 10 — System & Development optimizations
# =============================================================================
step "10/10 — System & Development optimizations"

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

# ulimits
NOFILE=$(ulimit -n 2>/dev/null || echo 0)
if [ "$NOFILE" -ge 65536 ] 2>/dev/null; then
    pass "Open file limit: $NOFILE (sufficient for Node.js / JVM / Docker)"
else
    warn "Open file limit: $NOFILE (low — may cause issues with Node.js or Docker)"
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
# AUDIO — delegate to verify-installation.sh
# =============================================================================
AUDIO_SCRIPT="$SCRIPT_DIR/verify-installation.sh"
if [ -f "$AUDIO_SCRIPT" ]; then
    echo -e "\n${BOLD}${BLUE}--- [+] Audio deep check — via verify-installation.sh ---${NC}"
    # Run and capture exit code, indent output
    bash "$AUDIO_SCRIPT" 2>&1 | grep -v "^======\|^    snd_hda" | sed 's/^/  /'
    AUDIO_RC=${PIPESTATUS[0]}
    if [ $AUDIO_RC -eq 0 ]; then
        ((PASS++))
    else
        ((WARN++))
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
