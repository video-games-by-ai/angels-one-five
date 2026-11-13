#!/usr/bin/env python3
"""Generate the Alpine valley arena: heightmap, terrain masks, tree placements.

Run:  python3 tools/generate_terrain.py
Writes into game/assets/terrain/:
  alpine_height.r32   float32 heights, N*N, row-major (row = z index, col = x index)
  alpine_mask.png     RGBA8: R = sun visibility (mountain shadows), G = cavity/AO,
                      B = forest density, A = meadow/wetness
  alpine_trees.bin    float32 records: x, y, z, scale, yaw, kind
  alpine_meta.json    world size, sample count, water level, sun, spawn, valley path
  docs/terrain_preview.png  shaded overview (not used by the game)

Everything is deterministic from SEED, so the arena can be regenerated and edited
by changing the parameters below.
"""
from __future__ import annotations

import json
import math
import struct
import time
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "game" / "assets" / "terrain"
SEED = 1944
N = 2048                 # height samples per side
SIZE = 24000.0           # metres covered by the heightmap, centred on the origin
WATER = 432.0            # lake surface height
FLOOR = 452.0            # meadow floor height around the lake
SUN_AZIMUTH = math.radians(-58.0)   # 0 = north (-Z), negative = west (-X)
SUN_ELEVATION = math.radians(13.0)


def valley_x(z: np.ndarray | float) -> np.ndarray | float:
    """Centre line of the main valley (x as a function of z)."""
    return 760.0 * np.sin(z / 3900.0 + 0.6) + 260.0 * np.sin(z / 1450.0 + 1.3)


