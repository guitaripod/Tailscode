"""Build and render the Tailscode launch film: a procedural iPhone Air playing the
scripted screen take, lit like a product shot.

Everything here is generated — no purchased assets, no HDRI packs — so the whole
film rebuilds from this repo plus one screen recording.

  blender --background -P scripts/film-scene.py -- --frames <jpg-dir> --out <png-dir>

Add --still N to render one frame for a fast look-dev loop.
"""
import argparse
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

MM = 0.001

BODY_H = 156.2 * MM
BODY_W = 74.7 * MM
BODY_D = 5.64 * MM
CORNER_R = 13.2 * MM
SCREEN_H = 151.08 * MM
SCREEN_W = 69.57 * MM
# The display is masked to the bezel profile inset by the bezel width, so its
# corner radius follows the body rather than being a separate design value.
SCREEN_R = (13.2 - 2.56) * MM

GLASS_LIFT = 0.15 * MM
GLASS_D = 0.30 * MM
SCREEN_LIFT = 0.25 * MM

PLATEAU_H = 26.0 * MM
PLATEAU_D = 3.03 * MM
PLATEAU_INSET = 1.6 * MM

# Sky Blue, the iPhone Air signature finish: #C3CDD5 sampled off Apple's own
# polished-rail render, converted to linear.
TITANIUM = (0.546, 0.611, 0.665)
ACCENT = (0.20, 0.45, 0.95)

SENSOR_W = 36.0


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--frames", required=True, help="directory of screen_####.jpg")
    p.add_argument("--out", default="/tmp/film-render/")
    p.add_argument("--stills", default="", help="comma-separated frames for look-dev")
    p.add_argument("--start", type=int, default=1)
    p.add_argument("--end", type=int, default=0)
    p.add_argument("--width", type=int, default=2560)
    p.add_argument("--height", type=int, default=1440)
    p.add_argument("--fps", type=int, default=60)
    p.add_argument("--seconds", type=float, default=107.0)
    p.add_argument("--samples", type=int, default=96)
    p.add_argument("--screen-offset", type=int, default=180,
                   dest="screen_offset", help="source frames to skip (springboard)")
    p.add_argument("--views", default="", help="comma-separated view transforms to A/B")
    p.add_argument("--diag", action="store_true", help="flat clay shading, geometry only")
    p.add_argument("--emission", type=float, default=1.0)
    p.add_argument("--save", default="")
    return p.parse_args(argv)


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0
    return scene


def squircle_outline(width, height, radius, per_corner=44, exponent=2.2):
    """The iPhone outline: corners with continuous curvature, not circular arcs.

    A circular corner meets the straight rail with a curvature step you can see at
    this size; the superellipse blend is what reads as an iPhone rather than as a
    rounded rectangle.

    Keep the exponent near 2: it also controls how evenly the arc is sampled, and a
    strongly squared profile bunches vertices into long thin faces that shade as
    flared plates rather than as a continuous corner.
    """
    hw, hh = width / 2.0, height / 2.0
    k = 2.0 / exponent
    corner = []
    for i in range(per_corner + 1):
        t = (math.pi / 2.0) * i / per_corner
        corner.append((radius * (1.0 - math.cos(t) ** k), radius * (1.0 - math.sin(t) ** k)))

    points = []
    for x, y in corner:
        points.append((hw - x, hh - y))
    for x, y in corner:
        points.append((-hw + y, hh - x))
    for x, y in corner:
        points.append((-hw + x, -hh + y))
    for x, y in corner:
        points.append((hw - y, -hh + x))

    deduped = [points[0]]
    for point in points[1:]:
        if (Vector(point) - Vector(deduped[-1])).length > 1e-6:
            deduped.append(point)
    if (Vector(deduped[0]) - Vector(deduped[-1])).length < 1e-6:
        deduped.pop()
    return deduped


