#!/bin/bash
# MacBook Pro 14,1 — Hardware Diagnostics Log Collector
# Run after a fresh install to capture the full system state for debugging.
#
# Usage:
#   sudo ./tests/collect-logs.sh              # saves to ~/macbook-diag-YYYYMMDD-HHMMSS.txt
#   sudo ./tests/collect-logs.sh /tmp/out.txt # saves to specified path
#
# The output file can be attached to a GitHub issue or shared for remote debugging.
# It contains: kernel messages, module state, service status, hardware readings,
# audio/BT/WiFi/GPU/display/power config — everything the project touches.

set -euo pipefail

OUTFILE="${1:-${HOME}/macbook-diag-$(date +%Y%m%d-%H%M%S).txt}"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")

section() {
    printf '\n\n══════════════════════════════════════════════════════════════\n' >> "$OUTFILE"
    printf '  %s\n' "$1" >> "$OUTFILE"
    printf '══════════════════════════════════════════════════════════════\n' >> "$OUTFILE"
}

run() {
    local label="$1"; shift
    printf '\n── %s ──\n' "$label" >> "$OUTFILE"
    eval "$@" >> "$OUTFILE" 2>&1 || printf '(command failed or not available)\n' >> "$OUTFILE"
}

run_user() {
    local label="$1"; shift
    local uid
    uid=$(id -u "$REAL_USER" 2>/dev/null) || uid=""
    if [ -n "$uid" ]; then
        printf '\n── %s ──\n' "$label" >> "$OUTFILE"
        sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            "$@" >> "$OUTFILE" 2>&1 || printf '(not available)\n' >> "$OUTFILE"
    fi
}

check_cs8409_suggestion() {
    local preferred="/lib/modules/$(uname -r)/updates/codecs/cirrus/snd-hda-codec-cs8409.ko"
    local dkms="/lib/modules/$(uname -r)/updates/dkms/snd-hda-codec-cs8409.ko"

    if [ -e "$preferred" ]; then
        echo "CS8409 driver file is in the expected updates/codecs/cirrus path."
        return
    fi

    if [ -e "$dkms" ]; then
        echo "Driver is installed in updates/dkms but not in updates/codecs/cirrus."
        echo "Suggested fix: sudo ./install.cirrus.driver.sh && sudo depmod -a"
        return
    fi

    echo "CS8409 driver file is not found in /lib/modules/$(uname -r)/updates."
    echo "Suggested fix: sudo ./install.cirrus.driver.sh && sudo depmod -a"
}

# ── Header ──────────────────────────────────────────────────────────────────
printf 'MacBook Pro 14,1 — Hardware Diagnostics\n' > "$OUTFILE"
printf 'Generated: %s\n' "$(date)" >> "$OUTFILE"
printf 'User: %s | Running as: %s\n' "$REAL_USER" "$(whoami)" >> "$OUTFILE"

# ── System ──────────────────────────────────────────────────────────────────
section "SYSTEM"
run "Kernel + distro"   "uname -a; echo; lsb_release -a 2>/dev/null; echo; cat /etc/os-release"
run "Hardware model"    "cat /sys/class/dmi/id/product_name /sys/class/dmi/id/product_version /sys/class/dmi/id/board_name 2>/dev/null; echo; dmidecode -t system 2>/dev/null | head -20"
run "CPU"               "lscpu | grep -E 'Model name|CPU MHz|Core|Thread|Cache|Stepping'"
run "Memory"            "free -h; echo; cat /proc/meminfo | grep -E 'MemTotal|MemFree|Swap'"
run "Storage"           "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE; echo; df -h"
run "Uptime"            "uptime; last reboot | head -3"

# ── PCI / USB ────────────────────────────────────────────────────────────────
section "PCI / USB"
run "lspci -nn"         "lspci -nn"
run "lspci -v (audio)"  "lspci -v | grep -A10 -i audio"
run "lsusb"             "lsusb"
run "Kernel modules"    "lsmod | sort"

# ── Audio ────────────────────────────────────────────────────────────────────
section "AUDIO — Cirrus CS8409"
run "Cirrus .ko file"   "ls -lh /lib/modules/$(uname -r)/updates/codecs/cirrus/ 2>/dev/null"
run "Module loaded"     "lsmod | grep -E 'snd_hda|cs8409|cirrus'"
run "ALSA playback"     "aplay -l 2>/dev/null"
run "ALSA capture"      "arecord -l 2>/dev/null"
run "ALSA cards"        "cat /proc/asound/cards"
run "HDA codec"         "cat /proc/asound/card0/codec#0 2>/dev/null | head -40"
run "dmesg — audio"     "dmesg | grep -i -E 'cs8409|cirrus|hda_codec|snd_hda|sound' | head -60"
run "CS8409 module files" "find /lib/modules/$(uname -r)/updates -type f -name '*cs8409*.ko*' 2>/dev/null | sort || echo 'none found'"
run "CS8409 fix suggestion" "check_cs8409_suggestion"
run "PipeWire DSP conf" "cat /etc/pipewire/pipewire.conf.d/99-macbook-mic-dsp.conf 2>/dev/null"
run "WirePlumber conf"  "cat /etc/wireplumber/wireplumber.conf.d/52-macbook-mic-default.conf 2>/dev/null"
run_user "PipeWire status" systemctl --user status pipewire wireplumber
run_user "PulseAudio sinks" pactl list sinks short
run_user "PulseAudio sources" pactl list sources short

