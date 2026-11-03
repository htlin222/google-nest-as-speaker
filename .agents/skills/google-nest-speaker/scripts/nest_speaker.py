#!/usr/bin/env python3
"""Play local audio or media URLs on a Google Cast speaker."""

from __future__ import annotations

import argparse
import contextlib
import functools
import hashlib
import http.server
import json
import mimetypes
import os
import pyexpat
from pathlib import Path
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from typing import BinaryIO, Iterator
from urllib.parse import quote, urlsplit

import pychromecast
from pychromecast.controllers.media import STREAM_TYPE_BUFFERED
from online_media import OnlineError, OnlineRelay, extract_streams, resolve_in_child, website_name
from remote_control import RemoteController


DEFAULT_DEVICE = os.environ.get("NEST_SPEAKER_DEVICE", "客廳")
ACTIVE_STATES = {"BUFFERING", "PAUSED", "PLAYING"}
URL_SCHEMES = {"http", "https"}
RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")
DIRECT_AUDIO_TYPES = {
    ".flac": "audio/flac",
    ".m4a": "audio/mp4",
    ".mp3": "audio/mpeg",
    ".oga": "audio/ogg",
    ".ogg": "audio/ogg",
    ".opus": "audio/ogg",
    ".wav": "audio/wav",
}
REMUX_AUDIO_TYPES = {
    "aac": (".m4a", "audio/mp4"),
    "mp3": (".mp3", "audio/mpeg"),
}
CACHE_VERSION = "media-v2"
CACHE_LIMIT_BYTES = 2 * 1024 * 1024 * 1024


def runtime_info() -> dict[str, str]:
    return {"pythonVersion": sys.version.split()[0], "opensslVersion": ssl.OPENSSL_VERSION, "expatVersion": pyexpat.EXPAT_VERSION}


class CliError(RuntimeError):
    """An expected, user-actionable command failure."""


class RangeRequestHandler(http.server.SimpleHTTPRequestHandler):
    """Serve files with byte ranges, which Cast receivers use for media."""

    protocol_version = "HTTP/1.1"

    def __init__(
        self,
        *args: object,
        quiet: bool = True,
        allowed_names: set[str] | None = None,
        **kwargs: object,
    ) -> None:
        self.quiet = quiet
        self.allowed_names = allowed_names
        self._byte_range: tuple[int, int] | None = None
        super().__init__(*args, **kwargs)

    def log_message(self, format: str, *args: object) -> None:
        if not self.quiet:
            super().log_message(format, *args)

    def send_head(self) -> BinaryIO | None:
        path = Path(self.translate_path(self.path))
        if self.allowed_names is not None and path.name not in self.allowed_names:
            self.send_error(404, "File not found")
            return None
        if not path.is_file():
            self.send_error(404, "File not found")
            return None

        try:
            source = path.open("rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        size = path.stat().st_size
        content_type = self.guess_type(str(path))
        self._byte_range = None

        try:
            range_header = self.headers.get("Range")
            if range_header:
                self._byte_range = parse_byte_range(range_header, size)
                start, end = self._byte_range
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                content_length = end - start + 1
            else:
                self.send_response(200)
                content_length = size

            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(content_length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Last-Modified", self.date_time_string(path.stat().st_mtime))
            self.end_headers()
            return source
        except ValueError as error:
            source.close()
            self.send_error(416, str(error))
            return None
        except Exception:
            source.close()
            raise

    def copyfile(self, source: BinaryIO, outputfile: BinaryIO) -> None:
        if self._byte_range is None:
            shutil.copyfileobj(source, outputfile)
            return

        start, end = self._byte_range
        source.seek(start)
        remaining = end - start + 1
        while remaining:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)


def parse_byte_range(header: str, size: int) -> tuple[int, int]:
    """Parse one RFC-style byte range and return its inclusive bounds."""
    match = RANGE_RE.fullmatch(header.strip())
    if not match or size <= 0:
        raise ValueError("Unsupported byte range")

    first, last = match.groups()
    if not first and not last:
        raise ValueError("Unsupported byte range")

    if not first:
        suffix_length = int(last)
        if suffix_length <= 0:
            raise ValueError("Unsupported byte range")
        start = max(size - suffix_length, 0)
        end = size - 1
    else:
        start = int(first)
        end = min(int(last), size - 1) if last else size - 1

    if start >= size or start > end:
        raise ValueError("Requested range is outside the file")
    return start, end


def is_media_url(value: str) -> bool:
    return urlsplit(value).scheme.lower() in URL_SCHEMES


def guess_content_type(value: str) -> str:
    path = urlsplit(value).path if is_media_url(value) else value
    content_type, _ = mimetypes.guess_type(path)
    return content_type or "application/octet-stream"


def local_ip_for_peer(host: str, port: int) -> str:
    """Return the source IPv4 address used to reach a Cast device."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect((host, port))
        return str(sock.getsockname()[0])


def native_media_url(value: str, cast_host: str, cast_port: int) -> str:
    """Advertise the native process's opaque endpoint on the Cast-facing NIC."""
    parsed = urlsplit(value)
    if (
        parsed.scheme != "http" or parsed.hostname != "127.0.0.1"
        or parsed.username is not None or parsed.password is not None
        or parsed.port is None or parsed.port < 1
        or parsed.query or parsed.fragment
        or not re.fullmatch(r"/[0-9a-fA-F-]{36}/audio", parsed.path)
    ):
        raise CliError("Invalid native media capability")
    host = local_ip_for_peer(cast_host, cast_port)
    return parsed._replace(netloc=f"{host}:{parsed.port}").geturl()


def run_ffmpeg(command: list[str], cancel_event: threading.Event | None = None) -> bool:
    process = subprocess.Popen(command)
    while process.poll() is None:
        if cancel_event is not None and cancel_event.wait(0.1):
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            return False
        if cancel_event is None:
            process.wait()
    return process.returncode == 0


def transcode_audio(
    source: Path,
    destination: Path,
    cancel_event: threading.Event | None = None,
) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise CliError("ffmpeg is required for local audio; install it or use --no-transcode")

    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
        "-vn",
        "-codec:a",
        "libmp3lame",
        "-q:a",
        "2",
        str(destination),
    ]
    if not run_ffmpeg(command, cancel_event):
        if cancel_event is not None and cancel_event.is_set():
            raise CliError("Transcode cancelled")
        raise CliError(f"ffmpeg could not transcode {source}")


