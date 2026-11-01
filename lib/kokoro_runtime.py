#!/usr/bin/env python3
"""Resident Kokoro worker and the client that streams PCM from it.

The client reads UTF-8 text on stdin and writes 24 kHz mono s16le PCM on
stdout. A detached worker loads the model once. While a chunk is being
written to the socket (and therefore played), the worker synthesizes the
next chunk into a one-deep queue.
"""

import hashlib
import json
import os
import queue
import re
import socket
import struct
import subprocess
import sys
import threading
import time

MAGIC = b"KOK1"
MAX_TEXT = 1 << 20
MAX_HEADER = 4096
FRAME_HEADER = struct.Struct("<I")
SPEED_MIN = 0.5
SPEED_MAX = 2.0
CONNECT_WAIT_S = 90.0
IDLE_DEFAULT_S = 900


def runtime_dir():
    explicit = os.environ.get("KOKORO_RUNTIME_DIR", "")
    if explicit:
        return explicit
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if runtime:
        return os.path.join(runtime, "omarchy-tts", "kokoro")
    state = os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
    return os.path.join(state, "omarchy-tts", "kokoro")


def socket_path():
    return os.path.join(runtime_dir(), "worker.sock")


def send_all(conn, blob):
    view = memoryview(blob)
    while view:
        sent = conn.send(view)
        if sent <= 0:
            raise ConnectionError("socket closed")
        view = view[sent:]


def read_exact(conn, size):
    chunks = []
    remaining = size
    while remaining:
        part = conn.recv(remaining)
        if not part:
            raise ConnectionError("socket closed")
        chunks.append(part)
        remaining -= len(part)
    return b"".join(chunks)


def write_request(conn, voice, speed, text):
    raw = text.encode("utf-8")
    if len(raw) > MAX_TEXT:
        raise ValueError("text exceeds 1 MiB")
    header = json.dumps(
        {"voice": voice, "speed": speed, "n": len(raw)},
        separators=(",", ":"),
    ).encode("utf-8")
    if len(header) > MAX_HEADER:
        raise ValueError("request header is too large")
    send_all(conn, MAGIC + FRAME_HEADER.pack(len(header)) + header + raw)


def read_request(conn):
    magic = read_exact(conn, 4)
    if magic != MAGIC:
        raise ValueError("unexpected kokoro worker protocol")
    (hlen,) = FRAME_HEADER.unpack(read_exact(conn, 4))
    if hlen < 2 or hlen > MAX_HEADER:
        raise ValueError("request header has an invalid length")
    header = json.loads(read_exact(conn, hlen).decode("utf-8"))
    voice = header.get("voice", "")
    speed = header.get("speed", 1.0)
    nbytes = header.get("n", -1)
    if not isinstance(voice, str) or not isinstance(nbytes, int):
        raise ValueError("request header is malformed")
    if not isinstance(speed, (int, float)) or isinstance(speed, bool):
        raise ValueError("request speed is malformed")
    if nbytes < 0 or nbytes > MAX_TEXT:
        raise ValueError("request text length is invalid")
    text = read_exact(conn, nbytes).decode("utf-8")
    return voice, float(speed), text


def write_status(conn, code, message=""):
    send_all(conn, FRAME_HEADER.pack(code & 0xFFFFFFFF))
    if code:
        raw = message.encode("utf-8")[:1024]
        send_all(conn, FRAME_HEADER.pack(len(raw)) + raw)


def write_frame(conn, pcm):
    send_all(conn, FRAME_HEADER.pack(len(pcm)) + pcm)


def iter_frames(conn):
    (code,) = FRAME_HEADER.unpack(read_exact(conn, 4))
    if code:
        (mlen,) = FRAME_HEADER.unpack(read_exact(conn, 4))
        if mlen > 1024:
            raise ValueError("worker error is too large")
        detail = read_exact(conn, mlen).decode("utf-8", "replace")
        raise RuntimeError(detail or "kokoro worker failed")
    while True:
        (flen,) = FRAME_HEADER.unpack(read_exact(conn, 4))
        if flen == 0:
            return
        if flen > 8 << 20:
            raise ValueError("audio frame is too large")
        yield read_exact(conn, flen)


