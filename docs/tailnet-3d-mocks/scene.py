"""Concept render of a Tailscode network window: every machine on the tailnet as a small 3D model.

blender -b --python scene.py -- <landscape|portrait> <width> <height> <samples> <out.png> [orbit degrees] [pulse phase]
"""
import math
import sys

import bpy
from mathutils import Vector

ARGS = sys.argv[sys.argv.index("--") + 1:]
LAYOUT, WIDTH, HEIGHT, SAMPLES, OUT = ARGS[0], int(ARGS[1]), int(ARGS[2]), int(ARGS[3]), ARGS[4]
ORBIT = math.radians(float(ARGS[5])) if len(ARGS) > 5 else 0.0
PHASE = float(ARGS[6]) if len(ARGS) > 6 else 0.0
PORTRAIT = LAYOUT == "portrait"
bpy.ops.wm.read_factory_settings(use_empty=True)

CANVAS = (0.0018, 0.0027, 0.0060)
TEAL = (0.26, 0.82, 0.86)
AMBER = (1.0, 0.62, 0.18)
BLUE = (0.10, 0.45, 1.0)
VIOLET = (0.48, 0.27, 1.0)
GREEN = (0.12, 0.74, 0.26)
CLAUDE = (0.70, 0.19, 0.10)
GHOST = (0.20, 0.26, 0.36)
WHITE = (0.85, 0.89, 0.95)
FONT_BOLD = "/usr/share/fonts/noto/NotoSans-Bold.ttf"
FONT_REGULAR = "/usr/share/fonts/noto/NotoSans-Regular.ttf"

MACHINES = [
    dict(name="studio", kind="tower", state="working", line="2 working · local model 179 tok/s", role="host", agents=[CLAUDE, BLUE, GREEN]),
    dict(name="laptop", kind="laptop", state="needs", line="1 needs you", role="host", agents=[CLAUDE, VIOLET]),
    dict(name="phone", kind="phone", state="here", line="this iPhone", role="screen"),
    dict(name="tablet", kind="tablet", state="idle", line="watching studio", role="screen"),
    dict(name="tablet-mini", kind="tablet", state="idle", line="online", role="screen"),
    dict(name="old-phone", kind="phone", state="idle", line="online", role="screen"),
    dict(name="tv", kind="puck", state="idle", line="online", role="screen"),
    dict(name="handheld", kind="handheld", state="off", line="offline", role="far"),
    dict(name="gaming-laptop", kind="laptop", state="off", line="offline", role="far"),
    dict(name="travel-laptop", kind="laptop", state="off", line="offline", role="far"),
    dict(name="gaming-pc", kind="tower", state="off", line="offline", role="far"),
    dict(name="spare-phone", kind="phone", state="off", line="offline", role="far"),
    dict(name="spare-tablet", kind="tablet", state="off", line="offline", role="far"),
]
STATE_COLOR = {"working": TEAL, "needs": AMBER, "here": BLUE, "idle": WHITE, "off": GHOST}


def material(name, color, metallic=0.0, roughness=0.5, emission=None, strength=0.0, alpha=1.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    values = {"Base Color": (*color, 1.0), "Metallic": metallic, "Roughness": roughness, "Alpha": alpha}
    if emission:
        values["Emission Color"] = (*emission, 1.0)
        values["Emission Strength"] = strength
    for key, value in values.items():
        if key in bsdf.inputs:
            bsdf.inputs[key].default_value = value
    return mat


def glow(name, color, strength):
    return material(name, (0, 0, 0), roughness=0.4, emission=color, strength=strength)


BODY = material("body", (0.10, 0.11, 0.13), metallic=0.9, roughness=0.32)
BODY_DARK = material("body-dark", (0.025, 0.028, 0.035), metallic=0.6, roughness=0.4)
GLASS = material("glass", (0.01, 0.012, 0.018), metallic=0.0, roughness=0.06)
SCREEN_OFF = material("screen-off", (0.004, 0.005, 0.008), roughness=0.12)
GHOST_MAT = glow("ghost", GHOST, 0.9)


def box(name, size, location, mat, bevel=0.03, parent=None, rotation=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location, rotation=rotation)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 4
        mod.limit_method = "ANGLE"
    for poly in obj.data.polygons:
        poly.use_smooth = True
    obj.data.materials.append(mat)
    if parent:
        obj.parent = parent
    return obj


def cylinder(name, radius, depth, location, mat, parent=None, rotation=(0, 0, 0), vertices=64):
    bpy.ops.mesh.primitive_cylinder_add(radius=radius, depth=depth, location=location, rotation=rotation, vertices=vertices)
    obj = bpy.context.active_object
    obj.name = name
    for poly in obj.data.polygons:
        poly.use_smooth = True
    obj.data.materials.append(mat)
    if parent:
        obj.parent = parent
    return obj


def torus(name, major, minor, location, mat, parent=None, rotation=(0, 0, 0)):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor, location=location, rotation=rotation, major_segments=128, minor_segments=12)
    obj = bpy.context.active_object
    obj.name = name
    for poly in obj.data.polygons:
        poly.use_smooth = True
    obj.data.materials.append(mat)
    if parent:
        obj.parent = parent
    return obj