def stage_media(source: Path, destination: Path) -> None:
    """Expose one source file in a temporary directory without copying it."""
    try:
        os.link(source, destination)
    except OSError:
        try:
            destination.symlink_to(source)
        except OSError:
            shutil.copy2(source, destination)


def probe_audio_codec(source: Path) -> str | None:
    ffprobe = shutil.which("ffprobe")
    if ffprobe is None:
        return None
    command = [
        ffprobe,
        "-v",
        "error",
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=codec_name",
        "-of",
        "default=nw=1:nk=1",
        str(source),
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None
    codec = result.stdout.strip().lower()
    return codec or None


def remux_audio(
    source: Path,
    destination: Path,
    cancel_event: threading.Event | None = None,
) -> bool:
    """Copy a compatible audio stream to a Cast-friendly container."""
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        return False
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
        "-map",
        "0:a:0",
        "-vn",
        "-codec:a",
        "copy",
    ]
    if destination.suffix == ".m4a":
        command += ["-movflags", "+faststart"]
    command.append(str(destination))
    succeeded = run_ffmpeg(command, cancel_event)
    if succeeded and destination.is_file():
        return True
    destination.unlink(missing_ok=True)
    return False


def emit(args: argparse.Namespace, event: str, message: str, **fields: object) -> None:
    """Emit either stable JSON-lines output or human-readable text."""
    if args.json:
        print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)
    else:
        print(message, flush=True)


