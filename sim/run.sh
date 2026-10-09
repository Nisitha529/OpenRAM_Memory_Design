#!/bin/bash
# Simulation runner.
#   sim/run.sh l1d              unit test: random traffic into L1D + DRAM
#   sim/run.sh systolic [N]     unit test: N x N systolic array (default 16)
#   sim/run.sh accel [N]        unit test: matmul accelerator with an N x N array (default 8)
#   sim/run.sh ideal  <prog>    core with perfect memories
#   sim/run.sh cached <prog>    core + L1I + L1D + L2 + DRAM
#   sim/run.sh all              every program in both modes + register compare
#   sim/run.sh gl-ideal  <prog> gate-level core netlist (from OpenLane), perfect memories
#   sim/run.sh gl-cached <prog> gate-level core netlist inside the cache hierarchy
#   sim/run.sh gl-all           both programs in both gate-level modes
#     NETLIST=<file.nl.v> picks the netlist (default: newest OpenLane run)
#   SRAM_TECH=scn4m_subm|sky130|ff selects the cache memories (see below)
# <prog> is a test name from sw/ (test_core, test_mem).
set -e
cd "$(dirname "$0")"
ROOT=..
BUILD=build
mkdir -p $BUILD

CORE=$(ls $ROOT/rtl/core/*.v | grep -vE '/(imem|dmem|top_module)\.v$')
# Cache memories (SRAM_TECH):
#   scn4m_subm (default) - OpenRAM 0.35 um macro models (cache/sram/)
#   sky130               - OpenRAM sky130 macro models (cache/sram_sky130/)
#   ff                   - flip-flop arrays used for the sky130 chip (rtl/mem_ff/)
sram() { echo "$SRAMS/$1/$1.v"; }
case "${SRAM_TECH:-scn4m_subm}" in
  scn4m_subm) SRAMS="$ROOT/cache/sram" ;;
  sky130)     SRAMS="$ROOT/cache/sram_sky130" ;;
  ff)         sram() { echo "$ROOT/rtl/mem_ff/$1.v"; } ;;
  *) echo "unknown SRAM_TECH=$SRAM_TECH"; exit 1 ;;
esac
# (l2_use_array is always flip-flops, in rtl/mem/)
L1I="$ROOT/cache/output/l1i/l1i.v $(sram l1i_tag_array)"
L1D="$ROOT/cache/output/l1d/l1d.v $(sram l1d_tag_array)"
L1DATA="$(sram sram_128x32_1r1w)"
L2="$ROOT/cache/output/l2/l2.v $(sram l2_tag_array) $(sram l2_data_array)"

# Gate-level: synthesized core + sky130 standard-cell models (zero-delay functional)
OL_DESIGN=/data/OpenLane/designs/riscv_core
SC_VERILOG=/data/OpenLane/pdks/sky130A/libs.ref/sky130_fd_sc_hd/verilog
latest_netlist() { ls -t $OL_DESIGN/runs/*/final/nl/riscv_module.nl.v 2>/dev/null | head -1; }
GL_DEFS="-DGL -DFUNCTIONAL -DUNIT_DELAY=#0 -DCLK_HALF=12.5"

# The OpenRAM behavioral models print every access; hide those lines
quiet() { grep -vE ' (Reading|Writing) |Not enough words' || true; }

build_prog() { make -s -C $ROOT/sw "$1.hex" >/dev/null; }

run_l1d() {
  iverilog -g2005 -o $BUILD/tb_l1d.vvp tb_l1d.v models/dram.v $ROOT/rtl/mem/ff_ram_1r1w.v $L1D $L1DATA
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

run_gl() {  # mode prog
  mode=$1; prog=$2
  nl=${NETLIST:-$(latest_netlist)}
  [ -f "$nl" ] || { echo "no gate-level netlist found (run OpenLane first)"; exit 1; }
  echo "Netlist : $nl"
  build_prog $prog
  cells="$SC_VERILOG/primitives.v $SC_VERILOG/sky130_fd_sc_hd.v"
  if [ $mode = ideal ]; then
    iverilog -g2005 $GL_DEFS -DIDEAL -o $BUILD/tb_gl_ideal.vvp tb_soc.v $nl $cells
  else
    iverilog -g2005 $GL_DEFS -o $BUILD/tb_gl_cached.vvp tb_soc.v models/dram.v $ROOT/rtl/soc/*.v $ROOT/rtl/mem/*.v $nl $cells $L1I $L1D $L1DATA $L2
  fi
  (cd $BUILD && vvp -n tb_gl_$mode.vvp +prog=../$ROOT/sw/$prog.hex) | quiet
}

run_systolic() {  # N
  iverilog -g2005 -DN=$1 -o $BUILD/tb_systolic_$1.vvp tb_systolic.v $ROOT/rtl/accel/*.v
  (cd $BUILD && vvp -n tb_systolic_$1.vvp) | grep -v "VCD info"
}

run_accel() {  # N
  iverilog -g2005 -DN=$1 -o $BUILD/tb_matmul_accel_$1.vvp tb_matmul_accel.v $ROOT/rtl/accel/*.v
  (cd $BUILD && vvp -n tb_matmul_accel_$1.vvp) | grep -v "VCD info"
}

case "$1" in
  accel)    run_accel "${2:-8}" ;;
  systolic) run_systolic "${2:-16}" ;;
  gl-ideal)  run_gl ideal  "${2:-test_core}" ;;
  gl-cached) run_gl cached "${2:-test_core}" ;;
  gl-all)    for p in test_core test_mem; do run_gl ideal $p; run_gl cached $p; done ;;
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
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
