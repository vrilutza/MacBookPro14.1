#!/bin/bash
# =============================================================================
# MacBook Pro Ubuntu — Complete Setup v5.0
# For: MacBook Pro 13" 2017 (MacBookPro14,1) on Ubuntu 26.04+
#
# Run once after a fresh Ubuntu install:
#   sudo bash macbook_hardware_fixer.sh
#
# Hardware covered (0-11, 12 steps total):
#    0. Cirrus Logic CS8409        — HDA audio + EasyEffects mic preset
#    1. Intel Iris Plus 640 GPU    — VA-API hardware acceleration
#    2. Bluetooth BCM4350C0 UART   — firmware (from firmware/) + bluez config
#    3. WiFi Broadcom BCM4350      — macOS NVRAM + power save optimizations
#    4. FaceTime HD Camera         — compile & install facetimehd driver
#    5. Thunderbolt 3 Alpine Ridge — bolt authorization daemon
#    6. Battery & Thermal          — TLP + thermald + RAPL PL1/PL2 + time windows
#    7. applesmc: Fan + Sensors + Keyboard Backlight
#    8. Touchpad & Keyboard        — libinput + PalmDetection + natural scroll
#    9. Screen Brightness + Suspend — s2idle + NVMe d3cold + auto-boot EFI fix
#   10. System & Dev optimizations — ZRAM, sysctl, BBR, earlyoom, ulimits
#   11. Display color calibration  — Apple factory ICC profile + colord autostart
#   12. Night Shift → redshift     — 6500K day / 4000K night (macOS Night Shift port)
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
# Calculate REAL_HOME once — used in steps 8, 11, 12
REAL_HOME=""
[ -n "$REAL_USER" ] && REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo -e "${BOLD}"
echo "============================================================"
echo "   MacBook Pro Ubuntu — Complete Setup v5.0               "
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
log_step "0/12 — Cirrus Logic CS8409 — HDA audio kernel driver + mic preset"

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

# --- EasyEffects: mic amplification + noise gate preset ---
# macOS applies DSP on the internal mic (BeamFormer + noise gate) via CoreAudio.
# Without processing the Linux mic level is too low and picks up fan/keyboard noise.
# EasyEffects applies equivalent processing: noise gate at -26 dB + autogain to -18 dBFS.
apt-get install -y --no-install-recommends easyeffects 2>/dev/null || \
    apt-get install -y --no-install-recommends pulseeffects 2>/dev/null || true

if [ -n "$REAL_HOME" ]; then
    EE_PRESET_DIR="$REAL_HOME/.local/share/easyeffects/input"
    mkdir -p "$EE_PRESET_DIR"
    cat > "$EE_PRESET_DIR/macbook-mic.json" << 'EOF'
{
    "input": {
        "blocklist": [],
        "plugins_order": ["gate#0", "autogain#0"],
        "gate#0": {
            "bypass": false,
            "input-gain": 0.0,
            "output-gain": 0.0,
            "attack": 20.0,
            "release": 250.0,
            "threshold": -26.0,
            "ratio": 10.0,
            "knee": 2.0,
            "range": -12.0,
            "makeup": 0.0,
            "detection": "RMS",
            "stereo-link": "Average"
        },
        "autogain#0": {
            "bypass": false,
            "target": -18.0,
            "silence-threshold": -70.0,
            "maximum-history": 5
        }
    }
}
EOF
    chown -R "$REAL_USER:$REAL_USER" "$EE_PRESET_DIR"
    log_ok "EasyEffects mic preset installed: noise gate + autogain (macOS mic DSP equivalent)."
    log_info "Open EasyEffects → Input → load 'macbook-mic' preset to activate."
fi

# =============================================================================
# STEP 1: System update + Intel GPU VA-API acceleration
# =============================================================================
log_step "1/12 — Intel Iris Plus 640 GPU — VA-API acceleration"

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
log_step "2/12 — Bluetooth BCM4350C0 UART — firmware fix"

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
# The firmware is included in this repo at firmware/bluetooth/BCM4350C0.hcd.
# It was extracted from macOS Ventura using hex2hcd.py and the source .hex files
# (firmware/bluetooth/source/BCM4350-MiniDriver-uart.hex + BCM4350-Updater.hex).
#
# Without firmware: BT works for scan/pair but A2DP audio is choppy (default baud rate).
# With firmware: A2DP at full quality, stable reconnects, AirPods work reliably.
BT_FW_REPO="$SCRIPT_DIR/firmware/bluetooth/BCM4350C0.hcd"

mkdir -p /lib/firmware/brcm

if [ -f "$BT_FW_DEST" ]; then
    log_ok "Bluetooth firmware already present: $BT_FW_DEST"