# ── Bluetooth ────────────────────────────────────────────────────────────────
section "BLUETOOTH — BCM4350C0"
run "hci0 status"       "hciconfig -a 2>/dev/null"
run "rfkill"            "rfkill list"
run "BT firmware"       "ls -lh /lib/firmware/brcm/BCM* 2>/dev/null"
run "bluez config"      "cat /etc/bluetooth/main.conf 2>/dev/null"
run "udev BT rule"      "cat /etc/udev/rules.d/60-bluetooth-macbook.rules 2>/dev/null"
run "journal — BT"      "journalctl -b --no-pager -u bluetooth 2>/dev/null | tail -40"
run "dmesg — BT"        "dmesg | grep -i -E 'bluetooth|bcm4350|hci_uart|btusb|hci0' | head -40"

# ── WiFi ─────────────────────────────────────────────────────────────────────
section "WIFI — BCM4350"
run "Network interfaces" "ip link show; echo; ip addr show"
run "iw dev"            "iw dev 2>/dev/null"
run "iw reg"            "iw reg get 2>/dev/null"
run "brcmfmac config"   "cat /etc/modprobe.d/brcmfmac-macbook.conf 2>/dev/null"
run "NM WiFi conf"      "cat /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf 2>/dev/null"
run "WiFi NVRAM"        "ls -lh /lib/firmware/brcm/brcmfmac4350* 2>/dev/null"
run "dmesg — WiFi"      "dmesg | grep -i -E 'brcmfmac|bcm4350|wlan' | head -30"

# ── GPU ──────────────────────────────────────────────────────────────────────
section "GPU — Intel Iris Plus 640"
run "GPU PCI"           "lspci | grep -i vga"
run "DRM devices"       "ls /sys/class/drm/"
run "i915 params"       "cat /etc/modprobe.d/i915-macbook.conf 2>/dev/null"
run "vainfo"            "vainfo 2>&1 | head -30"
run "dmesg — i915"      "dmesg | grep -i -E 'i915|drm|intel.*gpu' | head -30"

# ── Display ──────────────────────────────────────────────────────────────────
section "DISPLAY — scaling + ICC profile"
run "xrandr"            "DISPLAY=:0 xrandr 2>/dev/null || xrandr 2>/dev/null || echo 'No X display available (run as logged-in user)'"
run "monitors.xml"      "cat $REAL_HOME/.config/monitors.xml 2>/dev/null"
run "ICC system"        "ls -lh /usr/share/color/icc/macbook/ 2>/dev/null"
run "ICC user"          "ls -lh $REAL_HOME/.local/share/icc/ 2>/dev/null"
run "colormgr devices"  "colormgr get-devices 2>/dev/null"
run "colormgr profiles" "colormgr get-profiles 2>/dev/null"
run "autostart files"   "ls -la $REAL_HOME/.config/autostart/ 2>/dev/null"
run_user "GNOME scale"  gsettings get org.gnome.desktop.interface scaling-factor
run_user "GNOME frac"   gsettings get org.gnome.mutter experimental-features
run "Xfce scale"        "cat $REAL_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml 2>/dev/null"
run_user "Xfce WindowScalingFactor" xfconf-query -c xsettings -p /Gdk/WindowScalingFactor
run_user "Xfce Xft DPI"           xfconf-query -c xsettings -p /Xft/DPI
run "Xfce autostart scale" "cat $REAL_HOME/.config/autostart/macbook-xrandr-scale.desktop 2>/dev/null || echo 'none'"

# ── Battery / Thermal / Power ────────────────────────────────────────────────
section "POWER — RAPL + TLP + Fan"
run "RAPL PL1"          "cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null"
run "RAPL PL2"          "cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw 2>/dev/null"
run "RAPL time windows" "cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_time_window_us 2>/dev/null; cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_1_time_window_us 2>/dev/null"
run "RAPL service"      "systemctl status macbook-rapl-limits 2>/dev/null"
run "TLP config"        "cat /etc/tlp.d/50-macbook-pro14-1.conf 2>/dev/null"
run "TLP status"        "tlp-stat -p 2>/dev/null | head -50"
run "thermald"          "systemctl status thermald 2>/dev/null | head -15"
run "Temperatures"      "sensors 2>/dev/null"
run "Fan RPM"           "cat /sys/devices/platform/applesmc.768/fan1_input 2>/dev/null; cat /sys/devices/platform/applesmc.768/fan1_min 2>/dev/null"
run "mbpfan config"     "cat /etc/mbpfan.conf 2>/dev/null | grep -v '^#' | grep -v '^$'"
run "mbpfan status"     "systemctl status mbpfan 2>/dev/null | head -15"
run "Battery"           "cat /sys/class/power_supply/BAT0/capacity 2>/dev/null; cat /sys/class/power_supply/BAT0/status 2>/dev/null; upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null | head -20"