@contextlib.contextmanager
def media_server(
    directory: Path,
    bind: str,
    port: int,
    *,
    verbose: bool,
    allowed_names: set[str] | None = None,
) -> Iterator[http.server.ThreadingHTTPServer]:
    handler = functools.partial(
        RangeRequestHandler,
        directory=str(directory),
        quiet=not verbose,
        allowed_names=allowed_names,
    )
    server = http.server.ThreadingHTTPServer((bind, port), handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, name="media-http", daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


@contextlib.contextmanager
def connected_cast(
    device: str, host: str | None, timeout: float
) -> Iterator[pychromecast.Chromecast]:
    browser = None
    casts: list[pychromecast.Chromecast] = []
    try:
        casts, browser = pychromecast.get_listed_chromecasts(
            friendly_names=[device],
            known_hosts=[host] if host else None,
            timeout=timeout,
            discovery_timeout=timeout,
        )
        if not casts:
            host_hint = f" (known host: {host})" if host else ""
            raise CliError(f"Cast device {device!r} was not found{host_hint}; run 'list'")
        cast = casts[0]
        cast.wait(timeout=timeout)
        yield cast
    finally:
        for cast in casts:
            with contextlib.suppress(Exception):
                cast.disconnect(timeout=5)
        if browser is not None:
            browser.stop_discovery()


def list_devices(args: argparse.Namespace) -> int:
    casts: list[pychromecast.Chromecast] = []
    browser = None
    try:
        casts, browser = pychromecast.get_chromecasts(
            timeout=args.timeout,
            known_hosts=[args.host] if args.host else None,
        )
        if not casts:
            raise CliError("No Cast devices found; check LAN/mDNS access or pass --host")

        devices: list[dict[str, object]] = []
        for cast in sorted(casts, key=lambda item: item.cast_info.friendly_name):
            cast.wait(timeout=args.timeout)
            info = cast.cast_info
            devices.append(
                {
                    "name": info.friendly_name,
                    "model": info.model_name,
                    "host": str(info.host),
                    "port": int(info.port),
                    "type": info.cast_type,
                }
            )
        if args.json:
            print(json.dumps({"devices": devices}, ensure_ascii=False))
        else:
            print("NAME\tMODEL\tHOST\tTYPE")
            for device in devices:
                print(
                    f"{device['name']}\t{device['model']}\t"
                    f"{device['host']}:{device['port']}\t{device['type']}"
                )
        return 0
    finally:
        for cast in casts:
            with contextlib.suppress(Exception):
                cast.disconnect(timeout=5)
        if browser is not None:
            browser.stop_discovery()


def prepare_local_media(
    source: Path, directory: Path, no_transcode: bool, args: argparse.Namespace
) -> tuple[Path, str]:
    if not source.is_file():
        raise CliError(f"Media file does not exist: {source}")
    if no_transcode:
        suffix = source.suffix or ".bin"
        destination = directory / f"media{suffix.lower()}"
        stage_media(source, destination)
        return destination, guess_content_type(str(destination))

    suffix = source.suffix.lower()
    if content_type := DIRECT_AUDIO_TYPES.get(suffix):
        destination = directory / f"media{suffix}"
        stage_media(source, destination)
        emit(args, "ready", f"Using {source.name} without conversion", source=source.name)
        return destination, content_type

    codec = probe_audio_codec(source)
    if codec in REMUX_AUDIO_TYPES:
        output_suffix, content_type = REMUX_AUDIO_TYPES[codec]
        destination = directory / f"media{output_suffix}"
        emit(
            args,
            "remuxing",
            f"Preparing {source.name} without re-encoding…",
            source=source.name,
        )
        if remux_audio(source, destination):
            return destination, content_type

    destination = directory / "media.mp3"
    emit(args, "transcoding", f"Transcoding {source.name} to MP3…", source=source.name)
    transcode_audio(source, destination)
    return destination, "audio/mpeg"


def wait_for_playback(
    cast: pychromecast.Chromecast, timeout: float, args: argparse.Namespace
) -> None:
    controller = cast.media_controller
    deadline = time.monotonic() + timeout
    seen_active = False
    last_state: str | None = None
    last_progress_at = 0.0

    while True:
        state = controller.status.player_state
        if state != last_state:
            display_state = state or "UNKNOWN"
            emit(
                args,
                "state",
                f"Player state: {display_state}",
                state=display_state,
                currentTime=controller.status.current_time,
                duration=controller.status.duration,
            )
            last_state = state
        if state in ACTIVE_STATES:
            seen_active = True
        now = time.monotonic()
        if seen_active and now - last_progress_at >= 1.0:
            emit(
                args,
                "progress",
                "",
                state=state or "UNKNOWN",
                currentTime=controller.status.adjusted_current_time,
                duration=controller.status.duration,
            )
            last_progress_at = now
        if seen_active and state == "IDLE":
            return
        if not seen_active and time.monotonic() >= deadline:
            reason = controller.status.idle_reason or "no receiver response"
            raise CliError(f"Playback did not start within {timeout:g}s: {reason}")
        time.sleep(0.2)


def play_media(args: argparse.Namespace) -> int:
    with connected_cast(args.device, args.host, args.timeout) as cast:
        if args.volume is not None:
            cast.receiver_controller.set_volume(args.volume / 100.0, timeout=args.timeout)

        if website_name(args.source):
            cancel = threading.Event()
            try:
                emit(args, "resolving", f"Loading {website_name(args.source)}…", site=website_name(args.source))
                online = resolve_in_child(args.source, args.browser, cancel)
                with OnlineRelay(online, cache_root(), cancel) as relay:
                    info = cast.cast_info
                    media_url = relay.url("audio", local_ip_for_peer(str(info.host), int(info.port)))
                    cast.media_controller.play_media(
                        media_url, online["audio"]["contentType"],
                        title=args.title or online["title"], stream_type=STREAM_TYPE_BUFFERED,
                    )
                    wait_for_playback(cast, args.start_timeout, args)
                    return 0
            except KeyboardInterrupt:
                cancel.set()
                cast.media_controller.stop()
                return 130

        if is_media_url(args.source):
            content_type = args.content_type or guess_content_type(args.source)
            emit(
                args,
                "casting",
                f"Casting {args.source} to {cast.cast_info.friendly_name}…",
                source=args.source,
                device=cast.cast_info.friendly_name,
            )
            cast.media_controller.play_media(
                args.source,
                content_type,
                title=args.title,
                stream_type=STREAM_TYPE_BUFFERED,
            )
            wait_for_playback(cast, args.start_timeout, args)
            return 0

        source = Path(args.source).expanduser().resolve()
        with tempfile.TemporaryDirectory(prefix="nest-speaker-") as temporary:
            directory = Path(temporary)
            media, content_type = prepare_local_media(
                source, directory, args.no_transcode, args
            )
            with media_server(directory, args.bind, args.port, verbose=args.verbose) as server:
                info = cast.cast_info
                local_ip = local_ip_for_peer(str(info.host), int(info.port))
                actual_port = int(server.server_address[1])
                media_url = f"http://{local_ip}:{actual_port}/{media.name}"
                emit(
                    args,
                    "casting",
                    f"Casting {source.name} to {info.friendly_name} via {media_url}…",
                    source=source.name,
                    device=info.friendly_name,
                    url=media_url,
                )
                cast.media_controller.play_media(
                    media_url,
                    content_type,
                    title=args.title or source.stem,
                    stream_type=STREAM_TYPE_BUFFERED,
                )
                try:
                    wait_for_playback(cast, args.start_timeout, args)
                except KeyboardInterrupt:
                    print("\nStopping playback…", file=sys.stderr)
                    cast.media_controller.stop()
                    return 130
        return 0


def control(args: argparse.Namespace) -> int:
    with connected_cast(args.device, args.host, args.timeout) as cast:
        controller = cast.media_controller
        if args.command in {"pause", "resume", "seek", "stop", "status"}:
            controller.block_until_active(timeout=min(args.timeout, 2.0))
            controller.update_status()
            time.sleep(0.2)
        has_media_session = bool(controller.status.media_session_id)
        if args.command == "pause":
            if not has_media_session:
                raise CliError("No active media session to pause")
            controller.pause()
            emit(args, "paused", f"Paused {cast.cast_info.friendly_name}")
        elif args.command == "resume":
            if not has_media_session:
                raise CliError("No active media session to resume")
            controller.play()
            emit(args, "resumed", f"Resumed {cast.cast_info.friendly_name}")
        elif args.command == "stop":
            if has_media_session:
                controller.stop()
            emit(args, "stopped", f"Stopped {cast.cast_info.friendly_name}")
        elif args.command == "seek":
            if not has_media_session:
                raise CliError("No active media session to seek")
            controller.seek(args.seconds)
            emit(
                args,
                "seeked",
                f"Seeked {cast.cast_info.friendly_name} to {args.seconds:g}s",
                currentTime=args.seconds,
            )
        elif args.command == "volume":
            actual = cast.receiver_controller.set_volume(args.level / 100.0, timeout=args.timeout)
            emit(
                args,
                "volume",
                f"Volume on {cast.cast_info.friendly_name}: {round(actual * 100)}%",
                volume=round(actual * 100),
            )
        elif args.command == "status":
            status = controller.status
            receiver = cast.status
            if args.json:
                print(
                    json.dumps(
                        {
                            "device": cast.cast_info.friendly_name,
                            "player": status.player_state or "IDLE",
                            "title": status.title or None,
                            "currentTime": status.adjusted_current_time,
                            "duration": status.duration,
                            "volume": round(receiver.volume_level * 100),
                            "muted": receiver.volume_muted,
                        },
                        ensure_ascii=False,
                    )
                )
            else:
                print(f"Device: {cast.cast_info.friendly_name}")
                print(f"Player: {status.player_state or 'IDLE'}")
                print(f"Title: {status.title or '-'}")
                print(f"Position: {status.adjusted_current_time:.1f}s")
                print(f"Volume: {round(receiver.volume_level * 100)}%")
                print(f"Muted: {'yes' if receiver.volume_muted else 'no'}")
        return 0


def cache_root() -> Path:
    configured = os.environ.get("NEST_PLAYER_CACHE")
    root = Path(configured).expanduser() if configured else Path.home() / "Library/Caches/NestPlayer/media"
    root.mkdir(parents=True, exist_ok=True)
    return root


def media_cache_key(source: Path) -> str:
    stat = source.stat()
    fingerprint = f"{CACHE_VERSION}\0{source}\0{stat.st_size}\0{stat.st_mtime_ns}"
    return hashlib.sha256(fingerprint.encode()).hexdigest()


def prune_media_cache(root: Path, limit: int = CACHE_LIMIT_BYTES) -> None:
    files = [path for path in root.iterdir() if path.is_file()]
    total = sum(path.stat().st_size for path in files)
    for path in sorted(files, key=lambda item: item.stat().st_atime_ns):
        if total <= limit:
            break
        size = path.stat().st_size
        with contextlib.suppress(OSError):
            path.unlink()
            total -= size


def prepare_cached_media(
    source: Path,
    temporary: Path,
    emit_event: callable,
    cancel_event: threading.Event | None = None,
) -> tuple[Path, str]:
    """Use direct files immediately and cache only conversion work."""
    if not source.is_file():
        raise CliError(f"Media file does not exist: {source}")

    suffix = source.suffix.lower()
    if content_type := DIRECT_AUDIO_TYPES.get(suffix):
        destination = temporary / f"media{suffix}"
        stage_media(source, destination)
        emit_event("ready", source=source.name, cached=False)
        return destination, content_type

    root = cache_root()
    key = media_cache_key(source)
    codec = probe_audio_codec(source)
    if codec in REMUX_AUDIO_TYPES:
        output_suffix, content_type = REMUX_AUDIO_TYPES[codec]
        destination = root / f"{key}{output_suffix}"
        if destination.exists():
            os.utime(destination, None)
            emit_event("ready", source=source.name, cached=True)
            return destination, content_type
        emit_event("remuxing", source=source.name)
        partial = root / f".{key}.partial{output_suffix}"
        partial.unlink(missing_ok=True)
        if remux_audio(source, partial, cancel_event):
            partial.replace(destination)
            prune_media_cache(root)
            return destination, content_type

    destination = root / f"{key}.mp3"
    if destination.exists():
        os.utime(destination, None)
        emit_event("ready", source=source.name, cached=True)
        return destination, "audio/mpeg"
    emit_event("transcoding", source=source.name)
    partial = root / f".{key}.partial.mp3"
    partial.unlink(missing_ok=True)
    try:
        transcode_audio(source, partial, cancel_event)
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)
    prune_media_cache(root)
    return destination, "audio/mpeg"


