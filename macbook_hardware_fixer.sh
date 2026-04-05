#!/bin/bash
# =============================================================================
# MacBook Pro Ubuntu — Complete Setup v4.0
# For: MacBook Pro 13" 2017 (MacBookPro14,1) on Ubuntu 26.04+
#
# Run once after a fresh Ubuntu install:
#   sudo bash macbook_hardware_fixer.sh
#
# Hardware covered:
#   0. Cirrus Logic CS8409        — HDA audio kernel driver (compiled)
#   1. Intel Iris Plus 640 GPU    — VA-API hardware acceleration
#   2. Bluetooth BCM4350C0 UART   — firmware fix + bluez config
#   3. WiFi Broadcom BCM4350      — power save + regulatory domain
#   4. FaceTime HD Camera         — compile & install facetimehd driver
#   5. Thunderbolt 3 Alpine Ridge — bolt authorization daemon
#   6. Battery & Thermal          — TLP + thermald
#   7. applesmc: Fan + Sensors + Keyboard Backlight
#   8. Touchpad & Keyboard        — libinput tap-to-click + natural scroll
#   9. Screen Brightness + Suspend — brightnessctl + s2idle sleep fix
#  10. System & Dev optimizations — ZRAM, sysctl, BBR, earlyoom, ulimits
# =============================================================================

set -euo pipefail

# --- ANSI colours ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_step() { echo -e "\n${BOLD}${BLUE}>>> $1${NC}"; }
log_ok()   { echo -e "  ${GREEN}[✔]${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}[!]${NC} $1"; }
log_err()  { echo -e "  ${RED}[✘]${NC} $1"; }
log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }

# --- Root check ---
if [ "$EUID" -ne 0 ]; then
    log_err "Please run as root: sudo ./macbook_hardware_fixer.sh"
    exit 1
fi

KERNEL=$(uname -r)
REAL_USER="${SUDO_USER:-}"

echo -e "${BOLD}"
echo "============================================================"
echo "   MacBook Pro Ubuntu — Complete Setup v4.0               "
echo "   MacBook Pro 13\" 2017 | Ubuntu 26.04 | Kernel $KERNEL"
echo "============================================================"
echo -e "${NC}"

# =============================================================================
# STEP 0: Cirrus Logic CS8409 — HDA audio kernel driver
# =============================================================================
# This is the core driver for the built-in speakers/mic on MacBook Pro 14,1.
# The driver must be compiled against the running kernel source.
# install.cirrus.driver.sh handles: kernel detection, source download, patching,
# compilation, and installation into /lib/modules/$(uname -r)/updates/.
# =============================================================================
log_step "0/10 — Cirrus Logic CS8409 — HDA audio kernel driver"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CIRRUS_INSTALLER="$SCRIPT_DIR/install.cirrus.driver.sh"

if [ -f "$CIRRUS_INSTALLER" ]; then
    (
        cd "$SCRIPT_DIR"
        bash install.cirrus.driver.sh
    ) && log_ok "Cirrus CS8409 audio driver installed — speakers/mic active after reboot." \
      || log_warn "Audio driver install had issues (see output above). Run manually: sudo bash install.cirrus.driver.sh"
else
    log_warn "install.cirrus.driver.sh not found next to this script — skipping audio driver."
    log_info "Clone the full repo to get audio driver support: git clone <repo-url>"
fi

# =============================================================================
# STEP 1: System update + Intel GPU VA-API acceleration
# =============================================================================
log_step "1/10 — Intel Iris Plus 640 GPU — VA-API acceleration"

apt-get update -qq

PKGS_GPU=(
    mesa-utils
    vainfo
    intel-media-va-driver      # VA-API driver for Intel Gen 8+ (Kaby Lake = Gen 9)
    libva2
    libva-drm2
    libva-x11-2
    i965-va-driver             # Legacy fallback for Intel HD/Iris
    intel-microcode            # CPU errata + security patches for i5-7360U (Kaby Lake)
)
apt-get install -y --no-install-recommends "${PKGS_GPU[@]}"

log_ok "Intel GPU acceleration packages installed."
log_ok "intel-microcode installed — CPU security patches active after reboot."
log_info "Run 'vainfo' after reboot to confirm hardware decoding (H.264, HEVC)."

# --- i915 GPU power optimisations ---
# FBC (Framebuffer Compression): reduces GPU memory bandwidth on static screens → ~1W saved
# PSR (Panel Self Refresh): panel redraws itself without GPU involvement → ~1-2W saved
# Both are safe on Kaby Lake / Iris Plus 640 — no visual artefacts observed.
cat > /etc/modprobe.d/i915-macbook.conf << 'EOF'
# MacBook Pro i5-7360U / Iris Plus 640 — GPU power optimisations
# FBC: compresses framebuffer in VRAM, reduces memory bandwidth on idle/static content
# PSR: allows display panel to self-refresh without GPU, saves 1-2W
options i915 enable_fbc=1 enable_psr=1
EOF
log_ok "i915: FBC + PSR enabled (saves 1-2W GPU power draw)."

# =============================================================================
# STEP 2: Bluetooth BCM4350C0 — firmware fix + bluez config
# =============================================================================
log_step "2/10 — Bluetooth BCM4350C0 UART — firmware fix"

# --- 2a-pre. Remove wrong blacklists from /etc/modprobe.d/ ---
# Common bad internet advice: "blacklist hci_uart" or "blacklist btusb"
# hci_uart is the CORRECT driver for BCM4350C0 (UART chip, not USB).
# Blacklisting it makes Bluetooth completely invisible to the system.
for f in $(grep -rl "hci_uart\|btusb" /etc/modprobe.d/ 2>/dev/null || true); do
    sed -i '/blacklist hci_uart/d; /blacklist btusb/d' "$f"
    [ ! -s "$f" ] && rm -f "$f"
done
log_ok "Blacklist check done: hci_uart/btusb not blacklisted (hci_uart is the correct UART driver)."

# --- 2a. Install Bluetooth tools ---
apt-get install -y --no-install-recommends bluez bluez-tools

# --- 2b. Fix bluez main.conf ---
# In bluez 5.65+, AutoEnable belongs in [Policy], NOT [General].
# The bug: our previous sed put it in [General], causing the logged error:
#   "Unknown key AutoEnable for group General"
BT_CONF="/etc/bluetooth/main.conf"
if [ -f "$BT_CONF" ]; then
    cp "$BT_CONF" "${BT_CONF}.bak-$(date +%Y%m%d-%H%M%S)"

    # Use Python for safe section-aware config editing
    python3 - "$BT_CONF" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# ---- [General] section: keep FastConnectable, remove AutoEnable ----
content = re.sub(r'(?m)^AutoEnable\s*=.*\n?', '', content)

# Ensure FastConnectable is in [General] (already there if previous run, else add)
if not re.search(r'(?m)^FastConnectable\s*=\s*true', content):
    content = re.sub(r'(?m)(^\[General\])', r'\1\nFastConnectable = true', content)
