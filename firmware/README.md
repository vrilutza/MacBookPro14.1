# MacBook Pro 13" 2017 — Firmware extracted from macOS

This directory contains all proprietary firmware and calibration data
extracted from **macOS Ventura** running on the same MacBook Pro 13" 2017 (MacBookPro14,1).
These files are **not available in any Linux package** and must be taken from the macOS install.

---

## Directory layout

```
firmware/
├── bluetooth/                    ← Broadcom BCM4350C0 UART Bluetooth
│   ├── BCM4350C0.hcd             ← ready-to-use HCD for Linux (built by hex2hcd.py)
│   ├── hex2hcd.py                ← converter: macOS HEX → Linux HCD
│   └── source/
│       ├── BCM4350-MiniDriver-uart.hex   ← original macOS MiniDriver
│       └── BCM4350-Updater.hex           ← original macOS firmware patch
│
├── wifi/                         ← Broadcom BCM4350 WiFi
│   ├── brcmfmac4350-pcie.txt                          ← macOS NVRAM (generic fallback)
│   └── brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt ← macOS NVRAM (model-specific)
│
└── display/                      ← Built-in Retina LCD
    └── Color-LCD-MacBookPro14-1.icc  ← Apple factory color calibration (ICC profile)
```

---

## bluetooth/ — BCM4350C0 UART Bluetooth

### Hardware
| Key | Value |
|---|---|
| Chip | Broadcom BCM4350C0 |
| Transport | **UART** (ttyS4 / serial0) — not USB |
| macOS name | BCM\_4350 / BCM2E7C |
| Linux name | BCM4350C0 (die revision C0) |
| Firmware version | v134 c5628 (from macOS system\_profiler) |

### Why Linux needs this
The chip runs from internal ROM without external firmware — basic Bluetooth
(scan, pair, connect) works. **A2DP audio is choppy** without firmware because
the chip stays at a slower default baud rate.

The `linux-firmware` package does **not** ship BCM4350C0.hcd (it's an OEM
Apple file). It must be extracted from macOS.

### File origin
macOS ships the firmware as two Intel HEX files:

| File | Size | Purpose |
|---|---|---|
| `source/BCM4350-MiniDriver-uart.hex` | 20,513 bytes | Bootstrap loader (initialises UART comms) |
| `source/BCM4350-Updater.hex` | 181,600 bytes | Full firmware patch |

`hex2hcd.py` converts these to the `.hcd` format Linux expects:

```bash
# Rebuild BCM4350C0.hcd from source (Python 3, no dependencies):
python3 firmware/bluetooth/hex2hcd.py

# Verify output
xxd firmware/bluetooth/BCM4350C0.hcd | head -5
# Expected first bytes: 01 4c fc ff ...  (HCI_VS_Write_RAM opcode)
```

### Install on Ubuntu
`macbook_hardware_fixer.sh` handles this automatically (step 2). Manual install:

```bash
sudo cp firmware/bluetooth/BCM4350C0.hcd /lib/firmware/brcm/BCM4350C0.hcd
sudo ln -sf BCM4350C0.hcd /lib/firmware/brcm/BCM2E7C.hcd   # older kernel compat
sudo rmmod hci_uart && sudo modprobe hci_uart
```

Verify:
```bash
journalctl -b -k | grep "hci0.*BCM"   # should NOT show "firmware Patch file not found"
hciconfig hci0                         # should show: UP RUNNING, real BD Address
```

### ⚠️ SMC Reset required once after migrating from macOS
macOS sets the chip baud rate to 3 Mbaud. Linux uses 115200 baud → chip times out →
`hci0` never appears. An SMC Reset clears the chip to factory default. Needed **once**:

1. Shutdown completely (not restart)
2. Hold for 10 s: **Shift(L) + Ctrl(L) + Option(L) + Power**
3. Release all keys, press Power normally

---

## wifi/ — BCM4350 WiFi NVRAM

### Hardware
| Key | Value |
|---|---|
| Chip | Broadcom BCM4350 |
| Bus | PCIe |
| Vendor:Device | 14e4:4350 |
| macOS platform | "hawaii" (C-4355\_\_s-C1) |
| Board ID | 0x170, boardrev 0x1177 |

### Why Linux benefits from this
WiFi already works out-of-the-box in Linux via the `brcmfmac` driver and the
firmware binary from `linux-firmware` (`brcmfmac4350-pcie.bin`).

However, the **NVRAM** (`.txt`) file encodes board-specific RF calibration:
TX power levels, antenna parameters, channel restrictions, 2.4/5 GHz tuning.
The macOS NVRAM is calibrated for this exact board (`boardid=0x170`).

Using the macOS NVRAM can improve:
- WiFi range (correct TX power limits)
- Stability at 5 GHz (tuned channel offsets)
- Regulatory compliance (correct country band limits)

