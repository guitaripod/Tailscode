import math
import random
import sys

import bpy
from mathutils import Vector

out, width, height, samples = sys.argv[sys.argv.index("--") + 1 :][:4]
width, height, samples = int(width), int(height), int(samples)

HUES = [
    (1.0, 0.42, 0.2),
    (0.5, 0.3, 1.0),
    (0.1, 0.8, 0.95),
    (0.2, 0.85, 0.4),
    (0.25, 0.5, 1.0),
]
SPACING = 3.15
ROW_Z = 1.2

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


def glass(name, tint, roughness=0.02):
    mat, bsdf = material(name)
    bsdf.inputs["Base Color"].default_value = (*tint, 1)
    bsdf.inputs["Roughness"].default_value = roughness
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


def torus(name, location, major, minor, mat, rotation=(math.radians(90), 0, 0)):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=major, minor_radius=minor, location=location, rotation=rotation
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
bpy.context.active_object.data.materials.append(floor_mat)

seam = emissive("seam", (0.95, 0.96, 1.0), 1.4, False)
for index in range(6):
    x = (index - 2.5) * SPACING
    center = Vector((x, 0.0, ROW_Z))
    filled = index < 5
    radius = 1.18
    if filled:
        color = HUES[index]
        sphere(f"shell-{index}", center, radius, glass(f"glass-{index}", mix((1, 1, 1), color, 0.1)), 80)
        sphere(f"core-{index}", center, radius * 0.62, emissive(f"core-{index}", color, 1.5), 48)
        torus(f"seam-{index}", center, radius * 0.995, 0.034, seam)
        button = center + Vector((0, -radius * 0.98, 0))
        sphere(f"button-{index}", button, 0.2, emissive(f"button-{index}", mix(color, (1, 1, 1), 0.55), 1.4, False), 32)
        torus(f"button-ring-{index}", button, 0.27, 0.025, seam, rotation=(math.radians(90), 0, 0))
        if index == 1:
            torus("active", center + Vector((0, 0.02, 0)), radius * 1.3, 0.03, emissive("active", color, 2.2, False))
    else:
        sphere(f"empty-{index}", center, radius, glass(f"empty-glass-{index}", (0.85, 0.88, 1.0), 0.12), 80)
        torus(f"empty-seam-{index}", center, radius * 0.99, 0.012, emissive("empty-seam", (0.6, 0.62, 0.7), 0.35, False))

random.seed(21)
for i in range(30):
    pos = Vector((random.uniform(-12, 12), random.uniform(3, 14), random.uniform(0.4, 6.5)))
    color = random.choice(HUES)
    sphere(f"dust-{i}", pos, random.uniform(0.035, 0.08), emissive(f"dust-{i}", color, random.uniform(0.9, 2.2), False), 12)


def aim(obj, target, up="UP_Y"):
    constraint = obj.constraints.new("TRACK_TO")
    constraint.target = target
    constraint.track_axis = "TRACK_NEGATIVE_Z"
    constraint.up_axis = up


focus = bpy.data.objects.new("focus", None)
focus.location = (0, 0, 1.2)
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


area("top", (0, -3, 9), 10, 420, (0.8, 0.84, 1.0))
area("rim-a", (-12, -5, 3.2), 5, 220, HUES[0])
area("rim-b", (12, -5, 3.2), 5, 220, HUES[4])

cam_data = bpy.data.cameras.new("camera")
cam_data.lens = 30
cam_data.sensor_fit = "HORIZONTAL"
cam_data.dof.use_dof = True
cam_data.dof.focus_object = focus
cam_data.dof.aperture_fstop = 4.0
camera = bpy.data.objects.new("camera", cam_data)
camera.location = (0, -17.2, 2.5)
scene.collection.objects.link(camera)
aim(camera, focus)
scene.camera = camera

bpy.ops.render.render(write_still=True)