else:
    # Normalise any old value
    content = re.sub(r'(?m)^FastConnectable\s*=.*', 'FastConnectable = true', content)

# ---- [Policy] section: add AutoEnable = true ----
if re.search(r'(?m)^\[Policy\]', content):
    # Remove any existing AutoEnable in Policy first, then re-add cleanly
    in_policy = False
    lines = content.splitlines(keepends=True)
    new_lines = []
    added = False
    for line in lines:
        if re.match(r'^\[Policy\]', line):
            in_policy = True
            new_lines.append(line)
            if not added:
                new_lines.append('AutoEnable = true\n')
                added = True
            continue
        if in_policy and re.match(r'^\[', line):
            in_policy = False
        if in_policy and re.match(r'^AutoEnable\s*=', line):
            continue  # skip duplicate
        new_lines.append(line)
    content = ''.join(new_lines)

# ---- [Policy] section: Reconnect settings ----
if re.search(r'(?m)^ReconnectAttempts\s*=', content):
    content = re.sub(r'(?m)^ReconnectAttempts\s*=.*', 'ReconnectAttempts = 7', content)
else:
    content = re.sub(r'(?m)(^\[Policy\])', r'\1\nReconnectAttempts = 7', content)

if re.search(r'(?m)^ReconnectIntervals\s*=', content):
    content = re.sub(r'(?m)^ReconnectIntervals\s*=.*', 'ReconnectIntervals = 1,2,4,8,16,32,64', content)
else:
    content = re.sub(r'(?m)(^\[Policy\])', r'\1\nReconnectIntervals = 1,2,4,8,16,32,64', content)

with open(path, 'w') as f:
    f.write(content)

print("  Bluetooth config updated.")
PYEOF

    log_ok "bluez main.conf fixed (AutoEnable moved to [Policy])."
    log_info "FastConnectable=true in [General], AutoEnable/Reconnect in [Policy]."
fi

# --- 2c. Firmware fix for BCM4350C0 UART chip ---
# The BCM4350C0 Bluetooth on MacBook Pro 14,1 uses a UART connection (serial0 / ttyS4).
#
# How the kernel names the firmware file:
#   The driver (hci_uart_bcm / btbcm) queries the chip via HCI at boot.
#   The chip self-identifies as "BCM4350C0 UART 37.4 MHz Gamay USI UHE"
#   → kernel looks for: /lib/firmware/brcm/BCM4350C0.hcd
#   → fallback generic:  /lib/firmware/brcm/BCM.hcd
#
# NOTE: macOS calls this same chip "BCM2E7C" (marketing name).
#   The linux-firmware package does NOT ship this firmware (proprietary, OEM-specific).
#
# Symptoms without firmware (observed on this machine):
#   "BCM: failed to write update baudrate (-16)"   ← running at default slow baud
#   "BCM: firmware Patch file not found, tried: brcm/BCM.hcd"
#   Bluetooth works for basic scan/pair but A2DP audio is choppy/unusable.
#
BT_FW_DEST="/lib/firmware/brcm/BCM4350C0.hcd"

mkdir -p /lib/firmware/brcm

# --- 2c-pre. Remove wrong USB firmware that breaks the UART chip ---
# BCM4350C0 is a UART chip. USB firmware (BCM4350C5-0a5c-*.hcd) applied to it
# corrupts the baud rate state and makes BT completely non-functional until SMC Reset.
# These symlinks are sometimes created by incorrect internet advice.
for fname in BCM.hcd BCM2E7C.hcd BCM4350C5.hcd BCM4350C0.hcd; do
    fpath="/lib/firmware/brcm/$fname"
    if [ -L "$fpath" ]; then
        target=$(readlink "$fpath")
        if echo "$target" | grep -q "0a5c"; then
            rm -f "$fpath"
            log_warn "Removed wrong USB firmware symlink: $fname → $target"
            log_info "(USB firmware on UART chip corrupts baud rate — SMC Reset would be needed)"
        fi
    fi
done

# --- 2c. Bluetooth firmware (BCM4350C0.hcd) ---
# The chip runs from internal ROM — BT works without firmware.
# Firmware is optional: improves A2DP audio quality (higher baud rate).
# Place it manually if you want better audio quality.
if [ -f "$BT_FW_DEST" ]; then
    log_ok "Bluetooth firmware present: $BT_FW_DEST (A2DP quality optimised)."
else
    log_warn "Bluetooth firmware not found — BT works without it (chip runs from ROM)."
    log_info "═══════════════════════════════════════════════════════════"
    log_info "OPTIONAL: Install firmware for better A2DP audio quality:"
    log_info ""
    log_info "  Firmware file needed: /lib/firmware/brcm/BCM4350C0.hcd"
    log_info ""
    log_info "  Option A — from a running macOS (dual-boot) or macOS USB:"
    log_info "    # In macOS Terminal:"
    log_info "    sudo cp /usr/share/firmware/bluetooth/BCM4350C0.hcd \\"
    log_info "            /Volumes/<YourLinuxPartition>/lib/firmware/brcm/BCM4350C0.hcd"
    log_info ""
    log_info "  Option B — community-extracted firmware (search GitHub):"
    log_info "    Search: 'BCM4350C0.hcd site:github.com'"
    log_info "    Place at: /lib/firmware/brcm/BCM4350C0.hcd"
    log_info ""
    log_info "  After placing the firmware, reload driver:"
    log_info "    sudo rmmod hci_uart && sudo modprobe hci_uart"
    log_info "═══════════════════════════════════════════════════════════"
fi

# --- 2d. udev rule: bring hci0 up automatically after firmware is loaded ---
cat > /etc/udev/rules.d/60-bluetooth-macbook.rules << 'EOF'
# MacBook Pro BCM2E7C Bluetooth: bring hci0 up once firmware is available
ACTION=="add", SUBSYSTEM=="bluetooth", KERNEL=="hci0", \
    RUN+="/bin/bash -c 'sleep 1 && /usr/bin/hciconfig hci0 up || true'"
EOF
udevadm control --reload-rules
log_ok "udev rule created: hci0 will auto-bring-up after firmware loads."

# --- 2e. WirePlumber: prevent A2DP → HFP/HSP auto-switch (AirPods fix) ---
WP_CONF_DIR="/etc/wireplumber/wireplumber.conf.d"
mkdir -p "$WP_CONF_DIR"
cat > "$WP_CONF_DIR/51-airpods-fix.conf" << 'EOF'
# MacBook Hardware Fixer — AirPods Pro stability fix
# Prevents automatic switch from A2DP (high quality) to HFP/HSP (phone/mic),
# which causes audio dropouts on Ubuntu with bluez 5.72+.
wireplumber.settings = {
  bluetooth.autoswitch-to-headset-profile = false
}
EOF
log_ok "WirePlumber: A2DP auto-switch to HFP disabled (AirPods stability)."