### File origin
macOS stores NVRAM files at:
```
/usr/share/firmware/wifi/C-4355__s-C1/P-hawaii_M-YSBC_V-m__m-2.5.txt
```
Platform: `C-4355__s-C1` (BCM4355 silicon, revision C1 — shares firmware with BCM4350)
Board variant: `hawaii` (MacBook Pro 2016/2017 Wi-Fi board name)
Version: `2.5` (extracted from macOS Ventura; v2.5 has updated PA calibration vs v2.3:
improved `pa2ga0`/`pa2ga1` coefficients, `boardrev=0x1250`)

### Install on Ubuntu
`macbook_hardware_fixer.sh` handles this automatically (step 3). Manual install:

```bash
sudo cp firmware/wifi/brcmfmac4350-pcie.txt \
        /lib/firmware/brcm/brcmfmac4350-pcie.txt

# Model-specific name (kernel tries this first):
sudo cp "firmware/wifi/brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt" \
        "/lib/firmware/brcm/brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt"

# Reload driver:
sudo rmmod brcmfmac && sudo modprobe brcmfmac
```

Verify:
```bash
dmesg | grep brcmfmac   # should show: "brcmfmac: brcmf_fw_alloc_request: ...nvram"
```

---

## display/ — Apple factory LCD color calibration (ICC profile)

### Hardware
| Key | Value |
|---|---|
| Display | Built-in Retina LCD, 2560×1600 |
| Panel | LG LP133QD1 (13.3", IPS) |
| Profile type | ICC v2.16 display profile (mntr RGB XYZ) |
| CMM | Apple (appl) |
| White point | D65 (0.9496, 1.0000, 1.0890 XYZ) |

### Why Linux needs this
Ubuntu uses a generic sRGB color assumption for all displays. The MacBook Pro
panel has a **wider gamut than sRGB** (red/green primaries are outside sRGB).
Without the correct ICC profile:
- Reds and greens appear oversaturated
- White point is incorrect (warmer/cooler than calibrated)
- Any color-managed application (Firefox, Darktable, GIMP) renders wrong

### Profile content
| ICC tag | Content |
|---|---|
| `rXYZ` / `gXYZ` / `bXYZ` | Factory-measured RGB primaries in XYZ |
| `rTRC` / `gTRC` / `bTRC` | 1024-point tone response curves (per channel) |
| `wtpt` | D65 white point |
| `vcgt` | Video card gamma table (identity — TRC carries the calibration) |
| `vcgp` | Apple extended gamma parameters |

### File origin
macOS stores the per-display profile at:
```
/Library/ColorSync/Profiles/Displays/Color LCD-<UUID>.icc
```
The UUID (`C016EBBE-006D-7C90-E158-A8AFDA0A2266`) is unique per unit.
The profile included here was extracted from the specific MacBook Pro this
repo was built for. It should be correct for all MacBookPro14,1 units with
the same panel (LG LP133QD1).

### Install on Ubuntu
`macbook_hardware_fixer.sh` step 11 handles this automatically. Manual install:

```bash
sudo mkdir -p /usr/share/color/icc/macbook
sudo cp firmware/display/Color-LCD-MacBookPro14-1.icc \
        /usr/share/color/icc/macbook/

mkdir -p ~/.local/share/icc
cp firmware/display/Color-LCD-MacBookPro14-1.icc \
   ~/.local/share/icc/

# Assign via colormgr (replace DEVICE_ID with output of 'colormgr get-devices'):
colormgr import-profile firmware/display/Color-LCD-MacBookPro14-1.icc
colormgr device-add-profile <DEVICE_ID> \
    $(colormgr get-profiles | grep Color-LCD | awk '/Profile ID/{print $NF}')
```

Or use **GNOME Settings → Color** and select `Color-LCD-MacBookPro14-1` from the list.

---

## Re-extracting from macOS (if you need to redo this)

From a macOS terminal on the same MacBook Pro:

```bash
# Bluetooth firmware
cp /usr/share/firmware/bluetooth/BCM4350-MiniDriver-uart.hex firmware/bluetooth/source/
cp /usr/share/firmware/bluetooth/BCM4350-Updater.hex         firmware/bluetooth/source/
python3 firmware/bluetooth/hex2hcd.py

# WiFi NVRAM
cp "/usr/share/firmware/wifi/C-4355__s-C1/P-hawaii_M-YSBC_V-m__m-2.5.txt" \
   firmware/wifi/brcmfmac4350-pcie.txt
cp firmware/wifi/brcmfmac4350-pcie.txt \
   "firmware/wifi/brcmfmac4350-pcie.Apple Inc.-MacBookPro14,1.txt"

# Display ICC (UUID in filename varies per unit)
cp /Library/ColorSync/Profiles/Displays/Color\ LCD-*.icc \
   firmware/display/Color-LCD-MacBookPro14-1.icc
```
