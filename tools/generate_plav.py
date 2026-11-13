#!/usr/bin/env python3
"""Generate the Plav - Gusinje arena (Prokletije mountains, Montenegro).

The map is the real place, built in layers so each can be refined on its own:

  1. ELEVATION    surveyed heights (source-assets/plav_dem.npz, about 28 m per pixel;
                  see tools/fetch_plav_dem.py and licenses/TERRAIN-DATA.txt)
  2. LAKE         Plav lake: the level water surface found in the survey
  3. DRAINAGE     where water gathers on the surveyed ground: the Ljuca and the Lim
                  carry real water at lake level, the other streams are gravel beds
                  and brooks painted on the ground
  4. SETTLEMENTS  towns and villages, traced from a satellite screenshot
  5. rules        forest by altitude, slope and aspect; reed beds; hay meadows; snow

Traced coordinates are pixels of a 2000 x 1217 satellite screenshot (north up; not
part of the repository), tied to the survey by the lake. The game puts the lake
surface at 0 m and stretches heights so the highest summit stands 2450 m above
it: the mountains look bigger, and the snow line is at 1500 m. Two liberties are
taken so one level water surface can serve the whole map: ground within a few tens
of metres above the lake is levelled out (the real valley floor climbs 20 m from
the lake to Gusinje), and ground below the lake, down the Lim, is raised to it.

Run:  python3 tools/generate_plav.py
Writes game/assets/terrain/plav_* (same formats as the Alpine valley, plus
plav_mask2.png: R = gravel bed, G = brook, B = settlement, A = reed bed, and
plav_houses.bin) and docs/plav_preview.png, docs/plav_layers.png.
"""
from __future__ import annotations

import heapq
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
from scipy import ndimage
from scipy.spatial import cKDTree

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_terrain as gt  # noqa: E402
from generate_terrain import Noise, blur, fbm, ridged, smoothstep, write_png  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "game" / "assets" / "terrain"
SURVEY = ROOT / "source-assets" / "plav_dem.npz"
MAP_ID = "plav"
SEED = 1906
N = gt.N
SIZE = gt.SIZE
WATER = 0.0               # lake surface in game metres
PEAK = 2450.0             # the highest summit, game metres above the lake
FLOOR_LIFT = 6.0          # the lowest dry ground sits this far above the water
LEVELLING = 45.0          # real metres above the lake over which the ground is levelled out
SNOW_LINE = 1500.0
REF_ORIGIN = (990.0, 680.0)    # screenshot pixel at the world origin: south-west of the
                               # screenshot's centre, so the arena takes in the high peaks
REF_SCALE = 10.25              # metres per screenshot pixel
LAKE_PX = (1563.0, 312.0)      # centre of the lake on the screenshot: ties it to the survey
METRES_PER_DEGREE = (82068.0, 111084.0)   # east-west, north-south at 42.6 N
SUN_AZIMUTH = math.radians(-75.0)   # low sun in the west-north-west
SUN_ELEVATION = math.radians(14.0)
D = 801                   # drainage grid (30 m cells)
BROOK_AREA = 2.0          # km2 of catchment that makes a brook
GRAVEL_AREA = 12.0        # km2 of catchment that makes a gravel bed

# --- Layer 4: settlements (name, px, py, radius in metres, density 0..1) ----------------
SETTLEMENTS = [
    ("Gusinje", 832, 655, 620, 1.0), ("Plav", 1705, 262, 780, 1.0), ("Prnjavor", 1778, 285, 380, 0.7),
    ("Brezojevica", 1570, 132, 420, 0.6), ("Skic", 1672, 168, 380, 0.6), ("Djuricka Rijeka", 1672, 448, 380, 0.5),
    ("Bogajice", 1790, 425, 320, 0.5), ("Vojno Selo", 1568, 478, 380, 0.45), ("Martinovice", 1195, 512, 420, 0.5),
    ("Visnjevo", 1272, 618, 380, 0.5), ("Krusevo", 1052, 676, 340, 0.45), ("Dosudje", 925, 552, 380, 0.55),
    ("Vrela", 858, 545, 260, 0.5), ("Koljenovici", 892, 742, 340, 0.5), ("Grncar", 585, 505, 340, 0.45),
    ("Dolja", 578, 742, 260, 0.4), ("Vusanje", 925, 1068, 360, 0.5), ("Hoti", 1708, 705, 240, 0.35),
    ("Sarkinovici", 1468, 322, 300, 0.4), ("Grebaje", 458, 1140, 160, 0.3), ("Bashkimi", 80, 455, 300, 0.4),
    ("Komaraca", 1800, 52, 300, 0.45),
]