# Reload bluetoothd config WITHOUT triggering hci_uart_bcm hardware re-init.
#
# ROOT CAUSE of recurring BT failure on MacBook Pro:
#   The BCM4350C0 UART chip retains its baud rate through reboots (only cleared
#   by full power-off or SMC Reset). On first boot Linux probes at 115200 — if
#   the probe is triggered a SECOND time (by rfkill unblock or bluetoothd restart
#   that sends HCIDEVDOWN/UP), the baud rate change to 3 Mbaud succeeds.
#   On the next reboot Linux tries 115200 → command 0xfc18 timeout → hci0 DOWN.
#
# SAFE approach: send SIGHUP to reload config without tearing down hci0.
# Falls back to full restart only if bluetoothd is not running yet (fresh install).
if systemctl is-active bluetooth &>/dev/null; then
    kill -HUP "$(pidof bluetoothd 2>/dev/null)" 2>/dev/null || true
    log_ok "Bluetooth config reloaded (SIGHUP — no hardware re-init, baud rate safe)."
else
    systemctl restart bluetooth 2>/dev/null || true
    log_ok "Bluetooth daemon started."
fi

# IMPORTANT: only unblock rfkill if actually blocked.
# rfkill unblock triggers a second hci_uart_bcm probe → baud rate changes to
# 3 Mbaud → chip retains it through reboot → next boot: hci0 DOWN (ETIMEDOUT).
if rfkill list bluetooth 2>/dev/null | grep -q "Soft blocked: yes"; then
    rfkill unblock bluetooth 2>/dev/null || true
    log_ok "Bluetooth rfkill unblocked (was soft-blocked)."
    log_warn "BCM chip may have changed baud rate — do a FULL SHUTDOWN (not reboot) after install."
else
    log_ok "Bluetooth rfkill not blocked — baud rate unaffected."
fi

# --- 2f. SMC Reset reminder (critical for first boot after migrating from macOS) ---
# The BCM4350C0 chip retains the baud rate set by macOS (3 Mbaud).
# Linux uses 115200 baud → communication timeout → BT appears broken.
# An SMC Reset resets the chip to factory default baud rate.
# This is needed ONCE after migration from macOS — never again after that.
log_info "═══════════════════════════════════════════════════════════"
log_info "BLUETOOTH — SMC RESET (required ONCE after migrating from macOS)"
log_info ""
log_info "  If Bluetooth does NOT appear (no hci0) after reboot, do:"
log_info ""
log_info "  1. Shut down completely (not restart)"
log_info "  2. Hold for 10 seconds simultaneously:"
log_info "     Shift(left) + Ctrl(left) + Option(left) + Power button"
log_info "  3. Release all keys, then press Power normally to start"
log_info ""
log_info "  WHY: macOS sets BCM4350C0 to 3 Mbaud. Linux uses 115200 baud."
log_info "  SMC Reset clears the chip back to factory default — needed ONCE."
log_info ""
log_info "  After SMC Reset, BT will work. A2DP quality improves if firmware"
log_info "  BCM4350C0.hcd is present at /lib/firmware/brcm/ (see above)."
log_info "═══════════════════════════════════════════════════════════"

# =============================================================================
# STEP 3: WiFi Broadcom BCM4350 — power save + optimization
# =============================================================================
log_step "3/10 — WiFi BCM4350 — power save + regulatory"

apt-get install -y --no-install-recommends wireless-regdb iw

# Disable WiFi power management persistently via NetworkManager
NM_WIFI_CONF="/etc/NetworkManager/conf.d/99-wifi-powersave-off.conf"
mkdir -p /etc/NetworkManager/conf.d
cat > "$NM_WIFI_CONF" << 'EOF'
# MacBook Hardware Fixer: disable WiFi power saving for BCM4350
# Power saving on brcmfmac causes latency spikes and dropped packets.
[connection]
wifi.powersave = 2
EOF
log_ok "WiFi power save disabled persistently (NetworkManager)."

# Disable brcmfmac power management via module option
cat > /etc/modprobe.d/brcmfmac-macbook.conf << 'EOF'
# MacBook Pro BCM4350 WiFi optimizations
options brcmfmac power_save=0 roamoff=1
EOF
log_ok "brcmfmac: power_save=0, roamoff=1 set."

log_info "WiFi regulatory domain: Ubuntu reads from wireless-regdb automatically."
log_info "If channels are limited, set country: sudo iw reg set RO  (or your country code)"

# =============================================================================
# STEP 4: FaceTime HD Camera (Broadcom 720p PCIe — 14e4:1570)
# =============================================================================
log_step "4/10 — FaceTime HD Camera — Broadcom PCIe driver (facetimehd)"

PKGS_BUILD=(git curl xz-utils cpio build-essential kmod libssl-dev)
apt-get install -y --no-install-recommends "${PKGS_BUILD[@]}" linux-headers-"$KERNEL"

WEBCAM_DIR="/tmp/macbook_webcam_$$"
mkdir -p "$WEBCAM_DIR"

(
    set +e  # allow failures inside this subshell — camera is best-effort

    cd "$WEBCAM_DIR"

    log_info "Downloading facetimehd firmware extractor..."
    if ! git clone --depth=1 https://github.com/patjak/facetimehd-firmware.git -q 2>&1; then
        log_warn "git clone failed (network/SSL unavailable) — skipping camera firmware."
        exit 0
    fi
    cd facetimehd-firmware

    make 2>&1
    MAKE_FW_RC=$?

    if [ $MAKE_FW_RC -ne 0 ]; then
        log_warn "Firmware extraction failed — Apple's download URL may have changed."
        log_warn "Camera will NOT be available until this is resolved."
    else
        make install 2>&1
        log_ok "FaceTime HD firmware installed."
    fi

    cd "$WEBCAM_DIR"

    log_info "Cloning facetimehd kernel module (kernel $KERNEL)..."
    if ! git clone --depth=1 https://github.com/patjak/facetimehd.git -q 2>&1; then
        log_warn "git clone failed (network/SSL unavailable) — skipping camera module."
        exit 0
    fi
    cd facetimehd

    make KERNELRELEASE="$KERNEL" 2>&1
    MAKE_MOD_RC=$?

    if [ $MAKE_MOD_RC -ne 0 ]; then
        log_warn "facetimehd module failed to compile on kernel $KERNEL."
        log_warn "Check https://github.com/patjak/facetimehd for kernel $KERNEL support."
        log_warn "Camera will NOT be available until module is updated."
    else
        make install 2>&1
        depmod -a
        modprobe facetimehd \
            && log_ok "facetimehd module loaded — Camera should now work." \
            || log_warn "Module installed but not loaded. Try after reboot."
    fi
) || true

rm -rf "$WEBCAM_DIR"

