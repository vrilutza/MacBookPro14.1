#!/bin/bash
# =============================================================================
# bluetooth.sh — Fix Bluetooth pe MacBook Pro 14,1 (2017) cu Ubuntu 26.04
# Chip: BCM4350C0 UART (se identifică și ca BCM4350C5 în lspci)
# Autor: generat pe baza troubleshooting real, aprilie 2026
# =============================================================================
# UTILIZARE:
#   sudo bash bluetooth.sh
#
# CÂND se rulează:
#   - După o instalare curată de Ubuntu pe MacBook Pro 14,1 migrat de pe macOS
#   - Dacă Bluetooth nu merge după instalare
#   - Dacă cineva a stricat configurația urmând sfaturi greșite de pe internet
#
# DUPĂ rularea scriptului:
#   - Fă SMC Reset: Shift(stânga) + Ctrl(stânga) + Option(stânga) + Power (10 secunde)
#   - Apoi pornește normal — Bluetooth ar trebui să meargă
# =============================================================================

# --- Culori pentru output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Funcții de logging ---
log_ok()   { echo -e "${GREEN}[OK]${NC}    $1"; }
log_fix()  { echo -e "${YELLOW}[FIX]${NC}   $1"; }
log_skip() { echo -e "${BLUE}[SKIP]${NC}  $1"; }
log_warn() { echo -e "${RED}[WARN]${NC}  $1"; }
log_info() { echo -e "${BOLD}[INFO]${NC}  $1"; }
separator() { echo -e "${BOLD}────────────────────────────────────────────────────${NC}"; }

# =============================================================================
separator
echo -e "${BOLD}  Bluetooth Fix — MacBook Pro 14,1 — Ubuntu 26.04${NC}"
separator
echo ""

# --- Verifică root ---
if [ "$EUID" -ne 0 ]; then
    log_warn "Scriptul trebuie rulat cu sudo!"
    echo "    Rulează: sudo bash bluetooth.sh"
    exit 1
fi

# =============================================================================
# PASUL 1 — Elimină blacklist-ul greșit pe hci_uart
# De ce: sfaturi greșite de pe internet recomandă blacklistarea hci_uart
#         dar hci_uart este DRIVERUL CORECT pentru BCM4350C0 UART pe Mac
# =============================================================================
separator
log_info "PASUL 1 — Verifică blacklist module Bluetooth"
separator

BLACKLIST_FILES=$(grep -rl "hci_uart\|btusb" /etc/modprobe.d/ 2>/dev/null)

if [ -n "$BLACKLIST_FILES" ]; then
    for f in $BLACKLIST_FILES; do
        log_fix "Găsit blacklist greșit: $f"
        log_fix "Conținut: $(cat $f)"
        # Elimină doar liniile cu hci_uart sau btusb, nu întregul fișier
        # dacă fișierul conține și altceva util
        sed -i '/blacklist hci_uart/d' "$f"
        sed -i '/blacklist btusb/d' "$f"
        # Dacă fișierul a rămas gol, șterge-l
        if [ ! -s "$f" ]; then
            rm -f "$f"
            log_ok "Fișier blacklist eliminat: $f"
        else
            log_ok "Linii greșite eliminate din: $f"
        fi
    done
else
    log_ok "Niciun blacklist greșit găsit"
fi

echo ""

# =============================================================================
# PASUL 2 — Elimină firmware incompatibil
# De ce: firmware-ul USB (BCM4350C5-0a5c-*.hcd) e pentru alt chip
#         aplicat pe chipul UART BCM4350C0 îl strică și necesită SMC Reset
#         Chipul funcționează din ROM intern — nu are nevoie de firmware extern
# =============================================================================
separator
log_info "PASUL 2 — Verifică firmware Bluetooth incorect"
separator

FIRMWARE_DIR="/lib/firmware/brcm"
WRONG_LINKS=("BCM.hcd" "BCM2E7C.hcd" "BCM4350C5.hcd" "BCM4350C0.hcd")

for fname in "${WRONG_LINKS[@]}"; do
    fpath="$FIRMWARE_DIR/$fname"
    if [ -L "$fpath" ]; then
        target=$(readlink "$fpath")
        # Dacă symlink-ul pointează spre un fișier USB (cu -0a5c- în nume), elimină-l
        if echo "$target" | grep -q "0a5c\|0a5c"; then
            log_fix "Elimină symlink firmware incompatibil: $fname → $target"
            rm -f "$fpath"
        else
            log_skip "Symlink $fname păstrat (nu pare a fi USB firmware)"
        fi
    elif [ -f "$fpath" ]; then
        # Verifică dacă e un fișier USB firmware copiat direct
        log_warn "Fișier firmware găsit la $fpath — verifică manual dacă e corect"
    fi
