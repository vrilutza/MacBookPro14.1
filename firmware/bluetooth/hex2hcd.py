#!/usr/bin/env python3
"""
hex2hcd.py — Convert macOS Broadcom Bluetooth firmware (Intel HEX) to Linux .hcd

Converts the two macOS firmware files for BCM4350 UART Bluetooth into a single
.hcd file that the Linux kernel driver (hci_uart / btbcm) can load.

macOS ships Broadcom UART firmware as two Intel HEX files:
  BCM4350-MiniDriver-uart.hex   — bootstrap mini-driver (loaded into chip RAM first)
  BCM4350-Updater.hex           — full firmware patch (loaded after mini-driver)

Linux expects a single .hcd file with Broadcom HCI vendor commands:
  0xFC4C  HCI_VS_Write_RAM    — writes data to a RAM address
  0xFC4E  HCI_VS_Launch_RAM   — jumps to a RAM address

Usage:
  python3 hex2hcd.py                  # generates BCM4350C0.hcd in current dir
  python3 hex2hcd.py -o /out/path.hcd # custom output path

Output: BCM4350C0.hcd  (~86 kB)
  Install at: /lib/firmware/brcm/BCM4350C0.hcd
  Symlink:    /lib/firmware/brcm/BCM2E7C.hcd -> BCM4350C0.hcd  (older kernel compat)

Hardware:
  MacBook Pro 13" 2017 (MacBookPro14,1)
  Broadcom BCM4350C0 UART Bluetooth
    Transport:  UART (ttyS4 / serial0) — NOT USB
    macOS name: BCM_4350 / BCM2E7C
    Linux name: BCM4350C0 (die revision C0)
    FW version: v134 c5628 (as reported by macOS system_profiler)

Source files (from macOS Ventura, /usr/share/firmware/bluetooth/):
  BCM4350-MiniDriver-uart.hex   20,513 bytes
  BCM4350-Updater.hex          181,600 bytes

References:
  https://github.com/Dunedan/mbp-2016-linux
  https://www.kernel.org/doc/html/latest/bluetooth/btbcm.html
"""

import struct
import sys
import os

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
MINI_HEX    = os.path.join(SCRIPT_DIR, "source", "BCM4350-MiniDriver-uart.hex")
UPD_HEX     = os.path.join(SCRIPT_DIR, "source", "BCM4350-Updater.hex")
DEFAULT_OUT = os.path.join(SCRIPT_DIR, "BCM4350C0.hcd")

# HCI_VS_Write_RAM: 01 4C FC <len> <addr:4LE> <data...>
# Maximum HCI parameter length = 255 bytes.
# With 4-byte address prefix, max data per chunk = 251 bytes.
HCI_VS_WRITE_RAM  = b'\x01\x4c\xfc'
HCI_VS_LAUNCH_RAM = b'\x01\x4e\xfc\x04'
MAX_DATA_PER_CMD  = 251


def parse_intel_hex(filename):
    """
    Parse an Intel HEX file into a flat list of (address, bytearray) segments.

    Intel HEX record types used here:
      00 — data record
      01 — end-of-file
      04 — extended linear address (sets upper 16 bits of address)
    """
    raw = {}          # full_address -> bytearray
    upper = 0         # upper 16 bits of current address

    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line.startswith(':'):
                continue                          # skip non-record lines

            byte_count  = int(line[1:3],   16)
            address     = int(line[3:7],   16)
            record_type = int(line[7:9],   16)
            data_hex    = line[9:9 + byte_count * 2]

            if record_type == 0x00:               # data
                full_addr = (upper << 16) | address
                raw.setdefault(full_addr, bytearray()).extend(bytes.fromhex(data_hex))
            elif record_type == 0x04:             # extended linear address
                upper = int(data_hex, 16)
            elif record_type == 0x01:             # EOF
                break

    # Merge adjacent segments (sort by address, then merge contiguous blocks)
    merged = []
    for addr, data in sorted(raw.items()):
        if merged and merged[-1][0] + len(merged[-1][1]) == addr:
            merged[-1][1].extend(data)
        else:
            merged.append([addr, bytearray(data)])

    return merged


