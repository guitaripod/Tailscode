import bpy, bmesh, math, random, json, sys, os, re
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
opts = dict(a.split("=", 1) for a in argv if "=" in a)
OUT = opts.get("out", "/tmp/head.png")
SAMPLES = int(opts.get("samples", 48))
WIDTH = int(opts.get("width", 1024))
SEED = int(opts.get("seed", 7))
MODE = opts.get("mode", "beauty")
DEVICE = opts.get("device", "gpu")

MASK = MODE.startswith("mask")
EMIT = 1.0 if (MASK or MODE == "beauty") else float(opts.get("emit", 0.12))
BASIS = {
    "mask_i1": {"think": (1, 0, 0), "sense": (0, 1, 0), "act": (0, 0, 1)},
    "mask_i2": {"shell": (1, 0, 0), "delegate": (0, 1, 0), "say": (0, 0, 1)},
    "mask_i3": {"link": (1, 0, 0), "star": (0, 1, 0)},
    "mask_c": {"seam": (1, 0, 0), "eye": (0, 1, 0)},
    "mask_d": {"rib": (1, 0, 0), "ear": (0, 1, 0), "visor": (0, 0, 1)},
}
VISIBLE = {"beauty": {"chassis", "interior", "glass"}, "chassis": {"chassis"}, "interior": {"interior"}, "glass": {"glass"},
           "mask_i1": {"interior"}, "mask_i2": {"interior"}, "mask_i3": {"interior"}, "mask_c": {"chassis"}, "mask_d": {"chassis"}}[MODE]
TRANSPARENT = MODE in ("chassis", "interior", "glass")

S = 0.01
random.seed(SEED)

HEAD = [(196,412),(196,372),(136,322),(98,268),(80,196),(100,118),(162,56),(258,24),(372,16),(484,40),(556,98),(580,160),(614,184),(620,238),(586,254),(584,296),(544,330),(486,346),(436,352),(384,374),(384,412)]
DOME_PATH = "M128,212 C112,132 176,72 268,54 C366,38 462,52 512,108 C540,142 534,196 512,234 C494,260 452,268 420,270 L334,298 C296,314 254,322 214,314 C168,302 134,266 128,212 Z"
ZONES = {"think":(456,150),"act":(348,104),"sense":(204,162),"shell":(240,284),"delegate":(396,250),"say":(520,306)}
ZONE_R = {"think":(66,58),"act":(66,58),"sense":(66,58),"shell":(66,58),"delegate":(66,58),"say":(56,38)}
TONE = {"think":(0.85,1.0,0.9),"sense":(0.25,0.85,1.0),"act":(0.15,1.0,0.5),"shell":(0.62,0.45,1.0),"delegate":(0.55,0.85,0.7),"say":(0.3,1.0,0.8)}
ACCENT = (0.12, 1.0, 0.5)


def P(x, y, d=0.0):
    return Vector(((x - 320) * S, d, (210 - y) * S))


def parse_path(d):
    toks = re.findall(r"[MLCZ]|-?\d+\.?\d*", d)
    pts, i, cur = [], 0, None
    while i < len(toks):
        t = toks[i]
        if t in ("M", "L"):
            cur = (float(toks[i+1]), float(toks[i+2])); pts.append(cur); i += 3
        elif t == "C":
            c1 = (float(toks[i+1]), float(toks[i+2])); c2 = (float(toks[i+3]), float(toks[i+4])); e = (float(toks[i+5]), float(toks[i+6]))
            for k in range(1, 25):
                u = k / 24
                pts.append(((1-u)**3*cur[0] + 3*(1-u)**2*u*c1[0] + 3*(1-u)*u*u*c2[0] + u**3*e[0],
                            (1-u)**3*cur[1] + 3*(1-u)**2*u*c1[1] + 3*(1-u)*u*u*c2[1] + u**3*e[1]))
            cur = e; i += 7
        else:
            i += 1
    return pts


DOME = parse_path(DOME_PATH)


def ellipse_poly(cx, cy, rx, ry, n=48):
    return [(cx + rx * math.cos(2*math.pi*k/n), cy + ry * math.sin(2*math.pi*k/n)) for k in range(n)]


def inside(poly, x, y):
    c = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]; xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi + 1e-9) + xi:
            c = not c
        j = i
    return c