def empty(name, location):
    obj = bpy.data.objects.new(name, None)
    obj.location = location
    bpy.context.collection.objects.link(obj)
    return obj


def screen_material(machine):
    color = STATE_COLOR[machine["state"]]
    if machine["state"] == "off":
        return SCREEN_OFF
    if machine["state"] == "idle":
        return glow(f"screen-{machine['name']}", (0.03, 0.05, 0.10), 1.0)
    return glow(f"screen-{machine['name']}", tuple(c * 0.5 for c in color), 1.3)


def code_rows(parent, origin, width, height, normal_axis, color, rows=6):
    """Thin bright bars on a screen so it reads as a transcript, not a lamp."""
    mat = glow(f"rows-{parent.name}", color, 3.2)
    for i in range(rows):
        length = width * (0.35 + 0.5 * ((i * 37) % 10) / 10)
        z = origin[2] + height * (0.36 - i * 0.14)
        if normal_axis == "y":
            box(f"row{i}", (length, 0.004, height * 0.035), (origin[0] - (width - length) / 2 * 0.85, origin[1], z), mat, bevel=0, parent=parent)


def laptop(machine, root):
    box("base", (1.5, 1.0, 0.07), (0, 0, 0.035), BODY, parent=root)
    box("keys", (1.3, 0.55, 0.01), (0, 0.12, 0.075), BODY_DARK, bevel=0, parent=root)
    hinge = empty("hinge", (0, 0.5, 0.07))
    hinge.parent = root
    hinge.rotation_euler = (math.radians(-14), 0, 0)
    box("lid", (1.5, 0.05, 1.0), (0, 0, 0.5), BODY, parent=hinge)
    box("panel", (1.4, 0.012, 0.88), (0, -0.03, 0.5), screen_material(machine), bevel=0, parent=hinge)
    if machine["state"] != "off":
        code_rows(hinge, (0, -0.04, 0.5), 1.2, 0.88, "y", WHITE)


def tower(machine, root):
    box("case", (0.95, 1.9, 2.0), (0, 0, 1.0), BODY, bevel=0.05, parent=root)
    box("glass", (0.02, 1.6, 1.7), (-0.48, 0, 1.02), GLASS, bevel=0, parent=root)
    on = machine["state"] != "off"
    accent = STATE_COLOR[machine["state"]]
    gpu = glow(f"gpu-{machine['name']}", GREEN if on else GHOST, 4.0 if on else 0.2)
    box("gpu", (0.03, 1.25, 0.16), (-0.495, 0.05, 0.92), gpu, bevel=0, parent=root)
    box("gpu-body", (0.5, 1.3, 0.3), (-0.2, 0.05, 0.92), BODY_DARK, bevel=0.01, parent=root)
    ring = glow(f"fan-{machine['name']}", accent, 3.2 if on else 0.2)
    for z in (0.55, 1.05, 1.55):
        torus("fan", 0.19, 0.016, (0, -0.955, z), ring, parent=root, rotation=(math.radians(90), 0, 0))
    box("strip", (0.7, 0.02, 0.025), (0, -0.955, 1.86), ring, bevel=0, parent=root)


