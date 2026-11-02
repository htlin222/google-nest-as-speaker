"""Website extraction and a bounded-memory, range-capable media relay.

yt-dlp runs only in a disposable resolver process. Credentials and signed CDN
URLs travel through the private IPC pipe and are never written to disk.
"""
from __future__ import annotations

import contextlib
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

import requests


BROWSERS = {"chrome", "chromium", "edge", "brave", "firefox", "safari"}
SITE_DOMAINS = {"youtube.com", "youtu.be", "bilibili.com", "b23.tv", "bili2233.cn"}
ONLINE_CACHE_LIMIT = 512 * 1024 * 1024


class OnlineError(RuntimeError):
    def __init__(self, message: str, *, authentication: bool = False) -> None:
        super().__init__(message)
        self.authentication = authentication


def website_name(source: str) -> str | None:
    host = (urlsplit(source).hostname or "").lower()
    if any(host == domain or host.endswith("." + domain) for domain in SITE_DOMAINS):
        return "YouTube" if host == "youtu.be" or host.endswith(".youtu.be") or host.endswith("youtube.com") else "Bilibili"
    return None


def _is_auth_error(message: str) -> bool:
    value = message.lower()
    return any(word in value for word in (
        "sign in", "sign-in", "log in", "login", "cookies", "cookie database",
        "members-only", "premium", "age-restricted", "confirm your age", "登录", "登陆", "大会员",
    ))


def extract_streams(source: str, browser: str | None = None) -> dict[str, object]:
    """Run inside the child only; public videos never request browser cookies."""
    if not website_name(source):
        raise OnlineError("Paste a YouTube or Bilibili video link.")
    if browser and browser not in BROWSERS:
        raise OnlineError("Choose a supported browser session.")
    import yt_dlp

    class Logger:
        def debug(self, message: str) -> None:
            pass

        info = debug

        def warning(self, message: str) -> None:
            # Avoid printing private stream URLs or cookies into app diagnostics.
            pass

        error = warning

    runtimes = {name: {"path": path} for name in ("deno", "node") if (path := shutil.which(name))}
    options = {
        "quiet": True,
        "no_warnings": True,
        "logger": Logger(),
        "noplaylist": True,
        "socket_timeout": 12,
        "retries": 1,
        "extractor_retries": 1,
        "skip_download": True,
        "format": "bestaudio/best",
        "js_runtimes": runtimes,
        "remote_components": [],
        "cachedir": False,
    }
    if browser:
        # Explicit user consent is represented by this allowlisted browser value.
        # https://github.com/yt-dlp/yt-dlp#embedding-yt-dlp
        options["cookiesfrombrowser"] = (browser,)
    try:
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(source, download=False)
            if not info or info.get("_type") in {"playlist", "multi_video"}:
                raise OnlineError("Paste a single video link rather than a channel or playlist.")
            if info.get("is_live") or info.get("live_status") == "is_upcoming":
                raise OnlineError("Live streams are not supported yet. Choose a recorded video.")
            formats = info.get("formats") or [info]

            def direct(fmt: dict) -> bool:
                return urlsplit(fmt.get("url", "")).scheme in {"http", "https"} and fmt.get("protocol", "https") in {"http", "https"}

            audio_formats = [fmt for fmt in formats if direct(fmt)
                             and fmt.get("vcodec") == "none" and fmt.get("acodec") != "none"]
            if not audio_formats:
                raise OnlineError("This video has no directly playable audio stream. Try another video or update yt-dlp.")
            audio = max(audio_formats, key=lambda fmt: (
                fmt.get("ext") == "m4a", fmt.get("abr") or fmt.get("tbr") or 0,
            ))
            video_formats = [fmt for fmt in formats if direct(fmt)
                             and str(fmt.get("vcodec", "")).startswith(("avc", "h264"))
                             and fmt.get("acodec") == "none"
                             and 0 < (fmt.get("height") or 0) <= 720]
            video = max(video_formats, key=lambda fmt: (fmt.get("height") or 0, fmt.get("tbr") or 0), default=None)

            def resource(fmt: dict, kind: str) -> dict[str, object]:
                headers = dict(info.get("http_headers") or {})
                headers.update(fmt.get("http_headers") or {})
                cookie_header = ydl.cookiejar.get_cookie_header(fmt["url"])
                if cookie_header:
                    headers["Cookie"] = cookie_header
                ext = fmt.get("ext")
                content_type = "video/mp4" if kind == "video" else {
                    "m4a": "audio/mp4", "webm": "audio/webm", "mp3": "audio/mpeg",
                    "ogg": "audio/ogg", "opus": "audio/ogg",
                }.get(ext, "audio/mp4")
                return {
                    "url": fmt["url"], "headers": headers, "contentType": content_type,
                    "identity": f"{info.get('extractor_key')}:{info.get('id')}:{fmt.get('format_id')}:{kind}",
                }

            return {
                "title": info.get("title") or website_name(source),
                "duration": info.get("duration"),
                "site": website_name(source),
                "audio": resource(audio, "audio"),
                "video": resource(video, "video") if video else None,
            }
    except OnlineError:
        raise
    except Exception as error:
        message = str(error)
        if _is_auth_error(message):
            raise OnlineError(
                "This video needs a browser login, age verification, or account access. "
                "Sign in on the website, then explicitly use that browser session. "
                "If a cookie/keychain permission prompt appears, allow access for this operation.",
                authentication=True,
            ) from error
        if "JavaScript" in message or "runtime" in message:
            raise OnlineError("YouTube needs a JavaScript runtime. Install Deno with: brew install deno") from error
        raise OnlineError(f"Could not load this {website_name(source)} video: {message[:400]}") from error


