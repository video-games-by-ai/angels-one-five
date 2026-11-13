#!/usr/bin/env python3
"""Synthesise the original sound effects (no recordings, no downloads).

Run:  python3 tools/generate_audio.py            write the game's sounds
      python3 tools/generate_audio.py --audition  also write build/engine_audition.wav:
                                                  each engine swept idle -> boost -> idle
                                                  through the same two-layer mix the game uses
Writes 16-bit WAV files into game/assets/audio/:
  engine_<type>_low.wav   each engine at low revs
  engine_<type>_high.wav  the same engine half as fast again, for high revs
                          (the game crossfades the two as RPM rises, so the exhaust
                          note climbs without the whole sound turning thin)
  wind_loop.wav           airflow rush (volume follows airspeed)
  gun_light/medium/heavy_1..3.wav   three takes of one shot each
  gun_jam.wav             the guns stopping when they overheat
  whizz.wav               a round passing close by
  hit.wav, hurt.wav       bullet strikes on the target / on your own aircraft
  explosion.wav           an aircraft blowing up
Engine loops are stereo and built in the frequency domain, so they repeat
seamlessly. They fire at the rate of the real engines, are made of clean
harmonics (no distortion, no clipping, a trace of noise) and keep nearly all
their energy below 600 Hz.
"""
from __future__ import annotations

import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "game" / "assets" / "audio"
RATE = 44100