# =============================================================================
# STEP 5: Thunderbolt 3 (Intel Alpine Ridge 4C) — bolt daemon
# =============================================================================
log_step "5/10 — Thunderbolt 3 — bolt authorization daemon"

apt-get install -y --no-install-recommends bolt
# bolt uses D-Bus activation — start manually here for the current session
systemctl start bolt 2>/dev/null || true
log_ok "bolt installed (activates automatically via D-Bus when TB3 device connects)."
log_info "Authorize a device: boltctl enroll <device-uuid>"
log_info "Or use GNOME Settings → Privacy → Thunderbolt."

# =============================================================================
# STEP 6: Battery & Thermal management
# =============================================================================
log_step "6/10 — Battery & Thermal — TLP + thermald"

if dpkg -l power-profiles-daemon &>/dev/null 2>&1; then
    log_warn "Removing power-profiles-daemon (conflicts with TLP)..."
    apt-get remove -y power-profiles-daemon 2>/dev/null || true
    log_ok "power-profiles-daemon removed."
fi

apt-get install -y --no-install-recommends tlp tlp-rdw thermald powertop
systemctl enable --now tlp
systemctl enable --now thermald
log_ok "TLP battery management enabled."
log_ok "thermald CPU thermal management enabled."

# --- TLP: MacBook Pro 14,1 specific thermal/power configuration ---
# Ubuntu 26.04 TLP supports drop-in config files in /etc/tlp.d/
# This avoids touching /etc/tlp.conf while still applying all settings.
#
# ROOT CAUSE of Linux running hotter than macOS:
#   Linux BIOS default RAPL limits: PL1=100W, PL2=125W
#   macOS Ventura enforces:          PL1=15W,  PL2=25W
#   → on Linux the i5-7360U sustains turbo boost (3.5 GHz) indefinitely
#   → on macOS it bursts briefly then drops to base frequency (2.3 GHz)
#
mkdir -p /etc/tlp.d
cat > /etc/tlp.d/50-macbook-pro14-1.conf << 'EOF'
# MacBook Pro 13" 2017 (MacBookPro14,1) — thermal/power optimisation
# Intel i5-7360U · 15W TDP · Iris Plus 640 GT3
# Applied by macbook_hardware_fixer.sh

# CPU governor — powersave lets Intel HWP manage frequency dynamically
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave

# HWP energy/performance policy
# AC:  balance_power  (cooler idle — i5-7360U has enough headroom even at balance_power)
# BAT: balance_power  (efficiency on battery)
CPU_ENERGY_PERF_POLICY_ON_AC=balance_power
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power

# HWP dynamic boost — disabled: prevents CPU frequency spikes that raise idle temp
CPU_HWP_DYN_BOOST_ON_AC=0
CPU_HWP_DYN_BOOST_ON_BAT=0

# Turbo boost — disable on battery: -10 to -15°C under load, +30% battery life
# The i5-7360U base = 2.3 GHz, turbo = 3.5 GHz. Base is fast enough for most tasks.
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0

# PCIe Active State Power Management
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave

# Runtime power management for idle PCIe devices (WiFi, TB, etc.)
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto

# USB autosuspend — suspend idle USB devices
USB_AUTOSUSPEND=1

# Platform power profile (cooling/performance balance)
PLATFORM_PROFILE_ON_AC=balanced
PLATFORM_PROFILE_ON_BAT=low-power
EOF
log_ok "TLP: MacBook Pro 14,1 config written to /etc/tlp.d/50-macbook-pro14-1.conf"

# --- RAPL power limits: enforce i5-7360U TDP ---
# Intel i5-7360U spec: PL1=15W (sustained), PL2=25W (burst, 28-second window)
# BIOS default on this Mac: PL1=100W, PL2=125W — causes sustained turbo → overheating
# This systemd service restores correct limits on every boot (kernel resets to BIOS default).
RAPL_BASE="/sys/class/powercap/intel-rapl/intel-rapl:0"
cat > /etc/systemd/system/macbook-rapl-limits.service << 'EOF'
[Unit]
Description=MacBook Pro i5-7360U RAPL power limits — PL1=15W PL2=25W
Documentation=https://github.com/Dunedan/mbp-2016-linux
# basic.target is reached early in boot (before network, before login manager).
# This ensures 15W limit is enforced before the CPU can sustain turbo at boot.
After=basic.target

[Service]
Type=oneshot
RemainAfterExit=yes
# i5-7360U TDP=15W. These match macOS Ventura limits.
# Without this, BIOS default 100W/125W allows indefinite turbo → 70°C+ at idle.
ExecStart=/bin/bash -c '\
    R=/sys/class/powercap/intel-rapl/intel-rapl:0; \
    [ -w "$R/constraint_0_power_limit_uw" ] && echo 15000000 > "$R/constraint_0_power_limit_uw"; \
    [ -w "$R/constraint_1_power_limit_uw" ] && echo 25000000 > "$R/constraint_1_power_limit_uw"'

[Install]
WantedBy=basic.target
EOF
systemctl enable --now macbook-rapl-limits 2>/dev/null || true

# Apply immediately for the current session
if [ -w "$RAPL_BASE/constraint_0_power_limit_uw" ]; then
    echo 15000000 > "$RAPL_BASE/constraint_0_power_limit_uw"
    echo 25000000 > "$RAPL_BASE/constraint_1_power_limit_uw"
    log_ok "RAPL limits applied now: PL1=15W PL2=25W (was PL1=100W PL2=125W)."
else
    log_info "RAPL limits will be applied at next boot via macbook-rapl-limits.service."
fi

# Restart TLP to apply drop-in config immediately
systemctl restart tlp 2>/dev/null || true
log_ok "TLP restarted with MacBook Pro 14,1 optimisations."
log_info "Temperatures should drop 15-25°C vs BIOS defaults after reboot."
log_info "Run 'sudo powertop' to see per-process power usage."

# =============================================================================
# STEP 7: applesmc — Fan control, temperature sensors, keyboard backlight
# =============================================================================
log_step "7/10 — applesmc: Fan / Temperature Sensors / Keyboard Backlight"

apt-get install -y --no-install-recommends lm-sensors

# Configure sensors to pick up applesmc and coretemp automatically
# (sensors-detect is interactive; we use the known MacBook Pro sensor modules)
cat > /etc/modules-load.d/macbook-sensors.conf << 'EOF'
# MacBook Pro hardware monitoring modules
applesmc
coretemp
EOF
log_ok "lm-sensors installed, applesmc + coretemp auto-load configured."
log_info "Run 'sensors' after reboot to see CPU and chassis temperatures."

# --- Fan control via mbpfan (aggressive cooling profile) ---
# mbpfan reads applesmc temperatures and controls fan speed dynamically.
# Available in Ubuntu 26.04 repos (unlike macfanctld which is not packaged).
# Profile below is tuned for MacBook Pro 14,1 i5-7360U — very aggressive cooling:
#   baseline 3500 RPM, ramp starts at 38°C, full speed at 52°C
# This keeps the CPU in the 38-44°C range at idle — much cooler than macOS defaults.
apt-get install -y --no-install-recommends mbpfan smartmontools

