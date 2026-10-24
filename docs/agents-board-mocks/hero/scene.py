import math
import random
import sys

import bpy
from mathutils import Vector

out, width, height, samples = sys.argv[sys.argv.index("--") + 1 :][:4]
width, height, samples = int(width), int(height), int(samples)

LIVE = (0.12, 0.85, 0.42)
ATTENTION = (1.0, 0.62, 0.1)
QUIET = (0.55, 0.56, 0.62)
CENTER = Vector((0.0, 0.0, 1.7))

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.render.resolution_x = width
scene.render.resolution_y = height
scene.render.resolution_percentage = 100
scene.render.filepath = out
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_depth = "8"
scene.view_settings.view_transform = "Standard"

cycles = scene.cycles
cycles.device = "GPU"
cycles.samples = samples
cycles.use_denoising = True
cycles.denoiser = "OPENIMAGEDENOISE"
cycles.max_bounces = 10
cycles.transmission_bounces = 10
cycles.glossy_bounces = 4
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "OPTIX"
prefs.get_devices()
for device in prefs.devices:
    device.use = device.type != "CPU"

world = bpy.data.worlds.new("world")
scene.world = world
world.use_nodes = True
background = world.node_tree.nodes["Background"]
background.inputs["Color"].default_value = (0.004, 0.004, 0.010, 1)
background.inputs["Strength"].default_value = 0.25