def extruded_solid(name, outline, depth, y_center=0.0):
    """A closed slab from a 2D outline, standing upright in the XZ plane."""
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    front = [bm.verts.new((x, y_center - depth / 2.0, z)) for x, z in outline]
    back = [bm.verts.new((x, y_center + depth / 2.0, z)) for x, z in outline]
    bm.verts.ensure_lookup_table()
    count = len(outline)
    for i in range(count):
        j = (i + 1) % count
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bm.faces.new(list(reversed(front)))
    bm.faces.new(back)
    bm.normal_update()
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def flat_face(name, outline, y, width, height):
    """A single n-gon in the XZ plane, UV-mapped so an image fills its bounding box.

    The display is not a rectangle: it is masked to the same rounded profile as the
    bezel around it, so the recording has to be cut to that shape rather than laid
    on a square plane inside a rounded phone.
    """
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    verts = [bm.verts.new((x, y, z)) for x, z in outline]
    bm.verts.ensure_lookup_table()
    face = bm.faces.new(verts)
    bm.normal_update()
    layer = bm.loops.layers.uv.new("UVMap")
    for loop in face.loops:
        position = loop.vert.co
        loop[layer].uv = (
            (position.x + width / 2.0) / width,
            (position.z + height / 2.0) / height,
        )
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def bevel(obj, width, segments=6, angle=math.radians(35)):
    modifier = obj.modifiers.new("Bevel", "BEVEL")
    modifier.width = width
    modifier.segments = segments
    modifier.limit_method = "ANGLE"
    modifier.angle_limit = angle
    return modifier


def shade_smooth(obj, angle=40):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.shade_auto_smooth(angle=math.radians(angle))
    obj.select_set(False)


def principled(name, **inputs):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    for key, value in inputs.items():
        socket = key.replace("_", " ")
        if socket in bsdf.inputs:
            bsdf.inputs[socket].default_value = value
    return material


def build_body():
    outline = squircle_outline(BODY_W, BODY_H, CORNER_R)
    body = extruded_solid("Body", outline, BODY_D)
    bevel(body, 0.6 * MM, segments=10)
    shade_smooth(body)
    body.data.materials.append(
        principled(
            "Titanium",
            Base_Color=(*TITANIUM, 1.0),
            Metallic=1.0,
            Roughness=0.24,
            Anisotropic=0.3,
            Coat_Weight=0.25,
            Coat_Roughness=0.06,
        )
    )
    return body


def build_plateau():
    """The iPhone Air's signature: a full-width camera bar across the top of the back."""
    width = BODY_W - 2 * PLATEAU_INSET
    outline = squircle_outline(width, PLATEAU_H, 8.0 * MM)
    plateau = extruded_solid("Plateau", outline, PLATEAU_D * 2, y_center=BODY_D / 2.0)
    plateau.location.z = BODY_H / 2.0 - PLATEAU_H / 2.0 - 3.4 * MM
    bevel(plateau, 0.9 * MM, segments=8)
    shade_smooth(plateau)
    plateau.data.materials.append(
        principled(
            "PlateauTitanium",
            Base_Color=(*TITANIUM, 1.0),
            Metallic=1.0,
            Roughness=0.3,
            Coat_Weight=0.2,
        )
    )
    return plateau


