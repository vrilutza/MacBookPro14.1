#!/bin/bash
# monitor_macfan_extreme.sh
# Monitor vizual extrem temperaturi + RPM ventilator MacBook

set -e

# Limite din mbpfan.conf
LOW_TEMP=40
HIGH_TEMP=50
MAX_TEMP=55

blink_on="\e[41;97m"   # roșu fundal + text alb
blink_off="\e[0m"

color_temp_extreme() {
    temp=$1
    if (( temp < LOW_TEMP )); then
        echo -e "\e[32m${temp}°C\e[0m"    # verde
    elif (( temp < HIGH_TEMP )); then
        echo -e "\e[33m${temp}°C\e[0m"    # galben
    elif (( temp < MAX_TEMP )); then
        echo -e "\e[31m${temp}°C\e[0m"    # roșu
    else
        echo -e "${blink_on}${temp}°C (CRIT)\e[0m"  # blink dacă depășește max_temp
    fi
}

color_rpm_extreme() {
    rpm=$1
    if (( rpm < 4000 )); then
        echo -e "\e[32m${rpm} RPM\e[0m"
    elif (( rpm < 5500 )); then
        echo -e "\e[33m${rpm} RPM\e[0m"
    else
        echo -e "\e[31m${rpm} RPM\e[0m"
    fi
}

while true; do
    clear
    echo "=== MACBOOK EXTREME MONITOR ==="
    
    # Citire RPM ventilator
    FAN_RPM=$(cat /sys/devices/platform/applesmc.768/fan1_input 2>/dev/null || echo 0)
    echo "Ventilator: $(color_rpm_extreme $FAN_RPM)"
    
    # Citire temperaturi
    declare -A TEMP_SENSORS
    while read -r line; do
        name=$(echo $line | awk '{print $1}')
        value=$(echo $line | awk '{print $2}' | tr -d '+°C')
        TEMP_SENSORS[$name]=$value
    done < <(sensors | grep -E 'Package id 0|Core|TC|TB|TA|TW|TH|TM|Ts')

    for sensor in "${!TEMP_SENSORS[@]}"; do
        echo "$sensor : $(color_temp_extreme ${TEMP_SENSORS[$sensor]})"
    done

    echo ""
    echo "Apasă Ctrl+C pentru a ieși..."
    sleep 1
done