class NestPlayerService:
    """One long-lived owner for discovery, Cast connection and playback."""

    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.output_lock = threading.Lock()
        self.state_lock = threading.RLock()
        self.cast: pychromecast.Chromecast | None = None
        self.cast_device: str | None = None
        self.browser = None
        self.playback_thread: threading.Thread | None = None
        self.stop_event = threading.Event()
        self.generation = 0
        self.closed = False
        self.resolved_online: dict[tuple[str, str | None], tuple[float, dict]] = {}
        self.remote: RemoteController | None = None

    def emit(self, event: str, **fields: object) -> None:
        with self.output_lock:
            print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)

    def respond(self, request_id: str, *, ok: bool = True, **fields: object) -> None:
        self.emit("response", id=request_id, ok=ok, **fields)

    def disconnect(self) -> None:
        with self.state_lock:
            cast, browser = self.cast, self.browser
            self.cast = None
            self.browser = None
            self.cast_device = None
        if cast is not None:
            with contextlib.suppress(Exception):
                cast.disconnect(timeout=2)
        if browser is not None:
            with contextlib.suppress(Exception):
                browser.stop_discovery()

    def ensure_cast(self, device: str, host: str | None, timeout: float) -> pychromecast.Chromecast:
        with self.state_lock:
            if self.cast is not None and self.cast_device == device:
                return self.cast
        self.disconnect()
        casts, browser = pychromecast.get_listed_chromecasts(
            friendly_names=[device],
            known_hosts=[host] if host else None,
            timeout=timeout,
            discovery_timeout=timeout,
        )
        if not casts:
            if browser is not None:
                browser.stop_discovery()
            raise CliError(f"Cast device {device!r} was not found")
        cast = casts[0]
        cast.wait(timeout=timeout)
        for extra in casts[1:]:
            with contextlib.suppress(Exception):
                extra.disconnect(timeout=2)
        with self.state_lock:
            self.cast = cast
            self.cast_device = device
            self.browser = browser
        return cast

    def discover(self, device: str | None, host: str | None, timeout: float) -> list[dict[str, object]]:
        casts, browser = pychromecast.get_chromecasts(
            timeout=timeout,
            known_hosts=[host] if host else None,
        )
        devices: list[dict[str, object]] = []
        keep: pychromecast.Chromecast | None = None
        try:
            for cast in sorted(casts, key=lambda item: item.cast_info.friendly_name):
                cast.wait(timeout=timeout)
                info = cast.cast_info
                devices.append({
                    "name": info.friendly_name,
                    "model": info.model_name,
                    "host": str(info.host),
                    "port": int(info.port),
                    "type": info.cast_type,
                })
                if device and info.friendly_name == device:
                    keep = cast
            if keep is not None:
                self.disconnect()
                with self.state_lock:
                    self.cast = keep
                    self.cast_device = device
                    self.browser = browser
                browser = None
            return devices
        finally:
            for cast in casts:
                if cast is not keep:
                    with contextlib.suppress(Exception):
                        cast.disconnect(timeout=2)
            if browser is not None:
                browser.stop_discovery()

    def stop_playback(self, generation: int, *, remote: bool = True) -> None:
        with self.state_lock:
            if generation < self.generation:
                return
            self.generation = max(self.generation, generation)
            self.stop_event.set()
            thread = self.playback_thread
            cast = self.cast
        if remote and cast is not None and thread is not None:
            with contextlib.suppress(Exception):
                cast.media_controller.stop()
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=3)
        with self.state_lock:
            if self.playback_thread is thread and (thread is None or not thread.is_alive()):
                self.playback_thread = None

    def start_playback(self, request: dict[str, object]) -> None:
        generation = int(request["generation"])
        with self.state_lock:
            if generation < self.generation:
                return
        self.stop_playback(generation, remote=True)
        stop_event = threading.Event()
        with self.state_lock:
            self.generation = generation
            self.stop_event = stop_event
            thread = threading.Thread(
                target=self.playback_worker,
                args=(request, generation, stop_event),
                name=f"playback-{generation}",
                daemon=True,
            )
            self.playback_thread = thread
            thread.start()

    def playback_worker(
        self,
        request: dict[str, object],
        generation: int,
        stop_event: threading.Event,
    ) -> None:
        def event(name: str, **fields: object) -> None:
            self.emit(name, generation=generation, **fields)

        try:
            device = str(request.get("device") or DEFAULT_DEVICE)
            host = str(request["host"]) if request.get("host") else None
            timeout = float(request.get("timeout", 10))
            cast = self.ensure_cast(device, host, timeout)
            source_value = str(request["source"])
            title = str(request.get("title") or Path(source_value).stem)

            with contextlib.ExitStack() as stack:
                if website_name(source_value):
                    event("resolving", site=website_name(source_value))
                    browser = str(request["browser"]) if request.get("browser") else None
                    cache_key = (source_value, browser)
                    cached = self.resolved_online.get(cache_key)
                    if cached and time.monotonic() - cached[0] < 120:
                        online = cached[1]
                    else:
                        online = resolve_in_child(source_value, browser, stop_event)
                        self.resolved_online[cache_key] = (time.monotonic(), online)
                        while len(self.resolved_online) > 8:
                            self.resolved_online.pop(next(iter(self.resolved_online)))
                    if stop_event.is_set():
                        return
                    relay = stack.enter_context(OnlineRelay(online, cache_root(), stop_event))
                    info = cast.cast_info
                    local_ip = local_ip_for_peer(str(info.host), int(info.port))
                    media_url = relay.url("audio", local_ip)
                    content_type = online["audio"]["contentType"]
                    title = str(online["title"])
                    event(
                        "onlineReady", title=title, duration=online.get("duration"),
                        localAudioURL=relay.url("audio"), localVideoURL=relay.url("video"),
                        site=online.get("site"),
                    )
                elif is_media_url(source_value):
                    media_url = source_value
                    if request.get("nativeMedia") is True:
                        info = cast.cast_info
                        media_url = native_media_url(source_value, str(info.host), int(info.port))
                    content_type = str(request.get("contentType") or guess_content_type(source_value))
                else:
                    temporary = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="nest-player-")))
                    media, content_type = prepare_cached_media(
                        Path(source_value).expanduser().resolve(), temporary, event, stop_event
                    )
                    server = stack.enter_context(
                        media_server(
                            media.parent,
                            "0.0.0.0",
                            0,
                            verbose=False,
                            allowed_names={media.name},
                        )
                    )
                    info = cast.cast_info
                    local_ip = local_ip_for_peer(str(info.host), int(info.port))
                    media_url = f"http://{local_ip}:{server.server_address[1]}/{quote(media.name)}"

                if stop_event.is_set():
                    return
                event("casting", source=source_value, device=device, url=media_url)
                controller = cast.media_controller
                controller.play_media(media_url, content_type, title=title, stream_type=STREAM_TYPE_BUFFERED)
                self.monitor_owned_playback(controller, media_url, generation, stop_event, float(request.get("startTimeout", 30)))
        except OnlineError as error:
            if not stop_event.is_set():
                event(
                    "authenticationRequired" if error.authentication else "failed",
                    message=str(error), site=website_name(str(request.get("source", ""))),
                )
        except Exception as error:
            if not stop_event.is_set():
                event("failed", message=str(error))
        finally:
            with self.state_lock:
                if self.playback_thread is threading.current_thread():
                    self.playback_thread = None

    def monitor_owned_playback(
        self,
        controller: object,
        media_url: str,
        generation: int,
        stop_event: threading.Event,
        start_timeout: float,
    ) -> None:
        deadline = time.monotonic() + start_timeout
        owned_session: int | None = None
        started = False
        last_state: str | None = None
        last_progress = 0.0
        lost_since: float | None = None
        while not stop_event.wait(0.15):
            status = controller.status
            content_id = status.content_id
            session_id = status.media_session_id
            if owned_session is None and content_id == media_url and session_id is not None:
                owned_session = session_id
            owned = owned_session is not None and session_id == owned_session and content_id == media_url
            now = time.monotonic()
            state = status.player_state or "UNKNOWN"

            if owned:
                lost_since = None
                if state != last_state:
                    self.emit(
                        "state", generation=generation, state=state,
                        currentTime=status.current_time, duration=status.duration,
                    )
                    last_state = state
                if state == "PLAYING":
                    started = True
                if started and now - last_progress >= 1:
                    self.emit(
                        "progress", generation=generation, state=state,
                        currentTime=status.adjusted_current_time, duration=status.duration,
                    )
                    last_progress = now
                if state == "IDLE":
                    reason = status.idle_reason or "UNKNOWN"
                    if reason == "FINISHED":
                        self.emit("completed", generation=generation, reason=reason)
                    else:
                        self.emit("failed", generation=generation, message=f"Cast playback ended: {reason}")
                    return
            elif owned_session is not None:
                lost_since = lost_since or now
                if now - lost_since > 5:
                    self.emit("failed", generation=generation, message="Cast session was replaced or disconnected")
                    return

            if not started and now >= deadline:
                reason = status.idle_reason or state
                self.emit("failed", generation=generation, message=f"Playback did not start within {start_timeout:g}s: {reason}")
                with contextlib.suppress(Exception):
                    controller.stop()
                return

    def handle(self, request: dict[str, object]) -> bool:
        request_id = str(request.get("id", ""))
        command = str(request.get("command", ""))
        try:
            if command == "runtimeInfo":
                self.respond(request_id, **runtime_info())
            elif command == "forgetWebsiteSessions":
                self.resolved_online.clear()
                self.respond(request_id)
            elif command == "remoteInfo":
                if self.remote is None:
                    self.remote = RemoteController(self.emit)
                self.respond(request_id, **self.remote.info())
            elif command == "remoteState":
                state = json.loads(str(request.get("state", "{}")))
                if self.remote is not None and isinstance(state, dict):
                    self.remote.update(state)
                self.respond(request_id)
            elif command == "list":
                devices = self.discover(
                    str(request["device"]) if request.get("device") else None,
                    str(request["host"]) if request.get("host") else None,
                    float(request.get("timeout", 10)),
                )
                self.respond(request_id, devices=devices)
            elif command == "play":
                self.start_playback(request)
                self.respond(request_id, generation=int(request["generation"]))
            elif command == "stop":
                self.stop_playback(int(request.get("generation", self.generation + 1)))
                self.respond(request_id)
            elif command in {"pause", "resume", "seek", "volume", "status"}:
                self.handle_control(request_id, command, request)
            elif command == "shutdown":
                self.stop_playback(self.generation + 1)
                self.respond(request_id)
                return False
            else:
                raise CliError(f"Unknown service command: {command}")
        except Exception as error:
            self.respond(request_id, ok=False, error=str(error))
        return True

    def handle_control(self, request_id: str, command: str, request: dict[str, object]) -> None:
        requested_generation = int(request.get("generation", self.generation))
        with self.state_lock:
            if command != "volume" and requested_generation != self.generation:
                raise CliError("Obsolete playback command")
            cast = self.cast
        if cast is None:
            device = str(request.get("device") or DEFAULT_DEVICE)
            cast = self.ensure_cast(device, None, float(request.get("timeout", 10)))
        controller = cast.media_controller
        if command == "pause":
            controller.pause()
        elif command == "resume":
            controller.play()
        elif command == "seek":
            controller.seek(float(request["seconds"]))
        elif command == "volume":
            actual = cast.receiver_controller.set_volume(float(request["level"]) / 100, timeout=5)
            self.respond(request_id, volume=round(actual * 100))
            return
        elif command == "status":
            status = controller.status
            self.respond(
                request_id,
                player=status.player_state or "IDLE",
                currentTime=status.adjusted_current_time,
                duration=status.duration,
                volume=round(cast.status.volume_level * 100),
            )
            return
        self.respond(request_id)

    def run(self) -> int:
        self.remote = RemoteController(self.emit)
        self.emit("serviceReady", pid=os.getpid(), cache=str(cache_root()), **runtime_info())
        try:
            for line in sys.stdin:
                if not line.strip():
                    continue
                try:
                    request = json.loads(line)
                    if not self.handle(request):
                        break
                except json.JSONDecodeError as error:
                    self.emit("protocolError", message=str(error))
        finally:
            self.stop_playback(self.generation + 1)
            self.disconnect()
            if self.remote is not None:
                self.remote.close()
        return 0


