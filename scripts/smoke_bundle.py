#!/usr/bin/env python3
"""Check packaged IPC/phone control and site extraction; never sends Cast audio."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import time
from urllib.parse import urlsplit, parse_qs

import requests


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("helper", type=Path)
    parser.add_argument("--online", action="store_true")
    args = parser.parse_args()
    helper = args.helper.resolve()
    started = time.monotonic()
    process = subprocess.Popen([str(helper), "--json", "service"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        ready = json.loads(process.stdout.readline())
        assert ready["event"] == "serviceReady"
        cold_start = round(time.monotonic() - started, 3)

        def request(command: str, **fields) -> dict:
            process.stdin.write(json.dumps({"id": command, "command": command, **fields}) + "\n")
            process.stdin.flush()
            while True:
                message = json.loads(process.stdout.readline())
                if message.get("id") == command:
                    assert message.get("ok"), message
                    return message

        info = request("remoteInfo")
        parsed = urlsplit(info["remoteURL"])
        base = f"http://127.0.0.1:{parsed.port}"
        token = parse_qs(parsed.query)["token"][0]
        headers = {"Authorization": "Bearer " + token}
        request("remoteState", state=json.dumps({"title": "Packaged IPC smoke test"}))
        assert requests.get(base + "/api/state", timeout=3).status_code == 401
        assert requests.get(base + "/api/state", headers=headers, timeout=3).json()["title"] == "Packaged IPC smoke test"
        response = requests.post(base + "/api/command", headers=headers, json={"action": "toggle", "value": ""}, timeout=3)
        assert response.status_code == 200
        event = json.loads(process.stdout.readline())
        assert event["event"] == "remoteCommand" and event["action"] == "toggle"
        request("shutdown")
        process.wait(timeout=5)
        assert process.returncode == 0
        print(json.dumps({"packagedService": "passed", "phoneIPC": "passed", "coldStartSeconds": cold_start}))
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()

    if args.online:
        for url in (
            "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            "https://www.bilibili.com/video/BV1bK411W797?p=1",
        ):
            result = subprocess.run([str(helper), "--json", "resolve-online", url], capture_output=True, text=True, timeout=65)
            payload = json.loads(result.stdout)
            assert payload.get("ok"), payload.get("error")
            media = payload["media"]
            print(json.dumps({"packagedSite": media["site"], "title": media["title"], "audio": bool(media.get("audio")), "video": bool(media.get("video"))}, ensure_ascii=False))


if __name__ == "__main__":
    main()