elif [ -f "$BT_FW_REPO" ]; then
    cp "$BT_FW_REPO" "$BT_FW_DEST"
    chmod 644 "$BT_FW_DEST"
    # Compatibility symlink: older kernels look for BCM2E7C.hcd (macOS marketing name)
    ln -sf BCM4350C0.hcd /lib/firmware/brcm/BCM2E7C.hcd
    log_ok "Bluetooth firmware installed: $BT_FW_DEST"
    log_ok "Compatibility symlink: /lib/firmware/brcm/BCM2E7C.hcd → BCM4350C0.hcd"
    log_info "Source: firmware/bluetooth/BCM4350C0.hcd (converted from macOS Ventura hex files)"
else
    log_warn "Bluetooth firmware not found in repo ($BT_FW_REPO) — BT works without it."
    log_info "Rebuild: python3 $SCRIPT_DIR/firmware/bluetooth/hex2hcd.py"
    log_info "Requires: firmware/bluetooth/source/BCM4350-MiniDriver-uart.hex + BCM4350-Updater.hex"
fi

# --- 2d. udev rule: bring hci0 up automatically after firmware is loaded ---
cat > /etc/udev/rules.d/60-bluetooth-macbook.rules << 'EOF'
# MacBook Pro BCM2E7C Bluetooth: bring hci0 up once firmware is available.
# Uses systemd-run to defer the hciconfig call out of the udev context
# (avoids the blocking-sleep antipattern; completes asynchronously after boot).
ACTION=="add", SUBSYSTEM=="bluetooth", KERNEL=="hci0", \
    RUN+="/bin/systemd-run --no-block /usr/bin/hciconfig hci0 up"
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
log_step "3/12 — WiFi BCM4350 — power save + regulatory"

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

# Disable brcmfmac power management via module option.
# Note: 'power_save' was removed in kernel 6.x; NetworkManager handles it via
# wifi.powersave=2 above. 'roamoff=1' is still valid and prevents roaming drops.
cat > /etc/modprobe.d/brcmfmac-macbook.conf << 'EOF'
# MacBook Pro BCM4350 WiFi optimizations
options brcmfmac roamoff=1
EOF
log_ok "brcmfmac: roamoff=1 set (power_save handled by NetworkManager)."

# --- WiFi NVRAM: install macOS-extracted board-specific NVRAM calibration ---
# The linux-firmware package ships a generic brcmfmac4350-pcie.bin (firmware binary).
# The NVRAM (.txt) encodes board-specific RF calibration: TX power, antenna params,
# channel restrictions. The macOS NVRAM is tuned for this exact board (boardid=0x170).
# Using it can improve range, 5 GHz stability, and regulatory accuracy.
WIFI_NVRAM_DIR="$SCRIPT_DIR/firmware/wifi"
BRCM_FW_DIR="/lib/firmware/brcm"
mkdir -p "$BRCM_FW_DIR"

if [ -f "$WIFI_NVRAM_DIR/brcmfmac4350-pcie.txt" ]; then
    # Model-specific name (kernel tries this first, falls back to generic)
    cp "$WIFI_NVRAM_DIR/brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt" \
       "$BRCM_FW_DIR/brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt" 2>/dev/null || true
    # Generic fallback name
    cp "$WIFI_NVRAM_DIR/brcmfmac4350-pcie.txt" \
       "$BRCM_FW_DIR/brcmfmac4350-pcie.txt"
    # Kernel 6.6+ reports chip as brcmfmac4350c2-pcie (BCM4350 rev C2).
    # Without these symlinks the Apple NVRAM is silently ignored and the
    # generic firmware runs without board-specific RF calibration.
    ln -sf "brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt" \
        "$BRCM_FW_DIR/brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1.txt" 2>/dev/null || true
    ln -sf "brcmfmac4350-pcie.txt" \
        "$BRCM_FW_DIR/brcmfmac4350c2-pcie.txt" 2>/dev/null || true
    log_ok "WiFi NVRAM installed: macOS-calibrated board NVRAM for BCM4350/c2 (boardid=0x170)"
    log_info "Source: firmware/wifi/ (extracted from macOS Ventura, hawaii platform)"
else
    log_warn "WiFi NVRAM not found at firmware/wifi/ — using linux-firmware default NVRAM."
    log_info "WiFi will still work; custom NVRAM improves range and 5GHz stability."
fi

# --- WiFi 5GHz preference ---
# NOTE: NetworkManager conf.d files use legacy key names (e.g. "band") inside
# named sections like [wifi-<uuid>]. The dotted property form "wifi.band" is only
# valid inside .nmconnection profile files, NOT in conf.d — NM logs a warning and
# ignores it. 5GHz band preference must be set per-connection via nmcli or nm-applet.
# Example: nmcli connection modify "MyWiFi" 802-11-wireless.band a
# Remove any previously written invalid conf to stop boot warnings.
NM_WIFI_BAND_CONF="/etc/NetworkManager/conf.d/98-wifi-band-5ghz.conf"
if [ -f "$NM_WIFI_BAND_CONF" ]; then
    rm -f "$NM_WIFI_BAND_CONF"
    log_ok "Removed invalid WiFi band conf (wifi.band=a in conf.d generates NM warning, does nothing)."
