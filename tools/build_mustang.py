"""Build the P-51D Mustang model in Blender and export it for Godot.

Run:  blender --background --factory-startup --python tools/build_mustang.py [-- --preview]
Writes:
  source-assets/mustang.blend          editable source (separate named parts)
  game/assets/models/mustang.glb       game asset
  build/shots/mustang_preview.png      optional workbench render (--preview)

Coordinates below are written in Godot space (metres): +X right wing, +Y up,
-Z toward the nose. Overall size follows the real aircraft (span 11.28 m, length
9.83 m). Markings are fictional. Moving parts (propeller, ailerons, elevators,
rudder) have their origin on their rotation axis so the game can animate them.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
PREVIEW = "--preview" in sys.argv

bpy.ops.wm.read_factory_settings(use_empty=True)
COLLECTION = bpy.context.scene.collection


def G(x: float, y: float, z: float) -> tuple[float, float, float]:
    """Godot (x, y, z) to Blender (x, -z, y)."""
    return (x, -z, y)


def material(name, color, metallic=0.0, roughness=0.5, alpha=1.0, emission=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Alpha"].default_value = alpha
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*color, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission
    m.diffuse_color = (*color, alpha)
    if alpha < 1.0:
        m.surface_render_method = "BLENDED"
    return m


MAT = {
    "skin": material("Skin", (0.72, 0.74, 0.76), 1.0, 0.32),
    "antiglare": material("AntiGlare", (0.17, 0.18, 0.11), 0.0, 0.8),
    "accent": material("Accent", (0.95, 0.70, 0.12), 0.1, 0.45),
    "glass": material("Glass", (0.55, 0.65, 0.70), 0.0, 0.05, 0.28),
    "frame": material("Frame", (0.45, 0.47, 0.48), 0.9, 0.4),
    "dark": material("Dark", (0.05, 0.05, 0.05), 0.3, 0.7),
    "blade": material("PropBlade", (0.03, 0.03, 0.03), 0.0, 0.55),
    "tip": material("PropTip", (0.95, 0.78, 0.10), 0.0, 0.5),
    "ins_blue": material("InsigniaBlue", (0.05, 0.10, 0.28), 0.0, 0.55),
    "ins_white": material("InsigniaWhite", (0.88, 0.88, 0.86), 0.0, 0.55),
    "nav_red": material("NavRed", (1.0, 0.05, 0.03), 0.0, 0.3, emission=3.0),
    "nav_green": material("NavGreen", (0.05, 1.0, 0.2), 0.0, 0.3, emission=3.0),
    "pilot": material("Pilot", (0.25, 0.16, 0.10), 0.0, 0.8),
    "exhaust": material("Exhaust", (0.16, 0.11, 0.08), 0.6, 0.6),
}


def make_mesh(name, verts, faces, face_mats, pivot=(0.0, 0.0, 0.0), smooth_angle=48.0, parent=None):
    """verts in Godot space; pivot (Godot space) becomes the object origin."""
    px, py, pz = pivot
    me = bpy.data.meshes.new(name)
    me.from_pydata([G(x - px, y - py, z - pz) for x, y, z in verts], [], faces)
    used = []
    for key in face_mats:
        if key not in used:
            used.append(key)
    for key in used:
        me.materials.append(MAT[key])
    for poly, key in zip(me.polygons, face_mats):
        poly.material_index = used.index(key)
    me.validate()
    me.update()
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    for poly in me.polygons:
        poly.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(smooth_angle))
    ob = bpy.data.objects.new(name, me)
    ob.location = G(px, py, pz)
    COLLECTION.objects.link(ob)
    if parent is not None:
        ob.parent = parent
        ob.location = Vector(G(px, py, pz)) - parent.location
    return ob


def empty(name, pos):
    ob = bpy.data.objects.new(name, None)
    ob.location = G(*pos)
    ob.empty_display_size = 0.2
    COLLECTION.objects.link(ob)
    return ob


def loft(rings, cap_start=True, cap_end=True):
    """Connect equal-length rings of points into a closed tube with optional caps."""
    verts, faces = [], []
    m = len(rings[0])
    for ring in rings:
        verts.extend(ring)
    for r in range(len(rings) - 1):
        for i in range(m):
            a = r * m + i
            b = r * m + (i + 1) % m
            faces.append((a, b, b + m, a + m))
    if cap_start:
        c = len(verts)
        verts.append(tuple(sum(p[k] for p in rings[0]) / m for k in range(3)))
        for i in range(m):
            faces.append((c, (i + 1) % m, i))
    if cap_end:
        base = (len(rings) - 1) * m
        c = len(verts)
        verts.append(tuple(sum(p[k] for p in rings[-1]) / m for k in range(3)))
        for i in range(m):
            faces.append((c, base + i, base + (i + 1) % m))
    return verts, faces


def catmull(points, per_segment):
    """Smoothly resample a list of parameter tuples."""
    out = []
    n = len(points)
    for i in range(n - 1):
        p0 = points[max(i - 1, 0)]
        p1, p2 = points[i], points[i + 1]
        p3 = points[min(i + 2, n - 1)]
        for s in range(per_segment):
            t = s / per_segment
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                             for a, b, c, d in zip(p0, p1, p2, p3)))
    out.append(points[-1])
    return out


# --------------------------------------------------------------------------- fuselage
FUSELAGE = [  # z, half width, top, bottom
    (-3.86, 0.33, 0.31, -0.33),
    (-3.55, 0.39, 0.39, -0.46),
    (-3.10, 0.42, 0.45, -0.54),
    (-2.50, 0.44, 0.50, -0.56),
    (-1.90, 0.46, 0.54, -0.57),
    (-1.30, 0.47, 0.56, -0.58),
    (-0.60, 0.48, 0.57, -0.60),
    (0.20, 0.47, 0.55, -0.62),
    (1.00, 0.44, 0.51, -0.60),
    (1.80, 0.39, 0.47, -0.54),
    (2.60, 0.33, 0.43, -0.45),
    (3.40, 0.26, 0.39, -0.33),
    (4.20, 0.18, 0.35, -0.20),
    (4.90, 0.11, 0.31, -0.06),
    (5.28, 0.04, 0.27, 0.06),
]
FUSE_SECTIONS = catmull(FUSELAGE, 4)
SEG = 32
EXP = 2.5


def section_point(w, top, bottom, theta, n=EXP):
    c, s = math.cos(theta), math.sin(theta)
    x = w * math.copysign(abs(c) ** (2 / n), c)
    y = (top if s >= 0 else -bottom) * math.copysign(abs(s) ** (2 / n), s) if s >= 0 else bottom * abs(s) ** (2 / n)
    return x, y


def fuselage_at(z):
    """Interpolated (w, top, bottom) at z."""
    for (z0, *a), (z1, *b) in zip(FUSE_SECTIONS, FUSE_SECTIONS[1:]):
        if z0 <= z <= z1:
            t = (z - z0) / (z1 - z0)
            return tuple(u + (v - u) * t for u, v in zip(a, b))
    return FUSE_SECTIONS[-1][1:] if z > 0 else FUSE_SECTIONS[0][1:]


def side_x(z, y):
    w, top, bottom = fuselage_at(z)
    h = top if y >= 0 else -bottom
    q = min(abs(y) / h, 0.999) if h > 0 else 0.999
    return w * (1 - q ** EXP) ** (1 / EXP)


rings = []
for z, w, top, bottom in FUSE_SECTIONS:
    rings.append([(x, y, z) for x, y in (section_point(w, top, bottom, 2 * math.pi * i / SEG) for i in range(SEG))])
verts, faces = loft(rings)
mats = []
for f in faces:
    cx = sum(verts[i][0] for i in f) / len(f)
    cy = sum(verts[i][1] for i in f) / len(f)
    cz = sum(verts[i][2] for i in f) / len(f)
    if -3.86 <= cz <= -3.42:
        mats.append("accent")
    elif 3.0 <= cz <= 3.32:
        mats.append("accent")
    elif cy > 0.24 and -3.42 < cz < -1.25 and abs(cx) < 0.3:
        mats.append("antiglare")
    else:
        mats.append("skin")
make_mesh("Fuselage", verts, faces, mats)

# --------------------------------------------------------------------------- belly radiator scoop
SCOOP = [(-0.05, 0.24, -0.92), (0.40, 0.27, -0.97), (1.20, 0.28, -0.95), (2.00, 0.25, -0.83), (2.60, 0.18, -0.67), (3.05, 0.07, -0.52)]
rings = []
for z, w, bottom in catmull(SCOOP, 3):
    top = fuselage_at(z)[2] + 0.14
    mid = (top + bottom) * 0.5
    half_h = (top - bottom) * 0.5
    ring = []
    for i in range(20):
        th = 2 * math.pi * i / 20
        c, s = math.cos(th), math.sin(th)
        ring.append((w * math.copysign(abs(c) ** 0.5, c), mid + half_h * math.copysign(abs(s) ** 0.5, s), z))
    rings.append(ring)
verts, faces = loft(rings)
mats = ["dark" if len(f) == 3 and verts[f[0]][2] < 0.0 else "skin" for f in faces]
make_mesh("RadiatorScoop", verts, faces, mats, smooth_angle=60)

# --------------------------------------------------------------------------- lifting surfaces


def airfoil(u_from, u_to, count, thickness, camber=0.015):
    """Closed airfoil ring (u, offset) from upper TE side forward then lower side back."""
    def yt(u):
        return 5 * thickness * (0.2969 * math.sqrt(u) - 0.1260 * u - 0.3516 * u ** 2 + 0.2843 * u ** 3 - 0.1036 * u ** 4)

    def yc(u):
        p = 0.4
        return camber / p ** 2 * (2 * p * u - u * u) if u < p else camber / (1 - p) ** 2 * ((1 - 2 * p) + 2 * p * u - u * u)

    us = [u_from + (u_to - u_from) * (1 - math.cos(math.pi * i / (count - 1))) / 2 for i in range(count)]
    upper = [(u, yc(u) + yt(u)) for u in reversed(us)]
    lower = [(u, yc(u) - yt(u)) for u in us[1:-1]] if u_from == 0.0 else [(u, yc(u) - yt(u)) for u in us]
    if u_from == 0.0:
        return upper + lower
    return upper + lower


def surface_loft(name, stations, u_from, u_to, mats_fn, pivot=(0, 0, 0), count=14, mirror=False, vertical=False):
    """stations: (span, le, chord, base, thickness). Horizontal: span=x, base=y.
    Vertical (fin): span=y, base=x."""
    rings = []
    for span, le, chord, base, thick in stations:
        ring = []
        for u, off in airfoil(u_from, u_to, count, thick):
            z = le + u * chord
            o = off * chord
            if vertical:
                ring.append((base + o, span, z))
            else:
                ring.append((-span if mirror else span, base + o, z))
        rings.append(ring)
    verts, faces = loft(rings)
    mats = [mats_fn(sum(verts[i][0] for i in f) / len(f), sum(verts[i][1] for i in f) / len(f), sum(verts[i][2] for i in f) / len(f)) for f in faces]
    return make_mesh(name, verts, faces, mats, pivot=pivot, smooth_angle=55)


HALF_SPAN = 5.64
DIHEDRAL = math.tan(math.radians(5.0))


def wing_planform(x):
    t = x / HALF_SPAN
    le = -1.05 + 0.70 * t
    te = 1.60 - 0.75 * t
    chord = te - le
    if x > 4.95:  # rounded tip about the quarter chord
        k = math.sqrt(max(0.0, 1 - ((x - 4.95) / (HALF_SPAN - 4.95 + 0.02)) ** 2))
        q = le + chord * 0.3
        chord *= max(k, 0.12)
        le = q - chord * 0.3
    base = -0.40 + x * DIHEDRAL
    thick = 0.15 - 0.04 * t
    return le, chord, base, thick


def wing_station(x):
    le, chord, base, thick = wing_planform(x)
    return (x, le, chord, base, thick)


AIL_U = 0.76
AIL_IN, AIL_OUT = 3.05, 5.25


def upper_surface_y(x, z):
    le, chord, base, thick = wing_planform(abs(x))
    u = min(max((z - le) / chord, 0.0), 1.0)
    p = 0.4
    yc = 0.015 / p ** 2 * (2 * p * u - u * u) if u < p else 0.015 / (1 - p) ** 2 * ((1 - 2 * p) + 2 * p * u - u * u)
    yt = 5 * thick * (0.2969 * math.sqrt(u) - 0.1260 * u - 0.3516 * u ** 2 + 0.2843 * u ** 3 - 0.1036 * u ** 4)
    return base + (yc + yt) * chord


def wing_mats(x, y, z):
    return "skin"


for side, mirror in (("R", False), ("L", True)):
    inner = [wing_station(x) for x in (0.0, 0.5, 1.2, 2.0, 2.6, AIL_IN)]
    outer = [wing_station(x) for x in (AIL_IN, 3.6, 4.2, 4.7, AIL_OUT)]
    tip = [wing_station(x) for x in (AIL_OUT, 5.38, 5.5, 5.58, 5.63)]
    surface_loft(f"Wing_{side}_Inner", inner, 0.0, 1.0, wing_mats, mirror=mirror)
    surface_loft(f"Wing_{side}_Outer", outer, 0.0, AIL_U, wing_mats, mirror=mirror)
    surface_loft(f"Wing_{side}_Tip", tip, 0.0, 1.0, wing_mats, mirror=mirror)
    # Aileron: origin on the hinge line, mid-span.
    xm = (AIL_IN + AIL_OUT) / 2
    le, chord, base, _ = wing_planform(xm)
    hinge = ((-xm if mirror else xm), base + 0.012 * chord, le + AIL_U * chord)
    ail = [wing_station(x) for x in (AIL_IN + 0.02, 3.8, 4.5, AIL_OUT - 0.02)]
    surface_loft(f"Aileron_{side}", ail, AIL_U, 1.0, wing_mats, pivot=hinge, mirror=mirror)

# Tailplane and elevators.
TAIL_SPAN = 2.08


def tail_station(x):
    t = x / TAIL_SPAN
    le = 4.05 + 0.42 * t
    te = 5.27 - 0.08 * t
    chord = te - le
    if x > 1.55:
        k = math.sqrt(max(0.0, 1 - ((x - 1.55) / (TAIL_SPAN - 1.55 + 0.02)) ** 2))
        q = le + chord * 0.3
        chord *= max(k, 0.15)
        le = q - chord * 0.3
    return (x, le, chord, 0.20, 0.10)


ELEV_U = 0.62
for side, mirror in (("R", False), ("L", True)):
    stab = [tail_station(x) for x in (0.0, 0.4, 1.0, 1.55, 1.8, 1.95, 2.06)]
    surface_loft(f"Stabilizer_{side}", stab, 0.0, ELEV_U, wing_mats, mirror=mirror)
    xm = 1.0
    st = tail_station(xm)
    hinge = ((-xm if mirror else xm), 0.20, st[1] + ELEV_U * st[2])
    elev = [tail_station(x) for x in (0.22, 0.8, 1.4, 1.75)]
    surface_loft(f"Elevator_{side}", elev, ELEV_U, 1.0, wing_mats, pivot=hinge, mirror=mirror)

# Fin and rudder (vertical surfaces: span runs up +Y).
FIN_ROOT, FIN_TOP = 0.28, 1.62


def fin_station(y):
    t = (y - FIN_ROOT) / (FIN_TOP - FIN_ROOT)
    le = 3.98 + 0.70 * t
    te = 5.33 - 0.10 * t
    chord = te - le
    if t > 0.72:
        k = math.sqrt(max(0.0, 1 - ((t - 0.72) / 0.30) ** 2))
        q = le + chord * 0.35
        chord *= max(k, 0.15)
        le = q - chord * 0.35
    return (y, le, chord, 0.0, 0.10)


RUD_U = 0.58


def fin_mats(x, y, z):
    return "accent" if y > 1.38 else "skin"


fin = [fin_station(y) for y in (FIN_ROOT, 0.6, 1.0, 1.3, 1.45, 1.55, 1.61)]
surface_loft("Fin", fin, 0.0, RUD_U, fin_mats, vertical=True)
st = fin_station(0.9)
surface_loft("Rudder", [fin_station(y) for y in (0.30, 0.8, 1.2, 1.48)], RUD_U, 1.0, fin_mats,
             pivot=(0.0, 0.9, st[1] + RUD_U * st[2]), vertical=True)

# Dorsal fillet blending the fin into the spine.
fv = [(0.0, 0.44, 2.6), (0.0, 0.74, 4.12), (0.0, 0.36, 4.4)]
verts = [(-0.04, y, z) for _, y, z in fv] + [(0.04, y, z) for _, y, z in fv]
verts[0] = (0.0, 0.44, 2.6)
verts[3] = (0.0, 0.44, 2.6)
faces = [(0, 1, 2), (5, 4, 3), (0, 3, 4, 1), (1, 4, 5, 2), (2, 5, 3, 0)]
make_mesh("DorsalFillet", verts, faces, ["skin"] * len(faces), smooth_angle=30)

# --------------------------------------------------------------------------- canopy & cockpit
CANOPY = [  # z, half width, height above spine
    (-1.30, 0.29, 0.00), (-1.22, 0.30, 0.17), (-1.02, 0.31, 0.38), (-0.75, 0.33, 0.50), (-0.35, 0.34, 0.56),
    (0.05, 0.33, 0.53), (0.35, 0.30, 0.44), (0.58, 0.24, 0.28), (0.74, 0.16, 0.04)]
rings = []
for z, w, hgt in catmull(CANOPY, 3):
    base = fuselage_at(z)[1] - 0.05
    ring = []
    for i in range(18):
        th = math.pi * i / 17
        c, s = math.cos(th), math.sin(th)
        ring.append((w * c, base + max(hgt, 0.01) * s ** 0.85, z))
    rings.append(ring)
verts, faces = loft(rings)
mats = []
for f in faces:
    cz = sum(verts[i][2] for i in f) / len(f)
    mats.append("frame" if -1.06 < cz < -0.96 or len(f) == 3 else "glass")
make_mesh("Canopy", verts, faces, mats, smooth_angle=70)

bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=10, radius=0.14, location=G(0.0, 0.83, -0.22))
head = bpy.context.object
head.name = "Pilot"
head.data.materials.append(MAT["pilot"])
bpy.ops.object.shade_smooth()
bpy.ops.mesh.primitive_cube_add(size=1, location=G(0.0, 0.67, -0.05))
seat = bpy.context.object
seat.name = "PilotShoulders"
seat.dimensions = (0.40, 0.18, 0.20)
seat.data.materials.append(MAT["dark"])

# --------------------------------------------------------------------------- propeller assembly
PROP_Z = -3.92
prop = empty("Propeller", (0.0, 0.0, PROP_Z))
rings = []
for i in range(13):
    t = i / 12
    r = 0.33 * (1 - t ** 2.2) ** 0.55
    z = -3.86 - t * 0.72
    rings.append([(max(r, 0.004) * math.cos(2 * math.pi * k / 20), max(r, 0.004) * math.sin(2 * math.pi * k / 20), z) for k in range(20)])
verts, faces = loft(rings, cap_start=True, cap_end=True)
make_mesh("Spinner", verts, faces, ["accent"] * len(faces), pivot=(0.0, 0.0, PROP_Z), parent=prop, smooth_angle=80)

R_ROOT, R_TIP = 0.24, 1.70
for b in range(4):
    ang = b * math.pi / 2
    rings = []
    radii = [R_ROOT + (R_TIP - R_ROOT) * (1 - math.cos(math.pi * i / 22)) / 2 for i in range(23)]
    for r in radii:
        chord = 0.20 + 0.10 * math.sin(min(r / 1.1, 1.0) * math.pi * 0.6)
        if r > 1.5:
            chord *= math.sqrt(max(0.0, 1 - ((r - 1.5) / 0.21) ** 2)) * 0.9 + 0.1
        beta = math.atan(3.1 / (2 * math.pi * max(r, 0.3)))
        thick = 0.16 - 0.10 * (r / R_TIP)
        ring = []
        for u, off in airfoil(0.0, 1.0, 8, thick, 0.03):
            tang = (u - 0.35) * chord
            ax = off * chord
            t_rot = tang * math.cos(beta) - ax * math.sin(beta)
            z_rot = tang * math.sin(beta) + ax * math.cos(beta)
            # Blade along local +Y, rotated about the shaft.
            x = t_rot * math.cos(ang) - r * math.sin(ang)
            y = t_rot * math.sin(ang) + r * math.cos(ang)
            ring.append((x, y, PROP_Z + z_rot))
        rings.append(ring)
    verts, faces = loft(rings)
    mats = []
    for f in faces:
        cx = sum(verts[i][0] for i in f) / len(f)
        cy = sum(verts[i][1] for i in f) / len(f)
        mats.append("tip" if math.hypot(cx, cy) > 1.56 else "blade")
    make_mesh(f"Blade_{b}", verts, faces, mats, pivot=(0.0, 0.0, PROP_Z), parent=prop, smooth_angle=60)

# --------------------------------------------------------------------------- details
def cylinder(name, a, b, radius, mat_key, segments=10):
    va, vb = Vector(G(*a)), Vector(G(*b))
    d = vb - va
    bpy.ops.mesh.primitive_cylinder_add(vertices=segments, radius=radius, depth=d.length, location=(va + vb) / 2)
    ob = bpy.context.object
    ob.name = name
    ob.rotation_mode = "QUATERNION"
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
    ob.data.materials.append(MAT[mat_key])
    return ob


for side in (-1, 1):
    tag = "L" if side < 0 else "R"
    for k in range(6):
        z = -3.18 + k * 0.2
        x0 = side_x(z, 0.16) - 0.02
        cylinder(f"Exhaust_{tag}_{k}", (side * x0, 0.16, z), (side * (x0 + 0.09), 0.15, z + 0.07), 0.042, "exhaust", 8)
    for k, x in enumerate((1.95, 2.22, 2.49)):
        le, chord, base, _ = wing_planform(x)
        cylinder(f"Gun_{tag}_{k}", (side * x, base + 0.03, le + 0.25), (side * x, base + 0.03, le - 0.16 - 0.04 * k), 0.022, "dark", 8)
    le, chord, base, _ = wing_planform(HALF_SPAN - 0.04)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=8, ring_count=6, radius=0.05, location=G(side * (HALF_SPAN - 0.02), base + 0.01, le + chord * 0.3))
    light = bpy.context.object
    light.name = f"NavLight_{tag}"
    light.data.materials.append(MAT["nav_red" if side < 0 else "nav_green"])
    empty(f"Muzzle_{tag}", (side * 2.22, wing_planform(2.22)[2] + 0.03, wing_planform(2.22)[0] - 0.25))
    empty(f"ExhaustPort_{tag}", (side * (side_x(-2.7, 0.16) + 0.08), 0.15, -2.7))
    empty(f"WingTip_{tag}", (side * (HALF_SPAN - 0.05), wing_planform(HALF_SPAN - 0.05)[2], wing_planform(HALF_SPAN - 0.05)[0] + 0.4))

cylinder("Antenna", (0.0, 0.52, 1.05), (0.0, 0.92, 1.32), 0.018, "dark", 6)
le, chord, base, _ = wing_planform(4.6)
cylinder("Pitot", (4.6, base - 0.08, le + 0.1), (4.6, base - 0.08, le - 0.45), 0.012, "dark", 6)

# --------------------------------------------------------------------------- fictional insignia


def disc_rings(cx, cz, radii, project):
    """Concentric discs conforming to a surface. project(x, z) -> 3D point."""
    pieces = []
    for r_out, r_in, key in radii:
        verts, faces = [], []
        n = 28
        for i in range(n):
            a = 2 * math.pi * i / n
            for r in (r_out, r_in):
                verts.append(project(cx + r * math.cos(a), cz + r * math.sin(a)))
        for i in range(n):
            j = (i + 1) % n
            if r_in > 0:
                faces.append((2 * i, 2 * j, 2 * j + 1, 2 * i + 1))
            else:
                faces.append((2 * i, 2 * j, 2 * j + 1))
        pieces.append((verts, faces, key))
    return pieces


ROUNDEL = [(0.40, 0.31, "ins_white"), (0.31, 0.12, "ins_blue"), (0.12, 0.0, "accent")]
for side in (-1, 1):
    tag = "L" if side < 0 else "R"
    wx = 4.0
    le, chord, _, _ = wing_planform(wx)
    for k, (verts, faces, key) in enumerate(disc_rings(side * wx, le + chord * 0.42, ROUNDEL,
                                                       lambda x, z: (x, upper_surface_y(x, z) + 0.006 + 0.001 * k, z))):
        make_mesh(f"Roundel_Wing_{tag}_{k}", verts, faces, [key] * len(faces), smooth_angle=89)
    for k, (verts, faces, key) in enumerate(disc_rings(2.15, 0.02, [(r * 0.85, ri * 0.85, kk) for r, ri, kk in ROUNDEL],
                                                       lambda z, y: (side * (side_x(z, y) + 0.006 + 0.001 * k), y, z))):
        make_mesh(f"Roundel_Side_{tag}_{k}", verts, faces, [key] * len(faces), smooth_angle=89)

empty("CameraTarget", (0.0, 0.6, 0.0))

# --------------------------------------------------------------------------- save & export
(ROOT / "source-assets").mkdir(exist_ok=True)
(ROOT / "game/assets/models").mkdir(parents=True, exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / "source-assets/mustang.blend"))
bpy.ops.export_scene.gltf(filepath=str(ROOT / "game/assets/models/mustang.glb"), export_format="GLB",
                          export_apply=True, export_yup=True, export_extras=False)
print("MUSTANG_EXPORTED", sum(len(o.data.polygons) for o in bpy.data.objects if o.type == "MESH"), "faces")

if PREVIEW:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.show_cavity = True
    scene.render.resolution_x, scene.render.resolution_y = 1600, 900
    scene.render.film_transparent = False
    world = bpy.data.worlds.new("Preview")
    scene.world = world
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    COLLECTION.objects.link(cam)
    scene.camera = cam
    shots = ROOT / "build/shots"
    shots.mkdir(parents=True, exist_ok=True)
    for label, pos in (("front", (-9.0, 4.0, -12.0)), ("rear", (8.0, 5.0, 14.0)), ("top", (0.0, 22.0, 0.5))):
        cam.location = G(*pos)
        direction = Vector(G(0.0, 0.0, 0.3)) - cam.location
        cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = str(shots / f"mustang_{label}.png")
        bpy.ops.render.render(write_still=True)
    print("PREVIEW_DONE")