def build_lens(plateau):
    glass = principled(
        "LensGlass", Base_Color=(0.02, 0.02, 0.025, 1.0), Metallic=0.0, Roughness=0.04,
        Coat_Weight=1.0, Coat_Roughness=0.02,
    )
    ring = principled(
        "LensRing", Base_Color=(0.30, 0.32, 0.35, 1.0), Metallic=1.0, Roughness=0.16
    )
    parts = []
    z = plateau.location.z + 1.0 * MM
    x = -BODY_W / 2.0 + 15.0 * MM
    y = BODY_D / 2.0 + PLATEAU_D

    bpy.ops.mesh.primitive_cylinder_add(radius=8.2 * MM, depth=1.5 * MM, vertices=96)
    housing = bpy.context.object
    housing.name = "LensHousing"
    housing.rotation_euler = (math.radians(90), 0, 0)
    housing.location = (x, y, z)
    bevel(housing, 0.35 * MM, segments=6)
    shade_smooth(housing)
    housing.data.materials.append(ring)
    parts.append(housing)

    bpy.ops.mesh.primitive_cylinder_add(radius=6.4 * MM, depth=1.9 * MM, vertices=96)
    lens = bpy.context.object
    lens.name = "Lens"
    lens.rotation_euler = (math.radians(90), 0, 0)
    lens.location = (x, y + 0.2 * MM, z)
    shade_smooth(lens)
    lens.data.materials.append(glass)
    parts.append(lens)

    bpy.ops.mesh.primitive_cylinder_add(radius=3.1 * MM, depth=1.2 * MM, vertices=64)
    flash = bpy.context.object
    flash.name = "Flash"
    flash.rotation_euler = (math.radians(90), 0, 0)
    flash.location = (x + 21.0 * MM, y, z)
    shade_smooth(flash)
    flash.data.materials.append(
        principled("FlashGlass", Base_Color=(0.9, 0.85, 0.72, 1.0), Roughness=0.15)
    )
    parts.append(flash)
    return parts


def build_glass():
    """The black front lamination the display sits under — it is what makes the
    bezel read as glass rather than as a painted border."""
    outline = squircle_outline(
        BODY_W - 0.7 * MM, BODY_H - 0.7 * MM, CORNER_R - 0.35 * MM, per_corner=32
    )
    glass = extruded_solid(
        "Glass", outline, GLASS_D, y_center=-BODY_D / 2.0 - GLASS_LIFT - GLASS_D / 2.0
    )
    bevel(glass, 0.1 * MM, segments=4)
    shade_smooth(glass)
    glass.data.materials.append(
        principled(
            "FrontGlass",
            Base_Color=(0.004, 0.004, 0.006, 1.0),
            Metallic=0.0,
            Roughness=0.05,
            IOR=1.52,
            Coat_Weight=1.0,
            Coat_Roughness=0.02,
        )
    )
    return glass


def screen_plane_y():
    return -BODY_D / 2.0 - GLASS_LIFT - GLASS_D - SCREEN_LIFT


def build_screen(frames_dir, frame_count, offset, emission):
    outline = squircle_outline(SCREEN_W, SCREEN_H, SCREEN_R, per_corner=40)
    screen = flat_face("Screen", outline, screen_plane_y(), SCREEN_W, SCREEN_H)

    first = sorted(f for f in os.listdir(frames_dir) if f.endswith(".jpg"))[0]
    image = bpy.data.images.load(os.path.join(frames_dir, first))
    image.source = "SEQUENCE"
    image.colorspace_settings.name = "sRGB"

    material = bpy.data.materials.new("ScreenSurface")
    material.use_nodes = True
    tree = material.node_tree
    bsdf = tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.0, 0.0, 0.0, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.40
    bsdf.inputs["IOR"].default_value = 1.5
    bsdf.inputs["Specular IOR Level"].default_value = 0.18
    bsdf.inputs["Coat Weight"].default_value = 0.04
    bsdf.inputs["Coat Roughness"].default_value = 0.14
    bsdf.inputs["Emission Strength"].default_value = emission

    texture = tree.nodes.new("ShaderNodeTexImage")
    texture.image = image
    texture.interpolation = "Cubic"
    texture.extension = "EXTEND"
    texture.location = (-420, 260)
    texture.image_user.frame_duration = frame_count
    texture.image_user.frame_start = 1
    texture.image_user.frame_offset = offset
    texture.image_user.use_auto_refresh = True
    texture.image_user.use_cyclic = False
    tree.links.new(texture.outputs["Color"], bsdf.inputs["Emission Color"])

    screen.data.materials.append(material)
    return screen, texture


def area_light(name, location, rotation, size, size_y, energy, color):
    data = bpy.data.lights.new(name, type="AREA")
    data.shape = "RECTANGLE"
    data.size = size
    data.size_y = size_y
    data.energy = energy
    data.color = color
    light = bpy.data.objects.new(name, data)
    light.location = location
    light.rotation_euler = rotation
    bpy.context.collection.objects.link(light)
    return light


