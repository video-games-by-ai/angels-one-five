"""Build the low-poly conifers used by the forest system.

Run:  blender --background --factory-startup --python tools/build_trees.py
Writes source-assets/trees.blend and game/assets/models/trees.glb with two meshes,
"Spruce" (tall, narrow) and "Fir" (fuller), each about 22 m tall at scale 1 with
"Trunk" and "Needles" materials. Godot replaces the needle material with a shader.
"""
from __future__ import annotations

import math
import random
from pathlib import Path

import bmesh
import bpy

ROOT = Path(__file__).resolve().parents[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
random.seed(8)


def material(name, color):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = 1.0
    return m


TRUNK = material("Trunk", (0.22, 0.16, 0.11))
NEEDLES = material("Needles", (0.1, 0.2, 0.1))


def conifer(name, tiers, height, base_radius, taper, sides=9):
    verts, faces, mats = [], [], []

    def add_ring(radius, y, jag, phase):
        start = len(verts)
        for i in range(sides):
            a = 2 * math.pi * i / sides + phase
            r = radius * (1.0 + (jag if i % 2 else -jag) * 0.5) * random.uniform(0.9, 1.08)
            verts.append((r * math.cos(a), r * math.sin(a), y + random.uniform(-0.25, 0.25) * radius * 0.2))
        return start

    # Trunk: a short hexagonal prism under the lowest tier.
    t0 = len(verts)
    for y in (0.0, height * 0.35):
        for i in range(6):
            a = 2 * math.pi * i / 6
            verts.append((0.35 * math.cos(a), 0.35 * math.sin(a), y))
    for i in range(6):
        j = (i + 1) % 6
        faces.append((t0 + i, t0 + j, t0 + 6 + j, t0 + 6 + i))
        mats.append(0)
    # Tiers: drooping cones that overlap, each a rim ring plus an apex.
    tier_base = height * 0.12
    span = height - tier_base
    for t in range(tiers):
        f = t / tiers
        y_bottom = tier_base + span * f * 0.92
        radius = base_radius * (1.0 - f) ** taper + 0.25
        y_top = y_bottom + span / tiers * 1.9
        if t == tiers - 1:
            y_top = height
        rim = add_ring(radius, y_bottom, 0.35, t * 0.6)
        inner = add_ring(radius * 0.45, y_bottom + (y_top - y_bottom) * 0.12, 0.0, t * 0.6)
        apex = len(verts)
        verts.append((random.uniform(-0.1, 0.1), random.uniform(-0.1, 0.1), y_top))
        for i in range(sides):
            j = (i + 1) % sides
            faces.append((rim + i, rim + j, apex))
            mats.append(1)
            faces.append((inner + j, rim + j, rim + i, inner + i))
            mats.append(1)
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.materials.append(TRUNK)
    me.materials.append(NEEDLES)
    for poly, m in zip(me.polygons, mats):
        poly.material_index = m
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    for poly in me.polygons:
        poly.use_smooth = True
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


spruce = conifer("Spruce", 6, 22.0, 3.3, 1.1)
fir = conifer("Fir", 5, 19.0, 4.2, 0.9)
fir.location.x = 12.0

bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / "source-assets/trees.blend"))
fir.location.x = 0.0
bpy.ops.export_scene.gltf(filepath=str(ROOT / "game/assets/models/trees.glb"), export_format="GLB", export_apply=True)
print("TREES_EXPORTED", sum(len(o.data.polygons) for o in (spruce, fir)), "faces")
