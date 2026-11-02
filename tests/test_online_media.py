from __future__ import annotations

import contextlib
import http.server
import json
import re
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest import mock

import requests

SCRIPTS = Path(__file__).parents[1] / ".agents/skills/google-nest-speaker/scripts"
sys.path.insert(0, str(SCRIPTS))
import online_media
import remote_control


class ExtractionTests(unittest.TestCase):
    def test_only_recognizes_actual_site_domains(self) -> None:
        self.assertEqual(online_media.website_name("https://m.youtube.com/watch?v=abc"), "YouTube")
        self.assertEqual(online_media.website_name("https://b23.tv/abc"), "Bilibili")
        self.assertIsNone(online_media.website_name("https://youtube.com.evil.example/video"))

    def test_cookies_are_only_requested_for_explicit_browser_choice(self) -> None:
        info = {
            "id": "test", "title": "Example", "extractor_key": "Youtube", "duration": 12,
            "formats": [
                {"url": "https://example.com/audio", "vcodec": "none", "acodec": "mp4a", "ext": "m4a", "format_id": "a"},
                {"url": "https://example.com/video", "vcodec": "avc1", "acodec": "none", "ext": "mp4", "height": 720, "format_id": "v"},
            ],
        }
        with mock.patch("yt_dlp.YoutubeDL") as factory:
            ydl = factory.return_value.__enter__.return_value
            ydl.extract_info.return_value = info
            ydl.cookiejar.get_cookie_header.return_value = None
            result = online_media.extract_streams("https://www.youtube.com/watch?v=test")
            self.assertNotIn("cookiesfrombrowser", factory.call_args.args[0])
            self.assertEqual(result["audio"]["contentType"], "audio/mp4")
            self.assertIsNotNone(result["video"])
            online_media.extract_streams("https://www.youtube.com/watch?v=test", "chrome")
            self.assertEqual(factory.call_args.args[0]["cookiesfrombrowser"], ("chrome",))
        with self.assertRaises(online_media.OnlineError):
            online_media.extract_streams("https://youtu.be/test", "arbitrary-profile")

    def test_login_errors_have_a_dedicated_actionable_result(self) -> None:
        with mock.patch("yt_dlp.YoutubeDL") as factory:
            factory.return_value.__enter__.return_value.extract_info.side_effect = RuntimeError("Sign in to confirm your age")
            with self.assertRaises(online_media.OnlineError) as raised:
                online_media.extract_streams("https://youtu.be/test")
            self.assertTrue(raised.exception.authentication)

    def test_cancelled_resolver_terminates_its_process_group(self) -> None:
        cancel = threading.Event()
        cancel.set()
        with mock.patch.object(online_media.subprocess, "Popen") as launch, mock.patch.object(online_media.os, "killpg") as kill:
            process = launch.return_value
            process.pid = 12345
            process.communicate.side_effect = online_media.subprocess.TimeoutExpired("resolver", 0.15)
            with self.assertRaises(online_media.OnlineError):
                online_media.resolve_in_child("https://youtu.be/test", None, cancel)
            self.assertTrue(launch.call_args.kwargs["start_new_session"])
            kill.assert_called_with(12345, online_media.signal.SIGTERM)


