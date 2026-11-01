"""Protocol and lookahead tests for the resident Kokoro worker.

These do not load the model. They check the socket framing and that the next
chunk is produced while the consumer is still holding the current one.
"""

import socket
import sys
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

import kokoro_runtime as runtime  # noqa: E402


class ProtocolTests(unittest.TestCase):
    def test_request_round_trip(self):
        left, right = socket.socketpair()
        with left, right:
            runtime.write_request(left, "af_bella", 0.8, "Hello\n\nthere")
            voice, speed, text = runtime.read_request(right)
        self.assertEqual(voice, "af_bella")
        self.assertEqual(speed, 0.8)
        self.assertEqual(text, "Hello\n\nthere")

    def test_audio_frames_round_trip(self):
        left, right = socket.socketpair()

        def serve():
            with left:
                runtime.write_status(left, 0)
                runtime.write_frame(left, b"\x01\x02")
                runtime.write_frame(left, b"\x03\x04")
                runtime.write_frame(left, b"")

        threading.Thread(target=serve).start()
        with right:
            frames = list(runtime.iter_frames(right))
        self.assertEqual(frames, [b"\x01\x02", b"\x03\x04"])

    def test_worker_error_is_reported_before_audio(self):
        left, right = socket.socketpair()

        def serve():
            with left:
                runtime.write_status(left, 1, "model failed")

        threading.Thread(target=serve).start()
        with right:
            with self.assertRaises(RuntimeError) as caught:
                list(runtime.iter_frames(right))
        self.assertIn("model failed", str(caught.exception))


class PrefetchTests(unittest.TestCase):
    def test_next_chunk_starts_while_the_current_one_is_held(self):
        entered_next = threading.Event()
        release_next = threading.Event()

        def source():
            yield "first"
            entered_next.set()
            self.assertTrue(release_next.wait(2))
            yield "second"

        chunks = runtime.prefetch(source(), ahead=1)
        self.assertEqual(next(chunks), "first")
        # The caller has not asked for another chunk, and the next one has
        # already started.
        self.assertTrue(entered_next.wait(1))
        release_next.set()
        self.assertEqual(list(chunks), ["second"])

    def test_cancel_stops_further_chunks(self):
        cancel = threading.Event()
        produced = []

        def source():
            for index in range(5):
                produced.append(index)
                yield index

        chunks = runtime.prefetch(source(), ahead=1, cancel=cancel)
        self.assertEqual(next(chunks), 0)
        cancel.set()
        # Drain whatever was already queued, then the producer must stop.
        rest = list(chunks)
        self.assertLessEqual(len(rest), 1)
        self.assertLess(len(produced), 5)


if __name__ == "__main__":
    unittest.main()
