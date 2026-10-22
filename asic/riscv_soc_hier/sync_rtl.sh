#!/bin/bash
# Copy the SoC RTL from the project (the source of truth) into src/, WITHOUT the
# accelerator: in this hierarchical build matmul_accel is a hardened macro
# (see import_macro.sh).
set -e
PROJECT=/media/nisitha/My_Passport/MOODLE/OpenRAM_Project/OpenRAM_Memory_Design
cd "$(dirname "$0")"
rm -f src/*.v
for f in "$PROJECT"/rtl/core/*.v; do
  case "$(basename "$f")" in imem.v|dmem.v|top_module.v) ;; *) cp "$f" src/ ;; esac
done
cp "$PROJECT"/rtl/soc/*.v "$PROJECT"/rtl/mem/*.v "$PROJECT"/rtl/mem_ff/*.v src/
for c in l1i l1d l2; do cp "$PROJECT/cache/output/$c/$c.v" src/; done
ls src | wc -l | xargs echo "RTL files:"
