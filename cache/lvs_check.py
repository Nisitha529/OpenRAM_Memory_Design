#!/usr/bin/env python3
"""Decide LVS pass/fail from a netgen report, using OpenRAM's own rules
(compiler/verify/magic.py run_lvs): only the top-level section after the last
"Subcircuit summary:" counts."""
import re, sys

lines = open(sys.argv[1]).readlines()
final = []
for line in reversed(lines):
    if "Subcircuit summary:" in line:
        break
    final.insert(0, line)

errors = sum("Property errors were found." in l for l in lines)
errors += sum("Netlists do not match." in l for l in final)
errors += sum("The top level cell failed pin matching." in l for l in final)
if not any(re.search("match (uniquely|correctly)", l) for l in final):
    errors += 1
print("match" if errors == 0 else "MISMATCH")
sys.exit(1 if errors else 0)