def build_lighting(scene):
    """Two long soft strips do the work: on a mirror-flat glass front, a small bright
    light is a blown blob, while a distant strip becomes the clean falling highlight
    that reads as glass."""
    world = bpy.data.worlds.new("Void")
    scene.world = world
    world.use_nodes = True
    background = world.node_tree.nodes["Background"]
    background.inputs["Color"].default_value = (0.010, 0.012, 0.020, 1.0)
    background.inputs["Strength"].default_value = 0.8

    area_light("Key", (-0.80, -0.95, 0.72), (math.radians(48), 0, math.radians(-40)),
               1.2, 1.2, 170.0, (1.0, 0.97, 0.93))
    area_light("StripRight", (0.55, -0.62, 0.10), (math.radians(90), 0, math.radians(42)),
               0.028, 1.5, 42.0, (0.90, 0.94, 1.0))
    area_light("StripLeft", (-0.52, -0.58, 0.05), (math.radians(90), 0, math.radians(-42)),
               0.024, 1.3, 24.0, (0.84, 0.90, 1.0))
    area_light("Rim", (0.62, 0.82, 0.46), (math.radians(122), 0, math.radians(148)),
               0.9, 0.9, 150.0, (0.66, 0.76, 1.0))
    area_light("Under", (0.0, -0.42, -0.30), (math.radians(-30), 0, 0),
               0.8, 0.5, 6.0, ACCENT)


def build_backdrop():
    """A seamless falloff behind the phone, so its silhouette separates from the void
    without a visible horizon line."""
    bpy.ops.mesh.primitive_plane_add(size=9.0, location=(0.0, 2.2, 0.35))
    backdrop = bpy.context.object
    backdrop.name = "Backdrop"
    backdrop.rotation_euler = (math.radians(90), 0, 0)

    material = bpy.data.materials.new("BackdropGlow")
    material.use_nodes = True
    tree = material.node_tree
    for node in list(tree.nodes):
        if node.type != "OUTPUT_MATERIAL":
            tree.nodes.remove(node)
    output = tree.nodes["Material Output"]

    coord = tree.nodes.new("ShaderNodeTexCoord")
    coord.location = (-900, 0)
    mapping = tree.nodes.new("ShaderNodeMapping")
    mapping.location = (-700, 0)
    mapping.inputs["Location"].default_value = (0.5, 0.5, 0.0)
    mapping.inputs["Scale"].default_value = (1.0, 1.0, 1.0)
    gradient = tree.nodes.new("ShaderNodeTexGradient")
    gradient.gradient_type = "SPHERICAL"
    gradient.location = (-500, 0)
    ramp = tree.nodes.new("ShaderNodeValToRGB")
    ramp.location = (-300, 0)
    ramp.color_ramp.elements[0].position = 0.34
    ramp.color_ramp.elements[0].color = (0.004, 0.005, 0.010, 1.0)
    ramp.color_ramp.elements[1].position = 1.0
    ramp.color_ramp.elements[1].color = (0.055, 0.070, 0.115, 1.0)
    emission = tree.nodes.new("ShaderNodeEmission")
    emission.location = (-100, 0)
    emission.inputs["Strength"].default_value = 1.0

    tree.links.new(coord.outputs["Object"], mapping.inputs["Vector"])
    tree.links.new(mapping.outputs["Vector"], gradient.inputs["Vector"])
    tree.links.new(gradient.outputs["Color"], ramp.inputs["Fac"])
    tree.links.new(ramp.outputs["Color"], emission.inputs["Color"])
    tree.links.new(emission.outputs["Emission"], output.inputs["Surface"])
    backdrop.data.materials.append(material)
    return backdrop


