#!/usr/bin/env python3
"""Tests for the PCM edge fade.

A stream that starts or stops on a large sample is a step change, and a step
change is a click. Kokoro ends sentences near full scale; piper happens to
trail off near zero. The fade removes the difference between lucky and
unlucky engines.
"""
import array
import subprocess
import sys
import unittest
from pathlib import Path

FADE = Path(__file__).resolve().parents[1] / "lib" / "fade.py"
RATE = 24000


def run_fade(samples, rate=RATE, ms=8.0):
    buf = array.array("h", samples)
    if sys.byteorder == "big":
        buf.byteswap()
    result = subprocess.run(
        [sys.executable, str(FADE), "--rate", str(rate), "--ms", str(ms)],
        input=buf.tobytes(), capture_output=True, check=True)
    out = array.array("h")
    out.frombytes(result.stdout)
    if sys.byteorder == "big":
        out.byteswap()
    return list(out)


class FadeTests(unittest.TestCase):
    def test_loud_ending_is_ramped_down(self):
        loud = [28000] * 4000
        out = run_fade(loud)
        self.assertEqual(len(out), len(loud), "samples must not be lost")
        self.assertLess(abs(out[-1]), 1000, "stream still ends on a large sample")
        self.assertLess(abs(out[0]), 1000, "stream still starts on a large sample")

    def test_middle_is_untouched(self):
        loud = [20000] * 8000
        out = run_fade(loud)
        middle = out[len(out) // 2]
        self.assertEqual(middle, 20000, "audio away from the edges was altered")

    def test_fade_is_monotonic_at_the_end(self):
        out = run_fade([25000] * 6000)
        tail = [abs(v) for v in out[-100:]]
        self.assertTrue(all(a >= b for a, b in zip(tail, tail[1:])),
                        "the tail should descend, not wobble")

    def test_stream_shorter_than_the_fade_still_ends_quietly(self):
        out = run_fade([30000] * 20)
        self.assertEqual(len(out), 20)
        self.assertLess(abs(out[-1]), 30000)

    def test_odd_trailing_byte_is_dropped_not_passed_on(self):
        # A half sample would shift every following byte and turn speech into
        # noise, so it is discarded rather than forwarded.
        payload = array.array("h", [1000] * 500).tobytes() + b"\x01"
        result = subprocess.run([sys.executable, str(FADE), "--rate", str(RATE)],
                                input=payload, capture_output=True, check=True)
        self.assertEqual(len(result.stdout) % 2, 0, "emitted a misaligned byte")

    def test_silence_stays_silent(self):
        out = run_fade([0] * 3000)
        self.assertEqual(set(out), {0})


if __name__ == "__main__":
    unittest.main(verbosity=2)
