# MacBook Pro 13" 2017 — Ubuntu / Xubuntu 26.04 Hardware Guide

Complete hardware support guide and drivers for **MacBook Pro 13" 2017 (MacBookPro14,1)**
running Ubuntu 26.04 (GNOME) or Xubuntu 26.04 (Xfce 4.20).

Covers: Audio · GPU · Bluetooth · WiFi · Camera · Thunderbolt · Battery · Fan · Touchpad · Suspend · **Color Calibration**

---

## Hardware Status

| Component | Chip | Status | Fixed by |
|---|---|---|---|
| Audio (speakers + headphones) | Cirrus CS8409 / CS42L83 | ✅ Works | `macbook_hardware_fixer.sh` step 0 |
| Audio (microphone) | Cirrus CS8409 | ✅ Works | PipeWire filter-chain DSP (noise gate + autogain) — `macbook_hardware_fixer.sh` step 0 |
| Intel GPU | Iris Plus 640 (Kaby Lake GT3) | ✅ Works + VA-API | `macbook_hardware_fixer.sh` step 1 |
| WiFi | Broadcom BCM4350 | ✅ Works | `macbook_hardware_fixer.sh` step 3 |
| Bluetooth | Broadcom BCM4350C0 (UART) | ⚠️ SMC Reset needed once + firmware for A2DP | `macbook_hardware_fixer.sh` step 2 · `bluetooth/bluetooth.sh` |
| FaceTime HD Camera | Broadcom 720p PCIe 14e4:1570 | ⚠️ Needs driver | `macbook_hardware_fixer.sh` step 4 |
| Thunderbolt 3 | Intel Alpine Ridge 4C (JHL6540) | ✅ Works | `macbook_hardware_fixer.sh` step 5 |
| Battery & Thermal | Intel i5-7360U + applesmc | ✅ Works | `macbook_hardware_fixer.sh` step 6 |
| Fan control | applesmc + mbpfan | ✅ Works (max cooling profile: 4500 RPM min, 30°C trigger) | `macbook_hardware_fixer.sh` step 7 |
| Keyboard backlight | Apple SPI LED | ✅ Works | `macbook_hardware_fixer.sh` step 7 |
| Touchpad | Apple SPI Touchpad | ✅ Works | `macbook_hardware_fixer.sh` step 8 |
| Apple SPI Keyboard | Apple SPI Keyboard | ✅ Works | `macbook_hardware_fixer.sh` step 8 |
| Screen brightness | Intel i915 backlight | ✅ Works | `macbook_hardware_fixer.sh` step 9 |
| Suspend/Sleep | Intel S0ix / s2idle | ✅ Works (s2idle + NVMe d3cold fix) | `macbook_hardware_fixer.sh` step 9 |
| NVMe Storage | Apple SSD AP0256J | ✅ Works natively | — |
| USB 3.0 | Intel xHCI | ✅ Works natively | — |
| **Display color calibration** | **Apple factory ICC profile** | **✅ Works** | **`macbook_hardware_fixer.sh` step 11** |


## Known Limitations

- **Battery life**: expect under 4 hours. Panel Self-Refresh (PSR), NVMe APST, and
  Thunderbolt power management are not fully working — these components consume more
  power than on macOS.
- **Audio microphone input**: raw level is very low (CS8409/CS42L83 outputs the signal
  without hardware amplification). Fixed automatically by the PipeWire filter-chain DSP
  installed by `macbook_hardware_fixer.sh` step 0 — the virtual source "MacBook Pro Mic (DSP)"
  applies noise gate + auto-gain and is set as default capture device.
- **Bluetooth A2DP audio**: choppy without BCM4350C0 firmware (see Bluetooth section below).
  Basic scan and pairing work without firmware.
- **Suspend/resume**: works with s2idle + NVMe d3cold fix (both applied by
  `macbook_hardware_fixer.sh` step 9). Even so, resume may be slow in some cases.
