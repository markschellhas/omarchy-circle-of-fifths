#!/usr/bin/env python3
"""Placeholder sine-triad player. Args: hz1 hz2 hz3 [seconds]."""

import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave

RATE = 44100
DEFAULT_SECONDS = 0.9
AMPLITUDE = 0.18
ATTACK = 0.08
RELEASE = 0.28
PAD = 0.02


def cosine_ramp(x):
    x = max(0.0, min(1.0, x))
    return 0.5 - 0.5 * math.cos(math.pi * x)


def envelope(i, n, attack, release):
    if i < attack:
        return cosine_ramp(i / attack)
    tail = n - 1 - i
    if tail < release:
        return cosine_ramp(tail / release)
    return 1.0


def synth(freqs, seconds):
    n = max(1, int(RATE * seconds))
    attack = max(1, int(RATE * ATTACK))
    release = max(1, int(RATE * RELEASE))
    pad = max(0, int(RATE * PAD))
    if attack + release >= n:
        attack = max(1, n // 5)
        release = max(1, n - attack - 1)
    frames = [0] * pad
    for i in range(n):
        env = envelope(i, n, attack, release)
        sample = 0.0
        t = i / RATE
        for hz in freqs:
            sample += math.sin(2.0 * math.pi * hz * t)
        val = max(-1.0, min(1.0, sample * AMPLITUDE * env))
        frames.append(int(val * 32767))
    frames.extend([0] * pad)
    frames[0] = 0
    frames[-1] = 0
    return frames


def write_wav(path, frames):
    with wave.open(path, "w") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(b"".join(struct.pack("<h", s) for s in frames))


def play(path):
    for cmd in (
        ["pw-play", path],
        ["paplay", path],
        ["aplay", "-q", path],
    ):
        if shutil.which(cmd[0]):
            subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
    sys.stderr.write("play-triad: no pw-play, paplay, or aplay\n")
    sys.exit(1)


PITCH_CLASS = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5]
EARCON_SECONDS = 0.42
EARCON_AMPLITUDE = 0.14


def wrap12(index):
    return ((int(index) % 12) + 12) % 12


def midi_to_hz(midi):
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


def root_midi(index, minor):
    pc = PITCH_CLASS[wrap12(index)]
    if not minor:
        return 60 + pc
    mpc = (pc + 9) % 12
    return (48 if mpc >= 8 else 60) + mpc


def triad_hz(index, minor):
    root = root_midi(index, minor)
    third = root + (3 if minor else 4)
    return [midi_to_hz(root), midi_to_hz(third), midi_to_hz(root + 7)]


def earcon_hz(tonic, urgency):
    t = wrap12(tonic)
    try:
        u = int(urgency)
    except (TypeError, ValueError):
        u = 1
    if u >= 2:
        return triad_hz(wrap12(t + 1), False)
    if u <= 0:
        return triad_hz(t, True)
    return triad_hz(t, False)


def debounce_ok(wait=0.22):
    stamp = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "cof-earcon.stamp")
    now = time.time()
    try:
        prev = float(open(stamp, encoding="utf-8").read().strip())
        if now - prev < wait:
            return False
    except (OSError, ValueError):
        pass
    try:
        with open(stamp, "w", encoding="utf-8") as handle:
            handle.write(str(now))
    except OSError:
        pass
    return True


def play_freqs(freqs, seconds, amplitude=AMPLITUDE):
    global AMPLITUDE
    saved = AMPLITUDE
    AMPLITUDE = amplitude
    try:
        frames = synth(freqs, seconds)
    finally:
        AMPLITUDE = saved
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        path = tmp.name
    try:
        write_wav(path, frames)
        play(path)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def earcon_main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: play-triad.py --earcon tonicIndex jsonPath\n")
        sys.exit(2)
    if not debounce_ok():
        return
    path = argv[1]
    urgency = 1
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        urgency = data.get("urgency", 1)
    except (OSError, json.JSONDecodeError, AttributeError):
        pass
    play_freqs(earcon_hz(argv[0], urgency), EARCON_SECONDS, EARCON_AMPLITUDE)


def main(argv):
    if argv and argv[0] == "--earcon":
        earcon_main(argv[1:])
        return
    if len(argv) < 3:
        sys.stderr.write("usage: play-triad.py hz1 hz2 hz3 [seconds]\n")
        sys.exit(2)
    freqs = [float(argv[0]), float(argv[1]), float(argv[2])]
    seconds = float(argv[3]) if len(argv) > 3 else DEFAULT_SECONDS
    play_freqs(freqs, seconds)


if __name__ == "__main__":
    main(sys.argv[1:])
