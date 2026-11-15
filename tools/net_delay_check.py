#!/usr/bin/env python3
"""Compare the delay the stats readout reports with the real one.

Reads the --log output of games that flew one online match on the same machine.
Each line carries the game's tick with its real time, and for every other
player the moment of their flight being drawn (`shown`, on their clock) next to
the delay the readout showed. Since all clocks here are the same clock, the
real age of each picture is known: now minus the time the other game was at
that moment.

  tools/net_delay_check.py LOG [LOG ...]
"""
import re
import sys

TICK = 1.0 / 60.0


def parse(path):
    """-> (name, [(tick, unix)], {other: [(unix, shown, delay, ping, lost, guess)]})"""
    name, clock, seen = None, [], {}
    for line in open(path, errors="replace"):
        m = re.match(r"NET t=\d+ fps=\d+ tick=(\d+) unix=([\d.]+) (\S+)", line)
        if not m:
            continue
        tick, unix, name = int(m.group(1)), float(m.group(2)), m.group(3)
        if tick > 0:
            clock.append((tick, unix))
        for part in line.split(" | ")[1:]:
            r = re.match(r"(\S+) .*alive=(\w+) .*ping=(-?\d+) delay=(-?\d+) lost=(\d+)% guess=(\d+)% shown=(-?[\d.]+)", part)
            if r and r.group(2) == "true" and int(r.group(4)) >= 0 and float(r.group(7)) > 0:
                seen.setdefault(r.group(1), []).append((unix, float(r.group(7)), int(r.group(4)), int(r.group(3)), int(r.group(5)), int(r.group(6))))
    return name, clock, seen


def line_fit(points):
    n = len(points)
    mx = sum(p[0] for p in points) / n
    my = sum(p[1] for p in points) / n
    slope = sum((p[0] - mx) * (p[1] - my) for p in points) / sum((p[0] - mx) ** 2 for p in points)
    return slope, my - slope * mx


def main():
    games = [parse(p) for p in sys.argv[1:]]
    clocks = {name: line_fit(clock) for name, clock, _ in games if name and len(clock) > 3}
    worst = 0.0
    print(f"{'viewer':8} {'sees':8} {'samples':>7} {'ping':>6} {'readout':>8} {'real':>8} {'diff':>6} {'lost':>5} {'guess':>5}")
    for name, _, seen in games:
        for other, rows in sorted(seen.items()):
            if other not in clocks:
                continue
            slope, base = clocks[other]
            real, shown = [], []
            for unix, moment, delay, ping, lost, guess in rows:
                age = (unix - (base + slope * moment / TICK)) * 1000.0
                if 0.0 < age < 1500.0:
                    real.append(age)
                    shown.append((delay, ping, lost, guess))
            if not real:
                continue
            n = len(real)
            avg_real = sum(real) / n
            avg = [sum(s[k] for s in shown) / n for k in range(4)]
            worst = max(worst, abs(avg[0] - avg_real))
            print(f"{name:8} {other:8} {n:7d} {avg[1]:4.0f}ms {avg[0]:6.0f}ms {avg_real:6.0f}ms {avg[0] - avg_real:+5.0f}ms {avg[2]:4.0f}% {avg[3]:4.0f}%")
    print(f"largest difference between readout and real delay: {worst:.0f} ms")
    return 0 if worst <= 15.0 else 1


if __name__ == "__main__":
    sys.exit(main())