def prefetch(source, ahead=1, cancel=None):
    """Yield items from source while the next ones are produced.

    ahead=1 keeps a single finished chunk queued, which is enough to overlap
    the next synthesis with playback of the current chunk. The producer stops
    once cancel is set, including when it is blocked on a full queue.
    """
    if ahead < 1:
        raise ValueError("ahead must be at least 1")
    pending = queue.Queue(maxsize=ahead)
    failure = []

    def produce():
        try:
            for item in source:
                if cancel is not None and cancel.is_set():
                    return
                while True:
                    if cancel is not None and cancel.is_set():
                        return
                    try:
                        pending.put(item, timeout=0.2)
                        break
                    except queue.Full:
                        continue
        except Exception as exc:  # surfaced by the consumer
            failure.append(exc)
        finally:
            # Always unblock the consumer. On cancel, drop a queued chunk so
            # the sentinel can land while the consumer is no longer reading.
            while True:
                try:
                    pending.put(None, timeout=0.2)
                    return
                except queue.Full:
                    if cancel is not None and cancel.is_set():
                        try:
                            pending.get_nowait()
                        except queue.Empty:
                            pass
                    continue

    threading.Thread(target=produce, name="kokoro-prefetch", daemon=True).start()

    def consume():
        while True:
            item = pending.get()
            if item is None:
                if failure:
                    raise failure[0]
                return
            yield item

    return consume()


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _expected_digest(manifest, relative):
    try:
        with open(manifest, encoding="utf-8") as handle:
            files = json.load(handle)["kokoro"]["files"]
        want = files[relative]["sha256"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"{relative} is not a verified model file") from exc
    if not isinstance(want, str) or len(want) != 64:
        raise RuntimeError(f"{relative} is not a verified model file")
    return want


def verify_file(models, manifest, relative):
    path = os.path.join(models, relative)
    if os.path.islink(path) or not os.path.isfile(path):
        raise RuntimeError(f"{relative} is missing; reinstall Kokoro from the Provider tab")
    want = _expected_digest(manifest, relative)
    if _sha256(path) != want:
        raise RuntimeError(
            f"{relative} failed verification; reinstall Kokoro from the Provider tab"
        )
    return path


def _reject_unsafe_dir(path):
    if os.path.islink(path):
        raise RuntimeError(f"refusing symlink runtime directory: {path}")
    stat = os.stat(path)
    if stat.st_uid != os.getuid():
        raise RuntimeError(f"runtime directory is not owned by this user: {path}")
    if stat.st_mode & 0o022:
        os.chmod(path, 0o700)


def ensure_runtime_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    _reject_unsafe_dir(path)
    parent = os.path.dirname(path)
    if os.path.islink(parent):
        raise RuntimeError(f"refusing symlink runtime directory: {parent}")


def _peer_uid(conn):
    creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    _pid, uid, _gid = struct.unpack("3i", creds)
    return uid


def _pcm_chunks(pipe, text, pack, speed, cancel):
    import numpy as np

    def generate():
        for _graphemes, _phonemes, audio in pipe(text, voice=pack, speed=speed):
            if cancel.is_set():
                return
            if hasattr(audio, "detach"):
                audio = audio.detach().cpu().numpy()
            samples = np.clip(np.asarray(audio, dtype="float32"), -1.0, 1.0)
            yield (samples * 32767.0).astype("<i2").tobytes()

    yield from prefetch(generate(), ahead=1, cancel=cancel)


def write_stamp(models, relatives):
    """Record the files this process verified, so later utterances can skip a rehash.

    The stamp stores path, mtime, and size. A replaced file fails the
    comparison and the shell verifies it again before starting Python.
    """
    lines = ["models " + os.path.abspath(models)]
    for relative in relatives:
        path = os.path.join(models, relative)
        stat = os.stat(path)
        lines.append(f"file {relative} {stat.st_mtime_ns} {stat.st_size}")
    target = os.path.join(runtime_dir(), "verified.stamp")
    temporary = target + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)


def _load_engine(models, manifest):
    import warnings

    warnings.filterwarnings("ignore")
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    import torch
    from kokoro import KModel, KPipeline

    verify_file(models, manifest, "config.json")
    verify_file(models, manifest, "kokoro-v1_0.pth")
    model = KModel(
        repo_id="hexgrad/Kokoro-82M",
        config=os.path.join(models, "config.json"),
        model=os.path.join(models, "kokoro-v1_0.pth"),
    ).eval()
    pipelines = {}
    packs = {}

    def voice_pack(voice):
        if not isinstance(voice, str) or re.fullmatch(r"[a-z]{2}_[a-z]+", voice) is None:
            raise RuntimeError("invalid voice name")
        lang = voice[0]
        if voice not in packs:
            relative = "voices/" + voice + ".pt"
            path = verify_file(models, manifest, relative)
            write_stamp(models, ["config.json", "kokoro-v1_0.pth", relative])
            packs[voice] = torch.load(path, weights_only=True)
        if lang not in pipelines:
            pipelines[lang] = KPipeline(
                lang_code=lang,
                repo_id="hexgrad/Kokoro-82M",
                model=model,
            )
        return pipelines[lang], packs[voice]

    return voice_pack


