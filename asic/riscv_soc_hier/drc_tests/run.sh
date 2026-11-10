#!/bin/bash
# Check klayout_drc_stripes.py against one pass of the PDK deck on test layouts
# with known errors; both must report the same markers. Also runs the RISC-V
# core (known clean) in 100 um stripes: must give 0 (no clip artefacts kept).
#   ./run.sh            (from this directory; uses the OpenLane docker image)
set -e
cd "$(dirname "$(readlink -f "$0")")"
HERE=$PWD
DECK=/data/OpenLane/pdks/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A/libs.tech/klayout/drc/sky130A_mr.drc
CORE=/data/OpenLane/designs/riscv_core/runs/run6_grtrepair/final/gds/riscv_module.gds
KL="docker run --rm -u $(id -u):$(id -g) -v /data/OpenLane:/data/OpenLane -w $HERE/out ghcr.io/efabless/openlane2:2.3.10 klayout -b -zz"
OPTS="-rd feol=true -rd beol=true -rd floating_metal=false -rd offgrid=true -rd seal=true -rd threads=4"
mkdir -p out
for t in edges hierarchy; do
  $KL -r $HERE/${t}_layout.py
  $KL -r $DECK -rd input=$HERE/out/$t.gds -rd report=$HERE/out/${t}_onepass.xml $OPTS > out/${t}_onepass.log 2>&1
  $KL -r $HERE/../klayout_drc_stripes.py -rd input=$HERE/out/$t.gds -rd report=$HERE/out/${t}_stripes.xml \
      $OPTS -rd stripe_height=1000 > out/${t}_stripes.log 2>&1
  echo -n "$t: "; $KL -r $HERE/compare.py -rd ref=$HERE/out/${t}_onepass.xml -rd test=$HERE/out/${t}_stripes.xml
done
if [ -f $CORE ]; then
  $KL -r $HERE/../klayout_drc_stripes.py -rd input=$CORE -rd report=$HERE/out/core_stripes.xml \
      $OPTS -rd stripe_height=100 > out/core_stripes.log 2>&1
  echo "core (clean design, 100 um stripes): $(grep 'markers kept' out/core_stripes.log | sed 's/.*xml: //')"
fi