def write(name: str, signal: np.ndarray, peak: float | None = 0.85, folder: Path = OUT) -> None:
    """Save mono (n,) or stereo (n, 2), normalised to `peak` (None: as given)."""
    if peak is not None:
        signal = signal / (np.max(np.abs(signal)) + 1e-9) * peak
    signal = np.clip(signal, -1.0, 1.0)
    pcm = (signal * 32767).astype("<i2")
    with wave.open(str(folder / name), "wb") as w:
        w.setnchannels(1 if signal.ndim == 1 else 2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    print(f"{name:28s} {len(signal) / RATE:5.2f}s  {describe(signal)}")


def describe(signal: np.ndarray) -> str:
    """Spectral centroid and how the energy splits: the numbers the sounds are tuned by."""
    mono = signal if signal.ndim == 1 else signal.mean(axis=1)
    power = np.abs(np.fft.rfft(mono)) ** 2
    freqs = np.fft.rfftfreq(len(mono), 1 / RATE)
    total = power.sum() + 1e-12
    centroid = (freqs * power).sum() / total
    low = power[freqs < 150].sum() / total
    mid = power[(freqs >= 150) & (freqs < 600)].sum() / total
    high = power[freqs > 1000].sum() / total
    return f"centroid {centroid:5.0f} Hz  <150 Hz {low * 100:4.1f}%  150-600 Hz {mid * 100:4.1f}%  >1 kHz {high * 100:5.2f}%"


def looped_noise(n: int, rng, smooth: int) -> np.ndarray:
    """Band-limited noise that is periodic over n samples (built in the frequency domain)."""
    spec = rng.normal(size=n // 2 + 1) + 1j * rng.normal(size=n // 2 + 1)
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    spec *= 1.0 / (1.0 + (freqs / smooth) ** 2)
    spec[0] = 0
    return np.fft.irfft(spec, n)


def slow_wander(n: int, rng, cutoff: float) -> np.ndarray:
    """Slow random drift that is periodic over n samples, scaled to unit deviation."""
    spec = rng.normal(size=n // 2 + 1) + 1j * rng.normal(size=n // 2 + 1)
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    spec[freqs > cutoff] = 0
    spec[0] = 0
    out = np.fft.irfft(spec, n)
    return out / (out.std() + 1e-9)


ENGINE_SECONDS = 6.0
HIGH_RATE = 1.5
ENGINE_RMS = 0.2    ## every engine loop is written at this loudness, so the crossfade is even
ENGINE_PEAK = 0.89  ## and none may peak above this: a clipped loop sounds broken, not loud
PIPE_SPREAD = 3e-5  ## seconds later per Hz that the exhaust delivers its higher notes
## Each engine, tuned against recordings of the real aircraft (measured, not
## sampled: firing rate, which harmonics carry the sound, how the energy splits
## between bass and body). They are kept clean on purpose: the engine's own
## harmonics carry the sound, with no distortion and only a trace of noise.
##   beats        exhaust pulses per engine cycle (one per cylinder)
##   cycles       engine cycles per second at low revs; beats * cycles is the
##                firing rate (the high loop runs HIGH_RATE times faster)
##   orders       how strongly the sound repeats 0, 1, 2 ... beats/2 times per
##                engine cycle. Order 0 is the plain firing rate. A Merlin is
##                heard one cylinder bank at a time (order 6, half the firing
##                rate) and a radial in threes (orders 3, 6, 9: a low roll).
##                Those are octaves and fifths of each other, so they sound
##                like one deep note; the orders in between are the engine's
##                roughness and are kept low.
##   timing       how unevenly the cylinders arrive, as a share of the gap between beats
##   variation    how much each beat differs from the last, at random
##   resonances   the exhaust's voice: (Hz, sharpness, level)
##   floor        Hz below which the sound is rolled off
##   tilt         Hz above which each octave is half as strong as the last, and
##   lowpass      Hz above which it falls away faster: together they set how
##                much clean upper harmonic is left, which is what makes the
##                engine sound clear instead of muffled
##   air          level of the soft exhaust breath riding on the beats (300-1800 Hz)
##   prop         propeller blades passing per engine cycle, and `hum`, the
##                level of the low note they add under the exhaust
ENGINES = {
    # Packard Merlin V-1650 (P-51D): twelve short open stacks. Fires 160 times a
    # second at low revs and 213 at full throttle, heard mostly as the 107 Hz of
    # one bank: a deep, open growl, a shade rougher than the Spitfire's.
    "mustang": {"seed": 51, "beats": 12, "cycles": 40.0 / 3.0, "orders": (0.8, 0.04, 0.08, 0.24, 0.08, 0.12, 1.0), "timing": 0.018,
                "resonances": ((70, 1.5, 0.55), (112, 1.6, 0.9), (165, 1.6, 1.0), (225, 1.6, 1.0), (310, 1.5, 0.85), (430, 1.4, 0.6), (640, 1.3, 0.3)),
                "floor": 38.0, "pulse_ms": 1.2, "tilt": 240.0, "lowpass": 1400.0, "jitter": 0.006, "variation": 0.04,
                "width": 0.2, "air": 0.045, "prop": 3.83, "hum": 0.16},
    # Rolls-Royce Merlin 66 (Spitfire IX): the same engine, revving a little
    # higher and running smoother. 180 a second at low revs, 240 at full throttle.
    "spitfire": {"seed": 9, "beats": 12, "cycles": 15.0, "orders": (0.9, 0.03, 0.06, 0.2, 0.06, 0.08, 1.0), "timing": 0.012,
                 "resonances": ((78, 1.5, 0.45), (124, 1.6, 0.9), (182, 1.6, 1.0), (245, 1.6, 1.0), (340, 1.5, 0.8), (470, 1.4, 0.55), (700, 1.3, 0.28)),
                 "floor": 42.0, "pulse_ms": 1.2, "tilt": 260.0, "lowpass": 1450.0, "jitter": 0.005, "variation": 0.03,
                 "width": 0.2, "air": 0.035, "prop": 3.83, "hum": 0.14},
    # Pratt & Whitney R-2800 (P-47D): eighteen cylinders into collector rings.
    # 150 a second at low revs, 200 at full throttle, heard in threes: a deep
    # note at a third of that (67 Hz at full throttle) with a slow roll in it.
    "thunderbolt": {"seed": 47, "beats": 18, "cycles": 25.0 / 3.0, "orders": (0.6, 0.04, 0.08, 0.2, 0.1, 0.1, 1.0, 0.1, 0.08, 0.34), "timing": 0.02,
                    "resonances": ((52, 1.6, 0.7), (72, 1.6, 0.95), (100, 1.7, 1.0), (135, 1.7, 1.0), (180, 1.6, 0.8), (260, 1.5, 0.6), (390, 1.4, 0.42)),
                    "floor": 36.0, "pulse_ms": 1.6, "tilt": 170.0, "lowpass": 1000.0, "jitter": 0.008, "variation": 0.05,
                    "width": 0.16, "air": 0.03, "prop": 4.0, "hum": 0.14},
}


def firing_pattern(beats: int, orders: tuple[float, ...], rng) -> np.ndarray:
    """Strength of each cylinder's beat, in firing order, such that the pattern
    repeats m times per engine cycle with strength orders[m]. Beats may come out
    negative (a pull instead of a push): only their pattern is heard."""
    k = np.arange(beats)
    pattern = np.full(beats, float(orders[0]))
    for m, level in enumerate(orders[1:], start=1):
        if m * 2 == beats:
            pattern += level * np.cos(np.pi * k)
        else:
            pattern += 2.0 * level * np.cos(2 * np.pi * m * k / beats + rng.random() * 2 * np.pi)
    return pattern / np.max(np.abs(pattern))


def engine_loop(spec: dict, high: bool) -> np.ndarray:
    """One engine as a train of exhaust beats, each ringing in the pipes.

    Every cylinder has its own strength and arrives a touch early or late, and
    the whole engine breathes slowly, so the loop is alive without being noisy.
    Both loops of an engine share the same cylinders, so they stay in step and
    crossfade cleanly. Everything is periodic over the loop length, so it joins
    up without a click, and nothing is clipped or distorted.
    """
    cylinders = np.random.default_rng(spec["seed"])                    # the engine itself: the same in both loops
    rng = np.random.default_rng(spec["seed"] + (2000 if high else 1000))  # this take of it
    n = int(RATE * ENGINE_SECONDS)
    rate = HIGH_RATE if high else 1.0
    total = int(round(spec["beats"] * spec["cycles"] * rate * ENGINE_SECONDS))
    spacing = n / total
    index = np.arange(total)
    accents = firing_pattern(spec["beats"], spec["orders"], cylinders)
    timing = cylinders.normal(size=spec["beats"]) * spec["timing"]   # each cylinder's pipe is a different length
    # Hunting: the revs drift a fraction of a percent, a few times per loop.
    drift = sum(a * np.sin(2 * np.pi * k * index / total + rng.random() * 6.28) for k, a in ((1, 0.9), (2, 0.6), (3, 0.4)))
    where = (index + timing[index % spec["beats"]] + rng.normal(size=total) * spec["jitter"]) * spacing
    where += drift * 0.002 * RATE
    # Each beat differs very slightly from the last, and the engine swells and eases slowly.
    strength = accents[index % spec["beats"]] * (1.0 + spec["variation"] * rng.normal(size=total))
    strength *= 1.0 + 0.07 * slow_wander(n, rng, 0.8)[(where.astype(int)) % n]
    # Alternate beats come from the left and right cylinder banks.
    pan = np.where(index % 2 == 0, -1.0, 1.0) * spec["width"]

    freqs = np.fft.rfftfreq(n, 1 / RATE)
    safe = np.maximum(freqs, 1.0)
    # The exhaust system: broad pipe resonances, rolled off gently on top so the
    # upper harmonics stay audible (that is what makes it sound clear, not
    # muffled) and firmly above 3 kHz so nothing is shrill. The high loop is a
    # touch brighter, so the sound opens up as the revs rise.
    lift = 1.15 if high else 1.0
    lowpass = spec["lowpass"] * lift
    floor = spec["floor"]
    shape = 0.22 + sum(g / (1.0 + 1j * q * (safe / (f * lift) - f * lift / safe)) for f, q, g in spec["resonances"])
    shape = shape / np.sqrt(1.0 + (freqs / (spec["tilt"] * lift)) ** 2) / (1.0 + (freqs / lowpass) ** 2) / (1.0 + (freqs / 3000.0) ** 4)
    shape = shape * (freqs / floor) ** 4 / (1.0 + (freqs / floor) ** 4)
    # Long pipes spread each beat out in time (high notes arrive a few
    # milliseconds late). The ear hears the same harmonics, but the wave is
    # rounder: no spikes to make it buzz, and more room before it would clip.
    shape = shape * np.exp(-1j * np.pi * PIPE_SPREAD * freqs ** 2)
    breath = (freqs / 300.0) ** 2 / (1.0 + (freqs / 300.0) ** 2) / (1.0 + (freqs / 1800.0) ** 2) ** 2
    width = int(RATE * spec["pulse_ms"] / 1000.0 / (1.15 if high else 1.0))
    pulse = np.zeros(n)
    pulse[:width] = np.hanning(width)
    pulse_spec = np.fft.rfft(pulse)
    cloud = np.zeros(n)   # how much exhaust is in the air: the beats, smeared over a few milliseconds
    cloud[:int(RATE * 0.012)] = np.hanning(int(RATE * 0.012))
    cloud_spec = np.fft.rfft(cloud)

    out = np.zeros((n, 2))
    for channel in range(2):
        gain = np.sqrt(0.5 * (1.0 + pan * (1.0 if channel == 1 else -1.0)))
        beats = np.zeros(n)
        frac = where - np.floor(where)
        at = np.floor(where).astype(int)
        np.add.at(beats, at % n, strength * gain * (1.0 - frac))
        np.add.at(beats, (at + 1) % n, strength * gain * frac)
        beat_spec = np.fft.rfft(beats)
        sound = np.fft.irfft(beat_spec * pulse_spec * shape, n)
        level = np.sqrt(np.mean(sound ** 2))
        # A soft breath of exhaust riding on the beats, far below them.
        puffs = np.abs(np.fft.irfft(np.fft.rfft(np.abs(beats)) * cloud_spec, n))
        air = np.fft.irfft(np.fft.rfft(rng.normal(size=n) * puffs) * breath, n)
        out[:, channel] = sound + air / (np.sqrt(np.mean(air ** 2)) + 1e-9) * level * spec["air"]
    # The propeller: a low note at the rate the blades pass, and its octave.
    t = np.arange(n) / RATE
    blade = round(spec["cycles"] * rate * spec["prop"] * ENGINE_SECONDS) / ENGINE_SECONDS
    swell = 1.0 + 0.12 * slow_wander(n, rng, 0.6)
    hum = (np.sin(2 * np.pi * blade * t) + 0.4 * np.sin(2 * np.pi * 2 * blade * t + 1.0)) * swell
    out += hum[:, None] * np.sqrt(np.mean(out ** 2)) * spec["hum"] * np.sqrt(2.0) / np.sqrt(1.16)
    return out


## How the game mixes the two loops for a given RPM (keep in step with Sfx.engine_layers).
ENGINE_LOW_AT = 0.75
ENGINE_HIGH_AT = ENGINE_LOW_AT * HIGH_RATE


def engine_layers(rpm: float) -> tuple[float, float, float, float]:
    x = min(max((rpm - 0.78) / (1.12 - 0.78), 0.0), 1.0)
    blend = x * x * (3.0 - 2.0 * x)
    return rpm / ENGINE_LOW_AT, float(np.cos(blend * np.pi / 2)), rpm / ENGINE_HIGH_AT, float(np.sin(blend * np.pi / 2))


def audition(loops: dict) -> None:
    """Render each engine through the game's mix: idle, a slow run up to boost, and back."""
    seconds = 16.0
    n = int(RATE * seconds)
    t = np.arange(n) / RATE
    rpm = 0.72 + (1.24 - 0.72) * np.clip(np.minimum((t - 2.0) / 6.0, (seconds - 1.0 - t) / 5.0), 0.0, 1.0)
    parts = []
    for name, (low, high) in loops.items():
        mix = np.zeros((n, 2))
        layers = np.array([engine_layers(r) for r in rpm])
        for loop, pitch, gain in ((low, layers[:, 0], layers[:, 1]), (high, layers[:, 2], layers[:, 3])):
            phase = np.cumsum(pitch) % len(loop)
            i0 = phase.astype(int)
            f = (phase - i0)[:, None]
            mix += (loop[i0] * (1 - f) + loop[(i0 + 1) % len(loop)] * f) * gain[:, None]
        mix /= np.max(np.abs(mix))
        for label, r in (("idle", 0.75), ("full", 1.0), ("boost", 1.2)):
            at = int(np.argmin(np.abs(rpm[: n // 2] - r)))
            print(f"  {name:12s} {label:5s} {describe(mix[max(at - RATE // 2, 0): at + RATE // 2])}")
        parts.append(mix)
        parts.append(np.zeros((RATE // 2, 2)))
    folder = ROOT / "build"
    folder.mkdir(exist_ok=True)
    write("engine_audition.wav", np.concatenate(parts), 0.85, folder)


def shot(rng, seconds: float, noise_band: float, noise_decay: float, thump: tuple[float, float], thump_decay: float,
         thump_gain: float, echoes: tuple[float, ...] = (), tail: float = 0.16, tail_decay: float = 0.12) -> np.ndarray:
    """One gunshot in stereo: a dull crack over a falling-pitch thump, the breech
    clacking home, and the report rolling away across the valley."""
    n = int(RATE * seconds)
    t = np.arange(n) / RATE
    crack = looped_noise(n, rng, noise_band)
    crack = crack / (np.max(np.abs(crack)) + 1e-9) * np.exp(-t / noise_decay)
    f0, f1 = thump
    freq = f1 + (f0 - f1) * np.exp(-t / (thump_decay * 0.6))
    body = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t / thump_decay) * thump_gain
    core = crack + body
    for delay in echoes:   # the other guns in the battery, fractionally late
        d = int(RATE * delay)
        core[d:] += (crack + body)[: n - d] * 0.6
    # Breech: a short low clack a few milliseconds after the shot.
    d = int(RATE * 0.011)
    core[d:] += 0.16 * np.sin(2 * np.pi * 640.0 * t[: n - d]) * np.exp(-t[: n - d] / 0.004)
    core *= np.minimum(t / 0.0006, 1.0)             # click-free attack
    out = np.repeat(core[:, None], 2, axis=1)
    for channel in range(2):   # the rolling report: dull, different in each ear
        rumble = looped_noise(n, rng, 420.0)
        rumble = rumble / (np.max(np.abs(rumble)) + 1e-9)
        out[:, channel] += rumble * tail * np.minimum(t / 0.012, 1.0) * np.exp(-t / tail_decay)
    return out * np.minimum((seconds - t) / 0.03, 1.0)[:, None]


def whizz(rng) -> np.ndarray:
    """A round passing close by: a short rush that drops in pitch as it goes."""
    seconds = 0.3
    n = int(RATE * seconds)
    t = np.arange(n) / RATE
    hiss = looped_noise(n, rng, 180.0)
    hiss = hiss / (np.max(np.abs(hiss)) + 1e-9)
    freq = 620.0 + 900.0 / (1.0 + np.exp((t - 0.09) / 0.022))   # about 1500 Hz falling to 620 Hz
    out = hiss * np.sin(2 * np.pi * np.cumsum(freq) / RATE)
    return out * np.minimum(t / 0.05, 1.0) ** 2 * np.exp(-np.maximum(t - 0.09, 0.0) / 0.06) * np.minimum((seconds - t) / 0.03, 1.0)


def strike(rng, seconds: float, partials: tuple[float, ...], decay: float, noise_band: float, thud: float) -> np.ndarray:
    """Bullet hitting metal: a short noise tick with a ringing clank."""
    n = int(RATE * seconds)
    t = np.arange(n) / RATE
    tick = looped_noise(n, rng, noise_band)
    out = tick / (np.max(np.abs(tick)) + 1e-9) * np.exp(-t / 0.012)
    for i, f in enumerate(partials):
        out += 0.5 / (i + 1) * np.sin(2 * np.pi * f * t + rng.random() * 6.28) * np.exp(-t / (decay / (1 + 0.4 * i)))
    out += thud * np.sin(2 * np.pi * 95.0 * t) * np.exp(-t / 0.05)
    return out * np.minimum(t / 0.0005, 1.0) * np.minimum((seconds - t) / 0.02, 1.0)


def explosion(rng) -> np.ndarray:
    seconds = 2.4
    n = int(RATE * seconds)
    t = np.arange(n) / RATE
    rumble = looped_noise(n, rng, 180)
    rumble = rumble / np.max(np.abs(rumble)) * np.exp(-t / 0.55)
    crack = looped_noise(n, rng, 2600)
    crack = crack / np.max(np.abs(crack)) * np.exp(-t / 0.07)
    boom = np.sin(2 * np.pi * np.cumsum(38.0 + 70.0 * np.exp(-t / 0.12)) / RATE) * np.exp(-t / 0.4)
    out = rumble * 1.3 + crack * 0.8 + boom * 1.1
    return out * np.minimum(t / 0.001, 1.0) * np.minimum((seconds - t) / 0.3, 1.0)


def wind(rng) -> np.ndarray:
    """Airflow: a soft, low rush. Kept dull so it never hisses over the engine."""
    n = int(RATE * 3.0)
    t = np.arange(n) / RATE
    rush = looped_noise(n, rng, 420) + 0.1 * looped_noise(n, rng, 1600)
    swell = 0.8 + 0.2 * np.sin(2 * np.pi * t / 3.0) + 0.1 * np.sin(2 * np.pi * 2 * t / 3.0 + 1.0)
    return rush * swell


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    loops = {}
    for name, spec in ENGINES.items():
        pair = []
        for high in (False, True):
            loop = engine_loop(spec, high)
            loop *= ENGINE_RMS / np.sqrt(np.mean(loop ** 2))
            if np.max(np.abs(loop)) > ENGINE_PEAK:
                raise SystemExit(f"engine_{name} would peak at {np.max(np.abs(loop)):.2f}: lower ENGINE_RMS (and raise the game's engine level to match)")
            write(f"engine_{name}_{'high' if high else 'low'}.wav", loop, None)
            pair.append(loop)
        loops[name] = tuple(pair)
    write("wind_loop.wav", wind(np.random.default_rng(51)))
    rng = np.random.default_rng(303)
    for take in (1, 2, 3):
        write(f"gun_light_{take}.wav", shot(rng, 0.34, 2600, 0.020, (250.0, 130.0), 0.024, 0.75, (), 0.13, 0.09))
        write(f"gun_medium_{take}.wav", shot(rng, 0.42, 1900, 0.030, (165.0, 74.0), 0.05, 1.15, (0.009,), 0.16, 0.11))
        write(f"gun_heavy_{take}.wav", shot(rng, 0.52, 1300, 0.042, (108.0, 44.0), 0.10, 1.7, (0.007, 0.016), 0.2, 0.14))
    write("gun_jam.wav", strike(rng, 0.3, (240.0, 395.0, 610.0), 0.06, 1200, 1.2))
    write("whizz.wav", whizz(rng))
    write("hit.wav", strike(rng, 0.22, (1870.0, 2930.0, 4410.0), 0.05, 6000, 0.0))
    write("hurt.wav", strike(rng, 0.36, (410.0, 655.0, 1010.0, 1490.0), 0.11, 2500, 0.9))
    write("explosion.wav", explosion(rng))
    if "--audition" in sys.argv:
        audition(loops)


if __name__ == "__main__":
    main()
