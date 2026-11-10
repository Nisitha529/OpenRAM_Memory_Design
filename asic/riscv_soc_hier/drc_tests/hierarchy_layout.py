# Write hierarchy.gds: errors inside a 2 mm macro cell spanning all stripes and
# inside a small cell placed four times (one placement across a stripe edge).
# Used by run.sh.
import pya
ly = pya.Layout(); ly.dbu = 0.001
m1 = ly.layer(68, 20)
top = ly.create_cell("hierarchy"); mac = ly.create_cell("macro"); sub = ly.create_cell("sub")
def box(c, x1, y1, x2, y2): c.shapes(m1).insert(pya.DBox(x1, y1, x2, y2))
box(top, 0, 0, 2, 2); box(top, 2998, 2998, 3000, 3000)
box(sub, 0, 0, 5, 0.10)                                   # m1.1 inside a small cell
for y in (100, 600, 1300):                                # macro-local y (macro at y=700)
    box(mac, 50, y - 0.05, 60, y + 0.05)                   # m1.1 width
    box(mac, 80, y - 0.1, 80.2, y + 0.1)                   # m1.6 area
box(mac, 0, 0, 1, 1); box(mac, 1999, 1999, 2000, 2000)    # macro extent 2000 x 2000
top.insert(pya.DCellInstArray(mac.cell_index(), pya.DTrans(pya.DVector(500, 700))))   # spans y 700..2700
for x, y in ((100, 500), (100, 999.97), (2900, 2000), (2900, 1500)):    # 999.97: crosses the 1000 edge
    top.insert(pya.DCellInstArray(sub.cell_index(), pya.DTrans(pya.DVector(x, y))))
ly.write("hierarchy.gds")