GROUP = {"cur": "chassis"}


def link(obj):
    bpy.context.scene.collection.objects.link(obj)
    obj["grp"] = GROUP["cur"]
    return obj


def new_mesh_obj(name, bm):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    return link(bpy.data.objects.new(name, me))


def prism(name, poly, y0, y1, scale=1.0, center=(320, 210)):
    bm = bmesh.new()
    pts = [((x - center[0]) * scale + center[0], (y - center[1]) * scale + center[1]) for x, y in poly]
    vs = [bm.verts.new(P(x, y, y0)) for x, y in pts]
    f = bm.faces.new(vs)
    ret = bmesh.ops.extrude_face_region(bm, geom=[f])
    vv = [e for e in ret["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=vv, vec=Vector((0, y1 - y0, 0)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    return new_mesh_obj(name, bm)


def apply_mod(obj, mod):
    bpy.context.view_layer.objects.active = obj
    for o in bpy.context.selected_objects:
        o.select_set(False)
    obj.select_set(True)
    bpy.ops.object.modifier_apply(modifier=mod.name)


def boolean(obj, cutter, op="DIFFERENCE"):
    m = obj.modifiers.new("b", "BOOLEAN")
    m.operation = op; m.object = cutter; m.solver = "EXACT"
    apply_mod(obj, m)
    bpy.data.objects.remove(cutter, do_unlink=True)


def bevel(obj, width, seg=3, angle=35):
    m = obj.modifiers.new("bv", "BEVEL")
    m.width = width; m.segments = seg; m.limit_method = "ANGLE"; m.angle_limit = math.radians(angle)
    apply_mod(obj, m)


def smooth(obj, angle=32):
    bm = bmesh.new(); bm.from_mesh(obj.data)
    for f in bm.faces:
        f.smooth = True
    for e in bm.edges:
        if len(e.link_faces) == 2 and e.calc_face_angle(0) > math.radians(angle):
            e.smooth = False
    bm.to_mesh(obj.data); bm.free()


def open_front(obj, y):
    bm = bmesh.new(); bm.from_mesh(obj.data)
    bad = [f for f in bm.faces if f.calc_center_median().y < y]
    bmesh.ops.delete(bm, geom=bad, context="FACES_ONLY")
    bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data); bm.free()


def keep_front(obj):
    bm = bmesh.new(); bm.from_mesh(obj.data)
    bm.normal_update()
    bad = [f for f in bm.faces if f.normal.y > -0.25]
    bmesh.ops.delete(bm, geom=bad, context="FACES")
    bm.to_mesh(obj.data); bm.free()


def mat(name):
    m = bpy.data.materials.new(name); m.use_nodes = True
    for n in list(m.node_tree.nodes):
        m.node_tree.nodes.remove(n)
    return m


def out_node(nt, shader):
    o = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(shader.outputs[0], o.inputs[0])
    return o


BLOCK = {}


def block_mat():
    if "m" not in BLOCK:
        m = mat("block"); e = m.node_tree.nodes.new("ShaderNodeEmission")
        e.inputs["Color"].default_value = (0, 0, 0, 1); e.inputs["Strength"].default_value = 0
        out_node(m.node_tree, e); BLOCK["m"] = m
    return BLOCK["m"]


def metal_mat(name, base=(0.045, 0.055, 0.06), rough=0.34, edge=(0.55, 0.62, 0.6), wear=True):
    if MASK:
        return block_mat()
    m = mat(name); n = m.node_tree.nodes; L = m.node_tree.links
    pb = n.new("ShaderNodeBsdfPrincipled"); pb.inputs["Metallic"].default_value = 1.0
    noise = n.new("ShaderNodeTexNoise"); noise.inputs["Scale"].default_value = 140; noise.inputs["Detail"].default_value = 4
    ramp = n.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.35; ramp.color_ramp.elements[0].color = (rough * 0.85,) * 3 + (1,)
    ramp.color_ramp.elements[1].position = 0.7; ramp.color_ramp.elements[1].color = (rough * 1.15,) * 3 + (1,)
    L.new(noise.outputs["Fac"], ramp.inputs["Fac"]); L.new(ramp.outputs["Color"], pb.inputs["Roughness"])
    bump = n.new("ShaderNodeBump"); bump.inputs["Strength"].default_value = 0.025
    noise2 = n.new("ShaderNodeTexNoise"); noise2.inputs["Scale"].default_value = 220; noise2.inputs["Detail"].default_value = 3
    L.new(noise2.outputs["Fac"], bump.inputs["Height"]); L.new(bump.outputs["Normal"], pb.inputs["Normal"])
    if wear:
        bv = n.new("ShaderNodeBevel"); bv.inputs["Radius"].default_value = 0.012; bv.samples = 6
        geo = n.new("ShaderNodeNewGeometry")
        dot = n.new("ShaderNodeVectorMath"); dot.operation = "DOT_PRODUCT"
        L.new(bv.outputs["Normal"], dot.inputs[0]); L.new(geo.outputs["Normal"], dot.inputs[1])
        mr = n.new("ShaderNodeMapRange"); mr.inputs["From Min"].default_value = 0.93; mr.inputs["From Max"].default_value = 0.995
        mr.inputs["To Min"].default_value = 1.0; mr.inputs["To Max"].default_value = 0.0
        L.new(dot.outputs["Value"], mr.inputs["Value"])
        mix = n.new("ShaderNodeMix"); mix.data_type = "RGBA"
        mix.inputs[6].default_value = base + (1,); mix.inputs[7].default_value = edge + (1,)
        L.new(mr.outputs["Result"], mix.inputs[0]); L.new(mix.outputs[2], pb.inputs["Base Color"])
    else:
        pb.inputs["Base Color"].default_value = base + (1,)
    out_node(m.node_tree, pb)
    return m


def emit_mat(name, chan, tone, strength, beauty=None):
    m = mat(name); e = m.node_tree.nodes.new("ShaderNodeEmission")
    if MASK:
        c = BASIS[MODE].get(chan, (0, 0, 0)); st = min(strength / 3.0, 1.0) if c != (0, 0, 0) else 0.0
    else:
        c = tone; st = (strength if beauty is None else beauty) * EMIT
    e.inputs["Color"].default_value = tuple(c) + (1,); e.inputs["Strength"].default_value = st
    out_node(m.node_tree, e)
    return m


def glass_mat(name):
    m = mat(name); n = m.node_tree.nodes; L = m.node_tree.links
    if MASK:
        t = n.new("ShaderNodeBsdfTransparent"); out_node(m.node_tree, t); return m
    lw = n.new("ShaderNodeLayerWeight"); lw.inputs["Blend"].default_value = 0.35
    pw = n.new("ShaderNodeMath"); pw.operation = "POWER"; pw.inputs[1].default_value = 8.0
    L.new(lw.outputs["Fresnel"], pw.inputs[0])
    if MODE == "glass":
        tr = n.new("ShaderNodeBsdfTransparent"); gl = n.new("ShaderNodeBsdfGlossy"); gl.inputs["Roughness"].default_value = 0.03
        gl.inputs["Color"].default_value = (0.4, 0.46, 0.44, 1)
        em = n.new("ShaderNodeEmission"); em.inputs["Color"].default_value = (0.25, 1.0, 0.75, 1); em.inputs["Strength"].default_value = 0.45
        inner = n.new("ShaderNodeMixShader")
        L.new(pw.outputs[0], inner.inputs["Fac"]); L.new(gl.outputs[0], inner.inputs[1]); L.new(em.outputs[0], inner.inputs[2])
        sm = n.new("ShaderNodeMath"); sm.operation = "MULTIPLY_ADD"; sm.use_clamp = True
        L.new(lw.outputs["Fresnel"], sm.inputs[0]); sm.inputs[1].default_value = 1.4; sm.inputs[2].default_value = 0.03
        outer = n.new("ShaderNodeMixShader")
        L.new(sm.outputs[0], outer.inputs["Fac"]); L.new(tr.outputs[0], outer.inputs[1]); L.new(inner.outputs[0], outer.inputs[2])
        out_node(m.node_tree, outer)
        return m
    gl = n.new("ShaderNodeBsdfGlass"); gl.inputs["Color"].default_value = (0.86, 0.97, 0.94, 1); gl.inputs["Roughness"].default_value = 0.015; gl.inputs["IOR"].default_value = 1.35
    rimn = n.new("ShaderNodeEmission"); rimn.inputs["Color"].default_value = (0.2, 1.0, 0.7, 1); rimn.inputs["Strength"].default_value = 0.9
    mixf = n.new("ShaderNodeMixShader")
    L.new(pw.outputs[0], mixf.inputs["Fac"]); L.new(gl.outputs[0], mixf.inputs[1]); L.new(rimn.outputs[0], mixf.inputs[2])
    out_node(m.node_tree, mixf)
    return m


def assign(obj, m):
    obj.data.materials.clear(); obj.data.materials.append(m)


def tube(name, pts, radius, m, res=3):
    cu = bpy.data.curves.new(name, "CURVE"); cu.dimensions = "3D"
    sp = cu.splines.new("POLY"); sp.points.add(len(pts) - 1)
    for i, p in enumerate(pts):
        sp.points[i].co = (p.x, p.y, p.z, 1)
    cu.bevel_depth = radius; cu.bevel_resolution = res; cu.use_fill_caps = True
    o = link(bpy.data.objects.new(name, cu)); cu.materials.append(m)
    return o


def bez(a, b, c, d, n=28):
    return [a * (1-k/n)**3 + b * 3 * (1-k/n)**2 * (k/n) + c * 3 * (1-k/n) * (k/n)**2 + d * (k/n)**3 for k in range(n + 1)]


def slot(k, sp):
    if k == 0:
        return (0, 0)
    ring, count, idx = 1, 6, k - 1
    while idx >= count:
        idx -= count; ring += 1; count = 6 * ring
    a = (idx / count) * math.pi * 2 + (math.pi / 6 if ring % 2 else 0) - math.pi / 2
    return (math.cos(a) * ring * sp, math.sin(a) * ring * sp)


def hex_ring(bm, cx, cy, d, ro, ri):
    vo = [bm.verts.new(P(cx + math.cos(math.pi/3*i) * ro, cy + math.sin(math.pi/3*i) * ro, d)) for i in range(6)]
    vi = [bm.verts.new(P(cx + math.cos(math.pi/3*i) * ri, cy + math.sin(math.pi/3*i) * ri, d)) for i in range(6)]
    for i in range(6):
        j = (i + 1) % 6
        try:
            bm.faces.new((vo[i], vo[j], vi[j], vi[i]))
        except ValueError:
            pass


def chassis_obj(o, m):
    o["grp"] = "chassis"; assign(o, m)


def build():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    anchors = {"zones": {}, "slots": {}, "dome": DOME, "head": HEAD, "scale": S, "nodePlaneY": 0.4}

    GROUP["cur"] = "chassis"
    chassis_m = metal_mat("chassis")
    plate_m = metal_mat("plate", base=(0.07, 0.082, 0.088), rough=0.28)
    inner_m = metal_mat("bay", base=(0.02, 0.028, 0.03), rough=0.5, wear=False)
    jaw_poly = ellipse_poly(520, 306, 58, 40)

    hull = prism("hull", HEAD, -0.40, 0.20)
    boolean(hull, prism("win", DOME, -1.2, 0.6))
    boolean(hull, prism("jawhole", jaw_poly, -1.2, 0.6))
    bevel(hull, 0.016, 3); smooth(hull); assign(hull, chassis_m)

    plate = prism("plate", HEAD, -0.40, -0.50, scale=0.955, center=(350, 214))
    boolean(plate, prism("win2", DOME, -1.2, 0.6, scale=1.045, center=(320, 170)))
    boolean(plate, prism("jawcut", jaw_poly, -1.2, 0.2, scale=1.1, center=(520, 306)))
    bevel(plate, 0.012, 2); smooth(plate); assign(plate, plate_m)

    ear_m = metal_mat("ear", base=(0.03, 0.035, 0.04), rough=0.25)
    for r, h in ((19, 0.06), (13, 0.09), (6, 0.12)):
        bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=r * S, depth=h, location=P(340, 336, -0.50 - h / 2), rotation=(math.pi / 2, 0, 0))
        o = bpy.context.active_object; chassis_obj(o, ear_m); bevel(o, 0.006, 2)

    rivet_m = metal_mat("rivet", base=(0.2, 0.22, 0.22), rough=0.25, wear=False)
    for (x, y) in [(162,56),(484,40),(580,160),(436,352),(100,118),(136,322),(196,372),(384,374),(258,24),(556,98),(98,268),(80,196)]:
        bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=0.035, location=P(x, y, -0.52), scale=(1, 0.5, 1))
        chassis_obj(bpy.context.active_object, rivet_m)

    seam_pts = [[(196,372),(230,356),(330,356),(384,374)],[(162,56),(190,92)],[(484,40),(470,74)],[(580,160),(546,170),(546,236),(586,254)],[(112,240),(146,240)],[(108,254),(146,254)],[(118,268),(150,268)]]
    seam_m = emit_mat("seam", "seam", ACCENT, 3.0, 0.3)
    for k, pl in enumerate(seam_pts):
        tube(f"seam{k}", [P(x, y, -0.505) for x, y in pl], 0.006, seam_m, 2)

    visor = prism("visor", [(552,198),(612,196),(616,230),(558,236)], -0.30, -0.56)
    bevel(visor, 0.01, 2); assign(visor, metal_mat("visor", base=(0.004, 0.006, 0.006), rough=0.08, wear=False))
    backing = prism("visorglow", [(558,202),(609,200),(612,226),(561,231)], -0.545, -0.55)
    assign(backing, emit_mat("visorglow", "visor", ACCENT, 1.0, 0.05))
    top0, top1, bot0, bot1 = (562, 208), (600, 206), (566, 223), (603, 219)
    for k in range(5):
        t0, t1 = k / 5 + 0.012, (k + 1) / 5 - 0.012
        lerp = lambda a, b, t: (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        seg = [lerp(top0, top1, t0), lerp(top0, top1, t1), lerp(bot0, bot1, t1), lerp(bot0, bot1, t0)]
        assign(prism(f"eye{k}", seg, -0.56, -0.575), emit_mat(f"eye{k}", "eye", ACCENT, 9.0, 0.4))

    neck = prism("neck", [(196,372),(196,420),(384,420),(384,374)], -0.10, 0.12)
    assign(neck, metal_mat("neck", base=(0.03, 0.035, 0.04), rough=0.5, wear=False))
    rib_m = emit_mat("rib", "rib", ACCENT, 1.4, 0.06)
    for k in range(6):
        bpy.ops.mesh.primitive_cube_add(size=1, location=P(290, 384 + k * 6, -0.12), scale=(1.84, 0.02, 0.025))
        chassis_obj(bpy.context.active_object, plate_m)
        bpy.ops.mesh.primitive_cube_add(size=1, location=P(290, 384 + k * 6, -0.142), scale=(1.5, 0.006, 0.026))
        chassis_obj(bpy.context.active_object, rib_m)
    for r in (16, 9):
        pts = [P(340 + r * math.cos(2 * math.pi * i / 40), 336 + r * math.sin(2 * math.pi * i / 40), -0.575) for i in range(40)]
        pts.append(pts[0])
        tube(f"ear{r}", pts, 0.011, emit_mat(f"ear{r}", "ear", ACCENT, 1.4, 0.08), 2)

    GROUP["cur"] = "glass"
    bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64, radius=1.0, location=P(320, 164, 0.42), scale=(2.55, 0.95, 1.7))
    glass = bpy.context.active_object; glass["grp"] = "glass"
    boolean(glass, prism("gw", DOME, -1.5, 0.3, scale=1.002, center=(320, 170)), "INTERSECT")
    keep_front(glass)
    assign(glass, glass_mat("glass")); smooth(glass, 60)

    bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=48, radius=1.0, location=P(520, 306, 0.22), scale=(0.64, 0.26, 0.46))
    glass2 = bpy.context.active_object; glass2["grp"] = "glass"
    boolean(glass2, prism("gj", jaw_poly, -1.5, 0.3, scale=1.002, center=(520, 306)), "INTERSECT")
    keep_front(glass2)
    assign(glass2, glass_mat("glass2")); smooth(glass2, 60)

    GROUP["cur"] = "interior"
    bay = prism("bay", DOME, 0.1, 2.7, center=(320, 170)); open_front(bay, 0.15); assign(bay, inner_m)
    jawbay = prism("jawbay", jaw_poly, 0.1, 0.7); open_front(jawbay, 0.15); assign(jawbay, inner_m)
    back = prism("back", DOME, 2.7, 2.72, center=(320, 170))
    assign(back, emit_mat("backwall", "none", (0.02, 0.07, 0.06), 0.0))
    jback = prism("jback", jaw_poly, 0.7, 0.72)
    assign(jback, emit_mat("jback", "say", (0.02, 0.09, 0.07), 0.02))

    sock_bm = {z: bmesh.new() for z in ZONES}
    for z, (cx, cy) in ZONES.items():
        rx, ry = ZONE_R[z]
        anchors["zones"][z] = [cx, cy]; anchors["slots"][z] = []
        ring = bpy.data.curves.new(f"ring_{z}", "CURVE"); ring.dimensions = "3D"
        sp = ring.splines.new("POLY"); sp.points.add(47)
        for i in range(48):
            a = 2 * math.pi * i / 48
            p = P(cx + rx * math.cos(a), cy + ry * math.sin(a), 0.52)
            sp.points[i].co = (p.x, p.y, p.z, 1)
        sp.use_cyclic_u = True; ring.bevel_depth = 0.006; ring.bevel_resolution = 2
        link(bpy.data.objects.new(f"ring_{z}", ring)); ring.materials.append(emit_mat(f"ringm_{z}", z, TONE[z], 1.0))
        sp_, nslots, hro = (24, 7, 10) if z == "say" else (28, 19, 12)
        for k in range(nslots):
            dx, dy = slot(k, sp_)
            anchors["slots"][z].append([cx + dx, cy + dy])
            hex_ring(sock_bm[z], cx + dx, cy + dy, 0.55, hro, hro - 0.9)
    for z, b in sock_bm.items():
        o = new_mesh_obj(f"sockets_{z}", b); assign(o, emit_mat(f"sock_{z}", z, TONE[z], 0.45))

    fib_links = [("sense","think"),("sense","act"),("think","act"),("act","shell"),("think","delegate"),("shell","delegate"),("sense","shell"),("think","say"),("delegate","say"),("act","delegate")]
    sheath_m = mat("sheath"); n_ = sheath_m.node_tree.nodes
    if MASK:
        sg = n_.new("ShaderNodeBsdfTransparent")
    else:
        sg = n_.new("ShaderNodeBsdfGlass"); sg.inputs["Roughness"].default_value = 0.06; sg.inputs["IOR"].default_value = 1.25; sg.inputs["Color"].default_value = (0.8, 0.95, 0.9, 1)
    out_node(sheath_m.node_tree, sg)
    for k, (a_, b_) in enumerate(fib_links):
        pa = Vector((ZONES[a_][0], ZONES[a_][1], 0)); pb = Vector((ZONES[b_][0], ZONES[b_][1], 0))
        d = pb - pa; perp = Vector((-d.y, d.x, 0)).normalized()
        c1 = pa + d * 0.33 + perp * random.uniform(-70, 70); c2 = pa + d * 0.66 + perp * random.uniform(-70, 70)
        pts = bez(P(pa.x, pa.y, 0.95 + 0.2 * random.random()), P(c1.x, c1.y, random.uniform(1.3, 2.1)), P(c2.x, c2.y, random.uniform(1.3, 2.1)), P(pb.x, pb.y, 0.95 + 0.2 * random.random()), 40)
        t1 = TONE[a_]; t2 = TONE[b_]
        tube(f"fib{k}", pts, 0.006, emit_mat(f"fib{k}", "link", tuple((t1[i] + t2[i]) / 2 for i in range(3)), 1.6), 3)
        tube(f"fibs{k}", pts, 0.015, sheath_m, 4)
    for k in range(34):
        a_ = random.choice(list(ZONES)); b_ = random.choice(list(ZONES))
        pa = Vector((ZONES[a_][0] + random.uniform(-50, 50), ZONES[a_][1] + random.uniform(-40, 40), 0))
        pb = Vector((ZONES[b_][0] + random.uniform(-50, 50), ZONES[b_][1] + random.uniform(-40, 40), 0))
        if not (inside(DOME, pa.x, pa.y) and inside(DOME, pb.x, pb.y)) or a_ == b_:
            continue
        d0 = random.uniform(1.2, 2.3)
        d = pb - pa; perp = Vector((-d.y, d.x, 0)).normalized() * random.uniform(-40, 40)
        m1 = pa + d * 0.33 + perp; m2 = pa + d * 0.66 + perp
        pts = bez(P(pa.x, pa.y, d0), P(m1.x, m1.y, d0 + 0.5), P(m2.x, m2.y, d0 + 0.3), P(pb.x, pb.y, d0), 30)
        tube(f"den{k}", pts, 0.0028, emit_mat(f"denm{k}", "link", TONE[random.choice([a_, b_])], random.uniform(0.35, 0.9)), 2)

    bm = bmesh.new(); dust_cols = []

    def star(x, y, d, r, chan, tone, bright):
        start = len(bm.verts)
        res = bmesh.ops.create_icosphere(bm, subdivisions=1, radius=r)
        bmesh.ops.translate(bm, verts=res["verts"], vec=P(x, y, d))
        c = BASIS[MODE].get(chan, (0, 0, 0)) if MASK else tone
        dust_cols.append((start, len(bm.verts), tuple(v * bright for v in c)))

    for z, (cx, cy) in ZONES.items():
        rx, ry = ZONE_R[z]; tone = TONE[z]
        core = tuple(0.55 + 0.45 * tone[i] for i in range(3))
        for _ in range(260):
            star(cx + random.gauss(0, 6), cy + random.gauss(0, 5), (0.5 if z == "say" else 1.0) + random.gauss(0, 0.05), random.choice([0.004, 0.006, 0.008]), z, core, random.uniform(0.5, 0.8))
        for arm in range(2):
            for _ in range(620):
                u = random.random() ** 0.8
                r = 7 + 0.95 * rx * u
                th = arm * math.pi + 1.9 * math.log(r / 7) + random.gauss(0, 0.12)
                x = cx + r * math.cos(th) + random.gauss(0, 2.5 + 0.04 * r)
                y = cy + (ry / rx) * r * math.sin(th) + random.gauss(0, 2.5 + 0.04 * r)
                mix = min(1.0, u * 1.3)
                col = tuple((1 - mix) * 0.8 + mix * tone[i] for i in range(3))
                star(x, y, (0.5 if z == "say" else 1.0) + random.gauss(0, 0.05), random.choice([0.003, 0.004, 0.005, 0.006]), z, col, 0.9 - 0.65 * u)
        for _ in range(6):
            th = random.uniform(0, 2 * math.pi); r = random.uniform(8, rx * 0.8)
            star(cx + r * math.cos(th), cy + (ry / rx) * r * math.sin(th), 0.5 if z == "say" else 1.0, 0.012, z, tone, 0.9)
    for _ in range(900):
        x = random.uniform(120, 540); y = random.uniform(50, 320)
        if inside(DOME, x, y):
            star(x, y, random.uniform(1.6, 2.5), random.choice([0.003, 0.004, 0.005]), "star", random.choice([(1, 1, 1), (0.6, 0.9, 1.0), (0.7, 1.0, 0.85)]), random.uniform(0.2, 0.6))
    dust = new_mesh_obj("dust", bm)
    dm_ = mat("dustm"); dn = dm_.node_tree.nodes
    em = dn.new("ShaderNodeEmission"); em.inputs["Strength"].default_value = 1.0 if MASK else 6.0 * EMIT
    ca = dn.new("ShaderNodeAttribute"); ca.attribute_name = "Col"
    dm_.node_tree.links.new(ca.outputs["Color"], em.inputs["Color"])
    out_node(dm_.node_tree, em)
    dust.data.materials.append(dm_)
    cols = dust.data.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    for a, b, c in dust_cols:
        for i in range(a, b):
            cols.data[i].color = tuple(c) + (1.0,)

    rng = random.Random(3)
    for k in range(9):
        h = rng.uniform(0.12, 0.42)
        bpy.ops.mesh.primitive_cube_add(size=1, location=P(480 + k * 10, 316 - h * 20, 0.45), scale=(0.05, 0.03, h))
        o = bpy.context.active_object; o["grp"] = "interior"; assign(o, emit_mat("eq", "say", TONE["say"], 2.4))

    if not MASK:
        vol = prism("vol", DOME, 0.15, 2.65, scale=0.995, center=(320, 170))
        vm = mat("haze"); vn = vm.node_tree.nodes
        pv = vn.new("ShaderNodeVolumePrincipled"); pv.inputs["Density"].default_value = 0.09; pv.inputs["Anisotropy"].default_value = 0.45
        pv.inputs["Color"].default_value = (0.55, 1.0, 0.85, 1)
        vo = vn.new("ShaderNodeOutputMaterial"); vm.node_tree.links.new(pv.outputs[0], vo.inputs["Volume"])
        vol.data.materials.append(vm)

    sc.render.engine = "CYCLES"
    cyc = sc.cycles
    cyc.samples = SAMPLES; cyc.use_denoising = not MASK; cyc.denoiser = "OPENIMAGEDENOISE"
    cyc.max_bounces = 8; cyc.volume_bounces = 2; cyc.volume_step_rate = 1.5; cyc.glossy_bounces = 6; cyc.transmission_bounces = 8; cyc.transparent_max_bounces = 24
    if DEVICE == "gpu":
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "OPTIX"; prefs.get_devices()
        for d in prefs.devices:
            d.use = d.type == "OPTIX"
        cyc.device = "GPU"
    else:
        cyc.device = "CPU"
    sc.render.resolution_x = WIDTH; sc.render.resolution_y = int(round(WIDTH * 420 / 640)); sc.render.resolution_percentage = 100
    sc.render.film_transparent = TRANSPARENT
    sc.view_settings.view_transform = "Raw" if MASK else "AgX"
    sc.view_settings.look = "None"

    wd = bpy.data.worlds.new("w"); wd.use_nodes = True
    bg = wd.node_tree.nodes["Background"]; bg.inputs["Color"].default_value = (0.004, 0.009, 0.008, 1); bg.inputs["Strength"].default_value = 0.0 if MASK else 1.0
    sc.world = wd

    cam = bpy.data.cameras.new("cam"); cam.lens = 135; cam.sensor_width = 36
    co = bpy.data.objects.new("cam", cam); sc.collection.objects.link(co)
    co.location = (0, -23.6, 0); co.rotation_euler = (math.pi / 2, 0, 0); sc.camera = co

    def area(name, loc, rot, size, energy, color, strip=0):
        ld = bpy.data.lights.new(name, "AREA"); ld.energy = energy; ld.size = size; ld.color = color
        if strip:
            ld.shape = "RECTANGLE"; ld.size_y = strip
        lo = bpy.data.objects.new(name, ld); sc.collection.objects.link(lo)
        lo.location = loc; lo.rotation_euler = rot; lo.visible_camera = False
    if not MASK:
        area("key", (-3.4, -5.0, 4.2), (math.radians(62), 0, math.radians(-34)), 0.9, 420, (1.0, 0.97, 0.92), 7.0)
        if MODE != "glass":
            area("rimR", (6.0, 1.0, 1.0), (math.radians(90), 0, math.radians(90)), 4.0, 700, (0.4, 1.0, 0.8))
            area("rimL", (-6.0, 1.0, 1.5), (math.radians(90), 0, math.radians(-90)), 4.0, 500, (0.45, 0.7, 1.0))
            area("top", (0.5, -1.5, 5.5), (0, 0, 0), 5.0, 600, (0.9, 1.0, 1.0))
        for z, (cx, cy) in ZONES.items():
            ld = bpy.data.lights.new(f"zl_{z}", "POINT"); ld.energy = 16 * EMIT ** 0.5; ld.color = TONE[z]; ld.shadow_soft_size = 0.001
            lo = bpy.data.objects.new(f"zl_{z}", ld); sc.collection.objects.link(lo); lo.location = P(cx, cy, 0.9)

    for ob in bpy.data.objects:
        if ob.get("grp") is not None:
            ob.visible_camera = ob["grp"] in VISIBLE
    return anchors


def main():
    anchors = build()
    sc = bpy.context.scene
    sc.render.filepath = OUT
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_depth = "16" if MASK else "8"
    sc.render.image_settings.color_mode = "RGB" if MASK else "RGBA"
    json.dump(anchors, open(os.path.splitext(OUT)[0] + ".anchors.json", "w"))
    bpy.ops.render.render(write_still=True)
    print("RENDERED", MODE, OUT)


main()
