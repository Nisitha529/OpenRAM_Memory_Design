#!/usr/bin/env python3
"""Fill metal spacing violations in a GDS by bridging the too-narrow gaps.

    fill_spacing.py <in.gds> <out.gds> <layer>/<datatype> <min_space_um>

Every pair of shapes on the layer that is closer than min_space gets the gap
between them filled with the same layer. That merges the two shapes, which is
only correct when they are on the same net - so the result MUST be checked with
LVS afterwards (cache/patch_sram.sh does that and rejects the patch otherwise).
"""
import sys
import klayout.db as db

src, dst, layer, space = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
L, D = (int(v) for v in layer.split("/"))

ly = db.Layout()
ly.read(src)
top = ly.top_cell()
li = ly.layer(L, D)

metal = db.Region(top.begin_shapes_rec(li)).merged()
gaps = metal.space_check(int(round(space / ly.dbu)))
fill = gaps.polygons().merged()
print(f"{gaps.count()} spacing violations, {fill.count()} fill shapes")
for p in fill.each():
    print("  fill", p.bbox().to_dtype(ly.dbu))
top.shapes(li).insert(fill)
ly.write(dst)