def build_floor():
    bpy.ops.mesh.primitive_plane_add(size=8.0, location=(0.0, 0.35, -0.100))
    floor = bpy.context.object
    floor.name = "Floor"
    floor.data.materials.append(
        principled(
            "FloorSlate",
            Base_Color=(0.012, 0.013, 0.017, 1.0),
            Metallic=0.0,
            Roughness=0.48,
            Specular_IOR_Level=0.5,
        )
    )
    return floor


def action_fcurves(action):
    """Blender 5's slotted actions moved fcurves behind layers/strips/channelbags;
    the flat `action.fcurves` of 4.x is gone."""
    if hasattr(action, "fcurves"):
        return list(action.fcurves)
    curves = []
    for layer in action.layers:
        for strip in layer.strips:
            for bag in getattr(strip, "channelbags", []):
                curves.extend(bag.fcurves)
    return curves


def ease_all(obj):
    animation = obj.animation_data
    if not animation or not animation.action:
        return
    for curve in action_fcurves(animation.action):
        for point in curve.keyframe_points:
            point.interpolation = "BEZIER"
            point.handle_left_type = "AUTO_CLAMPED"
            point.handle_right_type = "AUTO_CLAMPED"


def keyed(obj, path, frames, values, index=-1):
    for frame, value in zip(frames, values):
        if index >= 0:
            getattr(obj, path)[index] = value
        else:
            setattr(obj, path, value)
        obj.keyframe_insert(data_path=path, frame=frame, index=index)


