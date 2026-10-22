#!/bin/sh
# Writes src/lib/zone/zones.txt: every zone of the system's zone.tab with its current rule
# (the TZif file's last line), and UTC. Run again when tzdata changes the rules.
dir=${1:-/usr/share/zoneinfo}
{
  echo "UTC UTC0"
  for zone in $(awk '!/^#/ { print $3 }' "$dir/zone.tab" | sort); do
    echo "$zone $(tail -n 1 "$dir/$zone")"
  done
} > "$(dirname "$0")/../src/lib/zone/zones.txt"