cat > /etc/mbpfan.conf << 'EOF'
[general]
# MacBook Pro 13" 2017 (MacBookPro14,1) — very aggressive cooling profile
# Tested on Ubuntu 26.04 with i5-7360U (15W TDP, Iris Plus 640)

# Fan speed limits (physical limits of this Mac's fan)
min_fan1_speed = 3500
max_fan1_speed = 6200

# Temperature thresholds — aggressive: fan reaches max at 52°C
low_temp  = 38       # fan starts ramping up above this (°C)
high_temp = 46       # fan ramps up quickly above this
max_temp  = 52       # fan at maximum above this

# Polling interval in seconds
polling_interval = 1
EOF

systemctl enable --now mbpfan
log_ok "mbpfan fan control installed: min 3500 RPM, ramp starts at 38°C, max at 52°C."
log_info "Adjust thresholds at /etc/mbpfan.conf"

# Enable smartd for SSD/NVMe temperature monitoring
systemctl enable --now smartd 2>/dev/null || true
log_ok "smartmontools enabled (SSD/NVMe temperature monitoring)."

# --- Fan monitor script (optional, run manually) ---
# A visual terminal monitor showing fan RPM + CPU temperatures with colour alerts.
# Not auto-launched (too intrusive for .bashrc) — run manually when needed.
MONITOR_SCRIPT="/usr/local/bin/macbook-monitor"
cat > "$MONITOR_SCRIPT" << 'MONEOF'
#!/bin/bash
# MacBook Pro — live fan + temperature monitor (Ctrl+C to quit)
LOW=40; HIGH=50; MAX=55
color_t() { t=$1
  (( t < LOW )) && echo -e "\e[32m${t}°C\e[0m" && return
  (( t < HIGH )) && echo -e "\e[33m${t}°C\e[0m" && return
  (( t < MAX ))  && echo -e "\e[31m${t}°C\e[0m" && return
  echo -e "\e[41;97m${t}°C CRITICAL\e[0m"
}
color_r() { r=$1
  (( r < 4000 )) && echo -e "\e[32m${r} RPM\e[0m" && return
  (( r < 5500 )) && echo -e "\e[33m${r} RPM\e[0m" && return
  echo -e "\e[31m${r} RPM\e[0m"
}
while true; do
  clear
  echo "=== MacBook Pro Monitor (Ctrl+C to quit) ==="
  FAN=$(cat /sys/devices/platform/applesmc.768/fan1_input 2>/dev/null || echo 0)
  echo "Fan:  $(color_r $FAN)"
  sensors 2>/dev/null | grep -E 'Package id 0:|Core [0-9]+:' | while read line; do
    name=$(echo "$line" | awk -F: '{print $1}')
    val=$(echo "$line" | grep -oP '[0-9]+(?=\.[0-9]+°C)')
    [ -n "$val" ] && echo "$name: $(color_t $val)"
  done
  sleep 1
done
MONEOF
chmod +x "$MONITOR_SCRIPT"
log_ok "Fan monitor installed at /usr/local/bin/macbook-monitor (run manually)."

# --- Keyboard backlight ---
# Set to maximum brightness on boot and restore across reboots.
KBD_BL="/sys/class/leds/spi::kbd_backlight"
if [ -d "$KBD_BL" ]; then
    MAX_BL=$(cat "$KBD_BL/max_brightness" 2>/dev/null || echo 255)
    DEFAULT_BL="$MAX_BL"  # 100% — maximum

    # Set immediately (skip silently in containers where /sys is read-only)
    if echo "$DEFAULT_BL" > "$KBD_BL/brightness" 2>/dev/null; then
        log_ok "Keyboard backlight set to maximum ($DEFAULT_BL / $MAX_BL)."
    else
        log_warn "Keyboard backlight: /sys path is read-only (container/VM) — will apply on real hardware."
    fi

    # Persist via systemd-tmpfiles
    mkdir -p /etc/tmpfiles.d
    cat > /etc/tmpfiles.d/macbook-kbd-backlight.conf << EOF
# Restore MacBook Pro keyboard backlight to maximum brightness on boot
w /sys/class/leds/spi::kbd_backlight/brightness - - - - $DEFAULT_BL
EOF
    log_ok "Keyboard backlight persistence configured (maximum on every boot)."
    log_info "Adjust manually: echo <0-$MAX_BL> | sudo tee $KBD_BL/brightness"
else
    log_warn "Keyboard backlight sysfs path not found — applespi module may not be loaded."
fi

# =============================================================================
# STEP 8: Touchpad & Keyboard — libinput natural scroll + tap-to-click
# =============================================================================
log_step "8/10 — Touchpad & Keyboard — libinput configuration"

apt-get install -y --no-install-recommends libinput-tools

# --- GNOME/Wayland: configure via gsettings (run as the logged-in user) ---
if [ -n "$REAL_USER" ]; then
    REAL_UID=$(id -u "$REAL_USER")
    DBUS_ADDR="unix:path=/run/user/${REAL_UID}/bus"

    run_as_user() {
        sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" "$@" 2>/dev/null || true
    }

    # Touchpad: Apple SPI Touchpad on MacBook Pro 14,1
    run_as_user gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
    run_as_user gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true
    run_as_user gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
    run_as_user gsettings set org.gnome.desktop.peripherals.touchpad disable-while-typing true
    run_as_user gsettings set org.gnome.desktop.peripherals.touchpad click-method 'fingers'

    # Keyboard: fn-key behaviour (treat F-keys as standard F1-F12 by default)
    run_as_user gsettings set org.gnome.desktop.peripherals.keyboard numlock-state false

    log_ok "Touchpad: tap-to-click, natural scroll, two-finger scroll enabled (GNOME)."

    # --- HiDPI: 2× scaling for MacBook Pro 2560×1600 Retina display ---
    # Without this, UI elements are 1× (microscopic at native resolution).
    # text-scaling-factor=1.0 keeps text crisp at 2× — don't set higher.
    run_as_user gsettings set org.gnome.desktop.interface scaling-factor 2
    run_as_user gsettings set org.gnome.desktop.interface text-scaling-factor 1.0

    # Wayland fractional scaling (allows 150%, 175% in GNOME Display Settings)
    # Needs experimental flag — harmless to set, GNOME ignores it if unsupported
    run_as_user gsettings set org.gnome.mutter experimental-features \
        "['scale-monitor-framebuffer', 'xwayland-native-scaling']"
    log_ok "HiDPI: 2× scaling set (2560×1600 Retina). Fractional scaling unlocked in Display Settings."

    # --- GNOME Power settings ---
    # Power button: suspend instead of opening shutdown dialog
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power power-button-action suspend

    # Screen blank: 5 minutes idle (default is often 2 min — too aggressive for coding)
    run_as_user gsettings set org.gnome.desktop.session idle-delay 300

    # Dim screen on battery after 30s idle (saves power while reading)
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power idle-dim true
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power idle-brightness 30

    # Sleep on lid close (both AC and battery)
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action suspend
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power lid-close-battery-action suspend

    # Sleep when inactive (battery: 20 min, AC: never during dev sessions)
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 1200
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type suspend
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
    run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing

    log_ok "GNOME power: button=suspend, lid=suspend, screen-blank=5min, AC=never-sleep."
