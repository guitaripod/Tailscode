import math
import random
import sys

import bpy
from mathutils import Vector

out, width, height, samples = sys.argv[sys.argv.index("--") + 1 :][:4]
width, height, samples = int(width), int(height), int(samples)

CORAL = (1.0, 0.36, 0.16)
VIOLET = (0.5, 0.3, 1.0)
A_POS = Vector((-4.7, 0.0, 1.6))
B_POS = Vector((4.7, 0.0, 1.6))
SPHERE_R = 1.55

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
    ramp.color_ramp.elements[0].color = (*[c * 1.0 for c in color], 1)
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

for name, pos, color in (("a", A_POS, CORAL), ("b", B_POS, VIOLET)):
    sphere(f"{name}-shell", pos, SPHERE_R, glass(f"{name}-glass", mix((1, 1, 1), color, 0.12)), 96)
    sphere(f"{name}-core", pos, 0.72, emissive(f"{name}-core", color, 1.6), 48)

path = []
carried = 6
for i in range(carried):
    s = i / (carried - 1)
    x = -2.85 + s * 5.7
    z = A_POS.z + 0.35 + 1.25 * math.sin(math.pi * s) - 0.35 * s
    y = -0.25 * math.sin(math.pi * s * 1.5)
    path.append(Vector((x, y, z)))

for i, point in enumerate(path):
    s = i / (carried - 1)
    color = mix(CORAL, VIOLET, s)
    sphere(f"bead-{i}", point, 0.2, emissive(f"bead-{i}", color, 1.5), 40)

curve = bpy.data.curves.new("thread", "CURVE")
curve.dimensions = "3D"
curve.bevel_depth = 0.022
curve.bevel_resolution = 3
spline = curve.splines.new("NURBS")
spline.points.add(len(path) + 1)
points = [A_POS + Vector((SPHERE_R * 0.7, 0, 0.1))] + path + [B_POS - Vector((SPHERE_R * 0.7, 0, -0.1))]
spline.points.add(len(points) - len(spline.points))
for point, vec in zip(spline.points, points):
    point.co = (vec.x, vec.y, vec.z, 1)
spline.order_u = 4
spline.use_endpoint_u = True
thread = bpy.data.objects.new("thread", curve)
scene.collection.objects.link(thread)
thread_mat, thread_bsdf = material("thread")
nodes = thread_mat.node_tree.nodes
links = thread_mat.node_tree.links
coords = nodes.new("ShaderNodeTexCoord")
ramp = nodes.new("ShaderNodeValToRGB")
separate = nodes.new("ShaderNodeSeparateXYZ")
links.new(coords.outputs["Generated"], separate.inputs["Vector"])
links.new(separate.outputs["X"], ramp.inputs["Fac"])
ramp.color_ramp.elements[0].color = (*CORAL, 1)
ramp.color_ramp.elements[1].color = (*VIOLET, 1)
links.new(ramp.outputs["Color"], thread_bsdf.inputs["Emission Color"])
thread_bsdf.inputs["Emission Strength"].default_value = 0.9
thread_bsdf.inputs["Base Color"].default_value = (0, 0, 0, 1)
curve.materials.append(thread_mat)

random.seed(11)
dropped = 8
for i in range(dropped):
    angle = math.radians(188 + i * 21 + random.uniform(-5, 5))
    radius = 2.55 + 0.18 * i + random.uniform(-0.1, 0.1)
    pos = A_POS + Vector((math.cos(angle) * radius, random.uniform(-0.3, 0.5), math.sin(angle) * radius * 0.7 + 0.2))
    pos.z = max(pos.z, 0.14)
    fade = 1.0 - i / dropped
    sphere(f"old-{i}", pos, 0.07 + 0.06 * fade, emissive(f"old-{i}", mix((0.5, 0.45, 0.5), CORAL, 0.35), 0.1 + 0.6 * fade), 24)

for i in range(34):
    pos = Vector((random.uniform(-11, 11), random.uniform(3, 14), random.uniform(0.4, 6.5)))
    color = random.choice((CORAL, VIOLET, (0.8, 0.85, 1.0)))
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
    return obj


area("top", (0, -2, 9), 9, 380, (0.75, 0.8, 1.0))
area("rim-a", (-10, -5, 3.2), 5, 260, CORAL)
area("rim-b", (10, -5, 3.2), 5, 260, VIOLET)

cam_data = bpy.data.cameras.new("camera")
cam_data.lens = 30
cam_data.sensor_fit = "HORIZONTAL"
cam_data.shift_x = 0.0
cam_data.dof.use_dof = True
cam_data.dof.focus_object = focus
cam_data.dof.aperture_fstop = 3.0
camera = bpy.data.objects.new("camera", cam_data)
camera.location = (0, -15.5, 3.0)
scene.collection.objects.link(camera)
aim(camera, focus)
scene.camera = camera

bpy.ops.render.render(write_still=True)
