# Airflight

A 1940s arcade flight game for desktop, built with **Godot 4.5.1**, typed GDScript
and **Blender 5.2**. You fly a P-51D Mustang low through an Alpine valley at golden
hour: snow peaks, forested slopes, a mountain lake, cumulus clouds and sun glare.

![Low over the valley floor](docs/screenshots/valley-low.png)
![Over the lake into the sun](docs/screenshots/lake-sun.png)

**Status: milestone 1 of 5, the flyable scene.** You can fly freely. There are no
weapons, opponents or multiplayer yet (see [Roadmap](#roadmap)).

## Play

**Windows:** unzip `build/airflight-windows.zip` and double-click `Airflight.exe`.
No installer is needed. It requires 64-bit Windows 10/11 and a Vulkan-capable GPU
with a current driver. The Windows build is exported and its data pack was
smoke-tested under Linux, but it **has not yet been run on a Windows PC**.

**Linux:**

```sh
./run.sh
```

This runs `build/airflight-linux/airflight.x86_64` (standalone, no editor
needed). If that build is missing, it runs the project with Godot 4.5.1.

**From source (any OS):** install [Godot 4.5.1](https://godotengine.org/download/archive/4.5.1-stable/),
open `game/project.godot` and press F5.

### Controls

| Input | Action |
|---|---|
| Mouse | Move the aim circle; the aircraft banks and turns toward it |
| Shift | Boost (limited, regenerating reserve) |
| W / S | Throttle up / down |
| A / D | Manual roll |
| Q / E | Rudder |
| C | Re-centre the aim on the nose |
| Esc | Pause menu and settings |
| F11 | Fullscreen |
| F3 | Frame-rate readout |

The small cross shows where the nose points; the amber circle is where you are
steering. If you leave the mouse alone, assisted levelling eases the aim back to
the horizon. The aircraft is lost on contact with the ground, the lake or
treetops, and respawns after three seconds.

### Settings (Esc)

Mouse sensitivity, inverted vertical mouse, assisted levelling, camera shake,
volume, graphics quality (Low / Medium / High) and fullscreen. Settings are saved
to Godot's user folder (`settings.cfg`).

## Performance

Measured with the built-in benchmark: 30 s of scripted low flight down the
valley, 1920×1080, vsync off, release export.

| Preset | Average FPS | 1% low FPS |
|---|---|---|
| High | 121.9 | 93.3 |
| Medium | 148.5 | 116.0 |
| Low | 318.0 | 212.3 |

Test machine: Fedora Linux 44, AMD Ryzen 7 3700X (8 cores), NVIDIA GeForce RTX
2070 SUPER 8 GB (driver 615.71), 46 GB RAM, Vulkan, Godot 4.5.1. Raw results are
in `docs/benchmarks/`. To reproduce:

```sh
./run.sh --resolution 1920x1080 --disable-vsync -- --benchmark=30 --quality=2
```

The presets differ in terrain detail distance, tree draw distance and shadows,
shadow distance, screen-space reflections and ambient occlusion, MSAA, cloud
count and render scale (Low renders at 80% with FSR upscaling).

## How it is built

Everything is original or freely licensed; nothing is downloaded at build time.

| Part | Source | Output |
|---|---|---|
| Valley heightmap, shadows, forest mask, 158k tree positions | `tools/generate_terrain.py` (Python + NumPy/SciPy) | `game/assets/terrain/` |
| P-51D Mustang (moving prop, ailerons, elevators, rudder; fictional markings) | `tools/build_mustang.py` → `source-assets/mustang.blend` | `game/assets/models/mustang.glb` |
| Conifers | `tools/build_trees.py` → `source-assets/trees.blend` | `game/assets/models/trees.glb` |
| Engine and wind sounds (synthesised) | `tools/generate_audio.py` | `game/assets/audio/` |
| Packages for Linux and Windows | `tools/build_release.sh` | `build/` |

Rebuild steps:

```sh
python3 tools/generate_terrain.py
blender --background --factory-startup --python tools/build_mustang.py
blender --background --factory-startup --python tools/build_trees.py
python3 tools/generate_audio.py
tools/build_release.sh
```

The release script also runs the headless flight tests in
`game/tests/test_flight.gd`. They cover terrain sampling, turning, climbing,
levelling, boost, collision, class balance and mouse/invert handling.

### Code layout (`game/scripts/`)

- `world/`: terrain data and LOD tiles, atmosphere (sky, sun, haze, post), clouds, forest, effects
- `aircraft/`: flight model (fixed-step, network-ready), aircraft visuals, engine audio, autopilot
- `input/`: `FlightCommand`, the device-independent pilot intent, and the mouse/keyboard source
- `camera/`: chase camera with boost pull-back and adjustable shake
- `ui/`: HUD with see-through airframe damage panel, lens flare, pause menu

Flight runs on a fixed 60 Hz step and is rendered with physics interpolation. All
pilot input goes through `FlightCommand`, so gamepad, touch, AI or network input
can be added without changing the flight code.

## Roadmap

1. **Flyable scene (done):** valley, lighting, clouds, forests, lake, Mustang, flight model, chase camera, HUD, settings, audio, Linux/Windows builds, benchmark.
2. **Combat:** machine guns with tracers, muzzle flash, hit sparks and sounds; limited rockets; hit confirmation; forgiving aim assist; damage zones that drive the airframe panel and smoke trails; practice targets and AI fighters that pursue, evade and explode.
3. **Aircraft choice:** Spitfire Mk IX (light) and P-47D Thunderbolt (heavy) models in Blender, using the balance already defined in `aircraft/airframes.gd`; a hangar menu with Practice, Host Match, Join Match, Settings and Quit.
4. **1v1 multiplayer:** host/join by IP address, server-authoritative damage and score, smooth remote aircraft, respawn and rematch. Team data is organised so 2v2 and 4v4 can follow.
5. **Release check:** run natively on Windows, cross-play between Windows and Linux, and a final performance pass.

Phones (Android/iOS) would be a later project. They need touch controls, a lighter graphics tier and a relay server for online play.

## Licence

MIT (see `LICENSE`). Godot Engine is MIT (`licenses/`). The Montserrat font is
under the SIL Open Font License (`game/assets/fonts/LICENSE.txt`).
