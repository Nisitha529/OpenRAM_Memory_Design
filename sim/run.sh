#!/bin/bash
# Simulation runner.
#   sim/run.sh l1d              unit test: random traffic into L1D + DRAM
#   sim/run.sh ideal  <prog>    core with perfect memories
#   sim/run.sh cached <prog>    core + L1I + L1D + L2 + DRAM
#   sim/run.sh all              every program in both modes + register compare
# <prog> is a test name from sw/ (test_core, test_mem).
set -e
cd "$(dirname "$0")"
ROOT=..
BUILD=build
mkdir -p $BUILD

CORE=$(ls $ROOT/rtl/core/*.v | grep -vE '/(imem|dmem|top_module)\.v$')
SRAMS="$ROOT/cache/sram"
L1I="$ROOT/cache/output/l1i/l1i.v $SRAMS/l1i_tag_array/l1i_tag_array.v"
L1D="$ROOT/cache/output/l1d/l1d.v $SRAMS/l1d_tag_array/l1d_tag_array.v"
L1DATA="$SRAMS/sram_128x32_1r1w/sram_128x32_1r1w.v"
L2="$ROOT/cache/output/l2/l2.v $SRAMS/l2_tag_array/l2_tag_array.v $SRAMS/l2_data_array/l2_data_array.v"   # l2_use_array is flip-flops, in rtl/mem/

# The OpenRAM behavioral models print every access; hide those lines
quiet() { grep -vE ' (Reading|Writing) |Not enough words' || true; }

build_prog() { make -s -C $ROOT/sw "$1.hex" >/dev/null; }

run_l1d() {
  iverilog -g2005 -o $BUILD/tb_l1d.vvp tb_l1d.v models/dram.v $L1D $L1DATA
  (cd $BUILD && vvp -n tb_l1d.vvp) | quiet
}

run_prog() {  # mode prog
  mode=$1; prog=$2
  build_prog $prog
  if [ $mode = ideal ]; then
    iverilog -g2005 -DIDEAL -o $BUILD/tb_ideal.vvp tb_soc.v $CORE
  else
    iverilog -g2005 -o $BUILD/tb_cached.vvp tb_soc.v models/dram.v $ROOT/rtl/soc/*.v $ROOT/rtl/mem/*.v $CORE $L1I $L1D $L1DATA $L2
  fi
  (cd $BUILD && vvp -n tb_$mode.vvp +prog=../$ROOT/sw/$prog.hex +regs=${prog}_$mode.regs) | quiet
}

case "$1" in
  l1d)    run_l1d ;;
  ideal)  run_prog ideal  "${2:-test_core}" ;;
  cached) run_prog cached "${2:-test_core}" ;;
  all)
    run_l1d
    for p in test_core test_mem; do
      run_prog ideal  $p
      run_prog cached $p
      if diff -q $BUILD/${p}_ideal.regs $BUILD/${p}_cached.regs >/dev/null; then
        echo "REGS    : $p final registers identical in ideal and cached runs"
      else
        echo "REGS    : $p final registers DIFFER:"; diff $BUILD/${p}_ideal.regs $BUILD/${p}_cached.regs
      fi
    done ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