def material(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    return mat, mat.node_tree.nodes["Principled BSDF"]


def emissive(name, color, strength, shaded=True):
    mat, bsdf = material(name)
    bsdf.inputs["Base Color"].default_value = (0, 0, 0, 1)
    bsdf.inputs["Roughness"].default_value = 0.35
    bsdf.inputs["Emission Strength"].default_value = strength
    if not shaded:
        bsdf.inputs["Emission Color"].default_value = (*color, 1)
        return mat
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    weight = nodes.new("ShaderNodeLayerWeight")
    weight.inputs["Blend"].default_value = 0.5
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (*color, 1)
    ramp.color_ramp.elements[1].position = 1.0
    ramp.color_ramp.elements[1].color = (*[c * 0.28 for c in color], 1)
    links.new(weight.outputs["Facing"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Emission Color"])
    return mat


def glass(name, tint):
    mat, bsdf = material(name)
    bsdf.inputs["Base Color"].default_value = (*tint, 1)
    bsdf.inputs["Roughness"].default_value = 0.02
    bsdf.inputs["IOR"].default_value = 1.45
    bsdf.inputs["Transmission Weight"].default_value = 1.0
    return mat


def smooth(obj):
    polygons = obj.data.polygons
    polygons.foreach_set("use_smooth", [True] * len(polygons))
    obj.data.update()


def sphere(name, location, radius, mat, segments=64):
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=segments, ring_count=segments // 2, radius=radius, location=location
    )
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(mat)
    smooth(obj)
    return obj


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


floor_mat, floor_bsdf = material("floor")
floor_bsdf.inputs["Base Color"].default_value = (0.012, 0.012, 0.02, 1)
floor_bsdf.inputs["Roughness"].default_value = 0.16
bpy.ops.mesh.primitive_plane_add(size=80, location=(0, 0, 0))
floor = bpy.context.active_object
floor.data.materials.append(floor_mat)

sphere("session-shell", CENTER, 1.55, glass("session-glass", mix((1, 1, 1), LIVE, 0.1)), 96)
sphere("session-core", CENTER, 0.78, emissive("session-core", LIVE, 1.6), 48)

orbit = bpy.data.curves.new("orbit", "CURVE")
orbit.dimensions = "3D"
orbit.bevel_depth = 0.008
orbit.bevel_resolution = 2
ring = orbit.splines.new("NURBS")
count = 48
ring.points.add(count - 1)
for index, point in enumerate(ring.points):
    angle = index / count * math.tau
    point.co = (math.cos(angle) * 4.3, math.sin(angle) * 1.1 - 0.0, CENTER.z + math.sin(angle) * 0.35, 1)
ring.use_cyclic_u = True
ring.order_u = 4
orbit_obj = bpy.data.objects.new("orbit", orbit)
scene.collection.objects.link(orbit_obj)
orbit_mat = emissive("orbit", QUIET, 0.22, False)
orbit.materials.append(orbit_mat)

satellites = [
    ("working", math.radians(193), LIVE, 0.42, 1.8, 3.0),
    ("needs-you", math.radians(337), ATTENTION, 0.5, 1.9, 3.6),
    ("settled", math.radians(24), QUIET, 0.34, 0.9, 2.1),
    ("working-b", math.radians(152), LIVE, 0.26, 1.6, 2.3),
]
for name, angle, color, radius, glow, _ in satellites:
    pos = Vector(
        (math.cos(angle) * 4.3, math.sin(angle) * 1.1, CENTER.z + math.sin(angle) * 0.35)
    )
    sphere(name, pos, radius, emissive(name, color, glow), 48)
    if name == "needs-you":
        bpy.ops.mesh.primitive_torus_add(
            major_radius=radius * 1.75, minor_radius=0.028, location=pos,
            rotation=(math.radians(78), 0, math.radians(8)),
        )
        halo = bpy.context.active_object
        halo.data.materials.append(emissive("halo", color, 2.2, False))
        smooth(halo)
    tether = bpy.data.curves.new(name + "-tether", "CURVE")
    tether.dimensions = "3D"
    tether.bevel_depth = 0.016
    tether.bevel_resolution = 2
    line = tether.splines.new("POLY")
    line.points.add(1)
    start = CENTER + (pos - CENTER).normalized() * 1.5
    end = pos - (pos - CENTER).normalized() * radius
    line.points[0].co = (*start, 1)
    line.points[1].co = (*end, 1)
    tether_obj = bpy.data.objects.new(name + "-tether", tether)
    scene.collection.objects.link(tether_obj)
    tether.materials.append(emissive(name + "-t", mix(color, (0.3, 0.3, 0.35), 0.4), 0.8 if name != "settled" else 0.25, False))

random.seed(7)
for i in range(30):
    pos = Vector((random.uniform(-11, 11), random.uniform(3, 14), random.uniform(0.4, 6.5)))
    color = random.choice((LIVE, ATTENTION, (0.8, 0.85, 1.0)))
    sphere(f"dust-{i}", pos, random.uniform(0.035, 0.08), emissive(f"dust-{i}", color, random.uniform(0.9, 2.2), False), 12)


def aim(obj, target, up="UP_Y"):
    constraint = obj.constraints.new("TRACK_TO")
    constraint.target = target
    constraint.track_axis = "TRACK_NEGATIVE_Z"
    constraint.up_axis = up


focus = bpy.data.objects.new("focus", None)
focus.location = (0, 0, 1.6)
scene.collection.objects.link(focus)


def area(name, location, size, energy, color):
    light = bpy.data.lights.new(name, "AREA")
    light.shape = "RECTANGLE"
    light.size = size
    light.size_y = size * 0.5
    light.energy = energy
    light.color = color
    obj = bpy.data.objects.new(name, light)
    obj.location = location
    scene.collection.objects.link(obj)
    aim(obj, focus)


area("top", (0, -2, 9), 9, 380, (0.75, 0.8, 1.0))
area("rim-a", (-10, -5, 3.2), 5, 230, LIVE)
area("rim-b", (10, -5, 3.2), 5, 230, ATTENTION)

cam_data = bpy.data.cameras.new("camera")
cam_data.lens = 30
cam_data.sensor_fit = "HORIZONTAL"
cam_data.dof.use_dof = True
cam_data.dof.focus_object = focus
cam_data.dof.aperture_fstop = 3.0
camera = bpy.data.objects.new("camera", cam_data)
camera.location = (0, -15.5, 3.0)
scene.collection.objects.link(camera)
aim(camera, focus)
scene.camera = camera

bpy.ops.render.render(write_still=True)