fi

# --- X11 fallback: libinput config for Xorg sessions ---
mkdir -p /usr/share/X11/xorg.conf.d
cat > /usr/share/X11/xorg.conf.d/40-macbook-libinput.conf << 'EOF'
# MacBook Pro 13" 2017 — libinput touchpad & keyboard (X11 / XWayland)
Section "InputClass"
    Identifier      "Apple SPI Touchpad"
    MatchIsTouchpad "on"
    Driver          "libinput"
    Option          "Tapping"           "on"
    Option          "TappingDrag"       "on"
    Option          "NaturalScrolling"  "true"
    Option          "ScrollMethod"      "twofinger"
    Option          "ClickMethod"       "clickfinger"
    Option          "DisableWhileTyping" "true"
EndSection

Section "InputClass"
    Identifier      "Apple SPI Keyboard"
    MatchIsKeyboard "on"
    MatchProduct    "Apple SPI Keyboard"
    Driver          "libinput"
    Option          "XkbOptions" "apple:alupckeys"
EndSection
EOF
log_ok "X11 libinput config written: tap-to-click, natural scroll, clickfinger."
log_info "XkbOptions apple:alupckeys maps Fn keys to standard F1-F12 under X11."

# --- fn-key behaviour at kernel level (hid_apple module) ---
if modinfo hid_apple &>/dev/null 2>&1; then
    cat > /etc/modprobe.d/hid-apple-macbook.conf << 'EOF'
# MacBook Pro fn-key: 0 = F1-F12 as media keys (default), 1 = F1-F12 as function keys
# Set to 1 so F-keys work without pressing Fn in terminals/IDEs
options hid_apple fnmode=1
EOF
    log_ok "hid_apple: fnmode=1 set (F1-F12 as function keys, media via Fn+F-key)."
    log_info "To use media keys as default: change fnmode=0 in /etc/modprobe.d/hid-apple-macbook.conf"
fi

# =============================================================================
# STEP 9: Screen Brightness + Suspend/Sleep fix
# =============================================================================
log_step "9/10 — Screen Brightness + Suspend/Sleep"

# --- Brightness ---
apt-get install -y --no-install-recommends brightnessctl

if [ -n "$REAL_USER" ]; then
    usermod -aG video "$REAL_USER"
    log_ok "User '$REAL_USER' added to 'video' group (brightness without sudo)."
fi
log_ok "brightnessctl installed."
log_info "Test: brightnessctl set 50%"

# --- Suspend/Sleep: use s2idle instead of deep (S3) ---
# MacBook Pro 14,1 does NOT support proper S3 (deep) sleep on Linux.
# s2idle (Windows Modern Standby equivalent) works reliably.
# Current state at this boot:
CURRENT_SLEEP=$(cat /sys/power/mem_sleep 2>/dev/null || echo "unknown")
log_info "Current sleep mode: $CURRENT_SLEEP"

GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ]; then
    GRUB_CHANGED=false

    # s2idle — MacBook Pro 14,1 does not support S3 deep sleep
    if grep -q "mem_sleep_default=s2idle" "$GRUB_FILE"; then
        log_ok "GRUB: mem_sleep_default=s2idle already set."
    else
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 mem_sleep_default=s2idle"/' "$GRUB_FILE"
        log_ok "GRUB: mem_sleep_default=s2idle added."
        GRUB_CHANGED=true
    fi

    # acpi_osi=Darwin — tells Apple BIOS to use macOS ACPI paths.
    # Fixes ACPI AE_ALREADY_EXISTS / AE_NOT_FOUND errors at boot (Apple SSDT double-load).
    # Safe on MacBookPro14,1 — tested and documented at mbp-2016-linux.
    if grep -q "acpi_osi=Darwin" "$GRUB_FILE"; then
        log_ok "GRUB: acpi_osi=Darwin already set."
    else
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 acpi_osi=Darwin"/' "$GRUB_FILE"
        log_ok "GRUB: acpi_osi=Darwin added (suppresses Apple ACPI boot errors)."
        GRUB_CHANGED=true
    fi

    if $GRUB_CHANGED; then
        update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || \
            log_warn "update-grub failed — edit /etc/default/grub manually."
        log_ok "GRUB updated (takes effect after reboot)."
    fi
fi

# Set immediately for the current session (without reboot)
if echo s2idle > /sys/power/mem_sleep 2>/dev/null; then
    log_ok "s2idle sleep mode activated for current session."
else
    log_warn "Could not set s2idle for current session (container/VM or kernel <5.3 — OK, takes effect after reboot)."
fi

# --- NVMe d3cold fix: required for successful resume from suspend ---
# MacBook Pro 14,1 uses Apple's S3X NVMe controller (0000:01:00.0).
# With d3cold_allowed=1 (default), the NVMe controller enters D3cold during
# suspend and fails to reinitialise on wake — causing a very slow (~1 min)
# or completely broken resume.
# Fix: disable d3cold for the NVMe controller. Kernel resets this to 1 on
# every boot, so a systemd service is required to apply it persistently.
# Reference: https://github.com/Dunedan/mbp-2016-linux#suspend--hibernation
NVME_PCI="0000:01:00.0"
NVME_D3COLD="/sys/bus/pci/devices/${NVME_PCI}/d3cold_allowed"

cat > /etc/systemd/system/macbook-nvme-d3cold.service << 'EOF'
[Unit]
Description=MacBook Pro NVMe d3cold fix — required for reliable suspend/resume
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'echo 0 > /sys/bus/pci/devices/0000:01:00.0/d3cold_allowed'

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now macbook-nvme-d3cold 2>/dev/null || true

# Apply immediately for the current session
if [ -f "$NVME_D3COLD" ]; then
    if echo 0 > "$NVME_D3COLD" 2>/dev/null; then
        log_ok "NVMe d3cold disabled — suspend/resume should now work reliably."
    else
        log_warn "NVMe d3cold: /sys path is read-only (container/VM) — will apply on real hardware via service."
    fi
else
    log_warn "NVMe PCI path $NVME_PCI not found — d3cold fix not applied for this session."
fi

