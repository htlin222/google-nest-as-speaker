#!/usr/bin/env python3
"""Loopback-only screenshot fixture. Uses production remote HTML and fictional data."""
from __future__ import annotations

import argparse
import http.server
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".agents/skills/google-nest-speaker/scripts"))
from remote_control import PAGE

DEMO_TOKEN = "documentation-demo-only"
STATE = {
    "title": "Midnight Coast — Live Session", "speaker": "Studio Nest",
    "detail": "Playing from your library · Mac audio muted", "playing": True,
    "position": 204, "duration": 1240, "volume": 38, "macAudio": False,
    "tracks": [
        {"id": "demo-1", "title": "Midnight Coast — Live Session", "selected": True},
        {"id": "demo-2", "title": "Sunday Focus — YouTube", "selected": False},
        {"id": "demo-3", "title": "設計的日常 — Bilibili", "selected": False},
        {"id": "demo-4", "title": "Field Notes — NAS Collection", "selected": False},
    ],
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, body: bytes, mime: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path in {"/", "/remote", "/pairing"}:
            self.reply(PAGE.encode(), "text/html; charset=utf-8")
        elif path == "/api/state":
            self.reply(json.dumps(STATE, ensure_ascii=False).encode(), "application/json")
        elif path in {"/showcase", "/showcase/"}:
            self.reply((ROOT / "docs/screenshots/showcase.html").read_bytes(), "text/html; charset=utf-8")
        elif path.startswith("/assets/"):
            target = (ROOT / path.removeprefix("/")).resolve()
            if not target.is_relative_to(ROOT / "assets") or not target.is_file():
                self.send_error(404)
                return
            self.reply(target.read_bytes(), "image/png" if target.suffix == ".png" else "image/svg+xml")
        else:
            self.send_error(404)

    def do_POST(self) -> None:
        # Fixture actions never reach Cast, filesystem, cookies, or the real app.
        length = min(int(self.headers.get("Content-Length", "0")), 8192)
        data = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/pair":
            result = {"token": DEMO_TOKEN} if data.get("code") == "000000" else {"error": "Use the fictional code 000000"}
        else:
            result = {"ok": True}
        self.reply(json.dumps(result).encode(), "application/json")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8992)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Documentation preview: http://127.0.0.1:{server.server_address[1]}/showcase", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