def smoothstep(a: float, b: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


class Noise:
    """Vectorised 2D value noise with analytic derivatives."""

    def __init__(self, seed: int, size: int = 512):
        rng = np.random.default_rng(seed)
        self.size = size
        self.grid = rng.random((size, size)).astype(np.float64)

    def sample(self, x: np.ndarray, z: np.ndarray):
        xi = np.floor(x)
        zi = np.floor(z)
        fx = x - xi
        fz = z - zi
        m = self.size - 1
        x0 = xi.astype(np.int64) & m
        z0 = zi.astype(np.int64) & m
        x1 = (x0 + 1) & m
        z1 = (z0 + 1) & m
        g = self.grid
        a = g[z0, x0]
        b = g[z0, x1]
        c = g[z1, x0]
        d = g[z1, x1]
        ux = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
        uz = fz * fz * fz * (fz * (fz * 6 - 15) + 10)
        dux = 30 * fx * fx * (fx * (fx - 2) + 1)
        duz = 30 * fz * fz * (fz * (fz - 2) + 1)
        k = a - b - c + d
        n = a + (b - a) * ux + (c - a) * uz + k * ux * uz
        dx = dux * ((b - a) + k * uz)
        dz = duz * ((c - a) + k * ux)
        return n * 2 - 1, dx * 2, dz * 2


def eroded_fbm(noise: Noise, x, z, octaves=8):
    """Derivative-damped fBm: smooth valleys, sharp crests, eroded look."""
    total = np.zeros_like(x)
    ddx = np.zeros_like(x)
    ddz = np.zeros_like(x)
    amp = 1.0
    norm = 0.0
    px, pz = x.copy(), z.copy()
    c, s = math.cos(0.6), math.sin(0.6)
    for _ in range(octaves):
        n, dx, dz = noise.sample(px, pz)
        ddx += dx
        ddz += dz
        total += amp * n / (1.0 + 0.9 * (ddx * ddx + ddz * ddz))
        norm += amp
        amp *= 0.5
        px, pz = (c * px - s * pz) * 2.03 + 17.1, (s * px + c * pz) * 2.03 - 9.3
    return total / norm


def ridged(noise: Noise, x, z, octaves=6):
    total = np.zeros_like(x)
    amp, norm, weight = 1.0, 0.0, np.ones_like(x)
    px, pz = x.copy(), z.copy()
    for _ in range(octaves):
        n, _, _ = noise.sample(px, pz)
        r = (1.0 - np.abs(n)) ** 2
        r *= weight
        weight = np.clip(r * 1.6, 0, 1)
        total += amp * r
        norm += amp
        amp *= 0.5
        px, pz = px * 2.1 + 3.7, pz * 2.1 - 1.9
    return total / norm


def fbm(noise: Noise, x, z, octaves=5):
    total = np.zeros_like(x)
    amp, norm = 1.0, 0.0
    px, pz = x.copy(), z.copy()
    for _ in range(octaves):
        n, _, _ = noise.sample(px, pz)
        total += amp * n
        norm += amp
        amp *= 0.5
        px, pz = px * 2.0 + 5.3, pz * 2.0 + 1.1
    return total / norm


def blur(a: np.ndarray, radius: int) -> np.ndarray:
    from scipy.ndimage import uniform_filter
    return uniform_filter(a, size=radius * 2 + 1, mode="nearest")


def build_heights() -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    coords = np.linspace(-SIZE / 2, SIZE / 2, N)
    X, Z = np.meshgrid(coords, coords)
    n1, n2, n3, n4 = Noise(SEED), Noise(SEED + 1), Noise(SEED + 2), Noise(SEED + 3)

    # Domain warp so ridges do not line up with the grid.
    wx = fbm(n3, X / 2600.0, Z / 2600.0, 4) * 520.0
    wz = fbm(n3, X / 2600.0 + 40.0, Z / 2600.0 - 13.0, 4) * 520.0
    Xw, Zw = X + wx, Z + wz

    centre = valley_x(Z)
    d_main = np.abs(X - centre)

    # Two side valleys feeding the main one, so there are corridors to fly through.
    def side_valley(z0, direction, length, width):
        along = (X - valley_x(z0)) * direction
        line_z = z0 + 0.22 * along + 380.0 * np.sin(along / 1700.0)
        dist = np.abs(Z - line_z)
        reach = smoothstep(-400.0, 300.0, along) * (1.0 - smoothstep(length * 0.75, length, along))
        return np.where(reach > 0.01, dist / np.maximum(reach, 0.01), 1e9), reach, along, width

    sides = [side_valley(-4300.0, 1, 7600.0, 1.0), side_valley(2900.0, -1, 7200.0, 1.0), side_valley(-8200.0, -1, 5200.0, 1.0)]

    base = np.clip((eroded_fbm(n1, Xw / 5600.0, Zw / 5600.0, 9) * 0.5 + 0.5 - 0.3) / 0.34, 0.0, 1.0)
    crest = ridged(n2, Xw / 3100.0, Zw / 3100.0, 6)
    mountains = 760.0 + 1450.0 * base + 1050.0 * crest * smoothstep(0.15, 0.7, base)

    # U-shaped glacial profile for the main valley.
    rise = smoothstep(320.0, 2600.0, d_main) ** 1.15
    floor_noise = fbm(n4, X / 900.0, Z / 900.0, 5) * 16.0 + fbm(n4, X / 220.0, Z / 220.0, 3) * 3.0
    h = FLOOR + floor_noise + rise * (mountains - FLOOR)

    # Side valleys are disabled: the straight carve produced pyramid artefacts.
    for dist, reach, along, _ in sides[:0]:
        side_rise = smoothstep(240.0, 2100.0, dist) ** 1.3
        side_floor = FLOOR + 30.0 + np.clip(along, 0, None) * 0.075 + floor_noise
        carved = side_floor + side_rise * (mountains - side_floor)
        h = np.minimum(h, np.where(reach > 0.01, carved, h))

    # The lake: an elongated basin on the valley floor.
    lake_z = -900.0
    lx = (X - valley_x(Z)) / 560.0
    lz = (Z - lake_z) / 2300.0
    lake = np.exp(-(lx * lx + lz * lz) ** 1.6 * 2.2)
    h -= lake * 62.0

    # Rim of high peaks so the arena reads as an enclosed basin from any altitude.
    r = (np.abs(X) ** 4 + (np.abs(Z) / 1.05) ** 4) ** 0.25 + fbm(n4, X / 3000.0, Z / 3000.0, 3) * 900.0
    rim = smoothstep(8600.0, 11800.0, r)
    h += rim * (500.0 + 500.0 * crest)

    # Fine erosion detail on slopes only.
    detail = fbm(n2, X / 160.0, Z / 160.0, 4) * 14.0 * smoothstep(0.1, 0.6, rise)
    h += detail
    return h.astype(np.float32), X, Z


def normals_and_slope(h: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    step = SIZE / (N - 1)
    gz, gx = np.gradient(h, step)
    ny = 1.0 / np.sqrt(1.0 + gx * gx + gz * gz)
    return gx, gz, ny


def sun_visibility(h: np.ndarray) -> np.ndarray:
    """Soft mountain shadows: march each texel toward the sun over a half-res grid."""
    t0 = time.time()
    hs = h[::2, ::2].astype(np.float64)
    n = hs.shape[0]
    step = SIZE / (N - 1) * 2
    # Direction toward the sun in grid units: x grows east (+X), rows grow south (+Z).
    dx = math.sin(SUN_AZIMUTH)
    dz = -math.cos(SUN_AZIMUTH)
    tan_e = math.tan(SUN_ELEVATION)
    rows, cols = np.mgrid[0:n, 0:n].astype(np.float64)
    horizon = np.full(hs.shape, -1.0)
    dist = step
    while dist < 9000.0:
        c = cols + dx * dist / step
        r = rows + dz * dist / step
        inside = (c >= 0) & (c <= n - 1) & (r >= 0) & (r <= n - 1)
        ci = np.clip(np.rint(c).astype(np.int64), 0, n - 1)
        ri = np.clip(np.rint(r).astype(np.int64), 0, n - 1)
        rise = (hs[ri, ci] - hs) / dist
        horizon = np.where(inside, np.maximum(horizon, rise), horizon)
        dist *= 1.045
        dist += step * 0.5
    # Penumbra width grows with distance: approximate by a smooth angular band.
    vis = 1.0 - smoothstep(tan_e - 0.035, tan_e + 0.02, horizon)
    vis = blur(vis, 2)
    vis = np.kron(vis, np.ones((2, 2)))
    print(f"  sun visibility in {time.time() - t0:.1f}s")
    return vis.astype(np.float32)


def place_trees(h, X, Z, forest, ny, rng) -> np.ndarray:
    """Jittered-grid conifer placement following the forest mask."""
    spacing = 30.0
    coords = np.arange(-SIZE / 2 + 600, SIZE / 2 - 600, spacing)
    gx, gz = np.meshgrid(coords, coords)
    gx = gx + rng.uniform(-spacing * 0.45, spacing * 0.45, gx.shape)
    gz = gz + rng.uniform(-spacing * 0.45, spacing * 0.45, gz.shape)
    fi = np.clip(((gx + SIZE / 2) / SIZE * (N - 1)).round().astype(int), 0, N - 1)
    fj = np.clip(((gz + SIZE / 2) / SIZE * (N - 1)).round().astype(int), 0, N - 1)
    dens = forest[fj, fi]
    keep = rng.random(gx.shape) < dens * 0.8
    # Keep most trees inside the region where low flying happens.
    radius = np.maximum(np.abs(gx), np.abs(gz))
    keep &= radius < 9800
    xs, zs = gx[keep], gz[keep]
    ys = h[fj[keep], fi[keep]]
    count = xs.size
    scale = rng.uniform(0.75, 1.35, count) * np.where(ys > 1500, 0.8, 1.0)
    yaw = rng.uniform(0, math.tau, count)
    kind = (rng.random(count) < 0.35).astype(np.float32)  # 0 spruce, 1 fir
    recs = np.stack([xs, ys - 0.6, zs, scale, yaw, kind], axis=1).astype(np.float32)
    return recs


def write_png(path: Path, rgba: np.ndarray) -> None:
    hgt, wid, _ = rgba.shape
    raw = b"".join(b"\x00" + rgba[y].tobytes() for y in range(hgt))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", wid, hgt, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 7)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def main() -> None:
    t0 = time.time()
    OUT.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    print("heights...")
    h, X, Z = build_heights()
    gx, gz, ny = normals_and_slope(h)
    print(f"  range {h.min():.0f} .. {h.max():.0f} m")

    print("masks...")
    vis = sun_visibility(h)
    cavity = np.clip(0.5 + (blur(h, 6) - h) / 60.0, 0.0, 1.0)
    noise = Noise(SEED + 9)
    patch = fbm(noise, X / 700.0, Z / 700.0, 5) * 0.5 + 0.5
    slope_ok = smoothstep(0.62, 0.86, ny)          # flat to moderate slopes
    alt_ok = smoothstep(WATER + 14.0, WATER + 60.0, h) * (1.0 - smoothstep(1650.0, 1950.0, h))
    valley_open = smoothstep(260.0, 900.0, np.abs(X - valley_x(Z)))  # meadows on the floor
    forest = np.clip(slope_ok * alt_ok * (0.35 + 0.9 * patch) * (0.25 + 0.75 * valley_open), 0, 1)
    forest = np.where(forest > 0.28, forest, 0.0)
    # Copses and hedgerow clumps on the valley floor give low flight a sense of speed.
    clumps = fbm(Noise(SEED + 11), X / 160.0, Z / 160.0, 3) * 0.5 + 0.5
    floor_trees = (1.0 - valley_open) * smoothstep(0.62, 0.74, clumps) * smoothstep(WATER + 6.0, WATER + 14.0, h)
    forest = np.maximum(forest, floor_trees * 0.75)
    meadow = np.clip((1.0 - valley_open) * smoothstep(WATER + 3.0, WATER + 20.0, h), 0, 1)
    mask = np.stack([vis, cavity, forest, meadow], axis=-1)
    write_png(OUT / "alpine_mask.png", (np.clip(mask, 0, 1) * 255).round().astype(np.uint8))

    print("trees...")
    trees = place_trees(h, X, Z, forest, ny, rng)
    trees.tofile(OUT / "alpine_trees.bin")
    print(f"  {trees.shape[0]} trees")

    h.astype("<f4").tofile(OUT / "alpine_height.r32")

    # Valley path for the autopilot and spawn placement.
    path = []
    for z in np.arange(8500.0, -8501.0, -250.0):
        x = float(valley_x(z))
        i = int(round((x + SIZE / 2) / SIZE * (N - 1)))
        j = int(round((z + SIZE / 2) / SIZE * (N - 1)))
        path.append([round(x, 1), round(float(h[j, i]), 1), round(float(z), 1)])
    sun = [math.sin(SUN_AZIMUTH) * math.cos(SUN_ELEVATION), math.sin(SUN_ELEVATION), -math.cos(SUN_AZIMUTH) * math.cos(SUN_ELEVATION)]
    meta = {
        "size": SIZE, "samples": N, "water_level": WATER, "seed": SEED,
        "height_min": float(h.min()), "height_max": float(h.max()),
        "sun_direction": [round(v, 5) for v in sun],
        "spawn": {"position": [float(valley_x(4200.0)), 760.0, 4200.0], "heading_deg": 0.0},
        "valley_path": path, "tree_count": int(trees.shape[0]),
    }
    (OUT / "alpine_meta.json").write_text(json.dumps(meta, indent=1))

    # Preview: hillshade tinted by masks (for humans only).
    light = np.clip(((-gx * sun[0] - gz * sun[2]) * ny + ny * sun[1]) * 2.5, 0, 1) * (0.3 + 0.7 * vis)
    base = np.stack([0.45 + 0.4 * light, 0.42 + 0.38 * light, 0.38 + 0.3 * light], axis=-1)
    base = base * (1 - forest[..., None] * 0.55) + np.array([0.0, 0.05, 0.0]) * forest[..., None]
    snow = smoothstep(1950.0, 2150.0, h) * smoothstep(0.75, 0.9, ny)
    base = base * (1 - snow[..., None]) + snow[..., None] * (0.8 + 0.2 * light[..., None])
    water = h < WATER
    base[water] = [0.2, 0.32, 0.42]
    prev = np.clip(base[::4, ::4], 0, 1)
    rgba = np.concatenate([prev, np.ones(prev.shape[:2] + (1,))], axis=-1)
    (ROOT / "docs").mkdir(exist_ok=True)
    write_png(ROOT / "docs" / "terrain_preview.png", (rgba * 255).astype(np.uint8))
    print(f"done in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
