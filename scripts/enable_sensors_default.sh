#!/bin/bash
# Enable default sensors for Apple Silicon in Stats app.
# Thresholds are calibrated for M4/M5 junction temperatures, which legitimately
# run 85-105 C under load, so the historical 90 C defaults fired constantly.
# Run this after building the app to set initial sensor states.

set -e

DEFAULT_DOMAIN="eu.exelban.Stats"

# Sensors to enable by default
SENSOR_KEYS=(
    "Average CPU"
    "Hottest CPU"
    "Tp00" "Tp04" "Tp0C" "Tp0G" "Tp0O" "Tp0R" "Tp0X" "Tp0a" "Tp0p" "Tp0u" "Tp0y"
    "Tp12" "Tp16" "Tp1E"
    "Average GPU"
    "Hottest GPU"
    "Tg0U" "Tg0X" "Tg0d" "Tg0g" "Tg0j" "Tg1Y" "Tg1c" "Tg1g"
    "CPU Power"
    "GPU Power"
    "ANE Power"
    "RAM Power"
    "PCI Power"
    "Total System Consumption"
    "Average System Total"
    "PSTR"
    "PDTR"
    "PPBR"
    "ID0R"
    "VD0R"
    "F0Ac"
    "TB1T"
    "TW0P"
)

echo "Enabling default sensors..."
for key in "${SENSOR_KEYS[@]}"; do
    defaults write "$DEFAULT_DOMAIN" "sensor_${key}" -bool true
done
echo "  ${#SENSOR_KEYS[@]} sensors enabled."

# Notification thresholds. The Sensors module applies a 5 C hysteresis, so an
# alert clears only once the reading drops below threshold - 5.
echo "Setting notification thresholds..."
defaults write "$DEFAULT_DOMAIN" "sensor_Average CPU_notification" "100"
defaults write "$DEFAULT_DOMAIN" "sensor_Hottest CPU_notification" "105"
defaults write "$DEFAULT_DOMAIN" "sensor_Total System Consumption_notification" "100"
echo "  Average CPU: 100 C (clears at 95 C)"
echo "  Hottest CPU: 105 C (clears at 100 C)"
echo ""
echo "Done. Restart Stats.app to see changes."
