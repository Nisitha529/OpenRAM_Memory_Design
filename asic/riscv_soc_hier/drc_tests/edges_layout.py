# Write edges.gds: met1 width / spacing / area errors in stripe middles, on stripe
# edges and in the margin bands (stripe height 1000 um), plus a wide strap
# crossing all stripes. Used by run.sh.
import pya
ly = pya.Layout(); ly.dbu = 0.001
top = ly.create_cell("edges"); m1 = ly.layer(68, 20); m2 = ly.layer(69, 20)
def box(l, x1, y1, x2, y2): top.shapes(l).insert(pya.DBox(x1, y1, x2, y2))
box(m1, 0, 0, 2, 2); box(m1, 2998, 2998, 3000, 3000)   # bbox 0..3000
# violations at y in a stripe middle, on stripe edges (1000, 2000) and in the
# margin band just above/below an edge (stripe height 1000 in the test)
for y in (500, 1000, 1005, 1990, 2000, 2995):
    box(m1, 100, y - 0.05, 110, y + 0.05)                  # m1.1 width 0.10
    box(m1, 200, y - 5, 205, y - 0.05); box(m1, 200, y + 0.05, 205, y + 5)  # m1.2 space 0.10
    box(m1, 300 - 0.1, y - 0.1, 300 + 0.1, y + 0.1)        # m1.6 area 0.04
# long wide m2 strap crossing all stripes: must give no marker
box(m2, 400, 1, 410, 2999)
ly.write("edges.gds")
