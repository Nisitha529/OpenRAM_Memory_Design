#!/bin/bash
# Copy the core RTL from the project (the source of truth) into src/.
# The project lives on an NTFS drive, so the ASIC run is kept here on ext4.
set -e
PROJECT=/media/nisitha/My_Passport/MOODLE/OpenRAM_Project/OpenRAM_Memory_Design
cd "$(dirname "$0")"
rm -f src/*.v
for f in "$PROJECT"/rtl/core/*.v; do
  case "$(basename "$f")" in
    imem.v|dmem.v|top_module.v) ;;          # behavioural memories / old top: not part of the core
    *) cp "$f" src/ ;;
  esac
done
ls src | wc -l | xargs echo "RTL files:"
