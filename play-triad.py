#!/usr/bin/env python3
"""Placeholder sine-triad player. Args: hz1 hz2 hz3 [seconds]."""

import errno
import json
import math
import os
import select
import shutil
import stat
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
WATCH_DEBOUNCE = 0.22
MAX_NOTIFICATION_BYTES = 16 * 1024


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


def notification_name_ok(name):
    name = str(name or "").strip()
    if len(name) < 6 or not name.endswith(".json"):
        return False
    if "/" in name or name in (".", "..") or ".." in name:
        return False
    return True


def open_notification_fd(path):
    return os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)


def read_notification_json(path, max_bytes=MAX_NOTIFICATION_BYTES):
    fd = open_notification_fd(path)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError(errno.EINVAL, "notification is not a regular file")
        if info.st_size > max_bytes:
            raise OSError(errno.EFBIG, "notification exceeds size cap")
        chunks = []
        remaining = max_bytes + 1
        while remaining > 0:
            chunk = os.read(fd, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > max_bytes:
            raise OSError(errno.EFBIG, "notification exceeds size cap")
    finally:
        os.close(fd)
    parsed = json.loads(data.decode("utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError("notification JSON must be an object")
    return parsed


def notification_urgency(path):
    try:
        return read_notification_json(path).get("urgency", 1)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError, TypeError, ValueError, AttributeError):
        return None


def coalesced_lines(stream, debounce=WATCH_DEBOUNCE):
    """Yield the latest line from each burst, after a quiet period."""
    while True:
        line = stream.readline()
        if not line:
            return
        deadline = time.monotonic() + debounce
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _, _ = select.select([stream], [], [], remaining)
            if not ready:
                break
            extra = stream.readline()
            if not extra:
                yield line
                return
            line = extra
        yield line


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


def play_earcon(tonic, path):
    urgency = notification_urgency(path)
    if urgency is None:
        return
    play_freqs(earcon_hz(tonic, urgency), EARCON_SECONDS, EARCON_AMPLITUDE)


def earcon_main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: play-triad.py --earcon tonicIndex jsonPath\n")
        sys.exit(2)
    play_earcon(argv[0], argv[1])


def watch_main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: play-triad.py --watch tonicIndex notifyDir\n")
        sys.exit(2)
    tonic, directory = argv[0], argv[1]
    if not directory or "\x00" in directory:
        sys.stderr.write("play-triad: invalid notification directory\n")
        sys.exit(2)
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
    except OSError as exc:
        sys.stderr.write("play-triad: cannot create %s: %s\n" % (directory, exc))
        sys.exit(1)
    try:
        proc = subprocess.Popen(
            ["inotifywait", "-m", "-q", "-e", "close_write", "--format", "%f", directory],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        sys.stderr.write("play-triad: inotifywait not found\n")
        sys.exit(1)
    try:
        for raw in coalesced_lines(proc.stdout):
            name = raw.decode("utf-8", "replace").strip()
            if not notification_name_ok(name):
                continue
            play_earcon(tonic, os.path.join(directory, name))
    finally:
        if proc.stdout:
            try:
                proc.stdout.close()
            except OSError:
                pass
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()


def main(argv):
    if argv and argv[0] == "--earcon":
        earcon_main(argv[1:])
        return
    if argv and argv[0] == "--watch":
        watch_main(argv[1:])
        return
    if len(argv) < 3:
        sys.stderr.write("usage: play-triad.py hz1 hz2 hz3 [seconds]\n")
        sys.exit(2)
    freqs = [float(argv[0]), float(argv[1]), float(argv[2])]
    seconds = float(argv[3]) if len(argv) > 3 else DEFAULT_SECONDS
    play_freqs(freqs, seconds)


if __name__ == "__main__":
    main(sys.argv[1:])