def serve(models, manifest, sock_path, idle_s):
    voice_pack = _load_engine(models, manifest)
    if os.path.lexists(sock_path):
        os.unlink(sock_path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    os.chmod(sock_path, 0o600)
    server.listen(4)
    server.settimeout(idle_s)
    try:
        while True:
            try:
                conn, _addr = server.accept()
            except socket.timeout:
                return
            with conn:
                accepted = False
                cancel = None
                try:
                    if _peer_uid(conn) != os.getuid():
                        continue
                    voice, speed, text = read_request(conn)
                    if not (SPEED_MIN <= speed <= SPEED_MAX):
                        write_status(conn, 65, "speed is outside the kokoro range")
                        continue
                    pipe, pack = voice_pack(voice)
                    cancel = threading.Event()
                    write_status(conn, 0)
                    accepted = True
                    try:
                        for pcm in _pcm_chunks(pipe, text, pack, speed, cancel):
                            write_frame(conn, pcm)
                        write_frame(conn, b"")
                    except (ConnectionError, BrokenPipeError, OSError):
                        # Playback stopped. Drop the rest of this utterance.
                        cancel.set()
                except (ConnectionError, BrokenPipeError, OSError):
                    continue
                except Exception as exc:
                    # Once status 0 is written, a later failure must not emit a
                    # second status word. Closing is the error signal then.
                    if not accepted:
                        try:
                            write_status(conn, 1, str(exc))
                        except OSError:
                            pass
                    elif cancel is not None:
                        cancel.set()
    finally:
        server.close()
        if os.path.lexists(sock_path):
            try:
                os.unlink(sock_path)
            except OSError:
                pass


def _connect(path, timeout):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    try:
        conn.connect(path)
    except OSError:
        conn.close()
        raise
    return conn


def _worker_alive(proc):
    return proc is not None and proc.poll() is None


def _spawn_worker(path):
    log_path = os.path.join(runtime_dir(), "worker.log")
    log = open(log_path, "ab", buffering=0)
    proc = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "--worker"],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env=os.environ.copy(),
        cwd=runtime_dir(),
    )
    return proc


def open_worker():
    """Connect to the resident worker, starting it when the socket is down."""
    import fcntl

    path = socket_path()
    ensure_runtime_dir(runtime_dir())
    try:
        return _connect(path, 2.0)
    except OSError:
        pass
    lock_path = os.path.join(runtime_dir(), "worker.lock")
    if os.path.islink(lock_path):
        raise RuntimeError("refusing to lock through a symlink")
    lock = open(lock_path, "a")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            return _connect(path, 2.0)
        except OSError:
            pass
        if os.path.lexists(path):
            if os.path.islink(path):
                raise RuntimeError("refusing kokoro socket symlink")
            os.unlink(path)
        proc = _spawn_worker(path)
        deadline = time.monotonic() + CONNECT_WAIT_S
        while time.monotonic() < deadline:
            if not _worker_alive(proc):
                raise RuntimeError("kokoro worker exited during startup")
            try:
                return _connect(path, 0.2)
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("kokoro worker did not become ready")
    finally:
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        lock.close()


def stream_stdin():
    voice = os.environ.get("KOKORO_VOICE", "af_heart")
    speed = float(os.environ.get("KOKORO_SPEED", "1.0"))
    text = sys.stdin.read()
    if not text.strip():
        return 0
    conn = open_worker()
    try:
        conn.settimeout(None)
        write_request(conn, voice, speed, text)
        for frame in iter_frames(conn):
            sys.stdout.buffer.write(frame)
            sys.stdout.buffer.flush()
    finally:
        conn.close()
    return 0


def main(argv):
    if "--worker" in argv:
        models = os.environ["KOKORO_MODELS"]
        manifest = os.path.join(os.environ["TTS_PLUGIN_DIR"], "lib", "engines", "models.json")
        idle = float(os.environ.get("KOKORO_IDLE_SECONDS", str(IDLE_DEFAULT_S)))
        ensure_runtime_dir(runtime_dir())
        serve(models, manifest, socket_path(), idle)
        return 0
    return stream_stdin()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except OSError:
            pass
        sys.exit(0)
    except Exception as exc:
        print(f"speak: kokoro: {exc}", file=sys.stderr)
        sys.exit(1)