done

# Verifică dacă există fișiere BCM.hcd sau BCM4350C0.hcd neașteptate
if [ -f "$FIRMWARE_DIR/BCM.hcd" ] && [ ! -L "$FIRMWARE_DIR/BCM.hcd" ]; then
    log_warn "Fișier BCM.hcd găsit (nu symlink) — îl las, poate e firmware corect"
fi

log_ok "Verificare firmware completă"
echo ""

# =============================================================================
# PASUL 3 — Corectează /etc/bluetooth/main.conf
# De ce: AutoEnable trebuie să fie în secțiunea [Policy], nu [General]
#         BlueZ 5.x ignoră AutoEnable din [General] și loghează eroare
# =============================================================================
separator
log_info "PASUL 3 — Corectează /etc/bluetooth/main.conf"
separator

MAIN_CONF="/etc/bluetooth/main.conf"

if [ ! -f "$MAIN_CONF" ]; then
    log_warn "$MAIN_CONF nu există — îl creez minimal"
    cat > "$MAIN_CONF" << 'EOF'
[Policy]
AutoEnable=true
ReconnectAttempts=7
ReconnectIntervals=1,2,4,8,16,32,64
EOF
    log_ok "main.conf creat"
else
    # Verifică dacă [Policy] există
    if ! grep -q "^\[Policy\]" "$MAIN_CONF"; then
        log_fix "Secțiunea [Policy] lipsește — o adaugă"
        echo "" >> "$MAIN_CONF"
        echo "[Policy]" >> "$MAIN_CONF"
        echo "AutoEnable=true" >> "$MAIN_CONF"
        echo "ReconnectAttempts=7" >> "$MAIN_CONF"
        echo "ReconnectIntervals=1,2,4,8,16,32,64" >> "$MAIN_CONF"
        log_ok "Secțiunea [Policy] adăugată"
    else
        # [Policy] există — verifică AutoEnable în ea
        # Decomentează AutoEnable dacă e comentat sub [Policy]
        python3 - << 'PYEOF'
import re

with open('/etc/bluetooth/main.conf', 'r') as f:
    content = f.read()

# Decomentează #AutoEnable=true în secțiunea [Policy]
# Pattern: în blocul [Policy], găsește #AutoEnable=true și decomentează
in_policy = False
lines = content.split('\n')
new_lines = []
autoenable_found_in_policy = False

for line in lines:
    if line.strip() == '[Policy]':
        in_policy = True
    elif line.strip().startswith('[') and line.strip() != '[Policy]':
        in_policy = False

    if in_policy and re.match(r'\s*#\s*AutoEnable\s*=\s*true', line):
        new_lines.append('AutoEnable=true')
        autoenable_found_in_policy = True
    elif in_policy and re.match(r'\s*AutoEnable\s*=\s*true', line):
        autoenable_found_in_policy = True
        new_lines.append(line)
    else:
        new_lines.append(line)

# Dacă AutoEnable nu există în [Policy], adaugă-l
if not autoenable_found_in_policy:
    final_lines = []
    for line in new_lines:
        final_lines.append(line)
        if line.strip() == '[Policy]':
            final_lines.append('AutoEnable=true')
    new_lines = final_lines

with open('/etc/bluetooth/main.conf', 'w') as f:
    f.write('\n'.join(new_lines))

print("OK")
PYEOF
        log_ok "AutoEnable=true verificat/setat în secțiunea [Policy]"
    fi

    # Verifică că AutoEnable nu e greșit în [General] (fără să fie comentat)
    if grep -A 20 "^\[General\]" "$MAIN_CONF" | grep -q "^AutoEnable=true"; then
        log_fix "AutoEnable găsit activ în [General] — îl comentează"
        sed -i '/^\[General\]/,/^\[/{s/^AutoEnable=true/#AutoEnable=true/}' "$MAIN_CONF"
        log_ok "AutoEnable dezactivat din [General]"
    fi
fi

echo ""

# =============================================================================
# PASUL 4 — Activează și pornește serviciul Bluetooth
# De ce: poate a fost dezactivat accidental cu systemctl disable bluetooth
# =============================================================================
separator
log_info "PASUL 4 — Serviciu Bluetooth"
separator

if systemctl is-enabled bluetooth &>/dev/null; then
    log_ok "Serviciul bluetooth este deja activat (enabled)"