def resolve_in_child(source: str, browser: str | None, cancel: threading.Event) -> dict:
    command = [sys.executable]
    if not getattr(sys, "frozen", False):
        command.append(str(Path(__file__).with_name("nest_speaker.py")))
    command += ["--json", "resolve-online", source]
    if browser:
        command += ["--browser", browser]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    deadline = time.monotonic() + 60
    try:
        while True:
            try:
                output, _diagnostics = process.communicate(timeout=0.15)
                break
            except subprocess.TimeoutExpired:
                if cancel.is_set():
                    raise OnlineError("Website loading cancelled.")
                if time.monotonic() >= deadline:
                    raise OnlineError("The website did not respond within 60 seconds. Please retry.")
        if cancel.is_set():
            raise OnlineError("Website loading cancelled.")
        try:
            result = json.loads(output)
        except (ValueError, TypeError):
            raise OnlineError("The website resolver could not start. Rebuild or reinstall Nest Player.")
        if not result.get("ok"):
            raise OnlineError(result.get("error") or "Could not load the video.", authentication=bool(result.get("authentication")))
        return result["media"]
    finally:
        # The new process group owns yt-dlp and its JS runtime. Stop kills both.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=0.7)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()


class OnlineRelay:
    """Relay signed CDN streams with headers; cache completed range responses."""

    def __init__(self, media: dict, cache: Path, cancel: threading.Event) -> None:
        self.media = media
        self.cache = cache / "online"
        self.cache.mkdir(parents=True, exist_ok=True)
        self.cancel = cancel
        self.prefix = "/" + secrets.token_urlsafe(24) + "/"
        self.resources = {self.prefix + name: media[name] for name in ("audio", "video") if media.get(name)}
        relay = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args: object) -> None:
                pass

            def do_HEAD(self) -> None:
                relay.respond(self, head=True)

            def do_GET(self) -> None:
                relay.respond(self, head=False)

        self.server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, name="online-relay", daemon=True)

    def __enter__(self) -> OnlineRelay:
        self.thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=1)

    def url(self, kind: str, host: str = "127.0.0.1") -> str | None:
        if not self.media.get(kind):
            return None
        return f"http://{host}:{self.server.server_address[1]}{self.prefix}{kind}"

    def respond(self, handler: http.server.BaseHTTPRequestHandler, *, head: bool) -> None:
        resource = self.resources.get(handler.path)
        if not resource or self.cancel.is_set():
            handler.send_error(404)
            return
        range_header = handler.headers.get("Range", "")
        key = hashlib.sha256(f"{resource['identity']}\0{range_header}".encode()).hexdigest()
        body_path = self.cache / f"{key}.body"
        metadata_path = self.cache / f"{key}.json"
        try:
            if body_path.is_file() and metadata_path.is_file():
                metadata = json.loads(metadata_path.read_text())
                with body_path.open("rb") as body:
                    os.utime(body_path, None)
                    handler.send_response(metadata["status"])
                    for name, value in metadata["headers"].items():
                        handler.send_header(name, value)
                    handler.end_headers()
                    if not head:
                        while not self.cancel.is_set() and (chunk := body.read(64 * 1024)):
                            handler.wfile.write(chunk)
                return
        except (OSError, ValueError, KeyError):
            pass

        request_headers = dict(resource.get("headers") or {})
        request_headers["Accept-Encoding"] = "identity"
        if range_header:
            request_headers["Range"] = range_header
        partial = self.cache / f".{key}.{secrets.token_hex(6)}.partial"
        headers_sent = False
        try:
            with requests.get(resource["url"], headers=request_headers, stream=True, timeout=(8, 15)) as response:
                headers = {name: response.headers[name] for name in (
                    "Content-Length", "Content-Range", "Accept-Ranges",
                ) if name in response.headers}
                headers["Content-Type"] = resource["contentType"]
                if "Content-Length" not in headers:
                    headers["Connection"] = "close"
                    handler.close_connection = True
                handler.send_response(response.status_code)
                for name, value in headers.items():
                    handler.send_header(name, value)
                handler.end_headers()
                headers_sent = True
                if head:
                    return
                written = 0
                cacheable = response.status_code in {200, 206}
                with partial.open("wb") as cache_body:
                    for chunk in response.iter_content(64 * 1024):
                        if self.cancel.is_set():
                            return
                        handler.wfile.write(chunk)
                        written += len(chunk)
                        if cacheable and written <= ONLINE_CACHE_LIMIT:
                            cache_body.write(chunk)
                        else:
                            cacheable = False
                if cacheable and written and ("Content-Length" not in headers or written == int(headers["Content-Length"])):
                    headers.pop("Connection", None)
                    headers["Content-Length"] = str(written)
                    partial.replace(body_path)
                    # Only response shape is persisted, never CDN URLs or headers with cookies.
                    metadata_path.write_text(json.dumps({"status": response.status_code, "headers": headers}))
                    self.prune()
        except (OSError, requests.RequestException, ValueError):
            if not headers_sent:
                with contextlib.suppress(OSError):
                    handler.send_error(502, "Media stream unavailable; stop and retry to refresh the website link")
            handler.close_connection = True
        finally:
            partial.unlink(missing_ok=True)

    def prune(self) -> None:
        bodies = list(self.cache.glob("*.body"))
        try:
            total = sum(path.stat().st_size for path in bodies)
            for path in sorted(bodies, key=lambda item: item.stat().st_atime_ns):
                if total <= ONLINE_CACHE_LIMIT:
                    break
                size = path.stat().st_size
                path.unlink(missing_ok=True)
                path.with_suffix(".json").unlink(missing_ok=True)
                total -= size
        except OSError:
            pass