def run_service(args: argparse.Namespace) -> int:
    return NestPlayerService(args).run()


def percentage(value: str) -> int:
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer from 0 to 100") from error
    if not 0 <= number <= 100:
        raise argparse.ArgumentTypeError("must be from 0 to 100")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nest-speaker",
        description="Play local audio or URLs on a Google Cast speaker.",
    )
    parser.add_argument("--device", default=DEFAULT_DEVICE, help=f"Cast friendly name (default: {DEFAULT_DEVICE})")
    parser.add_argument("--host", help="Known Cast IP/hostname when mDNS discovery is unavailable")
    parser.add_argument("--timeout", type=float, default=10.0, help="Discovery/connection timeout in seconds")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON or JSON lines")

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list", help="discover Cast devices")
    subparsers.add_parser("service", help="run the persistent JSON-lines app backend")
    resolve = subparsers.add_parser("resolve-online", help="resolve a YouTube or Bilibili video without playing")
    resolve.add_argument("source")
    resolve.add_argument("--browser", choices=sorted({"chrome", "chromium", "edge", "brave", "firefox", "safari"}))

    play = subparsers.add_parser("play", help="play a local audio file or HTTP(S) URL")
    play.add_argument("source", help="audio file path or HTTP(S) media URL")
    play.add_argument("--title", help="display title")
    play.add_argument("--content-type", help="MIME type override, mainly for URLs")
    play.add_argument("--no-transcode", action="store_true", help="serve a local file without ffmpeg conversion")
    play.add_argument("--bind", default="0.0.0.0", help="HTTP bind address for local media")
    play.add_argument("--port", type=int, default=0, help="HTTP port; 0 chooses a free port")
    play.add_argument("--start-timeout", type=float, default=30.0, help="seconds to wait for PLAYING")
    play.add_argument("--volume", type=percentage, help="set volume to 0..100 before playback")
    play.add_argument("--verbose", action="store_true", help="show HTTP request logs")
    play.add_argument("--browser", choices=sorted({"chrome", "chromium", "edge", "brave", "firefox", "safari"}), help="explicitly use this browser's website login session")

    subparsers.add_parser("status", help="show playback and volume state")
    subparsers.add_parser("pause", help="pause current media")
    subparsers.add_parser("resume", help="resume current media")
    subparsers.add_parser("stop", help="stop current media")
    seek = subparsers.add_parser("seek", help="seek current media")
    seek.add_argument("seconds", type=float, help="position in seconds")
    volume = subparsers.add_parser("volume", help="set speaker volume")
    volume.add_argument("level", type=percentage, help="volume from 0 to 100")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "list":
            return list_devices(args)
        if args.command == "service":
            return run_service(args)
        if args.command == "resolve-online":
            try:
                result = {"ok": True, "media": extract_streams(args.source, args.browser)}
            except OnlineError as error:
                result = {"ok": False, "error": str(error), "authentication": error.authentication}
            print(json.dumps(result, ensure_ascii=False), flush=True)
            return 0 if result["ok"] else 1
        if args.command == "play":
            return play_media(args)
        return control(args)
    except (CliError, OnlineError, TimeoutError, socket.gaierror) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
