#!/bin/bash
# Copy the systolic array RTL from the project (the source of truth) into src/.
set -e
PROJECT=/media/nisitha/My_Passport/MOODLE/OpenRAM_Project/OpenRAM_Memory_Design
cd "$(dirname "$0")"
rm -f src/*.v
cp "$PROJECT"/rtl/accel/*.v src/
ls src | wc -l | xargs echo "RTL files:"
