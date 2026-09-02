#!/usr/bin/env python3
"""Take the click off the ends of a raw PCM stream.

Some engines stop mid-waveform. Kokoro ends a sentence at around 86% of full
scale, and a stream that stops on a large sample is a step change - which is
exactly what a click is. Piper happens to trail off near zero, so it sounds
fine, but that is luck rather than a guarantee, and any new provider inherits
the same risk.

Reads signed 16-bit little-endian mono on stdin, writes it back with a short
fade at each end. The tail is held back by exactly the fade length so the end
can be faded without knowing in advance where it is, which costs a few
milliseconds of latency and nothing else.
"""
import argparse
import array
import sys

SAMPLE_BYTES = 2


def ramp(buf: array.array, start: int, count: int, rising: bool) -> None:
    """Scale count samples from start by a linear ramp, in place."""
    if count <= 0:
        return
    for i in range(count):
        gain = (i + 1) / (count + 1)
        if not rising:
            gain = 1.0 - gain
        buf[start + i] = int(buf[start + i] * gain)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rate", type=int, default=22050)
    ap.add_argument("--ms", type=float, default=8.0,
                    help="fade length in milliseconds (default 8)")
    args = ap.parse_args()

    fade = max(1, int(args.rate * args.ms / 1000.0))
    hold = fade * SAMPLE_BYTES

    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    pending = bytearray()
    faded_in = False

    while True:
        chunk = stdin.read(8192)
        if not chunk:
            break
        pending += chunk

        if not faded_in and len(pending) >= hold:
            head = array.array("h")
            head.frombytes(bytes(pending[:hold]))
            if sys.byteorder == "big":
                head.byteswap()
            ramp(head, 0, fade, rising=True)
            if sys.byteorder == "big":
                head.byteswap()
            pending[:hold] = head.tobytes()
            faded_in = True

        # Emit everything except the tail we may still need to fade, on a
        # whole-sample boundary so a split sample is never written.
        if len(pending) > hold:
            emit = (len(pending) - hold) // SAMPLE_BYTES * SAMPLE_BYTES
            if emit > 0:
                stdout.write(bytes(pending[:emit]))
                stdout.flush()
                del pending[:emit]

    # Drop a trailing half sample rather than passing a misaligned byte on.
    usable = len(pending) // SAMPLE_BYTES * SAMPLE_BYTES
    tail = array.array("h")
    tail.frombytes(bytes(pending[:usable]))
    if sys.byteorder == "big":
        tail.byteswap()

    if not faded_in:                      # stream shorter than one fade
        ramp(tail, 0, min(fade, len(tail) // 2), rising=True)
    ramp(tail, max(0, len(tail) - fade), min(fade, len(tail)), rising=False)

    if sys.byteorder == "big":
        tail.byteswap()
    stdout.write(tail.tobytes())
    stdout.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)          # player went away first; nothing to report
