#!/usr/bin/env bash
# Module 13 Demo 2 — DR strategy decision helper.
read -rp "Acceptable RPO (data loss): hours/minutes/seconds? " RPO
read -rp "Acceptable RTO (downtime):  hours/minutes/seconds? " RTO

if [[ "$RPO" == "hours" && "$RTO" == "hours" ]]; then
  echo "-> Backup & Restore (cheapest)"
elif [[ "$RPO" == "minutes" && "$RTO" == "hours" ]]; then
  echo "-> Pilot Light"
elif [[ "$RPO" == "minutes" && "$RTO" == "minutes" ]]; then
  echo "-> Warm Standby"
elif [[ "$RPO" == "seconds" && "$RTO" == "seconds" ]]; then
  echo "-> Multi-Site Active/Active"
else
  echo "-> Hybrid: closest match is Warm Standby; revisit cost trade-offs."
fi
