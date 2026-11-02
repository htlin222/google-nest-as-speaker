#!/usr/bin/env python3
"""Resolve public test videos and fetch stream bytes without playing any sound."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import tempfile
import threading

import requests

sys.path.insert(0, str(Path(__file__).parents[1] / ".agents/skills/google-nest-speaker/scripts"))
from online_media import OnlineRelay, resolve_in_child


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("urls", nargs="*", default=[
        "https://www.youtube.com/watch?v=jNQXAC9IVRw",
        "https://www.bilibili.com/video/BV1bK411W797?p=1",
    ])
    args = parser.parse_args()
    for source in args.urls:
        cancel = threading.Event()
        media = resolve_in_child(source, None, cancel)
        statuses = {}
        with tempfile.TemporaryDirectory(prefix="nest-online-smoke-") as temporary:
            with OnlineRelay(media, Path(temporary), cancel) as relay:
                for kind in ("audio", "video"):
                    url = relay.url(kind)
                    if url is None:
                        continue
                    with requests.get(url, headers={"Range": "bytes=0-4095"}, stream=True, timeout=25) as response:
                        response.raise_for_status()
                        first = next(response.iter_content(4096), b"")
                        assert first, f"Empty {kind} stream"
                        statuses[kind] = {"status": response.status_code, "bytes": len(first), "contentType": response.headers.get("Content-Type")}
        print(json.dumps({"site": media["site"], "title": media["title"], "streams": statuses}, ensure_ascii=False))


if __name__ == "__main__":
    main()
