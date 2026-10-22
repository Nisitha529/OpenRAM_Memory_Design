#!/bin/bash
# Bring the hardened matmul_accel into macros/matmul_accel/ (hard links: the
# GDS is ~0.5 GB) and write config.json with a floorplan sized for it.
#   import_macro.sh <accelerator run directory>
set -e
RUN=${1:?usage: import_macro.sh /data/OpenLane/designs/systolic_array/runs/<tag>}
cd "$(dirname "$0")"
M=macros/matmul_accel
rm -rf $M && mkdir -p $M
cp -rl "$RUN"/final/{gds,lef,vh,nl,lib,spef} $M/
echo "$RUN" > $M/SOURCE_RUN.txt
python3 make_config.py
