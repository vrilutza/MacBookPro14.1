#!/bin/bash
# =============================================================================
# test-docker.sh — Build and run macbook_hardware_fixer.sh in Docker
#
# Tests: package availability, config file writing, script logic
# Mocked: systemd, hardware paths, GNOME, kernel modules
#
# Requirements: docker (install with: sudo apt-get install docker.io)
# Usage:
#   bash tests/test-docker.sh           # full test
#   bash tests/test-docker.sh --syntax  # syntax check only (no Docker needed)
#   bash tests/test-docker.sh --clean   # remove Docker image after test
# =============================================================================

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

IMAGE="macbook-hw-fixer-test"
DOCKERFILE="Dockerfile.test"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

pass() { echo -e "  ${GREEN}[✔]${NC} $1"; }
fail() { echo -e "  ${RED}[✘]${NC} $1"; FAIL=1; }
info() { echo -e "  ${BLUE}[i]${NC} $1"; }
FAIL=0

cd "$SCRIPT_DIR"

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  MacBook Pro Hardware Fixer — Test Suite${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Bash syntax check (no tools needed)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}>>> Syntax checks${NC}"

for script in macbook_hardware_fixer.sh bluetooth/bluetooth.sh fan/fan_setup.sh \
              tests/verify-hardware.sh tests/verify-installation.sh; do
    if [ -f "$script" ]; then
        if bash -n "$script" 2>/dev/null; then
            pass "$script — syntax OK"
        else
            fail "$script — SYNTAX ERROR:"
            bash -n "$script" 2>&1 | sed 's/^/    /'
        fi
    fi
done

if [[ "${1:-}" == "--syntax" ]]; then
    echo ""
    if [ $FAIL -eq 0 ]; then
        echo -e "${GREEN}${BOLD}All syntax checks passed.${NC}"
    else
        echo -e "${RED}${BOLD}Syntax errors found — fix before running.${NC}"
        exit 1
    fi
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Docker availability
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}>>> Docker test${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${YELLOW}[!]${NC} Docker not installed. Install with:"
    echo "    sudo apt-get install docker.io"
    echo "    sudo usermod -aG docker \$USER   # then log out and back in"
    echo ""
    echo -e "${YELLOW}[!]${NC} Alternatively, test with Multipass (full Ubuntu VM with systemd):"
    echo "    sudo snap install multipass"
    echo "    multipass launch 26.04 --name macbook-test --cpus 2 --memory 4G --disk 20G"
    echo "    multipass mount . macbook-test:/project"
    echo "    multipass exec macbook-test -- sudo bash /project/macbook_hardware_fixer.sh"
    echo ""
    info "Syntax checks passed — Docker not available for package/logic tests."
    exit 0
fi

if ! docker info &>/dev/null; then
    echo -e "${RED}[✘]${NC} Docker daemon not running or current user not in docker group."
    echo "    Try: sudo systemctl start docker"
    echo "    Or:  sudo docker build ... (with sudo)"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Build Docker image
# ─────────────────────────────────────────────────────────────────────────────
echo ""
info "Building Docker image (Ubuntu 26.04)..."
BUILD_START=$(date +%s)

if docker build -f "$DOCKERFILE" -t "$IMAGE" . 2>&1 | tee /tmp/docker-build.log | grep -E "^(Step|RUN|ERROR|error)" | sed 's/^/  /'; then
    BUILD_END=$(date +%s)
    pass "Docker image built in $((BUILD_END - BUILD_START))s"
else
    fail "Docker build failed — see /tmp/docker-build.log"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Run the script in Docker
# ─────────────────────────────────────────────────────────────────────────────
echo ""
info "Running macbook_hardware_fixer.sh in container..."
echo ""

RUN_LOG="/tmp/macbook-docker-test.log"
RUN_START=$(date +%s)

if docker run --rm "$IMAGE" 2>&1 | tee "$RUN_LOG"; then
    RUN_EXIT=${PIPESTATUS[0]}
else
    RUN_EXIT=$?
fi

RUN_END=$(date +%s)
echo ""
echo -e "${BOLD}${BLUE}>>> Test analysis${NC}"

# Count real failures vs expected mock messages
REAL_ERRORS=$(grep -c "^\s*\[✘\]" "$RUN_LOG" 2>/dev/null || echo 0)
REAL_WARNS=$(grep -c "^\s*\[!\]" "$RUN_LOG" 2>/dev/null || echo 0)
REAL_OKS=$(grep -c "^\s*\[✔\]" "$RUN_LOG" 2>/dev/null || echo 0)
MOCK_CALLS=$(grep -c "\[MOCK\]" "$RUN_LOG" 2>/dev/null || echo 0)

info "Run time: $((RUN_END - RUN_START))s"
info "Script exit code: $RUN_EXIT"
echo -e "  ${GREEN}[✔]${NC} Passed:  $REAL_OKS"
echo -e "  ${YELLOW}[!]${NC} Warnings: $REAL_WARNS"
echo -e "  ${RED}[✘]${NC} Errors:  $REAL_ERRORS"
info "Mocked hardware calls: $MOCK_CALLS"

# Show only real errors (not hardware-not-found warnings which are expected)
UNEXPECTED=$(grep -E "^\s*\[✘\]" "$RUN_LOG" | grep -v "MOCK\|not found\|not available\|failed.*not\|NVMe PCI" || true)
if [ -n "$UNEXPECTED" ]; then
    echo ""
    echo -e "${RED}${BOLD}Unexpected failures:${NC}"
    echo "$UNEXPECTED" | sed 's/^/  /'
    fail "Script had unexpected failures in container"
fi

echo ""
echo "Full log saved to: $RUN_LOG"

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${*}" == *"--clean"* ]]; then
    docker rmi "$IMAGE" &>/dev/null || true
    info "Docker image removed."
fi

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
if [ $FAIL -eq 0 ] && [ "$RUN_EXIT" -eq 0 ]; then
    echo -e "${BOLD}${GREEN}  All tests passed.${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Next: test on a full Ubuntu VM for systemd service validation:"
    echo "    sudo snap install multipass"
    echo "    multipass launch 26.04 --name macbook-test"
    echo "    multipass mount . macbook-test:/project"
    echo "    multipass exec macbook-test -- sudo bash /project/macbook_hardware_fixer.sh"
else
    echo -e "${BOLD}${RED}  Test FAILED — fix errors above before running on hardware.${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
    exit 1
fi
