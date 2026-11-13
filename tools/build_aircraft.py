"""Build the three aircraft models in Blender and export them for Godot.

Run:  blender --background --factory-startup --python tools/build_aircraft.py [-- --plane=NAME --preview]
Writes, for each of spitfire / mustang / thunderbolt:
  source-assets/NAME.blend             editable source (separate named parts)
  game/assets/models/NAME.glb          game asset
  build/shots/NAME_{front,rear,top}.png   optional workbench renders (--preview)

Coordinates are written in Godot space (metres): +X right wing, +Y up, -Z toward
the nose. Overall sizes follow the real aircraft:
  Supermarine Spitfire Mk IX     span 11.23 m, length 9.47 m, elliptical wing
  North American P-51D Mustang   span 11.28 m, length 9.83 m, belly radiator
  Republic P-47D Thunderbolt     span 12.43 m, length 11.0 m, radial engine
Markings are fictional. Paint is applied in the game by the skin shader. Moving
parts (propeller, ailerons, elevators, rudder) have their origin on their
rotation axis so the game can animate them. Every model exposes the same named
parts and empties (Propeller, Aileron_L/R, Elevator_L/R, Rudder, Muzzle_L/R,
ExhaustPort_L/R, WingTip_L/R, CameraTarget).
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
PREVIEW = "--preview" in ARGS
ONLY = [a.split("=", 1)[1] for a in ARGS if a.startswith("--plane=")]

MAT: dict = {}
COLLECTION = None


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


def reset_scene():
    global MAT, COLLECTION
    bpy.ops.wm.read_factory_settings(use_empty=True)
    COLLECTION = bpy.context.scene.collection
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


def linspace(a, b, n):
    return [a + (b - a) * i / (n - 1) for i in range(n)]


def toward_tip(a, b, n):
    """n stations from a to b, packed closer together near b (the rounded tip)."""
    return [a + (b - a) * math.sin(math.pi / 2 * i / (n - 1)) for i in range(n)]


def round_tip(pos, le, chord, start, end, pivot_u, floor):
    """Shrink the chord to a rounded tip between start and end, about pivot_u."""
    if pos <= start:
        return le, chord
    k = math.sqrt(max(0.0, 1 - ((pos - start) / (end - start + 0.02)) ** 2))
    q = le + chord * pivot_u
    chord *= max(k, floor)
    return q - chord * pivot_u, chord


def centroid(verts, face):
    n = len(face)
    return tuple(sum(verts[i][k] for i in face) / n for k in range(3))


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
    mats = [mats_fn(*centroid(verts, f)) for f in faces]
    return make_mesh(name, verts, faces, mats, pivot=pivot, smooth_angle=55)


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


class Airframe:
    """Shared construction steps; a plane definition supplies shapes and numbers."""

    def __init__(self, p: dict):
        self.p = p
        self.sections = catmull(p["fuselage"], 4)
        self.exp = p.get("section_exp", 2.5)
        self.half_span = p["half_span"]

    # ----------------------------------------------------------------- fuselage
    def fuselage_at(self, z):
        """Interpolated (w, top, bottom) at z."""
        s = self.sections
        for (z0, *a), (z1, *b) in zip(s, s[1:]):
            if z0 <= z <= z1:
                t = (z - z0) / (z1 - z0)
                return tuple(u + (v - u) * t for u, v in zip(a, b))
        return s[-1][1:] if z > 0 else s[0][1:]

    def side_x(self, z, y):
        w, top, bottom = self.fuselage_at(z)
        h = top if y >= 0 else -bottom
        q = min(abs(y) / h, 0.999) if h > 0 else 0.999
        return w * (1 - q ** self.exp) ** (1 / self.exp)

    def build_fuselage(self):
        n = self.exp
        seg = 32
        rings = []
        for z, w, top, bottom in self.sections:
            ring = []
            for i in range(seg):
                th = 2 * math.pi * i / seg
                c, s = math.cos(th), math.sin(th)
                x = w * math.copysign(abs(c) ** (2 / n), c)
                y = top * abs(s) ** (2 / n) if s >= 0 else bottom * abs(s) ** (2 / n)
                ring.append((x, y, z))
            rings.append(ring)
        verts, faces = loft(rings)
        mats = [self.p["fuselage_mats"](*centroid(verts, f), len(f) == 3) for f in faces]
        make_mesh("Fuselage", verts, faces, mats)

    # ----------------------------------------------------------------- wings
    def wing(self, x):
        return self.p["wing"](x)

    def wing_station(self, x):
        return (x, *self.wing(x))

    def upper_surface_y(self, x, z):
        le, chord, base, thick = self.wing(abs(x))
        u = min(max((z - le) / chord, 0.0), 1.0)
        p = 0.4
        yc = 0.015 / p ** 2 * (2 * p * u - u * u) if u < p else 0.015 / (1 - p) ** 2 * ((1 - 2 * p) + 2 * p * u - u * u)
        yt = 5 * thick * (0.2969 * math.sqrt(u) - 0.1260 * u - 0.3516 * u ** 2 + 0.2843 * u ** 3 - 0.1036 * u ** 4)
        return base + (yc + yt) * chord

    def build_wings(self):
        p = self.p
        a_in, a_out, a_u = p["aileron"]
        b = self.half_span
        st = p.get("wing_stations", {})
        inner = st.get("inner", linspace(0.0, a_in, 7))
        outer = st.get("outer", linspace(a_in, a_out, 6))
        tip = st.get("tip", toward_tip(a_out, b - 0.01, 9))
        ail = st.get("aileron", linspace(a_in + 0.02, a_out - 0.02, 5))
        skin = lambda x, y, z: "skin"
        for side, mirror in (("R", False), ("L", True)):
            surface_loft(f"Wing_{side}_Inner", [self.wing_station(x) for x in inner], 0.0, 1.0, skin, mirror=mirror)
            surface_loft(f"Wing_{side}_Outer", [self.wing_station(x) for x in outer], 0.0, a_u, skin, mirror=mirror)
            surface_loft(f"Wing_{side}_Tip", [self.wing_station(x) for x in tip], 0.0, 1.0, skin, mirror=mirror)
            # Aileron: origin on the hinge line, mid-span.
            xm = (a_in + a_out) / 2
            le, chord, base, _ = self.wing(xm)
            hinge = ((-xm if mirror else xm), base + 0.012 * chord, le + a_u * chord)
            surface_loft(f"Aileron_{side}", [self.wing_station(x) for x in ail], a_u, 1.0, skin, pivot=hinge, mirror=mirror)

    # ----------------------------------------------------------------- tail
    def build_tail(self):
        p = self.p
        tail = p["tail"]
        span, elev_u, base_y = p["tail_span"], p["elevator_u"], p["tail_y"]
        st = p.get("tail_stations", {})
        stab = st.get("stab", toward_tip(0.0, span - 0.02, 8))
        elev = st.get("elevator", linspace(0.22, span * 0.9, 5))
        xm = st.get("hinge_x", span * 0.5)
        skin = lambda x, y, z: "skin"
        for side, mirror in (("R", False), ("L", True)):
            surface_loft(f"Stabilizer_{side}", [tail(x) for x in stab], 0.0, elev_u, skin, mirror=mirror)
            ts = tail(xm)
            hinge = ((-xm if mirror else xm), base_y, ts[1] + elev_u * ts[2])
            surface_loft(f"Elevator_{side}", [tail(x) for x in elev], elev_u, 1.0, skin, pivot=hinge, mirror=mirror)

        fin = p["fin"]
        root, top = p["fin_root"], p["fin_top"]
        rud_u = p["rudder_u"]
        fin_mats = p.get("fin_mats", lambda x, y, z: "skin")
        fst = p.get("fin_stations", {})
        fin_ys = fst.get("fin", toward_tip(root, top - 0.01, 8))
        rud_ys = fst.get("rudder", linspace(root + 0.02, root + (top - root) * 0.9, 5))
        ym = fst.get("hinge_y", root + (top - root) * 0.46)
        surface_loft("Fin", [fin(y) for y in fin_ys], 0.0, rud_u, fin_mats, vertical=True)
        fs = fin(ym)
        surface_loft("Rudder", [fin(y) for y in rud_ys], rud_u, 1.0, fin_mats,
                     pivot=(0.0, ym, fs[1] + rud_u * fs[2]), vertical=True)
        fillet = p.get("dorsal_fillet")
        if fillet:
            # Thin blade blending the fin into the spine.
            verts = [(-0.04, y, z) for y, z in fillet] + [(0.04, y, z) for y, z in fillet]
            verts[0] = (0.0, fillet[0][0], fillet[0][1])
            verts[3] = verts[0]
            faces = [(0, 1, 2), (5, 4, 3), (0, 3, 4, 1), (1, 4, 5, 2), (2, 5, 3, 0)]
            make_mesh("DorsalFillet", verts, faces, ["skin"] * len(faces), smooth_angle=30)

    # ----------------------------------------------------------------- canopy
    def build_canopy(self):
        p = self.p
        rings = []
        for z, w, hgt in catmull(p["canopy"], 3):
            base = self.fuselage_at(z)[1] - 0.05
            ring = []
            for i in range(18):
                th = math.pi * i / 17
                c, s = math.cos(th), math.sin(th)
                ring.append((w * c, base + max(hgt, 0.01) * s ** 0.85, z))
            rings.append(ring)
        verts, faces = loft(rings)
        mats = [p["canopy_mats"](centroid(verts, f)[2], len(f) == 3) for f in faces]
        make_mesh("Canopy", verts, faces, mats, smooth_angle=70)
        hx, hy, hz = p["pilot"]
        bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=10, radius=0.14, location=G(hx, hy, hz))
        head = bpy.context.object
        head.name = "Pilot"
        head.data.materials.append(MAT["pilot"])
        bpy.ops.object.shade_smooth()
        bpy.ops.mesh.primitive_cube_add(size=1, location=G(hx, hy - 0.16, hz + 0.17))
        seat = bpy.context.object
        seat.name = "PilotShoulders"
        seat.dimensions = (0.40, 0.18, 0.20)
        seat.data.materials.append(MAT["dark"])

    # ----------------------------------------------------------------- propeller
    def build_propeller(self):
        p = self.p["prop"]
        prop_z = p["z"]
        prop = empty("Propeller", (0.0, 0.0, prop_z))
        r0, length, z0 = p["spinner_radius"], p["spinner_length"], p["spinner_z"]
        rings = []
        for i in range(13):
            t = i / 12
            r = max(r0 * (1 - t ** 2.2) ** 0.55, 0.004)
            z = z0 - t * length
            rings.append([(r * math.cos(2 * math.pi * k / 20), r * math.sin(2 * math.pi * k / 20), z) for k in range(20)])
        verts, faces = loft(rings, cap_start=True, cap_end=True)
        make_mesh("Spinner", verts, faces, [p.get("spinner_mat", "accent")] * len(faces), pivot=(0.0, 0.0, prop_z), parent=prop, smooth_angle=80)

        r_root, r_tip = p["blade_root"], p["blade_tip"]
        c_base, c_bulge = p.get("chord", (0.20, 0.10))
        blades = p.get("blades", 4)
        for b in range(blades):
            ang = b * 2 * math.pi / blades
            rings = []
            radii = [r_root + (r_tip - r_root) * (1 - math.cos(math.pi * i / 22)) / 2 for i in range(23)]
            for r in radii:
                chord = c_base + c_bulge * math.sin(min(r / (0.647 * r_tip), 1.0) * math.pi * 0.6)
                if r > r_tip - 0.2:
                    chord *= math.sqrt(max(0.0, 1 - ((r - (r_tip - 0.2)) / 0.21) ** 2)) * 0.9 + 0.1
                beta = math.atan(3.1 / (2 * math.pi * max(r, 0.3)))
                thick = 0.16 - 0.10 * (r / r_tip)
                ring = []
                for u, off in airfoil(0.0, 1.0, 8, thick, 0.03):
                    tang = (u - 0.35) * chord
                    ax = off * chord
                    t_rot = tang * math.cos(beta) - ax * math.sin(beta)
                    z_rot = tang * math.sin(beta) + ax * math.cos(beta)
                    # Blade along local +Y, rotated about the shaft.
                    x = t_rot * math.cos(ang) - r * math.sin(ang)
                    y = t_rot * math.sin(ang) + r * math.cos(ang)
                    ring.append((x, y, prop_z + z_rot))
                rings.append(ring)
            verts, faces = loft(rings)
            mats = []
            for f in faces:
                cx, cy, _ = centroid(verts, f)
                mats.append("tip" if math.hypot(cx, cy) > r_tip - 0.14 else "blade")
            make_mesh(f"Blade_{b}", verts, faces, mats, pivot=(0.0, 0.0, prop_z), parent=prop, smooth_angle=60)

    # ----------------------------------------------------------------- details
    def build_details(self):
        p = self.p
        b = self.half_span
        stubs = p.get("exhaust_stubs")
        for side in (-1, 1):
            tag = "L" if side < 0 else "R"
            if stubs:
                z_first, count, y = stubs
                for k in range(count):
                    z = z_first + k * 0.2
                    x0 = self.side_x(z, y) - 0.02
                    cylinder(f"Exhaust_{tag}_{k}", (side * x0, y, z), (side * (x0 + 0.09), y - 0.01, z + 0.07), 0.042, "exhaust", 8)
            for k, (x, ahead, radius) in enumerate(p["guns"]):
                le, chord, base, _ = self.wing(x)
                cylinder(f"Gun_{tag}_{k}", (side * x, base + 0.03, le + 0.25), (side * x, base + 0.03, le - ahead), radius, "dark", 8)
            le, chord, base, _ = self.wing(b - 0.04)
            bpy.ops.mesh.primitive_uv_sphere_add(segments=8, ring_count=6, radius=0.05, location=G(side * (b - 0.02), base + 0.01, le + chord * 0.3))
            light = bpy.context.object
            light.name = f"NavLight_{tag}"
            light.data.materials.append(MAT["nav_red" if side < 0 else "nav_green"])
            mx, m_ahead = p["muzzle"]
            empty(f"Muzzle_{tag}", (side * mx, self.wing(mx)[2] + 0.03, self.wing(mx)[0] - m_ahead))
            ez, ey = p["exhaust_port"]
            empty(f"ExhaustPort_{tag}", (side * (self.side_x(ez, ey) + 0.08), ey - 0.01, ez))
            tle, tchord, tbase, _ = self.wing(b - 0.05)
            empty(f"WingTip_{tag}", (side * (b - 0.05), tbase, tle + min(0.4, tchord * 0.6)))
        a, bb = p["antenna"]
        cylinder("Antenna", a, bb, 0.018, "dark", 6)
        px = p["pitot_x"]
        le, chord, base, _ = self.wing(px)
        cylinder("Pitot", (px, base - 0.08, le + 0.1), (px, base - 0.08, le - 0.45), 0.012, "dark", 6)
        empty("CameraTarget", (0.0, 0.6, 0.0))

    def build_insignia(self):
        wx = self.p["roundel_wing_x"]
        sz, sy, scale = self.p["roundel_side"]
        for side in (-1, 1):
            tag = "L" if side < 0 else "R"
            le, chord, _, _ = self.wing(wx)
            for k, (verts, faces, key) in enumerate(disc_rings(side * wx, le + chord * 0.42, ROUNDEL,
                                                               lambda x, z: (x, self.upper_surface_y(x, z) + 0.008, z))):
                make_mesh(f"Roundel_Wing_{tag}_{k}", verts, faces, [key] * len(faces), smooth_angle=89)
            for k, (verts, faces, key) in enumerate(disc_rings(sz, sy, [(r * scale, ri * scale, kk) for r, ri, kk in ROUNDEL],
                                                               lambda z, y: (side * (self.side_x(z, y) + 0.008), y, z))):
                make_mesh(f"Roundel_Side_{tag}_{k}", verts, faces, [key] * len(faces), smooth_angle=89)

    def pod(self, name, sections, x, top_fn, segments=20, shape=0.5, mats=None):
        """Faired pod hanging below a surface: sections are (z, half width, bottom y)."""
        rings = []
        for z, w, bottom in catmull(sections, 3):
            top = top_fn(z)
            mid = (top + bottom) * 0.5
            half_h = (top - bottom) * 0.5
            ring = []
            for i in range(segments):
                th = 2 * math.pi * i / segments
                c, s = math.cos(th), math.sin(th)
                ring.append((x + w * math.copysign(abs(c) ** shape, c), mid + half_h * math.copysign(abs(s) ** shape, s), z))
            rings.append(ring)
        verts, faces = loft(rings)
        z_front = sections[0][0] + 0.02
        face_mats = [("dark" if len(f) == 3 and centroid(verts, f)[2] < z_front else "skin") for f in faces] if mats is None else mats(verts, faces)
        make_mesh(name, verts, faces, face_mats, smooth_angle=60)

    def build(self):
        self.build_fuselage()
        self.build_wings()
        self.build_tail()
        self.build_canopy()
        self.build_propeller()
        self.build_details()
        self.build_insignia()
        if "extras" in self.p:
            self.p["extras"](self)


# =========================================================================== P-51D Mustang
def mustang() -> dict:
    half_span = 5.64
    dihedral = math.tan(math.radians(5.0))

    def wing(x):
        t = x / half_span
        le = -1.05 + 0.70 * t
        chord = (1.60 - 0.75 * t) - le
        le, chord = round_tip(x, le, chord, 4.95, half_span, 0.3, 0.12)
        return le, chord, -0.40 + x * dihedral, 0.15 - 0.04 * t

    tail_span = 2.08

    def tail(x):
        t = x / tail_span
        le = 4.05 + 0.42 * t
        chord = (5.27 - 0.08 * t) - le
        le, chord = round_tip(x, le, chord, 1.55, tail_span, 0.3, 0.15)
        return (x, le, chord, 0.20, 0.10)

    fin_root, fin_top = 0.28, 1.62

    def fin(y):
        t = (y - fin_root) / (fin_top - fin_root)
        le = 3.98 + 0.70 * t
        chord = (5.33 - 0.10 * t) - le
        if t > 0.72:
            k = math.sqrt(max(0.0, 1 - ((t - 0.72) / 0.30) ** 2))
            q = le + chord * 0.35
            chord *= max(k, 0.15)
            le = q - chord * 0.35
        return (y, le, chord, 0.0, 0.10)

    def fuselage_mats(cx, cy, cz, tri):
        if -3.86 <= cz <= -3.42 or 3.0 <= cz <= 3.32:
            return "accent"
        if cy > 0.24 and -3.42 < cz < -1.25 and abs(cx) < 0.3:
            return "antiglare"
        return "skin"

    def extras(af: Airframe):
        # Belly radiator scoop.
        scoop = [(-0.05, 0.24, -0.92), (0.40, 0.27, -0.97), (1.20, 0.28, -0.95), (2.00, 0.25, -0.83), (2.60, 0.18, -0.67), (3.05, 0.07, -0.52)]
        af.pod("RadiatorScoop", scoop, 0.0, lambda z: af.fuselage_at(z)[2] + 0.14)

    return {
        "name": "mustang",
        "fuselage": [  # z, half width, top, bottom
            (-3.86, 0.33, 0.31, -0.33), (-3.55, 0.39, 0.39, -0.46), (-3.10, 0.42, 0.45, -0.54), (-2.50, 0.44, 0.50, -0.56),
            (-1.90, 0.46, 0.54, -0.57), (-1.30, 0.47, 0.56, -0.58), (-0.60, 0.48, 0.57, -0.60), (0.20, 0.47, 0.55, -0.62),
            (1.00, 0.44, 0.51, -0.60), (1.80, 0.39, 0.47, -0.54), (2.60, 0.33, 0.43, -0.45), (3.40, 0.26, 0.39, -0.33),
            (4.20, 0.18, 0.35, -0.20), (4.90, 0.11, 0.31, -0.06), (5.28, 0.04, 0.27, 0.06)],
        "fuselage_mats": fuselage_mats,
        "half_span": half_span,
        "wing": wing,
        "aileron": (3.05, 5.25, 0.76),
        "wing_stations": {"inner": (0.0, 0.5, 1.2, 2.0, 2.6, 3.05), "outer": (3.05, 3.6, 4.2, 4.7, 5.25),
                          "tip": (5.25, 5.38, 5.5, 5.58, 5.63), "aileron": (3.07, 3.8, 4.5, 5.23)},
        "tail": tail, "tail_span": tail_span, "elevator_u": 0.62, "tail_y": 0.20,
        "tail_stations": {"stab": (0.0, 0.4, 1.0, 1.55, 1.8, 1.95, 2.06), "elevator": (0.22, 0.8, 1.4, 1.75), "hinge_x": 1.0},
        "fin": fin, "fin_root": fin_root, "fin_top": fin_top, "rudder_u": 0.58,
        "fin_mats": lambda x, y, z: "accent" if y > 1.38 else "skin",
        "fin_stations": {"fin": (fin_root, 0.6, 1.0, 1.3, 1.45, 1.55, 1.61), "rudder": (0.30, 0.8, 1.2, 1.48), "hinge_y": 0.9},
        "dorsal_fillet": [(0.44, 2.6), (0.74, 4.12), (0.36, 4.4)],
        "canopy": [  # z, half width, height above spine
            (-1.30, 0.29, 0.00), (-1.22, 0.30, 0.17), (-1.02, 0.31, 0.38), (-0.75, 0.33, 0.50), (-0.35, 0.34, 0.56),
            (0.05, 0.33, 0.53), (0.35, 0.30, 0.44), (0.58, 0.24, 0.28), (0.74, 0.16, 0.04)],
        "canopy_mats": lambda cz, tri: "frame" if -1.06 < cz < -0.96 or tri else "glass",
        "pilot": (0.0, 0.83, -0.22),
        "prop": {"z": -3.92, "spinner_z": -3.86, "spinner_radius": 0.33, "spinner_length": 0.72, "blade_root": 0.24, "blade_tip": 1.70},
        "exhaust_stubs": (-3.18, 6, 0.16),
        "guns": [(1.95, 0.16, 0.022), (2.22, 0.20, 0.022), (2.49, 0.24, 0.022)],
        "muzzle": (2.22, 0.25),
        "exhaust_port": (-2.7, 0.16),
        "antenna": ((0.0, 0.52, 1.05), (0.0, 0.92, 1.32)),
        "pitot_x": 4.6,
        "roundel_wing_x": 4.0,
        "roundel_side": (2.15, 0.02, 0.85),
        "extras": extras,
    }


# =========================================================================== Spitfire Mk IX
def spitfire() -> dict:
    half_span = 5.61
    dihedral = math.tan(math.radians(6.0))
    root_chord, axis = 2.55, -0.38   # two half-ellipses sharing a spanwise axis at 34% chord

    def wing(x):
        t = min(x / half_span, 0.9995)
        chord = max(root_chord * math.sqrt(1 - t * t), 0.10)
        return axis - 0.34 * chord, chord, -0.42 + x * dihedral, 0.13 - 0.05 * t

    tail_span = 1.62

    def tail(x):
        t = min(x / tail_span, 0.999)
        chord = max(1.22 * math.sqrt(1 - t * t), 0.08)
        return (x, 4.22 - 0.42 * chord, chord, 0.30, 0.09)

    fin_root, fin_top = 0.22, 1.50

    def fin(y):
        t = (y - fin_root) / (fin_top - fin_root)
        le = 3.92 + 0.62 * t
        chord = (5.02 - 0.10 * t) - le
        if t > 0.55:   # broad rounded top
            k = math.sqrt(max(0.0, 1 - ((t - 0.55) / 0.47) ** 2))
            q = le + chord * 0.45
            chord *= max(k, 0.15)
            le = q - chord * 0.45
        return (y, le, chord, 0.0, 0.09)

    def fuselage_mats(cx, cy, cz, tri):
        if 2.95 <= cz <= 3.22:   # rear fuselage identification band
            return "accent"
        return "skin"

    def canopy_mats(cz, tri):
        # Sliding hood, then a metal fairing running back into the high spine.
        if cz > 1.02:
            return "skin"
        if -0.12 < cz < -0.03 or 0.92 < cz <= 1.02 or tri:
            return "frame"
        return "glass"

    def extras(af: Airframe):
        # Twin underwing radiators (symmetrical on the Mk IX) and the chin air intake.
        for side, tag in ((-1, "L"), (1, "R")):
            x = side * 1.36
            base = af.wing(1.36)[2]
            sections = [(-0.42, 0.22, base - 0.28), (-0.10, 0.27, base - 0.37), (0.50, 0.27, base - 0.37),
                        (0.90, 0.25, base - 0.30), (1.18, 0.19, base - 0.16)]
            af.pod(f"Radiator_{tag}", sections, x, lambda z: base + 0.02, segments=16, shape=0.42)
        intake = [(-2.05, 0.10, -0.66), (-1.75, 0.13, -0.72), (-1.20, 0.13, -0.72), (-0.70, 0.08, -0.66)]
        af.pod("AirIntake", intake, 0.0, lambda z: af.fuselage_at(z)[2] + 0.10, segments=14)

    return {
        "name": "spitfire",
        "fuselage": [
            (-3.76, 0.30, 0.30, -0.31), (-3.45, 0.35, 0.38, -0.42), (-3.00, 0.39, 0.44, -0.50), (-2.40, 0.42, 0.48, -0.55),
            (-1.80, 0.43, 0.51, -0.58), (-1.20, 0.44, 0.53, -0.60), (-0.50, 0.44, 0.55, -0.60), (0.20, 0.43, 0.56, -0.58),
            (0.90, 0.40, 0.55, -0.52), (1.60, 0.35, 0.50, -0.44), (2.40, 0.28, 0.43, -0.34), (3.20, 0.20, 0.36, -0.24),
            (4.00, 0.12, 0.30, -0.14), (4.60, 0.06, 0.25, -0.05), (4.96, 0.03, 0.21, 0.03)],
        "fuselage_mats": fuselage_mats,
        "half_span": half_span,
        "wing": wing,
        "aileron": (3.00, 5.05, 0.78),
        "tail": tail, "tail_span": tail_span, "elevator_u": 0.56, "tail_y": 0.30,
        "tail_stations": {"elevator": linspace(0.20, 1.50, 6), "hinge_x": 0.8},
        "fin": fin, "fin_root": fin_root, "fin_top": fin_top, "rudder_u": 0.46,
        "canopy": [
            (-0.38, 0.23, 0.00), (-0.30, 0.25, 0.14), (-0.08, 0.27, 0.33), (0.25, 0.29, 0.42), (0.60, 0.30, 0.43),
            (0.95, 0.28, 0.38), (1.30, 0.24, 0.27), (1.80, 0.18, 0.15), (2.40, 0.10, 0.05), (2.90, 0.04, 0.00)],
        "canopy_mats": canopy_mats,
        "pilot": (0.0, 0.82, 0.48),
        "prop": {"z": -3.82, "spinner_z": -3.76, "spinner_radius": 0.31, "spinner_length": 0.70, "blade_root": 0.22, "blade_tip": 1.63,
                 "chord": (0.18, 0.09)},
        "exhaust_stubs": (-3.10, 6, 0.15),
        # 20 mm Hispano cannon (long barrel) with the capped outer stub beside it.
        "guns": [(1.92, 0.92, 0.036), (2.22, 0.22, 0.045)],
        "muzzle": (1.92, 0.95),
        "exhaust_port": (-2.6, 0.15),
        "antenna": ((0.0, 0.86, 1.20), (0.0, 1.32, 1.38)),
        "pitot_x": 4.3,
        "roundel_wing_x": 3.75,
        "roundel_side": (2.05, 0.02, 0.80),
        "extras": extras,
    }


# =========================================================================== P-47D Thunderbolt
def thunderbolt() -> dict:
    half_span = 6.21
    dihedral = math.tan(math.radians(6.0))
    root_chord = 2.90

    def wing(x):
        # Nearly straight leading edge, elliptical trailing edge, broad round tip.
        t = min(x / half_span, 0.9995)
        chord = max(root_chord * (1 - t ** 2.5) ** 0.6, 0.12)
        le = -2.45 + 0.50 * t + 0.30 * t ** 6
        return le, chord, -0.60 + x * dihedral, 0.15 - 0.05 * t

    tail_span = 2.46

    def tail(x):
        t = min(x / tail_span, 0.999)
        chord = max(1.48 * (1 - t ** 2.4) ** 0.6, 0.10)
        return (x, 4.36 + 0.34 * t + 0.10 * t ** 6, chord, 0.38, 0.10)

    fin_root, fin_top = 0.30, 1.98

    def fin(y):
        t = (y - fin_root) / (fin_top - fin_root)
        le = 4.22 + 0.82 * t
        chord = (5.92 - 0.14 * t) - le
        if t > 0.66:
            k = math.sqrt(max(0.0, 1 - ((t - 0.66) / 0.36) ** 2))
            q = le + chord * 0.4
            chord *= max(k, 0.15)
            le = q - chord * 0.4
        return (y, le, chord, 0.0, 0.10)

    def fuselage_mats(cx, cy, cz, tri):
        if tri and cz < -4.6:
            return "dark"   # open cowl front
        if cz < -4.22:
            return "accent"  # coloured cowl ring
        if 3.55 <= cz <= 3.88:
            return "accent"
        if cy > 0.42 and -4.22 < cz < -1.45 and abs(cx) < 0.36:
            return "antiglare"
        return "skin"

    def extras(af: Airframe):
        # Reduction-gear housing and a ring of cylinders visible inside the cowl.
        cylinder("GearCase", (0.0, 0.0, -4.50), (0.0, 0.0, -4.86), 0.22, "frame", 16)
        for k in range(9):
            a = 2 * math.pi * k / 9
            cx, cy = 0.36 * math.sin(a), -0.03 + 0.38 * math.cos(a)
            cylinder(f"Cylinder_{k}", (cx, cy, -4.50), (cx, cy, -4.70), 0.085, "exhaust", 8)
        # Supercharger exit under the rear fuselage.
        duct = [(1.75, 0.16, -0.94), (2.10, 0.20, -0.96), (2.70, 0.18, -0.82), (3.10, 0.08, -0.66)]
        af.pod("SuperchargerDuct", duct, 0.0, lambda z: af.fuselage_at(z)[2] + 0.12, segments=14)

    return {
        "name": "thunderbolt",
        "section_exp": 2.15,
        "fuselage": [
            (-4.68, 0.50, 0.51, -0.62), (-4.56, 0.62, 0.63, -0.76), (-4.20, 0.66, 0.68, -0.83), (-3.50, 0.68, 0.71, -0.90),
            (-2.70, 0.68, 0.74, -0.95), (-1.80, 0.67, 0.76, -0.98), (-0.90, 0.65, 0.78, -0.98), (0.00, 0.62, 0.76, -0.96),
            (0.90, 0.57, 0.70, -0.90), (1.80, 0.50, 0.63, -0.80), (2.70, 0.41, 0.56, -0.64), (3.60, 0.31, 0.50, -0.46),
            (4.50, 0.20, 0.44, -0.28), (5.30, 0.10, 0.38, -0.12), (5.82, 0.04, 0.33, 0.00)],
        "fuselage_mats": fuselage_mats,
        "half_span": half_span,
        "wing": wing,
        "aileron": (3.45, 5.70, 0.76),
        "tail": tail, "tail_span": tail_span, "elevator_u": 0.60, "tail_y": 0.38,
        "tail_stations": {"elevator": linspace(0.24, 2.25, 6), "hinge_x": 1.2},
        "fin": fin, "fin_root": fin_root, "fin_top": fin_top, "rudder_u": 0.56,
        "fin_mats": lambda x, y, z: "accent" if y > 1.70 else "skin",
        "dorsal_fillet": [(0.52, 2.9), (0.78, 4.34), (0.42, 4.6)],
        "canopy": [
            (-1.50, 0.30, 0.00), (-1.40, 0.32, 0.18), (-1.16, 0.34, 0.40), (-0.80, 0.36, 0.52), (-0.35, 0.37, 0.58),
            (0.10, 0.36, 0.55), (0.46, 0.32, 0.45), (0.76, 0.25, 0.28), (0.98, 0.16, 0.04)],
        "canopy_mats": lambda cz, tri: "frame" if -1.22 < cz < -1.12 or tri else "glass",
        "pilot": (0.0, 1.04, -0.36),
        "prop": {"z": -4.84, "spinner_z": -4.80, "spinner_radius": 0.21, "spinner_length": 0.34, "spinner_mat": "frame",
                 "blade_root": 0.20, "blade_tip": 1.98, "chord": (0.25, 0.14)},
        "guns": [(2.50, 0.42, 0.024), (2.76, 0.34, 0.024), (3.02, 0.26, 0.024), (3.28, 0.18, 0.024)],
        "muzzle": (2.89, 0.38),
        "exhaust_port": (-3.6, -0.50),
        "antenna": ((0.0, 0.66, 1.45), (0.0, 1.10, 1.72)),
        "pitot_x": 5.1,
        "roundel_wing_x": 4.45,
        "roundel_side": (2.45, 0.0, 1.0),
        "extras": extras,
    }


# =========================================================================== save & export
def render_previews(name: str) -> None:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.show_cavity = True
    scene.render.resolution_x, scene.render.resolution_y = 1600, 900
    scene.render.film_transparent = False
    scene.world = bpy.data.worlds.new("Preview")
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    COLLECTION.objects.link(cam)
    scene.camera = cam
    shots = ROOT / "build/shots"
    shots.mkdir(parents=True, exist_ok=True)
    for label, pos in (("front", (-9.0, 4.0, -12.0)), ("rear", (8.0, 5.0, 14.0)), ("top", (0.0, 24.0, 0.5)), ("side", (-19.0, 0.6, 0.3))):
        cam.location = G(*pos)
        direction = Vector(G(0.0, 0.0, 0.3)) - cam.location
        cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = str(shots / f"{name}_{label}.png")
        bpy.ops.render.render(write_still=True)


def main() -> None:
    (ROOT / "source-assets").mkdir(exist_ok=True)
    (ROOT / "game/assets/models").mkdir(parents=True, exist_ok=True)
    for definition in (spitfire, mustang, thunderbolt):
        plane = definition()
        name = plane["name"]
        if ONLY and name not in ONLY:
            continue
        reset_scene()
        Airframe(plane).build()
        bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / f"source-assets/{name}.blend"))
        bpy.ops.export_scene.gltf(filepath=str(ROOT / f"game/assets/models/{name}.glb"), export_format="GLB",
                                  export_apply=True, export_yup=True, export_extras=False)
        print(f"EXPORTED {name}", sum(len(o.data.polygons) for o in bpy.data.objects if o.type == "MESH"), "faces")
        if PREVIEW:
            render_previews(name)


main()