else
    log_fix "Serviciul bluetooth e dezactivat — îl activez"
    systemctl enable bluetooth
    log_ok "bluetooth.service activat"
fi

if systemctl is-active bluetooth &>/dev/null; then
    log_ok "Serviciul bluetooth rulează deja"
else
    log_fix "Pornesc serviciul bluetooth"
    systemctl start bluetooth
    sleep 1
    if systemctl is-active bluetooth &>/dev/null; then
        log_ok "bluetooth.service pornit cu succes"
    else
        log_warn "Serviciul nu a pornit — verifică: systemctl status bluetooth"
    fi
fi

echo ""

# =============================================================================
# PASUL 5 — Actualizează initramfs
# De ce: modificările la /etc/modprobe.d/ și firmware trebuie incluse
# =============================================================================
separator
log_info "PASUL 5 — Actualizează initramfs"
separator

log_fix "Rulează update-initramfs -u ..."
update-initramfs -u 2>&1 | tail -1
log_ok "initramfs actualizat"

echo ""

# =============================================================================
# PASUL 6 — Verificare finală
# =============================================================================
separator
log_info "PASUL 6 — Verificare stare finală"
separator

echo ""
log_info "Blacklist hci_uart:"
if grep -r "blacklist hci_uart" /etc/modprobe.d/ 2>/dev/null | grep -v "^#"; then
    log_warn "hci_uart încă e blacklistat undeva!"
else
    log_ok "hci_uart nu este blacklistat"
fi

echo ""
log_info "AutoEnable în main.conf:"
if grep -A 30 "^\[Policy\]" "$MAIN_CONF" | grep -q "^AutoEnable=true"; then
    log_ok "AutoEnable=true prezent în [Policy]"
else
    log_warn "AutoEnable nu e setat corect în [Policy]!"
fi

echo ""
log_info "Serviciu bluetooth:"
systemctl is-enabled bluetooth 2>/dev/null | xargs -I{} echo "  enabled: {}"
systemctl is-active bluetooth 2>/dev/null | xargs -I{} echo "  active:  {}"

echo ""
log_info "Stare adaptor Bluetooth (dacă hci0 există):"
if hciconfig hci0 &>/dev/null 2>&1; then
    hciconfig hci0 | head -4 | sed 's/^/  /'
else
    log_warn "hci0 nu există încă — normal înainte de SMC Reset la prima rulare"
fi

# =============================================================================
# MESAJ FINAL — ACȚIUNE NECESARĂ
# =============================================================================
echo ""
separator
echo -e "${BOLD}${GREEN}  Script terminat cu succes!${NC}"
separator
echo ""
echo -e "${BOLD}  !! ACȚIUNE NECESARĂ DUPĂ ACEST SCRIPT !!${NC}"
echo ""
echo -e "  Fă ${BOLD}SMC Reset${NC} pentru a reseta chipul Bluetooth la baud rate-ul corect:"
echo ""
echo -e "  1. ${BOLD}Oprește laptopul complet${NC}"
echo -e "  2. Ține apăsat simultan ${BOLD}10 secunde${NC}:"
echo -e "     ${YELLOW}Shift(stânga) + Ctrl(stânga) + Option(stânga) + butonul Power${NC}"
echo -e "  3. Eliberează toate tastele"
echo -e "  4. Apasă ${BOLD}Power${NC} normal pentru a porni"
echo ""
echo -e "  După pornire, verifică cu:"
echo -e "  ${BOLD}hciconfig -a${NC}  →  trebuie să vezi ${GREEN}UP RUNNING${NC}"
echo ""
echo -e "  ${BOLD}DE CE e necesar SMC Reset:${NC}"
echo -e "  Chipul BCM4350C0 reține baud rate-ul setat de macOS (3 Mbaud)."
echo -e "  Linux comunică la 115.200 baud → timeout. SMC Reset resetează chipul."
echo -e "  Este necesar O SINGURĂ DATĂ după migrarea de pe macOS."
echo ""
separator
echo ""
echo -e "  ${BOLD}IMPORTANT — Ce NU trebuie să faci niciodată pe acest Mac:${NC}"
echo ""
echo -e "  ${RED}✗${NC} blacklist hci_uart   — hci_uart este driverul CORECT"
echo -e "  ${RED}✗${NC} modprobe btusb       — chipul e UART, nu USB"
echo -e "  ${RED}✗${NC} firmware BCM4350C5-0a5c-*.hcd — e pentru USB, strică chipul UART"
echo -e "  ${RED}✗${NC} systemctl disable bluetooth"
echo ""
separator