# Route the autopilot and the AI follow: down the Lim to the lake, up the Ljuca to
# Gusinje, then up the Grncar valley. Each point is moved to the lowest ground nearby.
ROUTE = [(1588, 135), (1578, 215), (1565, 310), (1500, 390), (1420, 440), (1300, 500),
         (1150, 560), (1000, 620), (830, 650), (760, 575), (680, 525), (600, 500), (500, 480), (400, 455),
         (310, 440)]
GUSINJE_PX = (832, 655)    # the river carries real water from here down
SPAWN_PX = (1640, 240)     # over the north-east shore of the lake
SPAWN_HEADING = 117.0      # degrees, toward Gusinje (0 = north, positive = toward west)
SHOWERS = [(2600.0, -900.0, 1500.0), (-4300.0, 4600.0, 1900.0), (-6000.0, -1500.0, 1600.0), (6300.0, 2600.0, 1700.0)]


def world(px: float, py: float) -> tuple[float, float]:
    return (px - REF_ORIGIN[0]) * REF_SCALE, (py - REF_ORIGIN[1]) * REF_SCALE


def grid(n: int):
    coords = np.linspace(-SIZE / 2, SIZE / 2, n)
    return np.meshgrid(coords, coords)


class Survey:
    """The surveyed elevations (Web Mercator pixels) and their place in the world."""

    def __init__(self) -> None:
        data = np.load(SURVEY)
        self.elevation = data["elevation_dm"].astype(np.float64) / 10.0
        self.scale = 2 ** int(data["zoom"]) * int(data["tile_size"])
        self.origin = (int(data["tile_x0"]) * int(data["tile_size"]), int(data["tile_y0"]) * int(data["tile_size"]))
        # The lake is the largest perfectly level surface in the survey.
        gy, gx = np.gradient(self.elevation)
        labels, _ = ndimage.label(np.hypot(gx, gy) < 0.05)
        sizes = np.bincount(labels.ravel())
        sizes[0] = 0
        lake = labels == int(np.argmax(sizes))
        row, col = ndimage.center_of_mass(lake)
        self.lake_level = float(np.median(self.elevation[lake]))
        self.lake_lon = (col + 0.5 + self.origin[0]) / self.scale * 360.0 - 180.0
        self.lake_lat = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * (row + 0.5 + self.origin[1]) / self.scale))))

    def sample(self, X, Z, order: int = 3) -> np.ndarray:
        """Real elevation at world positions."""
        lake_x, lake_z = world(*LAKE_PX)
        lon = self.lake_lon + (X - lake_x) / METRES_PER_DEGREE[0]
        lat = self.lake_lat - (Z - lake_z) / METRES_PER_DEGREE[1]
        cols = (lon + 180.0) / 360.0 * self.scale - self.origin[0] - 0.5
        rows = (1.0 - np.arcsinh(np.tan(np.radians(lat))) / math.pi) / 2.0 * self.scale - self.origin[1] - 0.5
        assert cols.min() >= 0 and rows.min() >= 0 and cols.max() <= self.elevation.shape[1] - 1 and rows.max() <= self.elevation.shape[0] - 1, \
            "the survey does not cover the whole map"
        return ndimage.map_coordinates(self.elevation, [rows, cols], order=order, mode="nearest")


def upsample(field, X, Z, order=1):
    n = field.shape[0]
    rows = (Z + SIZE / 2) / SIZE * (n - 1)
    cols = (X + SIZE / 2) / SIZE * (n - 1)
    return ndimage.map_coordinates(field, [rows, cols], order=order, mode="nearest")


