#!/usr/bin/env python3
"""Synthesise the original sound effects (no recordings, no downloads).

Run:  python3 tools/generate_audio.py
Writes 16-bit mono WAV loops into game/assets/audio/:
  engine_loop.wav   V-12 piston drone with propeller throb (pitch-shifted in game)
  wind_loop.wav     airflow rush (volume follows airspeed)
Loop lengths are whole numbers of every period, so they repeat seamlessly.
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


def wind(rng) -> np.ndarray:
    n = int(RATE * 3.0)
    t = np.arange(n) / RATE
    rush = looped_noise(n, rng, 900) + 0.35 * looped_noise(n, rng, 4000)
    swell = 0.8 + 0.2 * np.sin(2 * np.pi * t / 3.0) + 0.1 * np.sin(2 * np.pi * 2 * t / 3.0 + 1.0)
    return rush * swell


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(51)
    write("engine_loop.wav", engine(rng))
    write("wind_loop.wav", wind(rng))


if __name__ == "__main__":
    main()