# (t, azimuth°, elevation°, lens mm, phone height as a fraction of frame height,
#  sensor shift in frame widths, aim height in body-heights, phone spin°, phone tilt°)
#
# Timed against the screen take beat for beat, under one governing constraint: a
# source point survives to about 1.15 * fill pixels at 1080p, so the app's 11pt
# mono only becomes readable around fill 1.9. The film therefore alternates — the
# whole device while the screen is establishing or empty, and a hard push past the
# frame edge on the three beats that are actually made of text.
#
# `shift` is a sensor shift, not a position offset: it parks the phone right of
# centre to clear the type column without changing the viewing angle, which moving
# the camera sideways would.
SHOTS = [
    dict(t=0.0, az=-30.0, el=10.0, lens=45, fill=0.74, shift=0.00, aim=0.05, spin=-7.0, tilt=2.2),
    dict(t=2.2, az=-10.0, el=4.0, lens=56, fill=0.90, shift=-0.13, aim=0.02, spin=-2.5, tilt=0.7),
    dict(t=7.8, az=-6.0, el=3.0, lens=58, fill=0.94, shift=-0.14, aim=0.01, spin=-1.6, tilt=0.5),
    dict(t=9.6, az=0.0, el=0.0, lens=66, fill=1.10, shift=-0.15, aim=-0.06, spin=0.5, tilt=0.0),
    dict(t=11.4, az=1.0, el=0.0, lens=68, fill=1.14, shift=-0.15, aim=-0.06, spin=0.8, tilt=0.0),
    dict(t=13.2, az=4.0, el=0.0, lens=88, fill=1.82, shift=-0.14, aim=-0.02, spin=1.8, tilt=0.0),
    dict(t=17.0, az=5.0, el=0.0, lens=90, fill=1.88, shift=-0.14, aim=-0.01, spin=2.0, tilt=0.0),
    dict(t=25.0, az=6.0, el=1.0, lens=92, fill=1.94, shift=-0.14, aim=0.00, spin=2.3, tilt=0.0),
    dict(t=26.4, az=-3.0, el=1.0, lens=88, fill=1.80, shift=-0.14, aim=-0.12, spin=-1.0, tilt=0.2),
    dict(t=28.8, az=-4.0, el=1.0, lens=88, fill=1.80, shift=-0.14, aim=-0.12, spin=-1.3, tilt=0.2),
    dict(t=31.5, az=-4.0, el=2.0, lens=76, fill=1.34, shift=-0.13, aim=0.00, spin=-1.2, tilt=0.4),
    dict(t=34.0, az=-4.0, el=2.0, lens=76, fill=1.34, shift=-0.13, aim=0.00, spin=-1.2, tilt=0.4),
    dict(t=35.2, az=-6.0, el=3.0, lens=68, fill=1.10, shift=-0.11, aim=-0.02, spin=-1.8, tilt=0.6),
    dict(t=38.0, az=-7.0, el=3.0, lens=66, fill=1.06, shift=-0.11, aim=-0.02, spin=-2.0, tilt=0.6),
    dict(t=39.6, az=-9.0, el=4.0, lens=62, fill=0.94, shift=-0.09, aim=0.02, spin=-2.8, tilt=1.0),
    dict(t=41.2, az=-9.0, el=4.0, lens=62, fill=0.94, shift=-0.09, aim=0.02, spin=-2.8, tilt=1.0),
    dict(t=42.2, az=-5.0, el=3.0, lens=72, fill=1.20, shift=-0.12, aim=0.00, spin=-1.5, tilt=0.6),
    dict(t=46.4, az=-5.0, el=3.0, lens=72, fill=1.20, shift=-0.12, aim=0.00, spin=-1.5, tilt=0.6),
    dict(t=47.4, az=-9.0, el=4.0, lens=60, fill=0.90, shift=-0.08, aim=0.02, spin=-3.0, tilt=1.0),
    dict(t=48.8, az=-9.0, el=4.0, lens=60, fill=0.90, shift=-0.08, aim=0.02, spin=-3.0, tilt=1.0),
    dict(t=49.8, az=-6.0, el=1.0, lens=92, fill=1.92, shift=-0.14, aim=-0.12, spin=-2.0, tilt=0.2),
    dict(t=55.6, az=-5.0, el=1.0, lens=92, fill=1.92, shift=-0.14, aim=-0.10, spin=-1.6, tilt=0.2),
    dict(t=57.0, az=-10.0, el=4.0, lens=60, fill=0.90, shift=-0.08, aim=0.02, spin=-3.0, tilt=1.0),
    dict(t=58.6, az=-10.0, el=4.0, lens=60, fill=0.90, shift=-0.08, aim=0.02, spin=-3.0, tilt=1.0),
    dict(t=59.6, az=0.0, el=2.0, lens=90, fill=1.86, shift=-0.14, aim=-0.02, spin=0.5, tilt=0.3),
    dict(t=61.6, az=0.0, el=2.0, lens=90, fill=1.86, shift=-0.14, aim=-0.02, spin=0.5, tilt=0.3),
    dict(t=62.2, az=1.0, el=1.0, lens=88, fill=1.80, shift=-0.14, aim=-0.10, spin=0.8, tilt=0.2),
    dict(t=64.0, az=1.0, el=1.0, lens=88, fill=1.80, shift=-0.14, aim=-0.10, spin=0.8, tilt=0.2),
    dict(t=64.8, az=4.0, el=1.0, lens=92, fill=1.92, shift=-0.14, aim=0.02, spin=1.6, tilt=0.2),
    dict(t=68.4, az=5.0, el=1.0, lens=92, fill=1.92, shift=-0.14, aim=0.03, spin=1.8, tilt=0.2),
    dict(t=69.6, az=-8.0, el=4.0, lens=62, fill=0.94, shift=-0.09, aim=0.02, spin=-2.6, tilt=0.9),
    dict(t=73.6, az=-8.0, el=4.0, lens=64, fill=0.98, shift=-0.09, aim=0.02, spin=-2.4, tilt=0.9),
    dict(t=74.4, az=-2.0, el=1.0, lens=92, fill=1.94, shift=-0.14, aim=-0.10, spin=-0.5, tilt=0.2),
    dict(t=79.0, az=0.0, el=1.0, lens=92, fill=1.90, shift=-0.14, aim=-0.07, spin=0.4, tilt=0.2),
    dict(t=80.6, az=-7.0, el=3.0, lens=66, fill=1.05, shift=-0.10, aim=0.00, spin=-2.0, tilt=0.6),
    dict(t=83.4, az=-7.0, el=3.0, lens=66, fill=1.05, shift=-0.10, aim=0.00, spin=-2.0, tilt=0.6),
    dict(t=84.4, az=3.0, el=1.0, lens=92, fill=1.92, shift=-0.14, aim=-0.02, spin=1.2, tilt=0.2),
    dict(t=88.0, az=3.0, el=1.0, lens=92, fill=1.92, shift=-0.14, aim=-0.02, spin=1.2, tilt=0.2),
    dict(t=88.8, az=6.0, el=1.0, lens=90, fill=1.84, shift=-0.14, aim=0.02, spin=2.0, tilt=0.2),
    dict(t=93.0, az=6.0, el=1.0, lens=90, fill=1.84, shift=-0.14, aim=0.02, spin=2.0, tilt=0.2),
    dict(t=94.2, az=-8.0, el=4.0, lens=62, fill=0.94, shift=-0.09, aim=0.02, spin=-2.6, tilt=0.9),
    dict(t=96.0, az=-8.0, el=4.0, lens=62, fill=0.94, shift=-0.09, aim=0.02, spin=-2.6, tilt=0.9),
    dict(t=97.0, az=-4.0, el=4.0, lens=72, fill=1.22, shift=-0.11, aim=0.00, spin=-1.4, tilt=0.8),
    dict(t=101.0, az=-4.0, el=4.0, lens=72, fill=1.22, shift=-0.11, aim=0.00, spin=-1.4, tilt=0.8),
    dict(t=102.2, az=0.0, el=3.0, lens=60, fill=0.94, shift=-0.05, aim=0.02, spin=0.0, tilt=0.6),
    dict(t=105.0, az=0.0, el=2.0, lens=56, fill=0.86, shift=-0.03, aim=0.01, spin=0.0, tilt=0.5),
    dict(t=107.1, az=0.0, el=1.0, lens=50, fill=0.74, shift=0.00, aim=0.00, spin=0.0, tilt=0.3),
]