fi
log_info "WiFi 5GHz: set per-connection with: nmcli connection modify <name> 802-11-wireless.band a"

# Reload NetworkManager config — no disconnect needed
nmcli general reload conf 2>/dev/null || true

log_info "WiFi regulatory domain: Ubuntu reads from wireless-regdb automatically."
log_info "If channels are limited, set country: sudo iw reg set RO  (or your country code)"

# =============================================================================
# STEP 4: FaceTime HD Camera (Broadcom 720p PCIe — 14e4:1570)
# =============================================================================
log_step "4/12 — FaceTime HD Camera — Broadcom PCIe driver (facetimehd)"

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
log_step "5/12 — Thunderbolt 3 — bolt authorization daemon"

apt-get install -y --no-install-recommends bolt
# bolt uses D-Bus activation — start manually here for the current session
systemctl start bolt 2>/dev/null || true
log_ok "bolt installed (activates automatically via D-Bus when TB3 device connects)."
log_info "Authorize a device: boltctl enroll <device-uuid>"
log_info "Or use GNOME Settings → Privacy → Thunderbolt."

# =============================================================================
# STEP 6: Battery & Thermal management
# =============================================================================
log_step "6/12 — Battery & Thermal — TLP + thermald"

if dpkg -l power-profiles-daemon &>/dev/null 2>&1; then
    log_warn "Removing power-profiles-daemon (conflicts with TLP)..."
    apt-get remove -y power-profiles-daemon 2>/dev/null || true
    # Reload systemd unit list — apt removal leaves stale unit references without this
    systemctl daemon-reload 2>/dev/null || true
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

# CPU governor — powersave + intel_pstate lets HWP manage frequency dynamically.
# The governor name is misleading: with intel_pstate, 'powersave' still uses
# full turbo — frequency is governed by the EPP policy below, not the governor name.
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave

# HWP energy/performance policy
# AC:  performance   — HWP targets highest P-state, CPU at full speed under any load.
#                      With aggressive fan profile (4500+ RPM, 48°C max trigger) the
#                      i5-7360U stays cool even at sustained 28W — no need to throttle.
# BAT: balance_power — efficiency on battery (turbo disabled anyway, see below)
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power

# HWP dynamic boost — ON on AC: CPU proactively boosts above EPB hint when headroom exists.
# Combined with EPP=performance this gives maximum single-thread responsiveness.
CPU_HWP_DYN_BOOST_ON_AC=1
CPU_HWP_DYN_BOOST_ON_BAT=0

# Turbo boost — always ON on AC (sustained 3.6 GHz with RAPL 28W limit below).
# OFF on battery: -10 to -15°C under load, significant battery life gain.
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

# Platform power profile — performance on AC: firmware scheduler favours performance cores.
# low-power on battery preserves charge without impacting daily tasks.
PLATFORM_PROFILE_ON_AC=performance
PLATFORM_PROFILE_ON_BAT=low-power
EOF
log_ok "TLP: MacBook Pro 14,1 config written to /etc/tlp.d/50-macbook-pro14-1.conf"

# --- RAPL power limits: sweet-spot termic pentru MacBook Pro 13" 2017 ---
# Intel i5-7360U official specs:
#   TDP (stock):  PL1=15W, PL2=25W  — ce aplică macOS Ventura
#   cTDP-up:      PL1=28W            — spec Intel certificat, dar depășește capacitatea
#                                      termică a heatsink-ului mic din MBP 13"
#   BIOS default: PL1=100W, PL2=125W — turbo necontrolat → overheating instant
#
# De ce PL1=20W și nu 28W (cTDP-up):
#   Rezistența termică măsurată a acestui Mac: ~2.9°C/W la idle (fan 4800 RPM)
#   La fan max (6500 RPM) se reduce la ~2.0°C/W.
#   La 28W susținut: ambient(25) + 28×2.0 = 81°C → CPU throttle termic la ~95°C
#   La 20W susținut: ambient(25) + 20×2.0 = 65°C → stabil, fără throttle
#   PL1=20W susține ~2.8-3.0 GHz continuu (vs 2.3 GHz la 15W, vs throttle la 28W)
#
# PL2=40W (burst 28s): CPU ajunge la 3.6 GHz pentru taskuri scurte (compile,
#   JS, build rapid) fără acumulare termică. Acesta e câștigul real de performanță.
RAPL_BASE="/sys/class/powercap/intel-rapl/intel-rapl:0"
cat > /etc/systemd/system/macbook-rapl-limits.service << 'EOF'
[Unit]
Description=MacBook Pro i5-7360U RAPL power limits — PL1=20W PL2=40W
Documentation=https://github.com/Dunedan/mbp-2016-linux
# Must run AFTER thermald: thermald dynamically manages RAPL via DPTF and will
# raise PL1 back to BIOS default (100W) if it starts after this service.
# Running last (multi-user.target) guarantees our limits are the final values.
After=network.target thermald.service tlp.service
Wants=thermald.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Load RAPL modules so the sysfs tree exists before we write to it.
# Without this, intel-rapl:0 does not appear and bash [ -w ] returns exit 1,
# causing the service to fail with Result=exit-code.
ExecStartPre=/sbin/modprobe -a intel_rapl_msr intel_rapl_common
# PL1=20W = sweet-spot între TDP stock (15W) și cTDP-up (28W).
# Susține ~2.8-3.0 GHz fără throttle termic pe heatsink-ul mic al MBP 13" 2017.
# PL2=40W = burst pentru taskuri scurte (fereastră 28s — suficient pentru orice task interactiv).
# '; true' ensures bash exits 0 even if some sysfs paths are absent.
ExecStart=/bin/bash -c '\
    R=/sys/class/powercap/intel-rapl/intel-rapl:0; \
    [ -w "$R/constraint_0_power_limit_uw" ]   && echo 20000000  > "$R/constraint_0_power_limit_uw"; \
    [ -w "$R/constraint_1_power_limit_uw" ]   && echo 40000000  > "$R/constraint_1_power_limit_uw"; \
    [ -w "$R/constraint_0_time_window_us" ]   && echo 976563    > "$R/constraint_0_time_window_us"; \
    [ -w "$R/constraint_1_time_window_us" ]   && echo 27343000  > "$R/constraint_1_time_window_us"; \
    true'