- **Auto-boot on lid open**: the MacBook Pro 2016/2017 powers on automatically when the
  lid is opened. To disable this from Linux:
  ```bash
  sudo sh -c 'printf "\x07\x00\x00\x00\x00" > /sys/firmware/efi/efivars/AutoBoot-7c436110-ab2a-4bbb-a880-fe41995c9f82'
  ```
  If you get "No space left on device", first clean up stale EFI dump variables:
  ```bash
  for i in $(find /sys/firmware/efi/efivars/ -name 'dump-type0*'); do sudo chattr -i "$i" && sudo rm "$i"; done
  ```

---

## Fresh Install Quick Start (Ubuntu 26.04)

On a brand new Ubuntu 26.04 installation on a MacBook Pro 13" 2017, run in order:

**Step 1 — Install build dependencies:**
```bash
sudo apt-get update && sudo apt-get install -y \
    build-essential linux-headers-$(uname -r) make patch wget git dwarves
```

> `dwarves` provides `pahole`, required for BTF generation when building the kernel module.
> Without it the build still succeeds but emits a "pahole version differs" warning.
> `macbook_hardware_fixer.sh` installs it automatically if missing.

**Step 2 — Clone this repository:**
```bash
git clone https://github.com/vrilutza/MacBookPro14.1.git
cd MacBookPro14.1
```

**Step 3 — Install all hardware drivers** (Audio, GPU, Bluetooth, WiFi, Camera,
Thunderbolt, Battery, Fan, Keyboard backlight, Touchpad, Suspend,
**Display color calibration**):
```bash
sudo ./macbook_hardware_fixer.sh
```

**Step 4 — Fix Bluetooth firmware** (required for A2DP audio; basic scan/pair works without it):