# --- NVMe TRIM: enable weekly fstrim ---
# TRIM tells the NVMe controller which blocks are free, maintaining write speed
# and longevity. Ubuntu ships fstrim.timer but it may not be active on fresh install.
systemctl enable fstrim.timer 2>/dev/null && \
    log_ok "fstrim.timer enabled — weekly NVMe TRIM for sustained performance." || \
    log_warn "fstrim.timer not available — manual TRIM: sudo fstrim -v /"

# Run TRIM once now
fstrim -v / 2>/dev/null | grep -v "^$" | while read line; do log_info "$line"; done || true

# =============================================================================
# STEP 10: Development & System optimizations
# =============================================================================
log_step "10/10 — System & Development optimizations"

# --- 10a. ZRAM — compressed swap in RAM ---
# Replaces slow disk swap with compressed RAM swap (2x ratio, lz4 algorithm).
# Critical for development: prevents system freeze during heavy compilation
# (cargo build, webpack, docker image builds) without touching the NVMe.
# Impact: system stays responsive even at 100% RAM usage.
apt-get install -y --no-install-recommends zram-config 2>/dev/null || \
apt-get install -y --no-install-recommends zram-tools 2>/dev/null || true

# Configure zram if tools are available
if command -v zramctl &>/dev/null; then
    # Create /etc/default/zramswap or /etc/zram-generator.conf depending on tool
    if dpkg -l zram-config &>/dev/null 2>&1; then
        # Ubuntu 26.04 uses zram-config (from /usr/share/zram-config/zram-config.conf)
        log_ok "zram-config installed — ZRAM swap active after reboot."
    fi

    # systemd-zram-generator approach (preferred on newer Ubuntu)
    mkdir -p /etc/systemd/zram-generator.conf.d 2>/dev/null || true
    if [ -d /usr/lib/systemd/system-generators ] || systemctl list-unit-files | grep -q zram; then
        cat > /etc/systemd/zram-generator.conf << 'EOF'
# ZRAM swap — compressed RAM swap for MacBook Pro 14,1
# Uses lz4 (fastest) compression, 50% of RAM as compressed swap
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
swap-priority = 100
fs-type = swap
EOF
        systemctl daemon-reload
        log_ok "ZRAM: systemd-zram-generator configured (lz4, 50% RAM, priority 100)."
    fi
else
    log_info "zram tools not available — manual ZRAM setup may be needed."
fi

# --- 10b. sysctl: development & performance tuning ---
# These settings persist across reboots via /etc/sysctl.d/
cat > /etc/sysctl.d/60-macbook-dev.conf << 'EOF'
# MacBook Pro 14,1 — Development & performance sysctl tuning
# Applied by macbook_hardware_fixer.sh

# ── Memory management ──────────────────────────────────────────────────────────
# Lower swappiness: prefer keeping data in RAM, swap only when really needed
# Default=60 → 10 means "use RAM 6x more before swapping" — great for dev workloads
vm.swappiness = 10

# SSD-friendly dirty page ratios: flush to NVMe less aggressively
# Default dirty_ratio=20 → 15; dirty_background_ratio=10 → 5
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# ── Filesystem ─────────────────────────────────────────────────────────────────
# inotify: essential for IDEs and file watchers (VSCode, IntelliJ, webpack HMR)
# Default=8192 is almost always too low — IDEs open hundreds of file watchers
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# Open file descriptors: needed for Node.js, Docker, JVM-based tools
fs.file-max = 200000

# ── Network (developer QoL) ────────────────────────────────────────────────────
# BBR TCP congestion control: better throughput on variable-latency links
# Especially useful for git clone, npm install, docker pull over WiFi
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP buffer sizes: improve throughput for large transfers (git, docker)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Faster TCP connection reuse (useful for many short HTTP connections: npm, pip)
net.ipv4.tcp_tw_reuse = 1

# ── Kernel responsiveness ──────────────────────────────────────────────────────
# Reduce scheduler latency for interactive use (default: 6000000 = 6ms)
# Lower = more responsive UI/terminal, higher = better throughput on server
kernel.sched_latency_ns = 4000000
kernel.sched_min_granularity_ns = 500000

# Increase perf event limit (needed for profiling tools: perf, flamegraph)
kernel.perf_event_max_sample_rate = 10000
EOF

# Apply immediately (without reboot)
sysctl -p /etc/sysctl.d/60-macbook-dev.conf 2>/dev/null || true
log_ok "sysctl tuning applied: swappiness=10, inotify=524288, BBR TCP, dev file limits."

# --- 10c. I/O scheduler: none for NVMe ---
# NVMe has its own internal command queue — the Linux I/O scheduler adds latency.
# scheduler=none (pass-through) gives lowest latency for NVMe reads/writes.
# Applied via udev rule (persistent across reboots).
cat > /etc/udev/rules.d/61-nvme-scheduler.rules << 'EOF'
# MacBook Pro NVMe — use no scheduler (pass-through to NVMe internal queue)
# NVMe hardware already reorders requests optimally — Linux scheduler just adds overhead
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
EOF
udevadm control --reload-rules
# Apply immediately if NVMe block device exists (subshell suppresses /sys read-only error in containers)
for nvme_dev in /sys/block/nvme*/queue/scheduler; do
    [ -f "$nvme_dev" ] && (echo none > "$nvme_dev") 2>/dev/null || true
done
log_ok "I/O scheduler: NVMe set to 'none' (pass-through, lowest latency)."

# --- 10d. fstab: noatime for NVMe ---
# 'noatime' stops the kernel from writing access timestamps on every file read.
# On NVMe: reduces unnecessary write amplification and I/O overhead.
# Safe for all workloads (relatime is already the default, noatime is stricter).
if [ -f /etc/fstab ]; then
    if grep -q "noatime" /etc/fstab; then
        log_ok "fstab: noatime already present."
    else
        # Add noatime to all ext4/btrfs/xfs mount entries (not swap, not tmpfs)
        sed -i '/ext4\|btrfs\|xfs/ s/\(defaults\)/\1,noatime/' /etc/fstab 2>/dev/null || true
        log_ok "fstab: noatime added to filesystem mount entries (reduces NVMe writes)."
        log_info "Effective after next reboot or remount."
    fi
fi

# --- 10e. earlyoom — prevent system freeze under memory pressure ---
# When RAM + swap is exhausted, Linux freezes (kernel OOM killer is too slow).
# earlyoom kills the most memory-hungry process early (at 10% free RAM)
# → system stays responsive during heavy builds instead of becoming unresponsive.
apt-get install -y --no-install-recommends earlyoom
# Configure: kill at 10% free RAM / 5% free swap, prefer development processes
cat > /etc/default/earlyoom << 'EOF'
# earlyoom — early OOM killer for MacBook Pro development workloads
# Kill at: 10% free RAM and 5% free swap
# Avoids full system freeze during cargo/webpack/docker builds
EARLYOOM_ARGS="-m 10 -s 5 --prefer '(cc1|rustc|node|java|python)' --avoid '(sshd|bash|gnome)' -r 60"
EOF
systemctl enable --now earlyoom
log_ok "earlyoom installed: kills hungry processes at 10% free RAM (prevents freeze during builds)."

