#!/usr/bin/env python3
"""Write config.json for the hierarchical riscv_soc build.

The hardened matmul_accel (macros/matmul_accel/, see import_macro.sh) sits at
the top of the die; the rest of the SoC (core, caches, arbiter, ~1.2 mm2 of
standard cells) is placed and routed in the region below it. The macro has
almost all of its signal pins on its bottom edge (322 of 356), so they face
the logic directly. All SoC I/O pins are on the bottom die edge (pin_order.cfg),
so no wire has to go around the macro. The die is sized from the macro's LEF.

(The first floorplan put the macro at the bottom-left with the logic to its
right: its bottom pins then faced a 100 um channel at the die edge and global
routing failed with GRT-0118, routing congestion.)
"""
import glob
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
MACRO = "macros/matmul_accel"

# ---- macro size from its LEF ----
lef = open(os.path.join(HERE, MACRO, "lef", "matmul_accel.lef")).read()
mw, mh = (float(v) for v in re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", lef).groups())

# ---- floorplan (um) ----
EDGE = 100           # die edge to macro on the left, right and top
CHANNEL = 100        # macro bottom edge to the standard-cell region
LOGIC_AREA = 3.6e6   # standard-cell region (flat SoC alone needed 1.87 mm square)
die_w = round(mw + 2 * EDGE)
logic_h = round(LOGIC_AREA / die_w)
mx = EDGE
my = EDGE + logic_h + CHANNEL
die_h = round(my + mh + EDGE)


def rel(*parts):
    return "dir::" + os.path.join(MACRO, *parts)


def files(pattern):
    return sorted(os.path.relpath(p, HERE) for p in glob.glob(os.path.join(HERE, MACRO, pattern)))


libs = {}
for corner_dir in sorted(glob.glob(os.path.join(HERE, MACRO, "lib", "*"))):
    corner = os.path.basename(corner_dir)
    libs[corner] = ["dir::" + p for p in files(f"lib/{corner}/*.lib")]

spefs = {}
for kind in ("nom", "min", "max"):
    found = files(f"spef/{kind}/*.spef")
    if found:
        spefs[f"{kind}_*"] = ["dir::" + p for p in found]

config = {
    "meta": {
        "version": 2,
        "flow": "Classic",
        "substituting_steps": {
            # No second RepairDesignPostGRT after RepairAntennas (as used for the
            # accelerator): the diodes count as fanout, so it found 5139 fanout
            # violations and split those nets with 9280 buf_1 buffers after
            # routing; signoff setup fell to -17.7 ns with 124k slew violations.
            # the top-level chip needs no abstract LEF of itself; Magic.WriteLEF
            # needed 10 GB for the accelerator alone (and its LEF check goes with it)
            "Magic.WriteLEF": None,
            "Odb.CheckDesignAntennaProperties": None,
        },
    },
    "DESIGN_NAME": "riscv_soc",
    "VERILOG_FILES": "dir::src/*.v",

    "CLOCK_PORT": "clk",
    "CLOCK_PERIOD": 35,
    "IO_DELAY_CONSTRAINT": 20,
    # PnR uses tighter main-memory IO constraints than signoff (see pnr.sdc)
    "PNR_SDC_FILE": "dir::pnr.sdc",
    "SIGNOFF_SDC_FILE": "dir::signoff.sdc",

    "FP_SIZING": "absolute",
    "DIE_AREA": [0, 0, die_w, die_h],
    "FP_PIN_ORDER_CFG": "dir::pin_order.cfg",
    "PL_TARGET_DENSITY_PCT": 45,

    "MACROS": {
        "matmul_accel": {
            "gds": [rel("gds", "matmul_accel.gds")],
            "lef": [rel("lef", "matmul_accel.lef")],
            "vh": [rel("vh", "matmul_accel.vh")],
            "nl": [rel("nl", "matmul_accel.nl.v")],
            "lib": libs,
            "spef": spefs,
            "instances": {
                "u_accel": {"location": [mx, my], "orientation": "N"},
            },
        }
    },
    "PDN_MACRO_CONNECTIONS": ["u_accel VPWR VGND VPWR VGND"],
    "PL_MACRO_HALO": "20 20",

    "SYNTH_STRATEGY": "AREA 0",

    "DEFAULT_CORNER": "max_ss_100C_1v60",
    "RUN_POST_GRT_RESIZER_TIMING": True,
    "RUN_POST_GRT_DESIGN_REPAIR": True,
    # Hold margins: OpenLane defaults (0.1 / 0.05 ns), as in the flat SoC. The
    # ~27k memory flip-flops have short Q -> mux -> D loops just under 0.1 ns
    # at the ff corners, so post-CTS hold repair pads each of them (~27k
    # buffers, one to two hours). The 0.2 ns used for the accelerator only
    # makes that slower.

    "RUN_HEURISTIC_DIODE_INSERTION": True,
    "HEURISTIC_ANTENNA_THRESHOLD": 200,
    "GRT_ANTENNA_ITERS": 15,
    "GRT_ANTENNA_MARGIN": 50,

    "CTS_SINK_CLUSTERING_SIZE": 10,
    "DESIGN_REPAIR_MAX_SLEW_PCT": 30,
    "GRT_DESIGN_REPAIR_MAX_SLEW_PCT": 30,
    "DESIGN_REPAIR_MAX_WIRE_LENGTH": 400,
    "GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH": 400,
    "CTS_CLK_MAX_WIRE_LENGTH": 400,

    # Memory (15 GB laptop). Post-PnR STA reads the macro's netlist + SPEF
    # (STA_MACRO_PRIORITIZE_NL), ~2.5-3 GB per corner: all 9 corners at once
    # froze the machine. KLayout DRC needed 10 GB for the accelerator alone;
    # for the SoC the PDK deck went past 14 GB in deep mode and 10 GB in tiled
    # mode (both killed at the cap), so it runs in six horizontal stripes, one
    # klayout process each (same rules; see klayout_drc_stripes.py).
    "STA_THREADS": 3,
    "KLAYOUT_DRC_RUNSET": "dir::klayout_drc_stripes.py",
    "KLAYOUT_DRC_THREADS": 4,

    "pdk::sky130A": {"STD_CELL_LIBRARY": "sky130_fd_sc_hd"},
}

json.dump(config, open(os.path.join(HERE, "config.json"), "w"), indent=2)
print(f"macro {mw} x {mh} um at ({mx}, {my}); die {die_w} x {die_h} um; "
      f"logic region {die_w} x {logic_h} um below the macro")
print(f"corners with lib: {len(libs)}, spef: {list(spefs)}")