def framing_distance(lens, fill, width, height):
    """How far back the camera must sit for the phone to occupy `fill` of the frame."""
    sensor_v = SENSOR_W * height / width if height < width else SENSOR_W
    half_fov = math.atan(sensor_v / (2.0 * lens))
    return (BODY_H / fill) / (2.0 * math.tan(half_fov))


def shot_camera_position(shot, width, height):
    distance = framing_distance(shot["lens"], shot["fill"], width, height)
    az = math.radians(shot["az"])
    el = math.radians(shot["el"])
    aim_z = shot["aim"] * BODY_H
    x = distance * math.sin(az) * math.cos(el)
    y = -distance * math.cos(az) * math.cos(el)
    z = aim_z + distance * math.sin(el)
    return (x, y, z), (0.0, 0.0, aim_z)


def animate(camera, aim, phone, fps, width, height):
    frames = [round(shot["t"] * fps) + 1 for shot in SHOTS]
    positions, aims = zip(*(shot_camera_position(s, width, height) for s in SHOTS))
    for axis in range(3):
        keyed(camera, "location", frames, [p[axis] for p in positions], index=axis)
        keyed(aim, "location", frames, [a[axis] for a in aims], index=axis)
    for frame, shot in zip(frames, SHOTS):
        camera.data.lens = shot["lens"]
        camera.data.keyframe_insert(data_path="lens", frame=frame)
        camera.data.shift_x = shot["shift"]
        camera.data.keyframe_insert(data_path="shift_x", frame=frame)
    keyed(phone, "rotation_euler", frames,
          [math.radians(s["spin"]) for s in SHOTS], index=2)
    keyed(phone, "rotation_euler", frames,
          [math.radians(s["tilt"]) for s in SHOTS], index=0)
    for obj in (camera, camera.data, aim, phone):
        ease_all(obj)


