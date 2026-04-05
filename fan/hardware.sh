#!/bin/bash

OUTPUT_FILE="/tmp/hardware_info.txt"
echo "=== HARDWARE INFO MACBOOK PRO 2017 ===" > $OUTPUT_FILE
echo "" >> $OUTPUT_FILE

echo "=== lspci ===" >> $OUTPUT_FILE
lspci -nnk >> $OUTPUT_FILE 2>&1
echo "" >> $OUTPUT_FILE

echo "=== lsusb ===" >> $OUTPUT_FILE
lsusb >> $OUTPUT_FILE 2>&1
echo "" >> $OUTPUT_FILE

echo "=== lshw (requires sudo) ===" >> $OUTPUT_FILE
sudo lshw -short >> $OUTPUT_FILE 2>&1
echo "" >> $OUTPUT_FILE

echo "=== lsmod ===" >> $OUTPUT_FILE
lsmod >> $OUTPUT_FILE 2>&1
echo "" >> $OUTPUT_FILE

echo "=== uname -a ===" >> $OUTPUT_FILE
uname -a >> $OUTPUT_FILE 2>&1
echo "" >> $OUTPUT_FILE

echo "=== /proc/cpuinfo ===" >> $OUTPUT_FILE
cat /proc/cpuinfo >> $OUTPUT_FILE 2>&1
echo "" >> $OUTPUT_FILE

echo "=== /proc/meminfo ===" >> $OUTPUT_FILE
cat /proc/meminfo >> $OUTPUT_FILE 2>&1
echo "" >> $OUTPUT_FILE

echo "=== dmidecode (requires sudo) ===" >> $OUTPUT_FILE
sudo dmidecode >> $OUTPUT_FILE 2>&1
echo "" >> $OUTPUT_FILE

echo "Hardware info exported to $OUTPUT_FILE"