def slab(machine, root, width, height, lean):
    stand = empty("stand", (0, 0, 0.02))
    stand.parent = root
    stand.rotation_euler = (math.radians(lean), 0, 0)
    box("frame", (width, 0.06, height), (0, 0, height / 2), BODY, bevel=0.028, parent=stand)
    box("panel", (width * 0.93, 0.012, height * 0.95), (0, -0.031, height / 2), screen_material(machine), bevel=0, parent=stand)
    if machine["state"] != "off":
        code_rows(stand, (0, -0.04, height / 2), width * 0.8, height * 0.8, "y", WHITE, rows=5)


def handheld(machine, root):
    stand = empty("stand", (0, 0, 0.02))
    stand.parent = root
    stand.rotation_euler = (math.radians(-22), 0, 0)
    box("body", (1.7, 0.16, 0.66), (0, 0, 0.36), BODY, bevel=0.07, parent=stand)
    for x in (-0.83, 0.83):
        box("grip", (0.3, 0.26, 0.7), (x, 0.03, 0.34), BODY, bevel=0.12, parent=stand)
    box("panel", (1.02, 0.012, 0.56), (0, -0.082, 0.37), screen_material(machine), bevel=0, parent=stand)
    for x in (-0.66, 0.66):
        cylinder("stick", 0.07, 0.06, (x, -0.1, 0.5), BODY_DARK, parent=stand, rotation=(math.radians(90), 0, 0))


def puck(machine, root):
    box("puck", (0.8, 0.8, 0.26), (0, 0, 0.13), BODY, bevel=0.1, parent=root)
    box("led", (0.05, 0.012, 0.02), (0, -0.4, 0.1), glow("led", WHITE, 5.0), bevel=0, parent=root)


BUILDERS = {
    "laptop": (laptop, 1.0),
    "tower": (tower, 1.0),
    "phone": (lambda m, r: slab(m, r, 0.5, 1.02, -12), 1.0),
    "tablet": (lambda m, r: slab(m, r, 1.25, 0.9, -16), 1.0),
    "handheld": (handheld, 1.0),
    "puck": (puck, 1.0),
}
HEIGHT_OF = {"laptop": 1.1, "tower": 2.05, "phone": 1.05, "tablet": 0.95, "handheld": 0.75, "puck": 0.3}


def ghostify(root):
    """An offline machine is its own outline, so the eye skips it until it comes back."""
    for child in root.children_recursive:
        if child.type != "MESH":
            continue
        child.data.materials.clear()
        child.data.materials.append(GHOST_MAT)
        for mod in list(child.modifiers):
            child.modifiers.remove(mod)
        wire = child.modifiers.new("wire", "WIREFRAME")
        wire.thickness = 0.012


def text(body, location, size, color, strength, camera, font=FONT_REGULAR, align="CENTER"):
    curve = bpy.data.curves.new("label", "FONT")
    curve.body = body
    curve.size = size
    curve.align_x = align
    curve.font = bpy.data.fonts.load(font, check_existing=True)
    obj = bpy.data.objects.new("label", curve)
    obj.location = location
    obj.data.materials.append(glow("label-mat", color, strength))
    bpy.context.collection.objects.link(obj)
    follow = obj.constraints.new("COPY_ROTATION")
    follow.target = camera
    return obj


