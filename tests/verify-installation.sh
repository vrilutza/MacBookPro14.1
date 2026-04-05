#!/bin/bash

# =================================================================
# snd_hda_macbookpro Installation Verifier
# Checks that the Cirrus Logic CS8409 audio driver is properly
# installed and active on the running system.
# =================================================================

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

if [[ "${1}" == "-h" || "${1}" == "--help" ]]; then
    cat << EOF
Usage: $0

Verifies that the snd_hda_macbookpro Cirrus Logic CS8409 driver is correctly
installed and active on this Ubuntu system.

Checks performed:
  [0/4] Driver binary (.ko) exists in the kernel module tree
  [1/4] Module is loaded in the running kernel
  [2/4] Hardware probe logged in dmesg
  [3/4] ALSA playback (output) device is visible
  [4/4] ALSA capture (input) device is visible

Exit codes:
  0 — all checks passed
  1 — one or more checks failed or issued warnings

No options required. Run as a normal user (no root needed).
EOF
    exit 0
fi

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}-> SUCCESS:${NC} $1"; ((PASS++)); }
warn() { echo -e "  ${YELLOW}-> WARNING:${NC} $1"; ((FAIL++)); }
info() { echo -e "  ${BLUE}-> NOTE:${NC}    $1"; }

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}    snd_hda_macbookpro Installation Verifier    ${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# ------------------------------------------------------------
# [0/4] Check if the compiled .ko file exists on disk
# (supports plain .ko, compressed .ko.zst and .ko.gz variants)
# ------------------------------------------------------------
echo "[0/4] Checking if the driver binary (.ko) exists in the kernel module tree..."
KO_FOUND=false
for ko_path in \
    "/lib/modules/$(uname -r)/updates/codecs/cirrus/snd-hda-codec-cs8409.ko" \
    "/lib/modules/$(uname -r)/updates/codecs/cirrus/snd-hda-codec-cs8409.ko.zst" \
    "/lib/modules/$(uname -r)/updates/codecs/cirrus/snd-hda-codec-cs8409.ko.gz" \
    "/lib/modules/$(uname -r)/updates/snd-hda-codec-cs8409.ko" \
    "/lib/modules/$(uname -r)/updates/dkms/snd-hda-codec-cs8409.ko" \
    "/lib/modules/$(uname -r)/updates/dkms/snd-hda-codec-cs8409.ko.zst" \
    "/lib/modules/$(uname -r)/updates/dkms/snd-hda-codec-cs8409.ko.gz"; do
    if [ -f "$ko_path" ]; then
        pass "Compiled driver found at: $ko_path"
        KO_FOUND=true
        break
    fi
done
if [ "$KO_FOUND" = false ]; then
    warn "Could not find 'snd-hda-codec-cs8409.ko' (or .ko.zst/.ko.gz) in the updates folder."
    info "Did you run 'sudo ./install.cirrus.driver.sh' from the project root?"
fi

echo ""

# ------------------------------------------------------------
# [1/4] Check if the module is currently loaded in the kernel
# ------------------------------------------------------------
echo "[1/4] Verifying if module 'snd_hda_codec_cs8409' is loaded in the running kernel..."
if lsmod | grep -q "snd_hda_codec_cs8409"; then
    pass "Module is active and loaded."
else
    warn "Module is NOT currently loaded."
    info "If you just installed it, reboot or try: sudo modprobe snd-hda-codec-cs8409"
fi

echo ""

# ------------------------------------------------------------
# [2/4] Check dmesg for hardware probe logs
# ------------------------------------------------------------
echo "[2/4] Checking dmesg for Cirrus Logic CS8409 hardware initialization logs..."
dmesg_output=$(dmesg 2>&1)
if echo "$dmesg_output" | grep -qi "operation not permitted\|read kernel buffer failed"; then
    info "dmesg is restricted to root on this system."
    info "Re-run as root to check hardware probe logs: sudo $0"
elif echo "$dmesg_output" | grep -qi "cs8409"; then
    pass "Found 'cs8409' hardware diagnostic logs in dmesg."
    echo    "  ------------- Last 3 log entries: ---------------------"
    echo "$dmesg_output" | grep -i "cs8409" | tail -n 3 | sed 's/^/    /'
    echo    "  -------------------------------------------------------"
else
    warn "No CS8409 hardware logs found in dmesg."
    info "The driver might not have probed the hardware. Check that you are on a supported Mac model."
fi

echo ""

# ------------------------------------------------------------
# [3/4] Check ALSA playback (output) device
# ------------------------------------------------------------
echo "[3/4] Checking ALSA for CS8409 audio playback device..."
if aplay -l 2>/dev/null | grep -qi -E "cs8409|cirrus"; then
    pass "ALSA specifically recognized a Cirrus / CS8409 playback device!"
    aplay -l 2>/dev/null | grep -i -E "cs8409|cirrus" | sed 's/^/    /'
else
    info "Playback may be wrapped inside a generic 'HDA Intel PCH' card."
    info "Check Settings -> Sound and look for 'Analogue Stereo Output' or 'Headphones'."
fi

echo ""

# ------------------------------------------------------------
# [4/4] Check ALSA capture (input/recording) device
# ------------------------------------------------------------
echo "[4/4] Checking ALSA for CS8409 audio capture device..."
if arecord -l 2>/dev/null | grep -qi -E "cs8409|cirrus"; then
    pass "ALSA recognized a Cirrus / CS8409 capture (input) device!"
    arecord -l 2>/dev/null | grep -i -E "cs8409|cirrus" | sed 's/^/    /'
else
    info "No dedicated CS8409 capture entry found."
    info "Recording may be routed through a generic 'HDA Intel PCH' capture path."
    info "Check Settings -> Sound -> Input for available microphone options."
fi

echo ""
echo -e "${BLUE}==================================================${NC}"
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All checks passed! ($PASS passed, $FAIL warnings)${NC}"
    echo -e "${BLUE}==================================================${NC}"
    exit 0
else
    echo -e "${YELLOW}Completed with warnings ($PASS passed, $FAIL warnings)${NC}"
    echo -e "${BLUE}==================================================${NC}"
    exit 1
fi
