# klayout_drc_stripes.py - KLayout DRC of the SoC in horizontal stripes.
#
# Used as KLAYOUT_DRC_RUNSET: OpenLane's KLayout.DRC step runs
#   klayout -b -zz -r klayout_drc_stripes.py -rd input=... -rd report=... ...
# The PDK deck in one pass needs more memory than the laptop has: deep mode
# went past 14 GB in the met1 checks, and its tiled mode (which keeps every
# intermediate layer flat for the whole chip) past 10 GB in the licon checks.
#
# So this script runs klayout_drc_clip.drc (the PDK deck with a clip window,
# see make_drc_deck.py) once per stripe of the die, each in its own klayout
# process, so the memory is freed between stripes. Each process sees its
# stripe plus a MARGIN on both sides; the rules reach at most a few um, so
# markers caused by the clip cut lie in the margin. Only markers whose centre
# is inside the stripe itself are kept, and these are merged into the single
# report OpenLane reads. A stripe that fails fails the whole step.
#
# Optional -rd stripe_height=<um> (default 750) and margin=<um> (default 20).
import math
import os
import shutil
import subprocess
import sys

import pya

G = globals()
DECK = os.path.join(os.path.dirname(os.path.abspath(G.get("__file__", sys.argv[0]))),
                    "klayout_drc_clip.drc")
STRIPE_HEIGHT = float(G.get("stripe_height", 750))
MARGIN = float(G.get("margin", 20))
INPUT = G["input"]
REPORT = G["report"]
PASS_ON = ["topcell", "feol", "beol", "floating_metal", "offgrid", "seal", "threads"]
KLAYOUT = shutil.which("klayout") or "klayout"


def log(msg):
    print(f"[drc-stripes] {msg}", flush=True)


def run(args):
    log("running: " + " ".join(args))
    result = subprocess.run(args)
    if result.returncode != 0:
        raise RuntimeError(f"klayout exited with {result.returncode}: {' '.join(args)}")


# ---- die bounding box, read in a separate process (the GDS needs ~2 GB) ----
report_dir = os.path.dirname(os.path.abspath(REPORT))
bbox_file = os.path.join(report_dir, "stripes_bbox.txt")
bbox_script = os.path.join(report_dir, "stripes_bbox.py")
with open(bbox_script, "w") as f:
    f.write("import pya\n"
            "ly = pya.Layout()\n"
            f"ly.read({INPUT!r})\n"
            "b = ly.top_cell().dbbox()\n"
            f"open({bbox_file!r}, 'w').write(f'{{b.left}} {{b.bottom}} {{b.right}} {{b.top}}')\n")
run([KLAYOUT, "-b", "-zz", "-r", bbox_script])
left, bottom, right, top = (float(v) for v in open(bbox_file).read().split())
n = max(1, math.ceil((top - bottom) / STRIPE_HEIGHT))
h = (top - bottom) / n
log(f"layout bbox ({left}, {bottom}) - ({right}, {top}) um: {n} stripes of {h:.1f} um, "
    f"margin {MARGIN} um")

# ---- one DRC process per stripe ----
stripes = []
for i in range(n):
    lo = bottom + i * h
    hi = bottom + (i + 1) * h
    clip = f"{left - MARGIN},{lo - MARGIN},{right + MARGIN},{hi + MARGIN}"
    part = os.path.join(report_dir, f"stripe_{i}.klayout.xml")
    if os.path.exists(part):
        os.remove(part)
    log(f"stripe {i + 1}/{n}: y {lo:.1f} - {hi:.1f} um (clip {clip})")
    args = [KLAYOUT, "-b", "-zz", "-r", DECK, "-rd", f"input={INPUT}",
            "-rd", f"report={part}", "-rd", f"clip={clip}"]
    for name in PASS_ON:
        if name in G:
            args += ["-rd", f"{name}={G[name]}"]
    run(args)
    if not os.path.exists(part):
        raise RuntimeError(f"stripe {i + 1} wrote no report {part}")
    # the first stripe keeps everything below it, the last everything above
    stripes.append((part, -math.inf if i == 0 else lo, math.inf if i == n - 1 else hi))