def arc(start, end, lift, color, strength, radius, pulses=0):
    curve = bpy.data.curves.new("link", "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = radius
    curve.bevel_resolution = 6
    curve.resolution_u = 48
    spline = curve.splines.new("BEZIER")
    spline.bezier_points.add(1)
    a, b = Vector(start), Vector(end)
    up = Vector((0, 0, lift))
    for point, here, other in ((spline.bezier_points[0], a, b), (spline.bezier_points[1], b, a)):
        point.co = here
        toward = here + (other - here) * 0.33 + up
        away = here - (other - here) * 0.33 - up
        point.handle_left, point.handle_right = (away, toward) if here is a else (toward, away)
    obj = bpy.data.objects.new("link", curve)
    obj.data.materials.append(glow("link-mat", color, strength))
    bpy.context.collection.objects.link(obj)
    for i in range(pulses):
        t = ((i + 0.6) / (pulses + 0.4) + PHASE) % 1.0
        p0, p1, p2, p3 = a, a + (b - a) * 0.33 + up, b + (a - b) * 0.33 + up, b
        at = ((1 - t) ** 3) * p0 + 3 * ((1 - t) ** 2) * t * p1 + 3 * (1 - t) * t * t * p2 + (t ** 3) * p3
        bpy.ops.mesh.primitive_uv_sphere_add(radius=radius * 3.4, location=at, segments=24, ring_count=12)
        bead = bpy.context.active_object
        bead.data.materials.append(glow("pulse", color, strength * 3.2))


def placements():
    if PORTRAIT:
        return {
            "studio": (-1.6, 5.2), "laptop": (2.0, 0.8), "phone": (0.2, -4.6),
            "tablet": (-2.9, -1.6), "tablet-mini": (-2.4, -7.6), "old-phone": (2.6, -7.8), "tv": (3.1, -3.6),
            "handheld": (-5.0, 17.0), "gaming-laptop": (-3.1, 19.6), "travel-laptop": (-1.0, 21.0),
            "gaming-pc": (1.2, 21.0), "spare-phone": (3.2, 19.6), "spare-tablet": (5.0, 17.2),
        }
    sx, sy = 1.2, 0.8
    spots = {"studio": (-2.3 * sx, 2.2 * sy), "laptop": (2.6 * sx, 1.6 * sy), "phone": (0.2 * sx, -5.4 * sy)}
    front = {"tablet": 214, "tablet-mini": 244, "old-phone": 300, "tv": 328}
    for name, degrees in front.items():
        angle = math.radians(degrees)
        spots[name] = (6.6 * sx * math.cos(angle), 6.2 * sy * math.sin(angle))
    back = {"handheld": 172, "gaming-laptop": 156, "travel-laptop": 140, "gaming-pc": 44, "spare-phone": 27, "spare-tablet": 10}
    for name, degrees in back.items():
        angle = math.radians(degrees)
        spots[name] = (8.6 * sx * math.cos(angle), 8.9 * sy * math.sin(angle))
    return spots


def stage():
    floor = material("floor", (0.004, 0.005, 0.009), metallic=0.0, roughness=0.3)
    bpy.ops.mesh.primitive_plane_add(size=400, location=(0, 0, 0))
    bpy.context.active_object.data.materials.append(floor)
    sx, sy = (0.52, 1.5) if PORTRAIT else (1.2, 0.8)
    ring_mat = glow("ring", (0.08, 0.17, 0.38), 0.45)
    for radius in (3.6, 6.4, 8.8):
        ring = torus("orbit", radius, 0.01, (0, 0, 0.012), ring_mat)
        ring.scale = (sx, sy, 1)


def build():
    scene = bpy.context.scene
    world = bpy.data.worlds.new("world")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (*CANVAS, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    scene.world = world

    camera = bpy.data.objects.new("camera", bpy.data.cameras.new("camera"))
    bpy.context.collection.objects.link(camera)
    scene.camera = camera
    if PORTRAIT:
        camera.location, look, camera.data.lens = (0.0, -26.0, 20.0), Vector((0, 2.4, 0.8)), 45
    else:
        camera.location, look, camera.data.lens = (0.0, -22.5, 13.0), Vector((0, 0.1, 1.3)), 43
    swing = Vector(camera.location) - look
    camera.location = look + Vector((swing.x * math.cos(ORBIT) - swing.y * math.sin(ORBIT), swing.x * math.sin(ORBIT) + swing.y * math.cos(ORBIT), swing.z))
    camera.rotation_euler = (look - Vector(camera.location)).to_track_quat("-Z", "Y").to_euler()
    camera.data.dof.use_dof = True
    camera.data.dof.focus_distance = (look - Vector(camera.location)).length
    camera.data.dof.aperture_fstop = 5.6

    for name, location, energy, color, size in (
        ("key", (-7, -9, 13), 5200, (0.72, 0.84, 1.0), 9),
        ("rim", (10, 9, 7), 2600, (1.0, 0.72, 0.45), 7),
        ("fill", (0, -14, 4), 1500, (0.6, 0.7, 1.0), 12),
    ):
        light = bpy.data.objects.new(name, bpy.data.lights.new(name, "AREA"))
        light.data.energy, light.data.color, light.data.size = energy, color, size
        light.location = location
        light.visible_glossy = False
        light.rotation_euler = (Vector((0, 0, 0.8)) - Vector(location)).to_track_quat("-Z", "Y").to_euler()
        bpy.context.collection.objects.link(light)

    stage()
    spots = placements()
    tops = {}
    for machine in MACHINES:
        x, y = spots[machine["name"]]
        scale = {"studio": 1.5, "laptop": 1.45}.get(machine["name"], 1.0 if machine["role"] == "screen" else (1.1 if PORTRAIT else 0.85))
        root = empty(machine["name"], (x, y, 0))
        builder, _ = BUILDERS[machine["kind"]]
        builder(machine, root)
        root.scale = (scale, scale, scale)
        facing = math.atan2(-22.5 - y, 0 - x) + math.radians(90)
        root.rotation_euler = (0, 0, facing * 0.55 + (math.radians(-28) if machine["kind"] == "tower" else 0))
        color = STATE_COLOR[machine["state"]]
        height = HEIGHT_OF[machine["kind"]] * scale
        tops[machine["name"]] = (x, y, height)
        if machine["state"] == "off":
            ghostify(root)
        else:
            lit = machine["state"] in ("working", "needs", "here")
            reach = scale * {"tower": 1.3, "laptop": 1.3, "tablet": 0.95, "handheld": 1.2}.get(machine["kind"], 0.62)
            torus("pad", reach, 0.014, (x, y, 0.02), glow("pad-mat", color, 2.6 if lit else 0.35))
        big = machine["role"] == "host"
        reach = scale * {"tower": 1.3, "laptop": 1.3, "tablet": 0.95, "handheld": 1.2}.get(machine["kind"], 0.62)
        size = 0.5 if big else (0.36 if machine["role"] == "screen" else (0.46 if PORTRAIT else 0.32))
        label_color = color if machine["state"] in ("working", "needs", "here") else (WHITE if machine["state"] == "idle" else GHOST)
        if machine["role"] == "screen":
            front = y - reach - 1.3
            name_at, line_at = (x, front, 0.5), (x, front, 0.1)
        elif machine["role"] == "host":
            name_at, line_at = (x, y, height + size * 2.3), (x, y, height + size * 1.25)
        else:
            name_at, line_at = (x, y, height + size * 1.75), (x, y, height + size * 0.72)
        text(machine["name"], name_at, size, WHITE if machine["state"] != "off" else GHOST, 1.5 if machine["state"] != "off" else 1.3, camera, FONT_BOLD)
        text(machine["line"], line_at, size * 0.62, label_color, 2.0 if machine["state"] != "off" else 1.0, camera)
        for i, agent in enumerate(machine.get("agents", [])):
            count = len(machine["agents"])
            ox = (i - (count - 1) / 2) * 0.62
            bpy.ops.mesh.primitive_uv_sphere_add(radius=0.17, location=(x + ox, y, height + size * 3.75), segments=32, ring_count=16)
            orb = bpy.context.active_object
            for poly in orb.data.polygons:
                poly.use_smooth = True
            orb.data.materials.append(glow("agent", agent, 2.4))

    def anchor(name):
        x, y, height = tops[name]
        return (x, y - 0.35, height * 0.62) if name in ("studio", "laptop") else (x, y, height * 0.96)

    arc(anchor("studio"), anchor("phone"), 1.5, TEAL, 2.4, 0.02, pulses=3)
    arc(anchor("studio"), anchor("tablet"), 1.3, TEAL, 2.4, 0.02, pulses=2)
    arc(anchor("laptop"), anchor("phone"), 1.3, AMBER, 2.6, 0.02, pulses=1)
    arc(anchor("studio"), anchor("laptop"), 0.9, VIOLET, 2.4, 0.016, pulses=2)

    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for kind in ("OPTIX", "CUDA"):
        try:
            prefs.compute_device_type = kind
            prefs.get_devices()
            usable = [d for d in prefs.devices if d.type == kind]
            if usable:
                for device in prefs.devices:
                    device.use = device.type == kind
                scene.cycles.device = "GPU"
                print("RENDER DEVICE", kind, [d.name for d in usable])
                break
        except Exception as error:
            print("device", kind, error)
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = True
    scene.render.resolution_x, scene.render.resolution_y = WIDTH, HEIGHT
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_depth = "16"
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.render.filepath = OUT
    bpy.ops.render.render(write_still=True)


build()