def drainage(ground: np.ndarray, cell: float):
    """Where water goes on `ground`: for every cell the cell it drains to, and the
    area (km2) draining through it. Hollows are filled first (priority flood from
    the map edge), so every stream reaches the edge."""
    n = ground.shape[0]
    raw = ground.ravel().tolist()
    filled = [0.0] * (n * n)
    seen = bytearray(n * n)
    heap = []
    for i in range(n):
        for j in (i, (n - 1) * n + i, i * n, i * n + n - 1):
            if not seen[j]:
                seen[j] = 1
                filled[j] = raw[j]
                heap.append((raw[j], j))
    heapq.heapify(heap)
    steps = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
    while heap:
        level, i = heapq.heappop(heap)
        r, c = divmod(i, n)
        for dr, dc in steps:
            rr, cc = r + dr, c + dc
            if 0 <= rr < n and 0 <= cc < n:
                j = rr * n + cc
                if not seen[j]:
                    seen[j] = 1
                    value = raw[j] if raw[j] > level else level + 1e-4
                    filled[j] = value
                    heapq.heappush(heap, (value, j))
    surface = np.array(filled).reshape(n, n)
    # Steepest way down on the filled surface.
    p = np.pad(surface, 1, mode="edge")
    best = np.zeros((n, n))
    recv = np.arange(n * n).reshape(n, n)
    rows = np.arange(n)[:, None]
    cols = np.arange(n)[None, :]
    for dr, dc in steps:
        slope = (surface - p[1 + dr:n + 1 + dr, 1 + dc:n + 1 + dc]) / math.hypot(dr, dc)
        better = slope > best
        best = np.where(better, slope, best)
        recv = np.where(better, np.clip(rows + dr, 0, n - 1) * n + np.clip(cols + dc, 0, n - 1), recv)
    recv = recv.ravel()
    to = recv.tolist()
    area = [1.0] * (n * n)
    for i in np.argsort(surface.ravel(), kind="stable")[::-1].tolist():
        j = to[i]
        if j != i:
            area[j] += area[i]
    return recv, np.array(area) * cell * cell / 1e6


