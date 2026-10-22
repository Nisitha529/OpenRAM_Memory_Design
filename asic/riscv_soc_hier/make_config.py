#!/usr/bin/env python3
"""Write config.json for the hierarchical riscv_soc build.

The hardened matmul_accel (macros/matmul_accel/, see import_macro.sh) is placed
at the left of the die; the rest of the SoC (core, caches, arbiter, ~2 mm2 of
standard cells) is placed and routed to its right. The die is sized from the
macro's LEF so the floorplan follows the macro if it is re-hardened.
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
EDGE = 100        # die edge to macro (IO pins, power ring area)
CHANNEL = 150     # macro to standard-cell region (routing to the macro pins)
LOGIC_W = 1900    # standard-cell region width (flat SoC alone: 1.87 mm square)
mx, my = EDGE, EDGE
die_w = round(EDGE + mw + CHANNEL + LOGIC_W + EDGE)
die_h = round(max(mh + 2 * EDGE, 2000))


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
        # repair slew / capacitance again after antenna diodes are inserted
        "substituting_steps": {"+OpenROAD.RepairAntennas": "OpenROAD.RepairDesignPostGRT"},
    },
    "DESIGN_NAME": "riscv_soc",
    "VERILOG_FILES": "dir::src/*.v",

    "CLOCK_PORT": "clk",
    "CLOCK_PERIOD": 35,
    "IO_DELAY_CONSTRAINT": 20,

    "FP_SIZING": "absolute",
    "DIE_AREA": [0, 0, die_w, die_h],
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
    "PL_RESIZER_HOLD_SLACK_MARGIN": 0.2,
    "GRT_RESIZER_HOLD_SLACK_MARGIN": 0.2,

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

    "pdk::sky130A": {"STD_CELL_LIBRARY": "sky130_fd_sc_hd"},
}

json.dump(config, open(os.path.join(HERE, "config.json"), "w"), indent=2)
print(f"macro {mw} x {mh} um at ({mx}, {my}); die {die_w} x {die_h} um")
print(f"corners with lib: {len(libs)}, spef: {list(spefs)}")