The Broadcom **BCM4350C0** UART Bluetooth chip needs firmware not in `linux-firmware`.
See the [Bluetooth section](#2-bluetooth--bcm4350c0) below for full details.

```bash
# Option A: copy from macOS (dual-boot or USB installer)
sudo cp /path/to/BCM4350C0.hcd /lib/firmware/brcm/BCM4350C0.hcd
sudo ln -sf BCM4350C0.hcd /lib/firmware/brcm/BCM2E7C.hcd
sudo rmmod hci_uart && sudo modprobe hci_uart

# Option B: community-extracted firmware
# Search GitHub for 'BCM4350C0.hcd' and place at /lib/firmware/brcm/BCM4350C0.hcd
```

**Step 5 — Reboot:**
```bash
sudo reboot
```

**Step 6 — Verify everything was applied correctly:**
```bash
# Full hardware check (all 12 steps including audio + color calibration):
./tests/verify-hardware.sh
sudo ./tests/verify-hardware.sh   # for complete Bluetooth config check

# Audio-only check:
./tests/verify-installation.sh
```

### Collect debug logs for troubleshooting
If verification reports a missing CS8409 module, generate a full diagnostics file with:
```bash
sudo ./tests/collect-logs.sh /tmp/macbook-diag-$(date +%Y%m%d-%H%M%S).txt
```
That file includes the CS8409 module layout and a suggested fix when the driver is present only in `updates/dkms`.

---

## Hardware Components

### 1. Intel GPU — Iris Plus 640 (VA-API)

**Script:** `macbook_hardware_fixer.sh` step 1

Installs VA-API drivers for hardware-accelerated video decoding (H.264, HEVC):

```bash
sudo apt-get install -y intel-media-va-driver i965-va-driver vainfo
```

**Verify:**
```bash
vainfo   # should list VAProfileH264*, VAProfileHEVC* entries
```

---

### 2. Bluetooth — BCM4350C0

**Script:** `macbook_hardware_fixer.sh` step 2 · standalone: `bluetooth/bluetooth.sh`

The chip self-identifies as `BCM4350C0` (macOS marketing name: BCM2E7C). It is a **UART
chip** (not USB) — connected via serial0/ttyS4. The chip works from internal ROM; external
firmware is optional (improves A2DP audio quality but is not required for basic BT).

#### SMC Reset — required ONCE after migrating from macOS

The BCM4350C0 chip **retains the baud rate set by macOS** (3 Mbaud). Linux uses 115200
baud → the driver times out → `hci0` never appears. This is the most common cause of "no
Bluetooth after Ubuntu install".

**Fix (done once — never needed again):**

1. Shut down completely (not restart)
2. Hold simultaneously for **10 seconds**: `Shift(left)` + `Ctrl(left)` + `Option(left)` + `Power`
3. Release all keys, press `Power` normally to start

After SMC Reset the chip resets to factory baud rate and `hci0` will appear.

> **Important:** Never apply USB firmware (files with `0a5c` in the name) to this chip.
> USB firmware corrupts the UART baud rate and makes BT non-functional until another SMC Reset.
> `macbook_hardware_fixer.sh` automatically removes any such wrong symlinks.

**What the script fixes:**
- Removes wrong USB firmware symlinks (BCM4350C5-0a5c-*.hcd) that break the UART chip
- bluez 5.65+ config bug: `AutoEnable` moved from `[General]` to `[Policy]`
- Auto-installs `apfs-fuse` and scans for a macOS HFS+/APFS partition to extract BCM4350C0.hcd
- Creates `/etc/udev/rules.d/60-bluetooth-macbook.rules` to bring `hci0` up automatically
- WirePlumber: disables A2DP → HFP/HSP auto-switch (prevents AirPods Pro dropouts)

**Firmware (optional — improves A2DP; linux-firmware does NOT have it):**

```bash
# Option A: from running macOS (dual-boot) or macOS USB installer
ls /usr/share/firmware/bluetooth/     # find BCM4350C0.hcd
sudo cp /path/to/BCM4350C0.hcd /lib/firmware/brcm/BCM4350C0.hcd
sudo ln -sf BCM4350C0.hcd /lib/firmware/brcm/BCM2E7C.hcd   # older kernel compat

# Option B: community-extracted firmware (search GitHub for 'BCM4350C0.hcd')

# Reload driver (or reboot):
sudo rmmod hci_uart && sudo modprobe hci_uart
```

**Verify:**
```bash
hciconfig hci0           # should show: UP RUNNING
rfkill list bluetooth    # Soft blocked: no
journalctl -b -k | grep "hci0.*BCM"   # should NOT show "firmware Patch file not found"
```

---

### 3. WiFi — Broadcom BCM4350

**Script:** `macbook_hardware_fixer.sh` step 3

Works out of the box with the `brcmfmac` kernel driver. The script applies optimisations:

- Disables WiFi power save (causes latency spikes) via NetworkManager:
  `/etc/NetworkManager/conf.d/99-wifi-powersave-off.conf`
- Sets `roamoff=1` via `/etc/modprobe.d/brcmfmac-macbook.conf` (power_save removed in kernel 6.x)
- Installs macOS NVRAM (board-specific RF calibration) from `firmware/wifi/`:
  - `brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt` (model-specific, kernel prefers this)
  - `brcmfmac4350-pcie.txt` (generic fallback)
  - Symlinks for kernel 6.6+ which reports the chip as `brcmfmac4350c2-pcie` (BCM4350 rev C2):
    `brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1.txt` → model-specific NVRAM
    `brcmfmac4350c2-pcie.txt` → generic fallback

  The macOS NVRAM is calibrated for `boardid=0x170` (hawaii platform) and improves WiFi
  range, 5 GHz stability, and regulatory compliance vs the generic Linux NVRAM.
- **5 GHz band preference**: set per-connection (the `wifi.band=a` key is invalid in
  NetworkManager conf.d files — NM ignores it and logs a warning):
  ```bash
  nmcli connection modify "YourWiFiName" 802-11-wireless.band a
  ```

**Set regulatory domain** (if channels are limited):
```bash
sudo iw reg set RO   # replace RO with your country code
```

**Verify:**
```bash
lsmod | grep brcmfmac
ip link show          # should show wlp* interface UP
```

---

### 4. FaceTime HD Camera — Broadcom PCIe

**Script:** `macbook_hardware_fixer.sh` step 4

The camera (PCIe `14e4:1570`) requires the third-party `facetimehd` driver:

- Firmware downloaded from Apple CDN via [patjak/facetimehd-firmware](https://github.com/patjak/facetimehd-firmware)
- Kernel module compiled from [patjak/facetimehd](https://github.com/patjak/facetimehd)

If the module fails to compile (kernel too new), check
https://github.com/patjak/facetimehd for kernel compatibility.

**Verify:**
```bash
lsmod | grep facetimehd    # module loaded
ls /dev/video*             # /dev/video0 should exist
```

---

### 5. Thunderbolt 3 — Intel Alpine Ridge 4C

**Script:** `macbook_hardware_fixer.sh` step 5

Works out of the box. The `bolt` daemon handles device authorisation:

```bash
boltctl list                      # list connected TB3 devices
boltctl enroll <device-uuid>      # authorise a device permanently
```

Or use **GNOME Settings → Privacy → Thunderbolt**.

**Note:** Thunderbolt power management is incomplete — TB ports consume power
even with no devices attached, contributing to reduced battery life.

---

### 6. Battery & Thermal — TLP + thermald + RAPL limits

**Script:** `macbook_hardware_fixer.sh` step 6

#### Why Linux runs hotter than macOS

The i5-7360U has a **15W TDP**. macOS Ventura enforces PL1=15W / PL2=25W (Intel spec).
Linux BIOS defaults leave **PL1=100W / PL2=125W** — the CPU can sustain turbo boost
(3.5 GHz) indefinitely, generating much more heat than on macOS.

The script fixes this with two mechanisms:

| Fix | What it does |
|---|---|
| `macbook-rapl-limits.service` | Sets PL1=20W, PL2=40W on every boot, runs **after** `thermald` |
| `/etc/tlp.d/50-macbook-pro14-1.conf` | Disables turbo on battery, sets HWP to `balance_power` on battery / `performance` on AC |

> **Note — thermald interaction:** `thermald` dynamically adjusts RAPL limits via DPTF.
> The service is ordered `After=thermald.service` so it always applies last and its
> values are not overridden at boot. If you later run `systemctl restart thermald`,
> re-run `systemctl restart macbook-rapl-limits` to restore the correct limits.

**Why PL1=20W and not the stock 15W or cTDP-up 28W:**
- 15W: leaves performance on the table — CPU throttles to 2.3 GHz under load
- 28W: exceeds heatsink capacity (thermal resistance ~2.0°C/W at max fan → 81°C sustained → thermal throttle)
- **20W sweet-spot**: sustains 2.8–3.0 GHz continuously at ~65°C with aggressive fan — no throttle, no overheating

Expected result after reboot: **10–20°C lower** at sustained load vs BIOS defaults (100W).

```bash
# Check current RAPL limits:
cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw   # should be 20000000 (20W)
cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw   # should be 40000000 (40W)

# Check RAPL time windows (Intel Kaby Lake U spec):
cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_time_window_us   # should be 976563  (~1s)
cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_1_time_window_us   # should be 27343000 (~28s)

# Check RAPL service:
systemctl status macbook-rapl-limits

# Check TLP config applied:
sudo tlp-stat -p | grep -E "HWP|BOOST|PERF"

# Check CPU temperature:
sensors | grep "Package\|Core"

# Per-process power usage:
sudo powertop
```

**TLP configuration** (`/etc/tlp.d/50-macbook-pro14-1.conf`):

| Setting | AC | Battery |
|---|---|---|
| CPU governor | powersave | powersave |
| HWP policy | **performance** | balance_power |
| HWP dynamic boost | **ON** | OFF |
| Platform profile | **performance** | low-power |
| Turbo boost | ON | **OFF** (−10–15°C) |
| PCIe ASPM | default | powersupersave |
| Runtime PM | on | auto |

**Configure battery charging thresholds** (extend long-term battery health):
```bash
sudo nano /etc/tlp.conf
# Add:
BAT0_CHARGE_THRESH_START=20
BAT0_CHARGE_THRESH_STOP=80
sudo tlp start
```

**Note:** `power-profiles-daemon` (GNOME default) conflicts with TLP.
The script removes it automatically.

---

### 7. Fan Control, Temperature Sensors, Keyboard Backlight — applesmc

**Script:** `macbook_hardware_fixer.sh` step 7

**Read temperatures and fan speed:**
```bash
sensors        # CPU temp, chassis temp, fan RPM (after reboot)
```

**Fan control:** `mbpfan` is installed with an aggressive cooling profile tuned for the
i5-7360U. The profile (tested on Ubuntu 26.04) keeps the Mac cooler than the default:

| Setting | Value | Reason |
|---------|-------|--------|
| `min_fan1_speed` | **4500 RPM** | Always spinning fast — maximum baseline cooling |
| `low_temp` | **30°C** | Fan ramps at even minor load — catches any workload early |
| `high_temp` | **40°C** | Ramps up quickly |
| `max_temp` | **48°C** | Full speed above this — CPU rarely exceeds 70°C |
| `polling_interval` | 1 s | Fast response to temperature spikes |

Config at `/etc/mbpfan.conf`. Combined with the RAPL 20W limit (step 6), this keeps
the Mac at ~65°C sustained under full load. Fan noise is constant (~4500–6000 RPM) —
by design: cooling priority over silence.

**Live monitor** (run manually in any terminal):
```bash
macbook-monitor   # colour-coded fan RPM + CPU temps, Ctrl+C to quit
```

**Keyboard backlight:**
```bash
# Read current / max brightness:
cat /sys/class/leds/spi::kbd_backlight/brightness
cat /sys/class/leds/spi::kbd_backlight/max_brightness

# Set brightness (0–255):
echo 255 | sudo tee /sys/class/leds/spi::kbd_backlight/brightness
```

The script sets **maximum brightness** on every boot via `systemd-tmpfiles`
(`/etc/tmpfiles.d/macbook-kbd-backlight.conf`).

---

### 8. Touchpad & Keyboard — libinput

**Script:** `macbook_hardware_fixer.sh` step 8

Configured automatically for both Wayland (via `gsettings`) and X11 (via
`/usr/share/X11/xorg.conf.d/40-macbook-libinput.conf`):

- Tap-to-click
- Natural scroll
- Two-finger scroll
- Clickfinger (1-finger = left, 2-finger = right, 3-finger = middle)
- Disable-while-typing
- **PalmDetection** — prevents cursor jumps when palms touch the trackpad while typing
- **TappingButtonMap = lrm** — 1-finger tap = left, 2-finger = right, 3-finger = middle

**Fn key behaviour** (set via `hid_apple fnmode`):
```bash
# Current mode:
cat /sys/module/hid_apple/parameters/fnmode

# F1-F12 as function keys (default after script): fnmode=1
# F1-F12 as media keys (Apple default): fnmode=0
# Change persistently: edit /etc/modprobe.d/hid-apple-macbook.conf
```

---

### 9. Screen Brightness + Suspend/Sleep

**Script:** `macbook_hardware_fixer.sh` step 9

**Screen brightness** (no root needed after adding user to `video` group):
```bash
brightnessctl set 50%
brightnessctl set +10%
brightnessctl set 10%-
```

**Lid-open auto-boot** (step 9): macOS sets an EFI variable that causes the MacBook Pro
to power on automatically when the lid is opened. The script disables this:
```bash
printf '\x07\x00\x00\x00\x00' | sudo tee /sys/firmware/efi/efivars/AutoBoot-7c436110-ab2a-4bbb-a880-fe41995c9f82
```
Applied once at install time. If you see "No space left on device", clear stale EFI dump
variables first (see [Known Limitations](#known-limitations)).

**Suspend:** MacBook Pro 14,1 requires two fixes for reliable suspend/resume:

| Fix | What it does | Applied by |
|---|---|---|
| `mem_sleep_default=s2idle` in GRUB | Uses Intel S0ix instead of broken S3 | script + `update-grub` |
| NVMe d3cold disabled (`macbook-nvme-d3cold.service`) | Prevents NVMe from entering D3cold, which breaks resume | systemd service |

```bash
# Check current sleep mode (should show [s2idle]):
cat /sys/power/mem_sleep

# Check NVMe d3cold status (should be 0):
cat /sys/bus/pci/devices/0000:01:00.0/d3cold_allowed

# Check service:
systemctl status macbook-nvme-d3cold
```

Reference: https://github.com/Dunedan/mbp-2016-linux#suspend--hibernation

**Hibernate / SuspendThenHibernate (optional — not configured by the script):**

macOS uses `hibernatemode=3` (hybrid sleep): RAM stays powered AND is saved to disk.
After ~3 hours on battery (`standbydelaylow=10800`) the machine enters full hibernate.

On Linux this is not configured because:
- Hibernate requires a swap partition or swap file **≥ RAM size** (16 GB for this Mac)
- The Apple SSD NVMe controller's behaviour under hibernation is not well tested
- s2idle (`mem_sleep_default=s2idle`) works reliably and is sufficient for daily use

If you want to enable `SuspendThenHibernate` manually on Ubuntu 26.04:
```bash
# 1. Create a swap file >= your RAM size (e.g., 16 GB)
sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 2. Get swap file offset (needed for hibernation resume)
sudo filefrag -v /swapfile | awk 'NR==4{print $4}' | tr -d '.'

# 3. Add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub:
#    resume=/dev/nvme0n1p2 resume_offset=<offset_from_step_2>
# 4. Enable SuspendThenHibernate
sudo systemctl enable systemd-hibernate-resume@$(findmnt -n -o SOURCE /)
echo 'HandleLidSwitch=suspend-then-hibernate' | sudo tee /etc/systemd/logind.conf.d/hibernate.conf
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/sleep.conf.d/hibernate.conf << 'EOF'
[Sleep]
HibernateDelaySec=10800
EOF
```

> **Note:** On MacBook Pro 14,1 the NVMe controller is Apple-proprietary (not standard NVMe).
> Hibernate has not been tested on this specific hardware. Proceed at your own risk.

---

### 10. Audio — Cirrus Logic CS8409

**Script:** `macbook_hardware_fixer.sh` step 0 (calls `install.cirrus.driver.sh` internally)

The internal speakers and headphone jack use a Cirrus Logic CS8409 HDA codec
with CS42L83 / MAX98706 / SSM3515 / TAS5764L amplifiers. This requires a
custom out-of-tree kernel module.

**Install:**
```bash
sudo ./install.cirrus.driver.sh
```

**DKMS** (auto-rebuilds module on kernel upgrades — recommended):
```bash
sudo ./install.cirrus.driver.sh -i    # install with DKMS
sudo ./install.cirrus.driver.sh -r    # remove DKMS registration
```

**Remove driver:**
```bash
sudo rm /lib/modules/$(uname -r)/updates/codecs/cirrus/snd-hda-codec-cs8409.ko
sudo depmod -a
```

**GNOME sound settings:**
- Output: set to **Analogue Stereo Output**
- Input: set to **Analogue Stereo Duplex**

**Microphone:** the recorded level is low (same as macOS raw level — CS8409/CS42L83
outputs the raw signal; Apple applies DSP in CoreAudio, not in hardware).
The script installs a **system-level PipeWire filter-chain** (no GUI required) with:
- Noise gate (LADSPA `gate_1408`, threshold −26 dB — removes fan noise between speech)
- Auto-gain compressor (LADSPA `sc4_1882`, makeup +18 dB — normalises input level)

The virtual source **"MacBook Pro Mic (DSP)"** is set as the default capture device via
WirePlumber — transparent to all applications (video calls, recording software, etc.).
To bypass DSP and use the raw mic, select the original source in your audio settings.

**NOTA BENE:** The direct hardware device `hw:0,0` and `plughw:0,0` have
**NO volume control** and will be **VERY loud**.

**Test audio:**
```bash
aplay tests/StereoTest32.wav                              # normal (respects volume)
aplay -D hw:0,0 tests/StereoTest32_reduced_m24dB.wav     # direct hardware (-24 dB)
```

**Supported kernels:** Ubuntu 26.04 kernel 6.17+ and 7.0+.
The install script handles the 6.17 source directory reorganisation automatically.

**Technical notes** (audio hardware internals): see [`NOTES.md`](NOTES.md).

---

### 11. System & Development Optimizations

**Script:** `macbook_hardware_fixer.sh` step 10

Applied automatically — no extra tools needed. All settings are persistent across reboots.

| Optimization | Config file | Impact |
|---|---|---|
| **ZRAM** (lz4, 50% RAM) | `/etc/systemd/zram-generator.conf` | No more freezes during `cargo build` / `docker pull` |
| **vm.swappiness = 10** | `/etc/sysctl.d/60-macbook-dev.conf` | Keeps data in RAM 6× longer before swapping |
| **inotify = 524288** | same | VSCode / IntelliJ / webpack HMR work without error |
| **BBR TCP** | same | 30-50% faster `git clone`, `npm install`, `docker pull` over WiFi |
| **TCP buffers** | same | Better throughput for large transfers |
| **NVMe I/O scheduler: none** | `/etc/udev/rules.d/61-nvme-scheduler.rules` | Lowest possible disk latency |
| **fstab noatime** | `/etc/fstab` | Reduces NVMe write amplification on every file read |
| **earlyoom** | `/etc/default/earlyoom` | Kills hungry processes at 10% free RAM → no freeze |
| **ulimits** (nofile=65536) | `/etc/security/limits.d/60-macbook-dev.conf` | Node.js / Docker / JVM open many file descriptors |
| **i915 FBC + PSR** | `/etc/modprobe.d/i915-macbook.conf` | Saves 1-2W GPU power → cooler, longer battery |
| **HiDPI 2× scaling** | gsettings (GNOME) / xfconf-query (Xfce) | 2560×1600 Retina display — without this text is microscopic |
| **Fractional scaling** | gsettings mutter (GNOME/Wayland only) | Enables 150%/175% options in GNOME Display Settings; Xfce/X11 fractional xrandr scaling is disabled by default to avoid blurriness |
| **Power settings** | gsettings (GNOME) / xfconf-query (Xfce) | Power button=suspend, lid=suspend, AC=never-sleep, screen-blank=5min |
| **intel-microcode** | apt package | CPU security patches + errata fixes for i5-7360U (Kaby Lake) |
| **fstrim.timer** | systemd timer | Weekly NVMe TRIM — sustained write speed + SSD longevity |
| **journald limit** | `/etc/systemd/journald.conf.d/` | Caps logs at 1GB / 2 weeks — prevents disk fill during dev |
| **coredump limit** | `/etc/systemd/coredump.conf.d/` | 512MB cap per dump — JVM/Chromium crashes won't fill NVMe |
| **git fsmonitor** | `~/.gitconfig` | `git status` 10× faster in large repos (React, monorepo, Django) |

**Verify:**
```bash
sysctl fs.inotify.max_user_watches      # 524288
sysctl vm.swappiness                    # 10
sysctl net.ipv4.tcp_congestion_control  # bbr
zramctl                                 # /dev/zram0 present
cat /sys/block/nvme0n1/queue/scheduler  # [none]
systemctl is-active earlyoom            # active
systemctl is-enabled fstrim.timer       # enabled
dpkg -l intel-microcode | grep ^ii      # installed
gsettings get org.gnome.desktop.interface scaling-factor  # uint32 2
git config --global core.fsmonitor      # true
```

**Live monitor (fan + temps):**
```bash
macbook-monitor   # colour-coded RPM + CPU temps, Ctrl+C to quit
```

---

### 12. Display Color Calibration — Apple factory ICC profile

**Script:** `macbook_hardware_fixer.sh` step 11

The MacBook Pro 13" 2017 display is **factory-calibrated by Apple** at the unit level.
macOS ships a per-display ICC profile that encodes:

| Data | What it does |
|---|---|
| RGB primaries (rXYZ, gXYZ, bXYZ) | Describes the panel's actual gamut — wider than sRGB |
| Tone response curves (rTRC/gTRC/bTRC) | 1024-point factory gamma curves per channel |
| White point (D65) | Ensures neutral whites match the calibrated D65 standard |
| Apple vcgt/vcgp | Video card gamma table metadata |

**Without this profile**, Ubuntu uses a generic sRGB assumption: colors appear
oversaturated (especially reds and greens) and the white point is wrong.

The profile is included in this repo at `firmware/display/Color-LCD-MacBookPro14-1.icc` (3.3 kB),
extracted from macOS Ventura at:
```
/Library/ColorSync/Profiles/Displays/Color LCD-<UUID>.icc
```

**What the script does:**

1. Installs `colord` (Linux color management daemon)
2. Copies the profile to `/usr/share/color/icc/macbook/` (system-wide)
3. Copies to `~/.local/share/icc/` (per-user — GNOME Color Manager lists it here)
4. Installs `/usr/local/bin/macbook-color-profile.sh` — assigns the profile to the
   built-in eDP display via `colormgr` on each login
5. Creates `~/.config/autostart/macbook-color-profile.desktop` — runs the script
   automatically on every GNOME session start

**Verify:**
```bash
# Check profile files are installed
ls /usr/share/color/icc/macbook/
ls ~/.local/share/icc/

# Check colord knows about the profile (after login)
colormgr get-profiles | grep Color-LCD

# Check the built-in display device
colormgr get-devices

# Manually assign (if autostart didn't fire yet):
/usr/local/bin/macbook-color-profile.sh

# GNOME GUI: Settings → Color → built-in display → select 'Color-LCD-MacBookPro14-1'
```

**Notes:**
- The autostart script runs after every login — colord resets profile assignments
  between sessions, so it must be re-applied each time.
- If you use a display manager other than GDM, add `macbook-color-profile.sh` to
  your session startup manually.
- For dual-boot: the profile is already on the macOS partition at
  `/Library/ColorSync/Profiles/Displays/Color LCD-*.icc` if you ever need to re-extract it.

---

## Testing

Before running on real hardware you can catch most errors in Docker or a VM.
The three layers cover progressively more of the script:

| Layer | What it catches | Time | Command |
|---|---|---|---|
| **Syntax** | bash errors, typos | 5s | `make test-syntax` |
| **Docker** | missing packages, config logic, file writing | 3-5 min | `make test-docker` |
| **Multipass VM** | systemd services, GRUB, sysctl, fstab | 5-10 min | `make test-vm` |
| **Real hardware** | applesmc, Bluetooth, RAPL, NVMe | — | `sudo ./macbook_hardware_fixer.sh` |

### Syntax check (no tools needed)

```bash
make test-syntax
# or directly:
bash tests/test-docker.sh --syntax
```

Checks bash syntax on all scripts. Runs in seconds, no dependencies.

### Docker test (Ubuntu 26.04 container)

```bash
# Install Docker if not present:
sudo apt-get install docker.io
sudo usermod -aG docker $USER   # log out and back in after this

# Run:
make test-docker

# Run and remove image afterwards:
make test-docker-clean
```

**What Docker tests:** package availability (`apt-get install`), all config files
written correctly, script logic, Python sections, sysctl syntax.

**What Docker cannot test:** systemd services (mocked), kernel modules,
hardware paths (`/sys/devices/platform/applesmc`, `/sys/class/powercap/...`),
GNOME gsettings — all mocked with stubs that log and return 0.

### Multipass VM test (full Ubuntu 26.04 with systemd)

```bash
# Install Multipass:
sudo snap install multipass

# Run (creates a fresh Ubuntu 26.04 VM, runs the full script):
make test-vm
```

**What Multipass tests:** everything Docker tests, plus: real `systemctl enable/start`,
real `sysctl -p`, real GRUB file modification, real `fstab` editing, real `journald` config.

```bash
# After test-vm completes, run the verifier inside the VM:
multipass exec macbook-test -- sudo bash /project/tests/verify-hardware.sh

# Destroy VM when done:
multipass delete macbook-test && multipass purge
```

### CI — GitHub Actions

Every push and pull request automatically runs:
1. Bash syntax check on all scripts
2. Docker integration test (Ubuntu 26.04)
3. Generated config file validation

See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

---

## Verification

### Full hardware check (on real machine)
```bash
./tests/verify-hardware.sh          # run as normal user
sudo ./tests/verify-hardware.sh     # run as root for complete check
# or via make:
make verify
```

Checks all 10 steps: GPU · Bluetooth · WiFi · Camera · Thunderbolt ·
Battery/Thermal · applesmc · Touchpad/Keyboard · Suspend/Sleep · Dev optimizations · Audio

### Audio-only check
```bash
./tests/verify-installation.sh
```

Checks: driver `.ko` binary · module loaded · dmesg probe · ALSA playback · ALSA capture