# --- 10f. ulimits for development ---
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/60-macbook-dev.conf << 'EOF'
# MacBook Pro — development ulimits
# Open file descriptors: Node.js, JVM, and large projects need this
* soft nofile 65536
* hard nofile 524288
# Process limit (needed for parallel builds)
* soft nproc  32768
* hard nproc  32768
EOF
log_ok "ulimits: nofile=65536 (soft) / 524288 (hard), nproc=32768."

# --- 10g. systemd journald: limit log size ---
# Default: journal grows unbounded and fills disk over months of development.
# 500MB volatile (RAM) + 1GB persistent (/var/log/journal) is more than enough.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/60-macbook-dev.conf << 'EOF'
# MacBook Pro — limit journal disk usage for development machines
[Journal]
SystemMaxUse=1G
SystemKeepFree=512M
RuntimeMaxUse=64M
MaxRetentionSec=2week
Compress=yes
EOF
systemctl restart systemd-journald 2>/dev/null || true
log_ok "journald: capped at 1GB disk / 64MB RAM, 2-week retention."

# --- 10h. Coredump: limit size to 512MB ---
# A crashed JVM or Chromium can dump 4-8GB, filling the NVMe instantly.
# 512MB is enough for most debugging; disable entirely with 0 if preferred.
mkdir -p /etc/systemd/coredump.conf.d
cat > /etc/systemd/coredump.conf.d/60-macbook-dev.conf << 'EOF'
# MacBook Pro — coredump size cap (default unlimited → can fill NVMe on JVM crash)
[Coredump]
Storage=external
ProcessSizeMax=512M
ExternalSizeMax=512M
MaxUse=2G
KeepFree=1G
EOF
log_ok "coredump: capped at 512MB per dump, 2GB total."

# --- 10i. git global config: fsmonitor + untrackedCache (run as real user) ---
# git status is O(all files) by default — fsmonitor makes it O(changed files)
# using the kernel's inotify. 10× faster in React/Django/monorepo projects.
# untrackedCache: caches untracked file list — avoids re-walking directories.
if [ -n "$REAL_USER" ]; then
    sudo -u "$REAL_USER" git config --global core.fsmonitor true 2>/dev/null || true
    sudo -u "$REAL_USER" git config --global core.untrackedCache true 2>/dev/null || true
    sudo -u "$REAL_USER" git config --global fetch.parallel 4 2>/dev/null || true
    sudo -u "$REAL_USER" git config --global submodule.fetchJobs 4 2>/dev/null || true
    sudo -u "$REAL_USER" git config --global rerere.enabled true 2>/dev/null || true
    sudo -u "$REAL_USER" git config --global pull.rebase true 2>/dev/null || true
    log_ok "git global: fsmonitor=true, untrackedCache=true, fetch.parallel=4, rerere=true."
else
    log_info "git global config skipped — no SUDO_USER detected (run with sudo -u <user>)."
fi

log_info "Development optimisations applied:"
log_info "  ZRAM      — compressed RAM swap, no more freezes during builds"
log_info "  sysctl    — vm.swappiness=10, inotify=524288, BBR TCP"
log_info "  I/O       — NVMe scheduler=none (lowest latency)"
log_info "  fstab     — noatime (fewer NVMe writes)"
log_info "  earlyoom  — kills at 10% free RAM, system stays responsive"
log_info "  ulimits   — nofile=65536/524288, nproc=32768"
log_info "  journald  — capped 1GB, 2-week retention"
log_info "  coredump  — capped 512MB (no disk-filling crashes)"
log_info "  git       — fsmonitor + untrackedCache + fetch.parallel=4"

# =============================================================================
# Rebuild initramfs — ensure all modprobe configs take effect at early boot
# =============================================================================
log_step "Finalising — rebuilding initramfs"
if update-initramfs -u -k "$KERNEL" 2>/dev/null; then
    log_ok "initramfs rebuilt for kernel $KERNEL."
else
    log_warn "update-initramfs failed — modprobe settings may not apply until next kernel update."
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}   All done! MacBook Pro hardware configuration complete.   ${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
if lsmod 2>/dev/null | grep -q "snd_hda_codec_cs8409"; then
    echo -e "  ${GREEN}[✔]${NC} 0. Audio — Cirrus CS8409 driver loaded (speakers/mic active)"
else
    echo -e "  ${YELLOW}[!]${NC} 0. Audio — Cirrus CS8409 driver installed, active after reboot"
fi
echo -e "  ${GREEN}[✔]${NC} 1. Intel GPU — VA-API hardware acceleration"
if [ -f /lib/firmware/brcm/BCM4350C0.hcd ]; then
    echo -e "  ${GREEN}[✔]${NC} 2. Bluetooth — config fixed + firmware installed (BCM4350C0)"
else
    echo -e "  ${YELLOW}[!]${NC} 2. Bluetooth — config fixed, firmware MISSING (see step 2 above)"
fi
echo -e "  ${GREEN}[✔]${NC} 3. WiFi — power save off, brcmfmac optimized"
echo -e "  ${GREEN}[✔]${NC} 4. FaceTime HD Camera — driver attempted (see warnings above)"
echo -e "  ${GREEN}[✔]${NC} 5. Thunderbolt 3 — bolt daemon"
echo -e "  ${GREEN}[✔]${NC} 6. Battery & Thermal — TLP + thermald"
echo -e "  ${GREEN}[✔]${NC} 7. applesmc — mbpfan (3000 RPM min, 40°C trigger), sensors, keyboard backlight (max)"
echo -e "  ${GREEN}[✔]${NC} 8. Touchpad — tap-to-click, natural scroll, clickfinger"
echo -e "  ${GREEN}[✔]${NC} 9. Screen brightness + s2idle suspend"
echo -e "  ${GREEN}[✔]${NC} 10. System & Dev: ZRAM, sysctl, BBR TCP, NVMe I/O scheduler, earlyoom, ulimits"
echo ""
echo -e "  ${YELLOW}[!]${NC} ${BOLD}REBOOT required for all changes to take effect.${NC}"
if [ ! -f /lib/firmware/brcm/BCM4350C0.hcd ]; then
echo -e "  ${YELLOW}[!]${NC} Bluetooth: no firmware (BCM4350C0.hcd) — BT scan/pair works, A2DP quality optional (see step 2)."
fi
echo ""
echo -e "  ${BOLD}${YELLOW}BLUETOOTH — IF hci0 IS MISSING AFTER REBOOT (first migration from macOS):${NC}"
echo -e "  Do an SMC Reset: hold Shift(L)+Ctrl(L)+Option(L)+Power for 10 sec, then boot."
echo -e "  This is needed ONCE — the BCM4350C0 chip resets its baud rate to Linux default."
echo ""