def stream_points(recv, area, threshold: float, step: float = 6.0):
    """Stream centre lines as dense points (x, z) with their catchment area. Cell
    centres are averaged along the flow so the lines do not follow the grid."""
    n = D
    cell = SIZE / (n - 1)
    cells = np.flatnonzero(area >= threshold)
    main_donor = np.arange(n * n)
    order = cells[np.argsort(area[cells])]          # smallest first: the largest donor wins
    main_donor[recv[order]] = np.where(recv[order] != order, order, main_donor[recv[order]])
    x = (np.arange(n * n) % n) * cell - SIZE / 2
    z = (np.arange(n * n) // n) * cell - SIZE / 2
    chain = [main_donor[main_donor[cells]], main_donor[cells], cells, recv[cells], recv[recv[cells]]]
    sx = np.zeros(n * n)
    sz = np.zeros(n * n)
    sx[cells] = np.mean([x[c] for c in chain], axis=0)
    sz[cells] = np.mean([z[c] for c in chain], axis=0)
    down = recv[cells]
    k = np.linspace(0.0, 1.0, max(int(cell * 1.5 / step), 2), endpoint=False)[None, :]
    px = (sx[cells][:, None] * (1 - k) + sx[down][:, None] * k).ravel()
    pz = (sz[cells][:, None] * (1 - k) + sz[down][:, None] * k).ravel()
    return np.stack([px, pz], axis=1), np.repeat(area[cells], k.shape[1]), (sx, sz)


def river_course(recv, area, smooth_xy, start_xz, floor) -> np.ndarray:
    """The river from `start_xz` down to the edge of the map: the largest stream
    near the start, followed downstream, with gentle meanders on open floor."""
    n = D
    cell = SIZE / (n - 1)
    x = (np.arange(n * n) % n) * cell - SIZE / 2
    z = (np.arange(n * n) // n) * cell - SIZE / 2
    near = np.flatnonzero(np.hypot(x - start_xz[0], z - start_xz[1]) < 800.0)
    i = int(near[np.argmax(area[near])])
    cells = [i]
    while recv[i] != i:
        i = int(recv[i])
        cells.append(i)
    pts = np.stack([smooth_xy[0][cells], smooth_xy[1][cells]], axis=1)
    pts, s = resample(chaikin(list(pts), 2), 6.0)
    tangent = np.gradient(pts, axis=0)
    tangent /= np.maximum(np.hypot(tangent[:, 0], tangent[:, 1]), 1e-9)[:, None]
    normal = np.stack([-tangent[:, 1], tangent[:, 0]], axis=1)
    wave = np.sin(s / 780.0 * math.tau + 1.7) * 0.6 + np.sin(s / 290.0 * math.tau + 3.9) * 0.4
    room = upsample(floor, pts[:, 0], pts[:, 1]) * smoothstep(0.0, 300.0, s)
    return pts + normal * (wave * 60.0 * room)[:, None]


def chaikin(points, rounds=2):
    pts = [np.array(p, dtype=float) for p in points]
    for _ in range(rounds):
        out = [pts[0]]
        for a, b in zip(pts[:-1], pts[1:]):
            out.append(a * 0.75 + b * 0.25)
            out.append(a * 0.25 + b * 0.75)
        out.append(pts[-1])
        pts = out
    return pts


def resample(points, step):
    pts = np.array(points, dtype=float)
    seg = np.hypot(*np.diff(pts, axis=0).T)
    s = np.concatenate([[0.0], np.cumsum(seg)])
    at = np.arange(0.0, s[-1] + step * 0.5, step)
    return np.stack([np.interp(at, s, pts[:, 0]), np.interp(at, s, pts[:, 1])], axis=1), at


def distance_to(points, X, Z, reach):
    """Distance from every grid cell to the nearest of `points` and that point's
    index, exact within `reach` metres (1e9 and 0 beyond)."""
    spacing = SIZE / (N - 1)
    near = np.zeros((N, N), dtype=bool)
    ci = np.clip(np.rint((points[:, 0] + SIZE / 2) / spacing).astype(int), 0, N - 1)
    ri = np.clip(np.rint((points[:, 1] + SIZE / 2) / spacing).astype(int), 0, N - 1)
    near[ri, ci] = True
    near = ndimage.distance_transform_edt(~near) * spacing < reach + 2.0 * spacing
    d = np.full((N, N), 1e9)
    which = np.zeros((N, N), dtype=np.int64)
    d[near], which[near] = cKDTree(points).query(np.stack([X[near], Z[near]], axis=1))
    return d, which


def build() -> dict:
    t0 = time.time()
    X, Z = grid(N)
    spacing = SIZE / (N - 1)
    n2, n3, n4 = Noise(SEED + 1), Noise(SEED + 2), Noise(SEED + 3)
    survey = Survey()
    real = survey.sample(X, Z)
    level = survey.lake_level

    # Layer 2: the lake, as surveyed.
    lake_x, lake_z = world(*LAKE_PX)
    labels, _ = ndimage.label(real < level + 1.2)
    lake = labels == labels[int(round((lake_z + SIZE / 2) / spacing)), int(round((lake_x + SIZE / 2) / spacing))]
    sd = ndimage.gaussian_filter((ndimage.distance_transform_edt(~lake) - ndimage.distance_transform_edt(lake)) * spacing, 1.5)
    lake = sd < 0.0
    print(f"  lake {lake.sum() * spacing * spacing / 1e6:.2f} km2 at {level:.0f} m, {survey.lake_lat:.4f} N {survey.lake_lon:.4f} E")

    # Valley floors: level, low ground. The survey is noisy there (and reads tree
    # tops), so floors are smoothed.
    calm = ndimage.gaussian_filter(real, 4.0)
    gz, gx = np.gradient(calm, spacing)
    steepness = np.hypot(gx, gz)
    floor = (1.0 - smoothstep(0.035, 0.11, steepness)) * (1.0 - smoothstep(200.0, 330.0, real - level))
    real = np.where(lake, level, real * (1.0 - floor) + calm * floor)

    # Layer 1: game heights. Levelled near the lake, never below it, stretched so
    # the highest summit is PEAK.
    above = np.maximum(real - level, 0.0)
    eased = above - LEVELLING * (1.0 - np.exp(-above / LEVELLING))
    stretch = (PEAK - FLOOR_LIFT) / float(eased.max())
    h = FLOOR_LIFT + eased * stretch
    top = np.unravel_index(np.argmax(h), h.shape)
    print(f"  highest summit {real[top]:.0f} m real at world ({X[top]:.0f}, {Z[top]:.0f}), heights stretched x{stretch:.2f}")
    # Detail finer than the survey: rough slopes, rock ribs on the steep faces.
    game_steepness = steepness * stretch
    rx = X + fbm(n3, X / 900.0, Z / 900.0, 3) * 220.0
    rz = Z + fbm(n3, X / 900.0 + 31.0, Z / 900.0 + 7.0, 3) * 220.0
    h += fbm(n2, X / 160.0, Z / 160.0, 4) * 12.0 * smoothstep(0.12, 0.6, game_steepness)
    h += (ridged(n4, rx / 430.0, rz / 430.0, 4) - 0.5) * 34.0 * smoothstep(0.55, 1.2, game_steepness)
    h = FLOOR_LIFT + (h - FLOOR_LIFT) * (PEAK - FLOOR_LIFT) / (float(h.max()) - FLOOR_LIFT)

    beach = WATER + 0.4 + (FLOOR_LIFT - 0.4) * smoothstep(0.0, 130.0, sd)
    h = np.where(lake, WATER - 1.2 - 15.0 * smoothstep(0.0, 420.0, -sd), np.clip(h, beach, beach + np.maximum(sd - 60.0, 0.0) * 0.5))

    # Layer 3: drainage.
    cx, cz = grid(D)
    recv, area = drainage(upsample(real, cx, cz), SIZE / (D - 1))
    points, catchment, smooth_xy = stream_points(recv, area, BROOK_AREA)
    # On open floor the filled survey sends brooks dead straight: let them wander.
    wander = upsample(floor, points[:, 0], points[:, 1]) * 55.0
    points = points + np.stack([fbm(n3, points[:, 0] / 380.0, points[:, 1] / 380.0, 2),
                                fbm(n3, points[:, 0] / 380.0 + 17.0, points[:, 1] / 380.0 - 5.0, 2)], axis=1) * wander[:, None]
    course = river_course(recv, area, smooth_xy, world(*GUSINJE_PX), floor)
    # Across the level lake the traced course is arbitrary (it may skirt the shore):
    # the river runs straight into the lake where it first comes near, and leaves
    # where it is last near.
    by_lake = np.flatnonzero(upsample(sd, course[:, 0], course[:, 1]) < 150.0)
    if by_lake.size:
        slope_z, slope_x = np.gradient(sd, spacing)
        legs = [course[:by_lake[0]], course[by_lake[-1] + 1:]]
        for start in (course[by_lake[0]], course[by_lake[-1]]):
            at = np.array(start, dtype=float)
            leg = []
            while len(leg) < 100 and float(upsample(sd, at[:1], at[1:])[0]) > -40.0:
                leg.append(at.copy())
                down = np.array([upsample(slope_x, at[:1], at[1:])[0], upsample(slope_z, at[:1], at[1:])[0]])
                at -= down / max(float(np.hypot(*down)), 1e-6) * 6.0
            if leg:
                legs.append(np.array(leg))
        course = np.concatenate(legs)
    print(f"  drainage in {time.time() - t0:.1f}s: {points.shape[0] * 6 / 1000:.0f} km of streams, river {course.shape[0] * 6 / 1000:.1f} km")

    # The river carries real water: a channel at lake level.
    river, _ = distance_to(course, X, Z, 90.0)
    channel = 1.0 - smoothstep(10.0, 32.0, river)
    h = h * (1.0 - channel) + np.minimum(h, WATER - 1.8) * channel

    # Every other stream is a brook, with a gravel bed once it is large enough.
    d_stream, which = distance_to(points, X, Z, 220.0)
    size = catchment[which]
    half_width = np.where(size >= GRAVEL_AREA, np.clip(7.5 * np.sqrt(size), 0.0, 90.0), 0.0)
    braid = fbm(n4, X / 150.0, Z / 150.0, 3)
    gentle = 1.0 - smoothstep(0.10, 0.22, steepness)
    gravel = np.where(half_width > 0.0, 1.0 - smoothstep(half_width * 0.55, half_width * 1.15 + 1.0, d_stream + braid * half_width * 0.8), 0.0) * gentle
    brook = (1.0 - smoothstep(5.0, 15.0, d_stream)) * (river > 60.0)
    bars = (1.0 - smoothstep(22.0, 60.0, river + fbm(n4, X / 120.0, Z / 120.0, 3) * 45.0)) * (river > 16.0) * (sd > 70.0)
    dry = h > WATER + 0.3
    off_shore = smoothstep(40.0, 160.0, sd)     # streams fade into the lake shore
    gravel = np.maximum(gravel * (river > 40.0) * off_shore, bars * 0.8) * dry
    brook = brook * dry * off_shore
    h -= gravel * 1.4 * (h > WATER + 3.0)
    h = h.astype(np.float32)
    print(f"  heights in {time.time() - t0:.1f}s, range {h.min():.0f} .. {h.max():.0f} m")
    return {"h": h, "X": X, "Z": Z, "floor": floor, "lake_sd": sd, "river": river, "gravel": gravel, "brook": brook,
            "real": real, "stream": d_stream, "catchment": size}


def settlements(X, Z) -> np.ndarray:
    town = np.zeros((N, N))
    for _, px, py, radius, density in SETTLEMENTS:
        x, z = world(px, py)
        town = np.maximum(town, density * np.exp(-((X - x) ** 2 + (Z - z) ** 2) / (2.0 * (radius * 0.55) ** 2)))
    return town


def place_houses(h, X, Z, town, ok, rng) -> np.ndarray:
    spacing = 42.0
    coords = np.arange(-SIZE / 2 + 400, SIZE / 2 - 400, spacing)
    gx, gz = np.meshgrid(coords, coords)
    gx = gx + rng.uniform(-spacing * 0.35, spacing * 0.35, gx.shape)
    gz = gz + rng.uniform(-spacing * 0.35, spacing * 0.35, gz.shape)
    fi = np.clip(((gx + SIZE / 2) / SIZE * (N - 1)).round().astype(int), 0, N - 1)
    fj = np.clip(((gz + SIZE / 2) / SIZE * (N - 1)).round().astype(int), 0, N - 1)
    keep = (rng.random(gx.shape) < town[fj, fi] * 0.85) & ok[fj, fi]
    xs, zs = gx[keep], gz[keep]
    count = xs.size
    # Houses line up loosely with their neighbours, as along a street.
    street = fbm(Noise(SEED + 21), xs / 600.0, zs / 600.0, 2) * math.pi
    yaw = street + rng.integers(0, 2, count) * (math.pi / 2) + rng.normal(0.0, 0.12, count)
    scale = rng.uniform(0.85, 1.35, count)
    kind = rng.integers(0, 3, count).astype(np.float32)
    return np.stack([xs, h[fj[keep], fi[keep]] - 0.4, zs, scale, yaw, kind], axis=1).astype(np.float32)


def main() -> None:
    t0 = time.time()
    OUT.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    print("heights...")
    f = build()
    h, X, Z, sd = f["h"], f["X"], f["Z"], f["lake_sd"]
    step = SIZE / (N - 1)
    gz, gx = np.gradient(h, step)
    ny = 1.0 / np.sqrt(1.0 + gx * gx + gz * gz)

    print("masks...")
    vis = gt.sun_visibility(h, SUN_AZIMUTH, SUN_ELEVATION)
    cavity = np.clip(0.5 + (blur(h, 6) - h) / 60.0, 0.0, 1.0)
    noise = Noise(SEED + 9)
    patch = fbm(noise, X / 700.0, Z / 700.0, 5) * 0.5 + 0.5
    water = h < WATER + 0.3
    floor = f["floor"]
    town = settlements(X, Z) * floor * ~water
    gravel, brook = f["gravel"], f["brook"]

    # Reed beds and wet meadows: the south and west shores and the last reach of the Ljuca.
    lake_x, lake_z = world(*LAKE_PX)
    southwest = smoothstep(-0.3, 0.7, ((Z - lake_z) * 0.8 - (X - lake_x) * 0.6) / 900.0)
    reeds = (1.0 - smoothstep(40.0, 520.0, sd)) * southwest + (1.0 - smoothstep(60.0, 260.0, f["river"])) * (1.0 - smoothstep(900.0, 2600.0, sd)) * 0.8
    reeds = np.clip(reeds * (0.55 + 0.9 * patch), 0.0, 1.0) * (h < WATER + 7.0) * ~water * (sd > 0.0) * (1.0 - town)

    # Forest: conifers up to the snow line, thick on shaded northern slopes and thin
    # on the sunny southern ones, as on the satellite picture.
    northness = gz / np.maximum(np.hypot(gx, gz), 1e-6)
    sunny = smoothstep(-0.15, 0.55, -northness) * smoothstep(260.0, 700.0, h)
    slope_ok = smoothstep(0.50, 0.80, ny)
    tree_line = SNOW_LINE + 40.0 + (patch - 0.5) * 260.0
    alt_ok = smoothstep(WATER + 9.0, WATER + 40.0, h) * (1.0 - smoothstep(tree_line - 120.0, tree_line + 60.0, h))
    forest = np.clip(slope_ok * alt_ok * (0.35 + 0.9 * patch) * (0.12 + 0.88 * (1.0 - floor)) * (1.0 - 0.85 * sunny), 0, 1)
    forest = np.where(forest > 0.28, forest, 0.0)
    clumps = fbm(Noise(SEED + 11), X / 160.0, Z / 160.0, 3) * 0.5 + 0.5
    floor_trees = floor * smoothstep(0.62, 0.74, clumps) * smoothstep(WATER + 4.0, WATER + 9.0, h)
    forest = np.maximum(forest, floor_trees * 0.75)
    forest *= (1.0 - smoothstep(0.25, 0.6, town)) * (1.0 - np.clip(gravel * 2.0, 0, 1)) * (1.0 - np.clip(reeds * 1.5, 0, 1))
    forest *= f["river"] > 45.0
    meadow = np.clip(floor * smoothstep(WATER + 1.5, WATER + 5.0, h) * (1.0 - gravel) * (1.0 - reeds * 0.85), 0, 1)

    mask = np.stack([vis, cavity, forest, meadow], axis=-1)
    write_png(OUT / f"{MAP_ID}_mask.png", (np.clip(mask, 0, 1) * 255).round().astype(np.uint8))
    mask2 = np.stack([gravel, brook, town, reeds], axis=-1)
    write_png(OUT / f"{MAP_ID}_mask2.png", (np.clip(mask2, 0, 1) * 255).round().astype(np.uint8))

    print("trees and houses...")
    trees = gt.place_trees(h, X, Z, forest, ny, rng, 30.0, SNOW_LINE - 250.0)
    trees.tofile(OUT / f"{MAP_ID}_trees.bin")
    houses = place_houses(h, X, Z, town, (ny > 0.985) & ~water & (gravel < 0.2) & (f["river"] > 40.0), rng)
    houses.tofile(OUT / f"{MAP_ID}_houses.bin")
    print(f"  {trees.shape[0]} trees, {houses.shape[0]} houses")
    h.astype("<f4").tofile(OUT / f"{MAP_ID}_height.r32")

    def ground(x: float, z: float) -> float:
        i = int(round((x + SIZE / 2) / SIZE * (N - 1)))
        j = int(round((z + SIZE / 2) / SIZE * (N - 1)))
        return max(float(h[j, i]), WATER)

    # The route keeps to the valley bottoms: each traced point moves to the lowest
    # ground within 400 m.
    low = ndimage.minimum_filter(h, size=2 * int(400.0 / step) + 1)
    snapped = []
    for x, z in (world(*p) for p in ROUTE):
        j0, i0 = int(round((z + SIZE / 2) / step)), int(round((x + SIZE / 2) / step))
        win = h[j0 - 34:j0 + 35, i0 - 34:i0 + 35]
        dj, di = np.argwhere(win <= low[j0, i0] + 0.5).mean(axis=0) - 34
        snapped.append((x + di * step, z + dj * step))
    route, _ = resample(chaikin(snapped, 2), 250.0)
    path = [[round(float(x), 1), round(ground(x, z), 1), round(float(z), 1)] for x, z in route]
    sun = [math.sin(SUN_AZIMUTH) * math.cos(SUN_ELEVATION), math.sin(SUN_ELEVATION), -math.cos(SUN_AZIMUTH) * math.cos(SUN_ELEVATION)]
    spawn_x, spawn_z = world(*SPAWN_PX)
    meta = {
        "id": MAP_ID, "name": "Plav & Gusinje", "size": SIZE, "samples": N, "water_level": WATER, "seed": SEED,
        "height_min": float(h.min()), "height_max": float(h.max()),
        "sun_direction": [round(v, 5) for v in sun],
        "spawn": {"position": [spawn_x, WATER + 340.0, spawn_z], "heading_deg": SPAWN_HEADING},
        "showers": [list(s) for s in SHOWERS],
        "look": {
            "snow_line": SNOW_LINE, "snow_spread": 150.0, "snow_band": 90.0,
            "alpine_from": 900.0, "alpine_to": 1400.0, "rock_from": 1900.0, "rock_to": 2300.0, "field_top": 260.0,
            "grass_low": [0.33, 0.42, 0.15], "grass_dry": [0.50, 0.40, 0.19], "alpine": [0.47, 0.36, 0.21],
            "forest": [0.20, 0.28, 0.15], "rock": [0.50, 0.49, 0.47], "rock_dark": [0.30, 0.29, 0.29],
            "water_shallow": [0.30, 0.56, 0.50], "water_deep": [0.04, 0.20, 0.23],
        },
        "valley_path": path, "tree_count": int(trees.shape[0]), "house_count": int(houses.shape[0]),
        "places": [{"name": name, "position": [round(v, 1) for v in world(px, py)]} for name, px, py, _, _ in SETTLEMENTS],
    }
    (OUT / f"{MAP_ID}_meta.json").write_text(json.dumps(meta, indent=1))

    previews(f, h, gx, gz, ny, vis, forest, meadow, town, reeds, sun, houses)
    print(f"done in {time.time() - t0:.1f}s")


def previews(f, h, gx, gz, ny, vis, forest, meadow, town, reeds, sun, houses) -> None:
    """Pictures for people: a natural-colour overview and one panel per layer."""
    gravel, brook = f["gravel"], f["brook"]
    light = np.clip(((-gx * sun[0] - gz * sun[2]) * ny + ny * sun[1]) * 2.6, 0, 1) * (0.35 + 0.65 * vis)
    shade = (0.42 + 0.75 * light)[..., None]
    water = h < WATER
    snow = smoothstep(SNOW_LINE - 60.0, SNOW_LINE + 90.0, h) * (1.0 - smoothstep(0.45, 0.7, 1.0 - ny))

    def mix(base, colour, amount):
        return base * (1.0 - amount[..., None]) + np.array(colour) * amount[..., None]

    col = np.ones(h.shape + (3,)) * np.array([0.42, 0.40, 0.20])
    col = mix(col, [0.50, 0.37, 0.20], smoothstep(500.0, 1300.0, h))
    col = mix(col, [0.36, 0.47, 0.17], meadow * 0.9)
    col = mix(col, [0.45, 0.30, 0.20], np.clip(reeds, 0, 1) * 0.8)
    col = mix(col, [0.13, 0.20, 0.11], np.clip(forest * 1.5, 0, 1))
    col = mix(col, [0.50, 0.49, 0.47], smoothstep(0.30, 0.48, 1.0 - ny))
    col = mix(col, [0.72, 0.70, 0.64], np.clip(gravel, 0, 1))
    col = mix(col, [0.74, 0.70, 0.66], np.clip(town * 0.9, 0, 1) * 0.55)
    col = mix(col, [0.95, 0.96, 0.98], snow)
    col = col * shade
    col = mix(col, [0.30, 0.52, 0.55], np.clip(brook, 0, 1) * 0.8)
    col[water] = np.array([0.17, 0.42, 0.42])
    natural = np.clip(col[::2, ::2], 0, 1)
    rgba = np.concatenate([natural, np.ones(natural.shape[:2] + (1,))], axis=-1)
    (ROOT / "docs").mkdir(exist_ok=True)
    write_png(ROOT / "docs" / f"{MAP_ID}_preview.png", (rgba * 255).astype(np.uint8))

    def panel(rgb):
        return np.clip(rgb[::4, ::4], 0, 1)

    grey = (0.25 + 0.75 * light)[..., None] * np.ones(3)
    k = np.clip(h / PEAK, 0, 1)[..., None]
    elevation = (np.array([0.30, 0.45, 0.25]) * (1 - k) + np.array([0.95, 0.90, 0.80]) * k) * (0.5 + 0.5 * grey)
    # Drainage: every stream, drawn wider the more ground it drains.
    reach = 14.0 + 9.0 * np.sqrt(f["catchment"])
    streams = mix(grey * 0.55, [0.25, 0.55, 0.95], (f["stream"] < reach).astype(float))
    streams = mix(streams, [0.95, 0.75, 0.25], (f["river"] < 45.0).astype(float))
    streams[water] = np.array([0.15, 0.45, 0.85])
    woods = mix(grey * 0.6, [0.10, 0.45, 0.12], np.clip(forest * 1.6, 0, 1))
    woods = mix(woods, [0.55, 0.75, 0.25], meadow * 0.8)
    wet = mix(grey * 0.6, [0.80, 0.76, 0.62], np.clip(gravel, 0, 1))
    wet = mix(wet, [0.70, 0.40, 0.25], np.clip(reeds, 0, 1))
    wet = mix(wet, [0.20, 0.55, 0.95], np.clip(brook + (1.0 - smoothstep(10.0, 32.0, f["river"])), 0, 1))
    wet[water] = np.array([0.15, 0.45, 0.85])
    homes = mix(grey * 0.6, [0.98, 0.75, 0.25], np.clip(town, 0, 1))
    hi = np.clip(((houses[:, 0] + SIZE / 2) / SIZE * (N - 1)).round().astype(int), 0, N - 1)
    hj = np.clip(((houses[:, 2] + SIZE / 2) / SIZE * (N - 1)).round().astype(int), 0, N - 1)
    homes[hj, hi] = np.array([1.0, 0.25, 0.15])
    white = mix(grey * 0.6, [0.96, 0.97, 1.0], snow)
    top = np.concatenate([panel(elevation), panel(streams), panel(woods)], axis=1)
    bottom = np.concatenate([panel(wet), panel(homes), panel(white)], axis=1)
    sheet = np.concatenate([top, bottom], axis=0)
    rgba = np.concatenate([sheet, np.ones(sheet.shape[:2] + (1,))], axis=-1)
    write_png(ROOT / "docs" / f"{MAP_ID}_layers.png", (rgba * 255).astype(np.uint8))


if __name__ == "__main__":
    main()
