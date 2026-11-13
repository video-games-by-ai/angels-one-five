#!/usr/bin/env python3
"""Synthesise the original sound effects (no recordings, no downloads).

Run:  python3 tools/generate_audio.py
Writes 16-bit mono WAV files into game/assets/audio/:
  engine_mustang.wav      Packard Merlin V-12 drone with propeller throb
  engine_spitfire.wav     Rolls-Royce Merlin: smoother, slightly quicker V-12 purr
  engine_thunderbolt.wav  R-2800 eighteen-cylinder radial: deep, lumpy rumble
  wind_loop.wav           airflow rush (volume follows airspeed)
  gun_light/medium/heavy.wav   one shot each: crisp rattle, .50 punch, eight-gun thump
  hit.wav, hurt.wav       bullet strikes on the target / on your own aircraft
  explosion.wav           an aircraft blowing up
Engine loops are pitch-shifted in game; their lengths are whole numbers of every
period, so they repeat seamlessly.
"""
from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "game" / "assets" / "audio"
RATE = 44100


def write(name: str, signal: np.ndarray) -> None:
    signal = signal / (np.max(np.abs(signal)) + 1e-9) * 0.85
    pcm = (signal * 32767).astype("<i2")
    with wave.open(str(OUT / name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    print(name, f"{len(signal) / RATE:.2f}s")


def looped_noise(n: int, rng, smooth: int) -> np.ndarray:
    """Band-limited noise that is periodic over n samples (built in the frequency domain)."""
    spec = rng.normal(size=n // 2 + 1) + 1j * rng.normal(size=n // 2 + 1)
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    spec *= 1.0 / (1.0 + (freqs / smooth) ** 2)
    spec[0] = 0
    return np.fft.irfft(spec, n)


def engine(rng) -> np.ndarray:
    seconds = 2.0
    n = int(RATE * seconds)
    t = np.arange(n) / RATE
    firing = 90.0          # Hz, integer so it loops in 2 s
    out = np.zeros(n)
    # Uneven firing pulses: harmonic series with decaying, slightly random weights.
    for k in range(1, 28):
        amp = (1.0 / k ** 0.9) * (0.6 + 0.4 * rng.random())
        out += amp * np.sin(2 * np.pi * firing * k / 2 * t + rng.random() * 6.28)
    # Exhaust crackle: noise gated by the firing rhythm.
    gate = (0.5 + 0.5 * np.sin(2 * np.pi * firing * t)) ** 6
    out += looped_noise(n, rng, 2500) * gate * 18.0
    # Propeller blade-pass throb (4 blades) as amplitude modulation.
    out *= 0.78 + 0.22 * np.sin(2 * np.pi * 46.0 * t)
    out += 0.5 * np.sin(2 * np.pi * 23.0 * t)
    # Soft low-pass to take the edge off.
    k = np.exp(-np.arange(24) / 6.0)
    out = np.convolve(np.concatenate([out[-24:], out]), k / k.sum(), mode="valid")[: n]
    return out[:n]


def soften(out: np.ndarray, taps: int, tau: float) -> np.ndarray:
    """Periodic one-pole style low-pass, so the loop still joins up."""
    n = len(out)
    k = np.exp(-np.arange(taps) / tau)
    return np.convolve(np.concatenate([out[-taps:], out]), k / k.sum(), mode="valid")[:n]


def engine_spitfire(rng) -> np.ndarray:
    """Merlin 66: a smooth, even V-12 purr, a little quicker than the Mustang's and
    with far less exhaust crackle. The two cylinder banks are tuned a hair apart
    so they beat gently. No supercharger whine: it was shrill on headphones."""
    n = int(RATE * 2.0)
    t = np.arange(n) / RATE
    out = np.zeros(n)
    for bank, firing in ((0, 100.0), (1, 101.0)):   # 1 Hz beat between the banks
        for k in range(1, 22):
            even = 1.0 if k % 2 == 0 else 0.55
            amp = even * (1.0 / k ** 1.25) * (0.75 + 0.25 * rng.random())
            out += amp * np.sin(2 * np.pi * firing * k / 2 * t + rng.random() * 6.28)
    gate = (0.5 + 0.5 * np.sin(2 * np.pi * 100.0 * t)) ** 6
    out += looped_noise(n, rng, 1400) * gate * 7.0
    # Four-blade Rotol propeller: soft blade-pass throb and a low hum.
    out *= 0.82 + 0.18 * np.sin(2 * np.pi * 50.0 * t)
    out += 0.45 * np.sin(2 * np.pi * 25.0 * t)
    return soften(out, 20, 4.5)


def engine_thunderbolt(rng) -> np.ndarray:
    n = int(RATE * 2.0)
    t = np.arange(n) / RATE
    firing = 66.0
    out = np.zeros(n)
    # Two rows of nine cylinders: a dense cluster of quarter-order partials gives
    # the uneven, galloping beat of a big radial.
    for k in range(1, 56):
        f = firing * k / 4
        peak = np.exp(-((f - 66.0) / 60.0) ** 2) + 0.7 * np.exp(-((f - 132.0) / 70.0) ** 2) + 0.35 * np.exp(-((f - 33.0) / 20.0) ** 2)
        amp = (0.34 / k ** 0.4 + peak) * (0.45 + 0.55 * rng.random())
        out += amp * np.sin(2 * np.pi * f * t + rng.random() * 6.28)
    gate = (0.5 + 0.5 * np.sin(2 * np.pi * firing / 2 * t)) ** 3
    out += looped_noise(n, rng, 1300) * gate * 30.0
    # Slow four-blade paddle propeller: heavy throb.
    out *= 0.66 + 0.34 * np.sin(2 * np.pi * 22.0 * t) ** 2
    out += 0.9 * np.sin(2 * np.pi * 33.0 * t) + 0.4 * np.sin(2 * np.pi * 16.5 * t + 0.7)
    return soften(out, 32, 8.0)


def shot(rng, seconds: float, noise_band: float, noise_decay: float, thump: tuple[float, float], thump_decay: float,
         thump_gain: float, echoes: tuple[float, ...] = ()) -> np.ndarray:
    """One gunshot: a filtered noise crack over a falling-pitch thump."""
    n = int(RATE * seconds)
    t = np.arange(n) / RATE
    crack = looped_noise(n, rng, noise_band)
    crack = crack / (np.max(np.abs(crack)) + 1e-9) * np.exp(-t / noise_decay)
    f0, f1 = thump
    freq = f1 + (f0 - f1) * np.exp(-t / (thump_decay * 0.6))
    body = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t / thump_decay) * thump_gain
    out = crack + body
    for delay in echoes:   # the other guns in the battery, fractionally late
        d = int(RATE * delay)
        out[d:] += (crack + body)[: n - d] * 0.6
    out *= np.minimum(t / 0.0006, 1.0)             # click-free attack
    out *= np.minimum((seconds - t) / 0.02, 1.0)   # and release
    return out


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
    n = int(RATE * 3.0)
    t = np.arange(n) / RATE
    rush = looped_noise(n, rng, 900) + 0.35 * looped_noise(n, rng, 4000)
    swell = 0.8 + 0.2 * np.sin(2 * np.pi * t / 3.0) + 0.1 * np.sin(2 * np.pi * 2 * t / 3.0 + 1.0)
    return rush * swell


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(51)
    write("engine_mustang.wav", engine(rng))
    write("wind_loop.wav", wind(rng))
    write("engine_spitfire.wav", engine_spitfire(np.random.default_rng(9)))
    write("engine_thunderbolt.wav", engine_thunderbolt(np.random.default_rng(47)))
    rng = np.random.default_rng(303)
    write("gun_light.wav", shot(rng, 0.20, 5200, 0.022, (260.0, 140.0), 0.022, 0.55))
    write("gun_medium.wav", shot(rng, 0.28, 3000, 0.036, (170.0, 78.0), 0.05, 0.95, (0.009,)))
    write("gun_heavy.wav", shot(rng, 0.38, 1900, 0.05, (110.0, 46.0), 0.10, 1.5, (0.007, 0.016)))
    write("hit.wav", strike(rng, 0.22, (1870.0, 2930.0, 4410.0), 0.05, 6000, 0.0))
    write("hurt.wav", strike(rng, 0.36, (410.0, 655.0, 1010.0, 1490.0), 0.11, 2500, 0.9))
    write("explosion.wav", explosion(rng))


if __name__ == "__main__":
    main()