def build_hcd(minidriver_hex, updater_hex, output_hcd):
    """
    Build a Broadcom .hcd file from MiniDriver + Updater Intel HEX sources.

    Load sequence:
      1. Write MiniDriver to chip RAM (HCI_VS_Write_RAM, chunked)
      2. Execute MiniDriver            (HCI_VS_Launch_RAM at its start address)
      3. Write full firmware to RAM    (HCI_VS_Write_RAM, chunked)
      4. Execute firmware              (HCI_VS_Launch_RAM at its start address)
    """
    hcd = bytearray()

    def write_ram(address, data):
        data = bytearray(data)
        for i in range(0, len(data), MAX_DATA_PER_CMD):
            chunk   = data[i:i + MAX_DATA_PER_CMD]
            addr    = (address + i) & 0xFFFFFFFF
            payload = struct.pack('<I', addr) + chunk
            assert len(payload) <= 255, f"HCI payload overflow: {len(payload)}"
            hcd.extend(HCI_VS_WRITE_RAM)
            hcd.append(len(payload))
            hcd.extend(payload)

    def launch_ram(address):
        hcd.extend(HCI_VS_LAUNCH_RAM)
        hcd.extend(struct.pack('<I', address & 0xFFFFFFFF))

    mini_segs = parse_intel_hex(minidriver_hex)
    upd_segs  = parse_intel_hex(updater_hex)

    # MiniDriver
    for addr, data in mini_segs:
        write_ram(addr, data)
    if mini_segs:
        launch_ram(mini_segs[0][0])

    # Full firmware
    for addr, data in upd_segs:
        write_ram(addr, data)
    if upd_segs:
        launch_ram(upd_segs[0][0])

    os.makedirs(os.path.dirname(os.path.abspath(output_hcd)), exist_ok=True)
    with open(output_hcd, 'wb') as f:
        f.write(hcd)

    n_write  = hcd.count(bytes(HCI_VS_WRITE_RAM))
    n_launch = hcd.count(bytes(HCI_VS_LAUNCH_RAM))
    print(f"Written: {output_hcd}")
    print(f"  Size : {len(hcd):,} bytes")
    print(f"  Commands: {n_write} Write_RAM + {n_launch} Launch_RAM")
    print(f"  MiniDriver : 0x{mini_segs[0][0]:08X}  ({sum(len(d) for _,d in mini_segs):,} bytes)")
    print(f"  Firmware   : 0x{upd_segs[0][0]:08X}  ({sum(len(d) for _,d in upd_segs):,} bytes)")
    print()
    print(f"Install on Ubuntu:")
    print(f"  sudo cp {output_hcd} /lib/firmware/brcm/BCM4350C0.hcd")
    print(f"  sudo ln -sf BCM4350C0.hcd /lib/firmware/brcm/BCM2E7C.hcd")
    print(f"  sudo rmmod hci_uart && sudo modprobe hci_uart")


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('-m', '--minidriver', default=MINI_HEX,
                        help=f'MiniDriver HEX path (default: {MINI_HEX})')
    parser.add_argument('-u', '--updater', default=UPD_HEX,
                        help=f'Updater HEX path (default: {UPD_HEX})')
    parser.add_argument('-o', '--output', default=DEFAULT_OUT,
                        help=f'Output .hcd path (default: {DEFAULT_OUT})')
    args = parser.parse_args()

    for path in (args.minidriver, args.updater):
        if not os.path.isfile(path):
            sys.exit(f"Error: source file not found: {path}\n"
                     f"Copy from macOS: /usr/share/firmware/bluetooth/")

    build_hcd(args.minidriver, args.updater, args.output)


if __name__ == '__main__':
    main()