# ---- merge ----
# In deep mode a marker is stored in the cell where it was found, in that
# cell's coordinates, and the report gives each cell one representative
# placement (not every instance). Markers are written flat into the top cell
# of the merged report:
#  - markers in the top cell, and in "CLIP" variants (cells cut by the clip
#    window: cells crossing its edge, and the accelerator macro, which spans
#    every stripe), can be clip artefacts. They are mapped to chip
#    coordinates and kept only if their centre is inside the stripe.
#  - markers in any other cell come from a cell lying wholly inside the
#    window, so they are real. Like a one-pass deep run, they count once per
#    cell: kept the first time seen, duplicates from other stripes skipped.
# Checked against one-pass runs of the PDK deck on test layouts with errors on
# stripe edges, in margins, in a clipped macro cell and in a repeated cell.
GEOMETRY = (("is_box", "box"), ("is_polygon", "polygon"), ("is_edge", "edge"),
            ("is_edge_pair", "edge_pair"), ("is_path", "path"), ("is_text", "text"))


def geometry(value):
    for kind, get in GEOMETRY:
        if getattr(value, kind)():
            return getattr(value, get)()
    return None  # string / float annotations


def placements(rdb, cell_id, top_id, cache):
    """Transformations of a cell into the top cell, through nested references."""
    if cell_id == top_id:
        return [pya.DCplxTrans()]
    if cell_id not in cache:
        cache[cell_id] = []  # guards against reference loops
        result = []
        for ref in rdb.cell_by_id(cell_id).each_reference():
            for up in placements(rdb, ref.parent_cell_id, top_id, cache):
                result.append(up * ref.trans)
        cache[cell_id] = result
    return cache[cell_id]


def clipped(rdb, cell):
    """Is the cell, or any cell it is placed in, a clip variant?"""
    seen = set()
    todo = [cell]
    while todo:
        c = todo.pop()
        if c.rdb_id() in seen:
            continue
        seen.add(c.rdb_id())
        if "CLIP" in (c.variant() or ""):
            return True
        todo += [rdb.cell_by_id(r.parent_cell_id) for r in c.each_reference()]
    return False


def add_flat(cat_name, values, t):
    new = merged.create_item(merged_top.rdb_id(), merged_cats[cat_name].rdb_id())
    for v in values:
        g = geometry(v)
        new.add_value(pya.RdbItemValue(g.transformed(t)) if g is not None else v)


merged = pya.ReportDatabase("SKY130 DRC runset")
merged_cats = {}
merged_top = None
seen_in_cells = set()
kept = dropped = duplicates = 0
for part, lo, hi in stripes:
    rdb = pya.ReportDatabase("part")
    rdb.load(part)
    top_name = rdb.top_cell_name
    top_cell = rdb.cell_by_qname(top_name)
    if top_cell is None:
        raise RuntimeError(f"{part}: top cell {top_name} not in the report")
    if merged_top is None:
        merged.top_cell_name = top_name
        merged_top = merged.create_cell(top_name)
    for cat in rdb.each_category():
        if cat.name() not in merged_cats:
            mc = merged.create_category(cat.name())
            mc.description = cat.description
            merged_cats[cat.name()] = mc
    cache = {}
    clip_cache = {}
    for item in rdb.each_item():
        values = list(item.each_value())
        cat_name = rdb.category_by_id(item.category_id()).name()
        cell = rdb.cell_by_id(item.cell_id())
        trans = placements(rdb, cell.rdb_id(), top_cell.rdb_id(), cache)
        if cell.rdb_id() not in clip_cache:
            clip_cache[cell.rdb_id()] = clipped(rdb, cell)
        if cell.rdb_id() != top_cell.rdb_id() and not clip_cache[cell.rdb_id()]:
            key = (cat_name, cell.name(), tuple(v.to_s() for v in values))
            if key in seen_in_cells:
                duplicates += 1
            else:
                seen_in_cells.add(key)
                add_flat(cat_name, values, trans[0] if trans else pya.DCplxTrans())
                kept += 1
            continue
        for t in trans:
            box = pya.DBox()
            for v in values:
                g = geometry(v)
                if g is not None:
                    box += g.transformed(t).bbox() if not v.is_text() else t * g.position()
            if box.empty() or not (lo <= box.center().y < hi):
                dropped += 1
                continue
            add_flat(cat_name, values, t)
            kept += 1

merged.save(REPORT)
log(f"merged {len(stripes)} stripe reports into {REPORT}: {kept} markers kept, "
    f"{dropped} outside their stripe (clip margin) dropped, "
    f"{duplicates} repeats of a cell's marker from other stripes skipped")