def configure_render(scene, args):
    render = scene.render
    render.engine = "BLENDER_EEVEE"
    render.resolution_x = args.width
    render.resolution_y = args.height
    render.resolution_percentage = 100
    render.fps = args.fps
    render.film_transparent = False
    render.use_motion_blur = True
    for attr, value in (("motion_blur_shutter", 0.3), ("motion_blur_position", "CENTER")):
        if hasattr(render, attr):
            setattr(render, attr, value)
    render.image_settings.file_format = "PNG"
    render.image_settings.color_mode = "RGB"
    render.image_settings.compression = 15
    render.filepath = args.out

    eevee = scene.eevee
    eevee.taa_render_samples = args.samples
    eevee.use_raytracing = True
    eevee.use_shadows = True
    eevee.shadow_ray_count = 2
    eevee.shadow_step_count = 8
    eevee.use_fast_gi = True
    for attr, value in (("resolution_scale", "1"), ("use_denoise", True),
                        ("screen_trace_quality", 0.5)):
        if hasattr(eevee.ray_tracing_options, attr):
            try:
                setattr(eevee.ray_tracing_options, attr, value)
            except (TypeError, ValueError):
                pass

    scene.view_settings.view_transform = "Khronos PBR Neutral"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.35


def main():
    args = parse_args()
    scene = reset_scene()

    jpgs = sorted(f for f in os.listdir(args.frames) if f.endswith(".jpg"))
    total = min(len(jpgs) - args.screen_offset, int(args.seconds * args.fps))

    body = build_body()
    plateau = build_plateau()
    lens_parts = build_lens(plateau)
    glass = build_glass()
    screen, _ = build_screen(args.frames, len(jpgs) - args.screen_offset, args.screen_offset, args.emission)

    phone = bpy.data.objects.new("Phone", None)
    phone.empty_display_size = 0.02
    bpy.context.collection.objects.link(phone)
    for part in [body, plateau, glass, screen] + lens_parts:
        part.parent = phone
        part.matrix_parent_inverse = phone.matrix_world.inverted()

    build_lighting(scene)
    build_backdrop()

    aim = bpy.data.objects.new("Aim", None)
    aim.empty_display_size = 0.01
    bpy.context.collection.objects.link(aim)

    camera_data = bpy.data.cameras.new("Camera")
    camera_data.sensor_width = SENSOR_W
    focus = bpy.data.objects.new("Focus", None)
    focus.empty_display_size = 0.005
    bpy.context.collection.objects.link(focus)
    focus.parent = phone
    focus.location = (0.0, screen_plane_y(), 0.0)

    camera_data.dof.use_dof = True
    camera_data.dof.focus_object = focus
    camera_data.dof.aperture_fstop = 9.0
    camera = bpy.data.objects.new("Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    track = camera.constraints.new("TRACK_TO")
    track.target = aim
    track.track_axis = "TRACK_NEGATIVE_Z"
    track.up_axis = "UP_Y"
    scene.camera = camera

    if args.diag:
        clay = principled("Clay", Base_Color=(0.45, 0.45, 0.47, 1.0), Metallic=0.0,
                          Roughness=0.55)
        for obj in bpy.data.objects:
            if obj.type == "MESH" and obj.name not in ("Backdrop",):
                obj.data.materials.clear()
                obj.data.materials.append(clay)

    animate(camera, aim, phone, args.fps, args.width, args.height)
    configure_render(scene, args)

    scene.frame_start = args.start
    scene.frame_end = args.end or total

    if args.save:
        bpy.ops.wm.save_as_mainfile(filepath=args.save)

    if args.stills:
        views = args.views.split(",") if args.views else [scene.view_settings.view_transform]
        for view in views:
            scene.view_settings.view_transform = view
            if view != "AgX":
                scene.view_settings.look = "None"
            tag = view.replace(" ", "")
            for frame in (int(f) for f in args.stills.split(",")):
                scene.frame_set(frame)
                scene.render.filepath = f"{args.out.rstrip('/')}/{tag}_{frame:04d}"
                bpy.ops.render.render(write_still=True)
    else:
        bpy.ops.render.render(animation=True)


main()