class RelayTests(unittest.TestCase):
    def test_forwards_ranges_and_private_headers_and_reuses_completed_cache(self) -> None:
        requests_seen = []

        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                requests_seen.append(dict(self.headers))
                self.send_response(206)
                self.send_header("Content-Length", "4")
                self.send_header("Content-Range", "bytes 2-5/10")
                self.end_headers()
                self.wfile.write(b"2345")

        upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temporary:
                cache = Path(temporary)
                media = {"audio": {
                    "url": f"http://127.0.0.1:{upstream.server_address[1]}/signed-secret",
                    "identity": "test:a", "contentType": "audio/mp4",
                    "headers": {"Cookie": "sensitive-cookie", "Referer": "https://www.bilibili.com/"},
                }}
                with online_media.OnlineRelay(media, cache, threading.Event()) as relay:
                    for _ in range(2):
                        response = requests.get(relay.url("audio"), headers={"Range": "bytes=2-5"}, timeout=3)
                        self.assertEqual(response.status_code, 206)
                        self.assertEqual(response.content, b"2345")
                        self.assertEqual(response.headers["Content-Range"], "bytes 2-5/10")
                    self.assertEqual(requests.get(relay.url("audio").rsplit("/", 2)[0] + "/not-authorized", timeout=3).status_code, 404)
                self.assertEqual(len(requests_seen), 1)
                self.assertEqual(requests_seen[0]["Range"], "bytes=2-5")
                self.assertEqual(requests_seen[0]["Cookie"], "sensitive-cookie")
                metadata = next((cache / "online").glob("*.json")).read_text()
                self.assertNotIn("sensitive-cookie", metadata)
                self.assertNotIn("signed-secret", metadata)
        finally:
            upstream.shutdown()
            upstream.server_close()
            thread.join()


class RemoteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.events = []
        with mock.patch.dict("os.environ", {"NEST_PLAYER_REMOTE_PORT": "0"}):
            self.remote = remote_control.RemoteController(lambda event, **fields: self.events.append((event, fields)))
        self.base = f"http://127.0.0.1:{self.remote.server.server_address[1]}"

    def tearDown(self) -> None:
        self.remote.close()

    def test_pairing_protects_state_and_only_allows_player_actions(self) -> None:
        self.assertEqual(requests.get(self.base + "/api/state", timeout=3).status_code, 401)
        paired = requests.post(self.base + "/api/pair", json={"code": self.remote.code}, timeout=3)
        self.assertEqual(paired.status_code, 200)
        headers = {"Authorization": "Bearer " + paired.json()["token"]}
        self.remote.update({"title": "Song"})
        self.assertEqual(requests.get(self.base + "/api/state", headers=headers, timeout=3).json()["title"], "Song")
        response = requests.post(self.base + "/api/command", headers=headers, json={"action": "toggle", "value": ""}, timeout=3)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.events, [("remoteCommand", {"action": "toggle", "value": ""})])
        forbidden = requests.post(self.base + "/api/command", headers=headers, json={"action": "shell", "value": "anything"}, timeout=3)
        self.assertEqual(forbidden.status_code, 400)

    def test_pairing_rate_limit_and_public_page_never_reveal_token(self) -> None:
        page = requests.get(self.base + "/", timeout=3).text
        self.assertNotIn(self.remote.token, page)
        self.assertNotIn(self.remote.code, page)
        for _ in range(6):
            self.assertEqual(requests.post(self.base + "/api/pair", json={"code": "wrong"}, timeout=3).status_code, 403)
        self.assertEqual(requests.post(self.base + "/api/pair", json={"code": "wrong"}, timeout=3).status_code, 429)

    @unittest.skipUnless(shutil.which("node"), "Node is required for the browser-handler regression")
    def test_transport_handlers_work_with_native_button_command_property(self) -> None:
        handlers = re.findall(r'onclick="([^"]+)"', remote_control.PAGE)
        script = r'''
const fs=require('node:fs'), handlers=JSON.parse(fs.readFileSync(0,'utf8')), seen=[];
for(const body of handlers.filter(h=>!h.startsWith('disconnect'))){
  new Function('command','sendPlayerCommand','document',body)(
    '', action=>seen.push(action), {getElementById:()=>({value:'track'})}
  );
}
if(JSON.stringify(seen)!==JSON.stringify(['previous','toggle','next','stop','playTrack']))process.exit(1);
'''
        subprocess.run([shutil.which("node"), "-e", script], input=json.dumps(handlers), text=True, check=True)


if __name__ == "__main__":
    unittest.main()