[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now macbook-rapl-limits 2>/dev/null || true

# Apply immediately for the current session
if [ -w "$RAPL_BASE/constraint_0_power_limit_uw" ]; then
    echo 20000000  > "$RAPL_BASE/constraint_0_power_limit_uw"
    echo 40000000  > "$RAPL_BASE/constraint_1_power_limit_uw"
    [ -w "$RAPL_BASE/constraint_0_time_window_us" ] && echo 976563   > "$RAPL_BASE/constraint_0_time_window_us"
    [ -w "$RAPL_BASE/constraint_1_time_window_us" ] && echo 27343000 > "$RAPL_BASE/constraint_1_time_window_us"
    log_ok "RAPL limits applied: PL1=20W/~1s, PL2=40W/~28s — sweet-spot pentru MBP 13\" 2017."
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
log_step "7/12 — applesmc: Fan / Temperature Sensors / Keyboard Backlight"

apt-get install -y --no-install-recommends lm-sensors

# Configure sensors to pick up applesmc and coretemp automatically
# (sensors-detect is interactive; we use the known MacBook Pro sensor modules)
cat > /etc/modules-load.d/macbook-sensors.conf << 'EOF'
# MacBook Pro hardware monitoring modules
applesmc
coretemp
# Intel RAPL power capping — required for /sys/class/powercap/intel-rapl sysfs
# Without these, macbook-rapl-limits.service fails (sysfs absent at boot)
intel_rapl_msr
intel_rapl_common
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
# MacBook Pro 13" 2017 (MacBookPro14,1) — maximum aggressive cooling profile
# Always spinning at high baseline, reaches full speed early.
# User preference: maximum cooling, noise is acceptable.

# Fan speed limits (physical hardware limits of this Mac's fan: 1200-7200 RPM)
min_fan1_speed = 4500   # always spinning fast — no silent idle
max_fan1_speed = 6500   # just below hardware max (7200) for longevity

# Temperature thresholds — very aggressive: ramp starts early, max at 48°C
low_temp  = 30       # fan starts ramping above this (°C) — catches any workload
high_temp = 40       # fan ramps up quickly above this
max_temp  = 48       # fan at maximum above this (CPU rarely exceeds 70°C)

# Polling interval in seconds
polling_interval = 1
EOF

systemctl enable --now mbpfan
log_ok "mbpfan fan control installed: min 4500 RPM, ramp starts at 30°C, max at 48°C (max cooling)."
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
# MacBook Pro 13" 2017 — live fan + temperature monitor (Ctrl+C to quit)
# Thresholds match /etc/mbpfan.conf: low_temp=38, high_temp=46, max_temp=52

# Thresholds from mbpfan.conf
LOW=38; HIGH=46; MAX=52

color_t() {
  t=$1
  (( t < LOW  )) && echo -e "\e[32m${t}°C\e[0m"        && return   # green
  (( t < HIGH )) && echo -e "\e[33m${t}°C\e[0m"        && return   # yellow
  (( t < MAX  )) && echo -e "\e[31m${t}°C\e[0m"        && return   # red
  echo -e "\e[41;97m${t}°C CRITICAL\e[0m"                           # red bg
}
color_r() {
  r=$1
  (( r < 4000 )) && echo -e "\e[32m${r} RPM\e[0m"      && return   # green
  (( r < 5500 )) && echo -e "\e[33m${r} RPM\e[0m"      && return   # yellow
  echo -e "\e[31m${r} RPM\e[0m"                                      # red
}

while true; do
  clear
  echo "=== MacBook Pro 13\" 2017 Monitor (Ctrl+C to quit) ==="
  echo "  mbpfan thresholds: low=${LOW}°C  high=${HIGH}°C  max=${MAX}°C"
  echo ""

  FAN=$(cat /sys/devices/platform/applesmc.768/fan1_input 2>/dev/null || echo 0)
  echo "  Fan1:   $(color_r $FAN)"
  echo ""

  # Show all coretemp + applesmc sensors with numeric temp values
  sensors 2>/dev/null | grep -E 'Package id 0:|Core [0-9]+:|TCAL|TC[0-9]|TB[0-9]' | \
  while IFS= read -r line; do
    name=$(echo "$line" | awk -F: '{print $1}' | sed 's/^ *//')
    val=$(echo "$line" | grep -oP '\+?[0-9]+(?=\.[0-9]+°C)' | head -1)
    [ -n "$val" ] && printf "  %-18s %s\n" "${name}:" "$(color_t $val)"
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
log_step "8/12 — Touchpad & Keyboard — libinput configuration"

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
# PalmDetection: matches macOS TrackpadHandResting=1 (palm rejection)
# TappingButtonMap lrm: 1-finger=left, 2-finger=right, 3-finger=middle
Section "InputClass"
    Identifier      "Apple SPI Touchpad"
    MatchIsTouchpad "on"
    Driver          "libinput"
    Option          "Tapping"           "on"
    Option          "TappingDrag"       "on"
    Option          "TappingButtonMap"  "lrm"
    Option          "NaturalScrolling"  "true"
    Option          "ScrollMethod"      "twofinger"
    Option          "ClickMethod"       "clickfinger"
    Option          "DisableWhileTyping" "true"
    Option          "PalmDetection"     "on"
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
log_step "9/12 — Screen Brightness + Suspend/Sleep"

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

# --- Auto-boot on lid open: disable via EFI variable ---
# MacBook Pro 2016/2017 powers on automatically when the lid is opened.
# macOS NVRAM: auto-boot=true. On Linux this is annoying (bag opens = OS boots).
# Write the EFI variable to disable it. Safe to run on every install.
EFI_AUTOBOOT="/sys/firmware/efi/efivars/AutoBoot-7c436110-ab2a-4bbb-a880-fe41995c9f82"
if [ -f "$EFI_AUTOBOOT" ]; then
    # Remove immutable flag if set, then write disable value
    chattr -i "$EFI_AUTOBOOT" 2>/dev/null || true
    if printf '\x07\x00\x00\x00\x00' > "$EFI_AUTOBOOT" 2>/dev/null; then
        log_ok "Auto-boot on lid open DISABLED (EFI var AutoBoot cleared)."
    else
        log_warn "Could not write AutoBoot EFI var — check: ls -la $EFI_AUTOBOOT"
        log_info "Manual fix: sudo chattr -i $EFI_AUTOBOOT && printf '\\x07\\x00\\x00\\x00\\x00' | sudo tee $EFI_AUTOBOOT"
    fi
elif [ -d /sys/firmware/efi/efivars ]; then
    log_info "AutoBoot EFI var not found — already disabled or variable name differs on this unit."
else
    log_info "EFI vars not mounted — auto-boot state unchanged (non-EFI boot or container)."
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
log_step "10/12 — System & Development optimizations"

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
# NVMe hardware already reorders requests optimally — Linux scheduler just adds overhead.
# ENV{DEVTYPE}=="disk" restricts the rule to block devices only (nvme0n1), excluding
# partitions (nvme0n1p1...) which have no queue/scheduler attribute and would log errors.
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ENV{DEVTYPE}=="disk", ATTR{queue/scheduler}="none"
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
# STEP 11: Display Color Calibration — Apple factory LCD ICC profile
# =============================================================================
# The MacBook Pro 13" 2017 uses a panel calibrated at the Apple factory.
# macOS ships an ICC profile specific to each unit in:
#   /Library/ColorSync/Profiles/Displays/Color LCD-<UUID>.icc
#
# This profile contains:
#   • Display-specific RGB primaries (wider gamut than generic sRGB)
#   • Factory tone response curves (rTRC/gTRC/bTRC, 1024-point)
#   • Apple vcgt / vcgp gamma data
#   • D65 white point calibration
#
# Without this profile Ubuntu uses a generic sRGB assumption, which causes
# visibly inaccurate colors: oversaturated reds/greens, incorrect white point.
#
# The profile was extracted from macOS Ventura and is included in this repo
# at firmware/display/Color-LCD-MacBookPro14-1.icc (3.3 kB).
#
# Install approach:
#   1. Copy ICC to /usr/share/color/icc/macbook/ (system-wide, colord reads it)
#   2. Copy to ~/.local/share/icc/ (per-user, GNOME Color Manager picks it up)
#   3. Create /usr/local/bin/macbook-color-profile.sh — assigns profile via
#      colormgr to the eDP (embedded DisplayPort / built-in display) on each login
#   4. Install ~/.config/autostart/macbook-color-profile.desktop — auto-runs it
#
# Manual verify after reboot:
#   colormgr get-devices        — look for the built-in display (eDP-1)
#   colormgr get-profiles       — should list Color-LCD-MacBookPro14-1
#   colormgr device-get-default-profile <device-id>   — confirms assignment
# =============================================================================
log_step "11/12 — Display color calibration — Apple factory ICC profile"

apt-get install -y --no-install-recommends colord

ICC_SRC="$SCRIPT_DIR/firmware/display/Color-LCD-MacBookPro14-1.icc"

ICC_SYSTEM_DIR="/usr/share/color/icc/macbook"
ICC_SYSTEM_PATH="$ICC_SYSTEM_DIR/Color-LCD-MacBookPro14-1.icc"

if [ ! -f "$ICC_SRC" ]; then
    log_warn "ICC profile not found — skipping color calibration."
    log_info "Expected: firmware/display/Color-LCD-MacBookPro14-1.icc"
    log_info "Extract from macOS: /Library/ColorSync/Profiles/Displays/Color LCD-*.icc"
else
    # --- System-wide installation (colord scans /usr/share/color/icc/) ---
    mkdir -p "$ICC_SYSTEM_DIR"
    cp "$ICC_SRC" "$ICC_SYSTEM_PATH"
    chmod 644 "$ICC_SYSTEM_PATH"
    log_ok "ICC profile installed system-wide: $ICC_SYSTEM_PATH"

    # --- Per-user installation (GNOME Color Manager reads ~/.local/share/icc/) ---
    if [ -n "$REAL_HOME" ]; then
        USER_ICC_DIR="$REAL_HOME/.local/share/icc"
        mkdir -p "$USER_ICC_DIR"
        cp "$ICC_SRC" "$USER_ICC_DIR/Color-LCD-MacBookPro14-1.icc"
        chown -R "$REAL_USER:$REAL_USER" "$USER_ICC_DIR"
        log_ok "ICC profile installed for user '$REAL_USER': $USER_ICC_DIR/"
    fi

    # --- colormgr autostart script ---
    # Assigns the profile to the built-in eDP display on every login.
    # We cannot hard-code the colord device ID here because colord derives it
    # from the display's EDID at runtime (format: xrandr-eDP-1 or similar).
    # The script does a one-time lookup and caches the result in ~/.cache/.
    cat > /usr/local/bin/macbook-color-profile.sh << 'COLOREOF'
#!/bin/bash
# MacBook Pro 13" 2017 — apply factory LCD color calibration on login.
# Assigns Apple's ICC profile to the built-in display via colord/colormgr.
#
# The profile (Color-LCD-MacBookPro14-1.icc) was extracted from macOS Ventura.
# It encodes the factory-calibrated RGB primaries and tone response curves for
# this specific panel. Without it GNOME uses generic sRGB → wrong colors.
#
# colord is session-scoped: the assignment must be repeated on every login.
# This script is invoked by ~/.config/autostart/macbook-color-profile.desktop.

ICC_FILE="/usr/share/color/icc/macbook/Color-LCD-MacBookPro14-1.icc"
PROFILE_NAME="Color-LCD-MacBookPro14-1"

[ -f "$ICC_FILE" ] || exit 0

# Wait for colord daemon to be available (up to 15 s after login)
for i in $(seq 1 15); do
    colormgr get-devices &>/dev/null 2>&1 && break
    sleep 1
done
colormgr get-devices &>/dev/null 2>&1 || { echo "macbook-color-profile: colord not ready" >&2; exit 1; }

# Import profile if colord doesn't know it yet
if ! colormgr get-profiles 2>/dev/null | grep -q "$PROFILE_NAME"; then
    colormgr import-profile "$ICC_FILE" 2>/dev/null || true
    sleep 1
fi

# Find the built-in display device ID.
# colord names it after the X/Wayland output name. On MacBook Pro 14,1 the
# internal eDP link appears as 'eDP-1' (Wayland/KMS) or 'LVDS-1' (old X11).
# NOTE: 'Model: Color LCD' appears BEFORE 'Device ID:' in colormgr output, so
# we must extract Device ID lines directly with sed (not awk look-ahead).
# The Device ID contains spaces, so $NF would only capture the last word.
DEVICE_ID=$(colormgr get-devices 2>/dev/null \
    | sed -n 's/^[[:space:]]*Device ID:[[:space:]]*//p' \
    | grep -i "edp\|color.lcd\|apple" | head -1)

if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(colormgr get-devices 2>/dev/null \
        | sed -n 's/^[[:space:]]*Device ID:[[:space:]]*//p' | head -1)
fi

if [ -z "$DEVICE_ID" ]; then
    echo "macbook-color-profile: no display device found in colord" >&2
    exit 1
fi

# Find profile by name — Filename appears BEFORE Profile ID in colormgr output,
# so we set a flag when we see the name, then capture the next Profile ID line.
PROFILE_ID=$(colormgr get-profiles 2>/dev/null \
    | awk "/$PROFILE_NAME/ { found=1 } found && /Profile ID:/ { print \$NF; exit }")

if [ -z "$PROFILE_ID" ]; then
    echo "macbook-color-profile: profile not found in colord after import" >&2
    exit 1
fi

colormgr device-add-profile     "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
colormgr device-make-profile-default "$DEVICE_ID" "$PROFILE_ID" 2>/dev/null || true
COLOREOF
    chmod +x /usr/local/bin/macbook-color-profile.sh
    log_ok "Color profile assignment script: /usr/local/bin/macbook-color-profile.sh"

    # --- Autostart .desktop entry (per-user) ---
    if [ -n "$REAL_HOME" ]; then
        AUTOSTART_DIR="$REAL_HOME/.config/autostart"
        mkdir -p "$AUTOSTART_DIR"
        cat > "$AUTOSTART_DIR/macbook-color-profile.desktop" << 'DTEOF'
[Desktop Entry]
Type=Application
Name=MacBook Pro LCD Color Profile
Comment=Apply Apple factory color calibration for the built-in display
Exec=/usr/local/bin/macbook-color-profile.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DTEOF
        chown "$REAL_USER:$REAL_USER" "$AUTOSTART_DIR/macbook-color-profile.desktop"
        log_ok "Color profile autostart entry installed for '$REAL_USER'."
        log_info "On every login the built-in display will be assigned the Apple ICC profile."
    fi

    log_info "Verify after reboot:"
    log_info "  colormgr get-devices          — find your display's Device ID"
    log_info "  colormgr get-profiles         — confirm Color-LCD-MacBookPro14-1 is listed"
    log_info "  GNOME Settings → Color        — profile visible and assigned"
    log_info "Without this profile: oversaturated colors, incorrect white point (generic sRGB)."
fi

# =============================================================================
# STEP 12: Night Shift → redshift (6500K day / 4000K night)
# =============================================================================
# macOS Ventura Night Shift: 6500K (D65) during the day, 4000K in the evening.
# redshift replicates this on Linux using RandR/Wayland to adjust display colour
# temperature gradually, reducing blue light in the evening.
#
# Config is placed system-wide at /etc/xdg/redshift.conf so it works for any
# user without per-user setup. The user can override with ~/.config/redshift.conf.
# Autostart entry created for the sudo-invoking user.
# =============================================================================
log_step "12/12 — Night Shift → redshift (colour temperature)"

apt-get install -y --no-install-recommends redshift-gtk 2>/dev/null || \
    apt-get install -y --no-install-recommends redshift 2>/dev/null || true

if command -v redshift &>/dev/null || command -v redshift-gtk &>/dev/null; then
    # Detect which DRM card belongs to the Intel GPU (vendor 0x8086).
    # On kernel >= 5.14 with simpledrm, the EFI framebuffer takes card0 at boot
    # and the real i915 driver gets card1. simpledrm's card0 is released once i915
    # takes over, so only card1 remains. On older kernels (no simpledrm) card0 is Intel.
    INTEL_CARD_NUM=0  # safe default
    for _card in /sys/class/drm/card[0-9]*; do
        [[ -d "$_card" ]] || continue
        _num="${_card##*/card}"
        [[ "$_num" =~ ^[0-9]+$ ]] || continue
        _vendor=$(cat "$_card/device/vendor" 2>/dev/null)
        if [[ "$_vendor" == "0x8086" ]]; then
            INTEL_CARD_NUM=$_num
            break
        fi
    done
    log_info "redshift DRM: Intel GPU detected at /dev/dri/card${INTEL_CARD_NUM}"

    # System-wide config — latitude/longitude set to Bucharest (Romania).
    # User can edit /etc/xdg/redshift.conf or create ~/.config/redshift.conf to override.
    cat > /etc/xdg/redshift.conf << EOF
; MacBook Pro Night Shift equivalent — matches macOS Ventura defaults
; Extracted from: macOS Night Shift = 4000K warm, D65 = 6500K neutral
[redshift]
temp-day=6500
temp-night=4000
gamma=1.0
fade=1
adjustment-method=drm
location-provider=manual

[manual]
; Edit these coordinates for your location.
; Default: Bucharest, Romania (lat=44.4, lon=26.1)
lat=44.4
lon=26.1

[drm]
; Intel GPU card number detected at install time: card${INTEL_CARD_NUM}
; On kernel >= 5.14 simpledrm takes card0 first; i915 gets card1.
; Without this, redshift fails with "Failed to open DRM device: /dev/dri/card0".
card=${INTEL_CARD_NUM}
EOF
    log_ok "redshift config: 6500K day, 4000K night (matches macOS Night Shift defaults)."
    log_info "Edit /etc/xdg/redshift.conf to change your latitude/longitude."

    # Also write per-user config — on GNOME/Wayland, XDG_CONFIG_DIRS may not
    # include /etc/xdg at session startup, so the system-wide file is skipped.
    # ~/.config/redshift.conf is always read by redshift/redshift-gtk.
    if [ -n "$REAL_HOME" ]; then
        mkdir -p "$REAL_HOME/.config"
        cp /etc/xdg/redshift.conf "$REAL_HOME/.config/redshift.conf"
        chown "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/redshift.conf"
    fi

    # Autostart for the desktop user
    if [ -n "$REAL_HOME" ]; then
        AUTOSTART_DIR="$REAL_HOME/.config/autostart"
        mkdir -p "$AUTOSTART_DIR"
        # Use redshift-gtk if available (has tray icon), fall back to redshift
        REDSHIFT_BIN=$(command -v redshift-gtk 2>/dev/null || command -v redshift)
        cat > "$AUTOSTART_DIR/redshift.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Night Shift (redshift)
Comment=Adjust colour temperature at night — macOS Night Shift equivalent
Exec=$REDSHIFT_BIN
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
        chown "$REAL_USER:$REAL_USER" "$AUTOSTART_DIR/redshift.desktop"
        log_ok "redshift autostart enabled for '$REAL_USER'."
    fi
else
    log_warn "redshift not available in apt — skipping Night Shift equivalent."
    log_info "Install manually: sudo apt-get install redshift-gtk"
fi

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
    echo -e "  ${GREEN}[✔]${NC}  0. Audio — Cirrus CS8409 driver loaded (speakers/mic active)"
else
    echo -e "  ${YELLOW}[!]${NC}  0. Audio — Cirrus CS8409 driver installed, active after reboot"
fi
if command -v easyeffects &>/dev/null || command -v pulseeffects &>/dev/null; then
    echo -e "  ${GREEN}[✔]${NC}     Mic DSP — EasyEffects preset installed (noise gate + autogain)"
else
    echo -e "  ${YELLOW}[!]${NC}     Mic DSP — EasyEffects not installed (mic level will be low)"
fi
echo -e "  ${GREEN}[✔]${NC}  1. Intel GPU — VA-API hardware acceleration"
if [ -f /lib/firmware/brcm/BCM4350C0.hcd ]; then
    echo -e "  ${GREEN}[✔]${NC}  2. Bluetooth — config fixed + firmware installed (BCM4350C0.hcd)"
else
    echo -e "  ${YELLOW}[!]${NC}  2. Bluetooth — firmware missing — check firmware/bluetooth/"
fi
echo -e "  ${GREEN}[✔]${NC}  3. WiFi — macOS NVRAM (BCM4350/c2) + power save off + 5GHz preferred"
echo -e "  ${GREEN}[✔]${NC}  4. FaceTime HD Camera — driver attempted (see warnings above)"
echo -e "  ${GREEN}[✔]${NC}  5. Thunderbolt 3 — bolt daemon"
echo -e "  ${GREEN}[✔]${NC}  6. Battery & Thermal — TLP + thermald + RAPL PL1=20W/PL2=40W (time windows set)"
echo -e "  ${GREEN}[✔]${NC}  7. applesmc — mbpfan (4500 RPM min, 30°C trigger, max at 48°C), sensors, keyboard backlight (max)"
echo -e "  ${GREEN}[✔]${NC}  8. Touchpad — tap-to-click, natural scroll, PalmDetection, clickfinger"
echo -e "  ${GREEN}[✔]${NC}  9. Screen brightness + s2idle suspend + auto-boot EFI disabled"
echo -e "  ${GREEN}[✔]${NC} 10. System & Dev: ZRAM, sysctl, BBR TCP, NVMe I/O scheduler, earlyoom, ulimits"
if [ -f "$SCRIPT_DIR/firmware/display/Color-LCD-MacBookPro14-1.icc" ]; then
    echo -e "  ${GREEN}[✔]${NC} 11. Display color calibration — Apple ICC profile installed + autostart"
else
    echo -e "  ${YELLOW}[!]${NC} 11. Display color calibration — ICC file missing (firmware/display/)"
fi
if command -v redshift &>/dev/null || command -v redshift-gtk &>/dev/null; then
    echo -e "  ${GREEN}[✔]${NC} 12. Night Shift → redshift (6500K day / 4000K night)"
else
    echo -e "  ${YELLOW}[!]${NC} 12. redshift not installed — install: apt-get install redshift-gtk"
fi
echo ""
echo -e "  ${YELLOW}[!]${NC} ${BOLD}REBOOT required for all changes to take effect.${NC}"
echo ""
echo -e "  ${BOLD}${YELLOW}BLUETOOTH — IF hci0 IS MISSING AFTER FIRST REBOOT (migration from macOS):${NC}"
echo -e "  macOS sets BCM4350C0 to 3 Mbaud; Linux uses 115200 baud → chip times out."
echo -e "  Fix (once only): SMC Reset — hold Shift(L)+Ctrl(L)+Option(L)+Power 10 sec, then boot."
echo ""