# ── Suspend / Sleep ──────────────────────────────────────────────────────────
section "SUSPEND — s2idle + NVMe"
run "Sleep mode"        "cat /sys/power/mem_sleep"
run "GRUB cmdline"      "cat /proc/cmdline"
run "NVMe d3cold"       "cat /sys/bus/pci/devices/0000:01:00.0/d3cold_allowed 2>/dev/null"
run "NVMe service"      "systemctl status macbook-nvme-d3cold 2>/dev/null | head -10"
run "fstrim"            "systemctl status fstrim.timer 2>/dev/null | head -10"
run "journal — suspend" "journalctl -b --no-pager -u systemd-suspend 2>/dev/null | tail -20"

# ── Camera ───────────────────────────────────────────────────────────────────
section "CAMERA — facetimehd"
run "Module"            "lsmod | grep facetimehd"
run "Video devices"     "ls -l /dev/video* 2>/dev/null"
run "Firmware"          "ls /usr/lib/firmware/facetimehd/ 2>/dev/null"
run "dmesg — camera"    "dmesg | grep -i -E 'facetime|fthd|14e4:1570' | head -20"

# ── Touchpad / Keyboard ──────────────────────────────────────────────────────
section "INPUT — touchpad + keyboard"
run "Input devices"     "libinput list-devices 2>/dev/null | grep -E 'Device:|Capabilities:'"
run "hid_apple fnmode"  "cat /sys/module/hid_apple/parameters/fnmode 2>/dev/null"
run "hid-apple conf"    "cat /etc/modprobe.d/hid-apple-macbook.conf 2>/dev/null"
run "libinput X11 conf" "cat /usr/share/X11/xorg.conf.d/40-macbook-libinput.conf 2>/dev/null"
run "Kbd backlight"     "cat /sys/class/leds/spi::kbd_backlight/brightness 2>/dev/null; cat /sys/class/leds/spi::kbd_backlight/max_brightness 2>/dev/null"
run_user "GNOME touchpad" gsettings get org.gnome.desktop.peripherals.touchpad tap-to-click

# ── System Optimizations ─────────────────────────────────────────────────────
section "SYSTEM OPTIMIZATIONS"
run "ZRAM"              "zramctl 2>/dev/null; cat /etc/systemd/zram-generator.conf 2>/dev/null"
run "vm.swappiness"     "sysctl vm.swappiness"
run "inotify watches"   "sysctl fs.inotify.max_user_watches"
run "TCP congestion"    "sysctl net.ipv4.tcp_congestion_control"
run "NVMe scheduler"    "cat /sys/block/nvme0n1/queue/scheduler 2>/dev/null"
run "earlyoom"          "systemctl status earlyoom 2>/dev/null | head -10"
run "fstab"             "cat /etc/fstab"
run "ulimits"           "cat /etc/security/limits.d/60-macbook-dev.conf 2>/dev/null"

# ── Thunderbolt ──────────────────────────────────────────────────────────────
section "THUNDERBOLT 3"
run "bolt"              "systemctl status bolt 2>/dev/null | head -10; boltctl list 2>/dev/null"
run "dmesg — TB"        "dmesg | grep -i -E 'thunderbolt|tb_|jhl6540' | head -20"

# ── All MacBook systemd services ─────────────────────────────────────────────
section "MACBOOK SYSTEMD SERVICES"
run "All macbook-*"     "systemctl list-units 'macbook-*' --all 2>/dev/null"
for svc in macbook-rapl-limits macbook-nvme-d3cold; do
    run "status: $svc"  "systemctl status $svc 2>/dev/null"
done

# ── Full dmesg tail ──────────────────────────────────────────────────────────
section "DMESG — LAST 200 LINES"
run "dmesg tail"        "dmesg | tail -200"

# ── Journal errors ───────────────────────────────────────────────────────────
section "JOURNAL — ERRORS THIS BOOT"
run "journal errors"    "journalctl -b --no-pager -p err 2>/dev/null | tail -60"

# ── Footer ───────────────────────────────────────────────────────────────────
printf '\n\n── END OF DIAGNOSTICS ──\n' >> "$OUTFILE"
printf 'File: %s\n' "$OUTFILE" >> "$OUTFILE"
printf 'Size: %s\n' "$(wc -c < "$OUTFILE") bytes" >> "$OUTFILE"

echo ""
echo "  Diagnostics saved to: $OUTFILE"
echo "  Size: $(wc -l < "$OUTFILE") lines, $(wc -c < "$OUTFILE") bytes"
echo ""
echo "  Share this file to diagnose hardware issues on MacBookPro14,1."
