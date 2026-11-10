# Compare two KLayout DRC reports (-rd ref=..., -rd test=...) after mapping
# every marker to top-cell coordinates. Used by run.sh.
import pya
def flat(f):
    rdb = pya.ReportDatabase(""); rdb.load(f)
    top = rdb.cell_by_qname(rdb.top_cell_name).rdb_id()
    def pl(cid):
        if cid == top: return [pya.DCplxTrans()]
        return [u * r.trans for r in rdb.cell_by_id(cid).each_reference() for u in pl(r.parent_cell_id)]
    out = []
    for it in rdb.each_item():
        for t in pl(it.cell_id()):
            b = pya.DBox()
            for v in it.each_value():
                for k, g in (("is_box","box"),("is_polygon","polygon"),("is_edge","edge"),("is_edge_pair","edge_pair"),("is_path","path")):
                    if getattr(v, k)(): b += getattr(v, g)().transformed(t).bbox()
            out.append((rdb.category_by_id(it.category_id()).name(), round(b.center().x, 2), round(b.center().y, 2)))
    return sorted(out)
a, b = flat(ref), flat(test)
print(f"deep (flattened): {len(a)}  stripes: {len(b)}  identical: {a == b}")
for m in sorted(set(a) ^ set(b)): print("  differs:", m)
