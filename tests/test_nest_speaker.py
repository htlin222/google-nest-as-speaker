from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest import mock


SCRIPT = (
    Path(__file__).parents[1]
    / ".agents"
    / "skills"
    / "google-nest-speaker"
    / "scripts"
    / "nest_speaker.py"
)
SPEC = importlib.util.spec_from_file_location("nest_speaker", SCRIPT)
assert SPEC and SPEC.loader
sys.path.insert(0, str(SCRIPT.parent))
nest_speaker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nest_speaker)


class ByteRangeTests(unittest.TestCase):
    def test_full_and_open_ranges(self) -> None:
        self.assertEqual(nest_speaker.parse_byte_range("bytes=2-5", 10), (2, 5))
        self.assertEqual(nest_speaker.parse_byte_range("bytes=7-", 10), (7, 9))

    def test_suffix_range(self) -> None:
        self.assertEqual(nest_speaker.parse_byte_range("bytes=-4", 10), (6, 9))

    def test_invalid_range(self) -> None:
        with self.assertRaises(ValueError):
            nest_speaker.parse_byte_range("bytes=10-12", 10)
        with self.assertRaises(ValueError):
            nest_speaker.parse_byte_range("items=0-1", 10)


class MediaServerTests(unittest.TestCase):
    def test_server_supports_cast_style_range_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "media.mp3").write_bytes(b"0123456789")
            with nest_speaker.media_server(directory, "127.0.0.1", 0, verbose=False) as server:
                port = server.server_address[1]
                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/media.mp3",
                    headers={"Range": "bytes=3-6"},
                )
                with urllib.request.urlopen(request) as response:
                    self.assertEqual(response.status, 206)
                    self.assertEqual(response.headers["Content-Range"], "bytes 3-6/10")
                    self.assertEqual(response.read(), b"3456")

    def test_server_can_restrict_access_to_active_media(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "active.mp3").write_bytes(b"active")
            (directory / "other.mp3").write_bytes(b"private")
            with nest_speaker.media_server(
                directory,
                "127.0.0.1",
                0,
                verbose=False,
                allowed_names={"active.mp3"},
            ) as server:
                port = server.server_address[1]
                with self.assertRaises(urllib.error.HTTPError) as denied:
                    urllib.request.urlopen(f"http://127.0.0.1:{port}/other.mp3")
                self.assertEqual(denied.exception.code, 404)


class UtilityTests(unittest.TestCase):
    def test_native_media_capability_uses_cast_facing_network_address(self) -> None:
        path = "/00000000-0000-4000-8000-000000000001/audio"
        with mock.patch.object(nest_speaker, "local_ip_for_peer", return_value="192.0.2.10"):
            self.assertEqual(
                nest_speaker.native_media_url("http://127.0.0.1:45678" + path, "192.0.2.20", 8009),
                "http://192.0.2.10:45678" + path,
            )
        for invalid in ["https://127.0.0.1:1234" + path, "http://example.com:1234" + path, "http://127.0.0.1:1234/private", "http://127.0.0.1:1234" + path + "?token=other"]:
            with self.assertRaises(nest_speaker.CliError):
                nest_speaker.native_media_url(invalid, "192.0.2.20", 8009)

    def test_url_detection_and_mime_guessing(self) -> None:
        self.assertTrue(nest_speaker.is_media_url("https://example.com/a.mp3"))
        self.assertFalse(nest_speaker.is_media_url("/tmp/a.mp3"))
        self.assertEqual(nest_speaker.guess_content_type("https://example.com/a.mp3"), "audio/mpeg")

    def test_volume_validation(self) -> None:
        self.assertEqual(nest_speaker.percentage("35"), 35)
        with self.assertRaises(Exception):
            nest_speaker.percentage("101")

    def test_machine_interface_flags_and_seek(self) -> None:
        parser = nest_speaker.build_parser()
        args = parser.parse_args(["--json", "seek", "12.5"])
        self.assertTrue(args.json)
        self.assertEqual(args.command, "seek")
        self.assertEqual(args.seconds, 12.5)

    def test_emit_json_line(self) -> None:
        args = mock.Mock(json=True)
        with mock.patch("builtins.print") as output:
            nest_speaker.emit(args, "state", "ignored", state="PLAYING")
        line = output.call_args.args[0]
        self.assertIn('"event": "state"', line)
        self.assertIn('"state": "PLAYING"', line)

    def test_stop_without_media_session_is_idempotent(self) -> None:
        controller = mock.Mock()
        controller.status.media_session_id = None
        cast = mock.Mock()
        cast.cast_info.friendly_name = "客廳"
        cast.media_controller = controller
        args = mock.Mock(command="stop", timeout=0, json=True)
        with mock.patch.object(nest_speaker, "connected_cast") as connection:
            connection.return_value.__enter__.return_value = cast
            with mock.patch("builtins.print"):
                self.assertEqual(nest_speaker.control(args), 0)
        controller.stop.assert_not_called()


class _FakeStatus:
    def __init__(
        self,
        state: str,
        content_id: str,
        session_id: int | None,
        idle_reason: str | None = None,
    ) -> None:
        self.player_state = state
        self.content_id = content_id
        self.media_session_id = session_id
        self.idle_reason = idle_reason
        self.current_time = 1.0
        self.adjusted_current_time = 1.0
        self.duration = 10.0


class _FakeController:
    def __init__(self, statuses: list[_FakeStatus]) -> None:
        self.statuses = statuses
        self.index = 0
        self.stop_calls = 0

    @property
    def status(self) -> _FakeStatus:
        value = self.statuses[min(self.index, len(self.statuses) - 1)]
        self.index += 1
        return value

    def stop(self) -> None:
        self.stop_calls += 1


class PlaybackOwnershipTests(unittest.TestCase):
    def service(self) -> tuple[object, list[tuple[str, dict[str, object]]]]:
        service = nest_speaker.NestPlayerService(mock.Mock())
        events: list[tuple[str, dict[str, object]]] = []
        service.emit = lambda event, **fields: events.append((event, fields))
        return service, events

    def test_buffering_does_not_disable_start_deadline(self) -> None:
        service, events = self.service()
        controller = _FakeController([_FakeStatus("BUFFERING", "owned", 7)])
        service.monitor_owned_playback(controller, "owned", 3, threading.Event(), 0.01)
        self.assertEqual(events[-1][0], "failed")
        self.assertEqual(controller.stop_calls, 1)

    def test_stale_receiver_session_is_not_accepted(self) -> None:
        service, events = self.service()
        controller = _FakeController([_FakeStatus("PLAYING", "someone-else", 4)])
        service.monitor_owned_playback(controller, "ours", 8, threading.Event(), 0.01)
        self.assertEqual(events[-1][0], "failed")

    def test_only_owned_finished_session_completes(self) -> None:
        service, events = self.service()
        controller = _FakeController([
            _FakeStatus("PLAYING", "owned", 9),
            _FakeStatus("IDLE", "owned", 9, "FINISHED"),
        ])
        service.monitor_owned_playback(controller, "owned", 5, threading.Event(), 1)
        self.assertIn("completed", [event for event, _ in events])

    def test_older_play_request_is_discarded(self) -> None:
        service, _ = self.service()
        service.generation = 10
        service.start_playback({"generation": 9, "source": "/unused", "device": "unused"})
        self.assertIsNone(service.playback_thread)

    def test_fresh_probe_does_not_treat_occupied_or_other_receivers_as_idle(self) -> None:
        for app_id, statuses, expected in [
            ("CC1AD845", [], True),
            ("CC1AD845", [{"playerState": "PLAYING"}], False),
            ("another-app", [], False),
        ]:
            with self.subTest(app_id=app_id, statuses=statuses):
                service, _ = self.service()
                cast = mock.Mock()
                cast.is_idle = False
                cast.app_id = app_id
                cast.status.volume_level = 0.5
                cast.media_controller.status = _FakeStatus("IDLE", "", None)
                cast.media_controller.update_status.side_effect = lambda callback_function: callback_function(True, {"status": statuses})
                service.cast = cast
                service.respond = mock.Mock()
                service.handle_control("probe", "status", {"fresh": True})
                self.assertEqual(service.respond.call_args.kwargs["probeIdle"], expected)
                cast.receiver_controller.set_volume.assert_not_called()
                cast.media_controller.play_media.assert_not_called()

    def test_protocol_trace_excludes_media_urls_and_metadata(self) -> None:
        messages: list[str] = []
        observer = nest_speaker.MediaProtocolTrace(messages.append)
        observer.receive_message(None, {
            "type": "MEDIA_STATUS", "status": [{
                "playerState": "IDLE", "idleReason": "ERROR", "detailedErrorCode": 102,
                "media": {"contentId": "https://private.invalid/token", "metadata": {"title": "private title"}},
            }],
        })
        self.assertIn("detailedErrorCode=102", messages[0])
        self.assertNotIn("private", messages[0])


class CacheTests(unittest.TestCase):
    def test_ffmpeg_process_can_be_cancelled_promptly(self) -> None:
        cancel = threading.Event()
        threading.Timer(0.1, cancel.set).start()
        started = time.monotonic()
        self.assertFalse(nest_speaker.run_ffmpeg(["/bin/sleep", "5"], cancel))
        self.assertLess(time.monotonic() - started, 1.5)

    def test_transcode_result_is_reused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "movie.bin"
            source.write_bytes(b"source")
            staging = root / "staging"
            staging.mkdir()
            cache = root / "cache"
            events: list[str] = []

            def fake_transcode(
                _source: Path,
                destination: Path,
                _cancel_event: object = None,
            ) -> None:
                destination.write_bytes(b"encoded")

            with mock.patch.dict("os.environ", {"NEST_PLAYER_CACHE": str(cache)}), \
                 mock.patch.object(nest_speaker, "probe_audio_codec", return_value=None), \
                 mock.patch.object(nest_speaker, "transcode_audio", side_effect=fake_transcode) as transcode:
                first, _ = nest_speaker.prepare_cached_media(
                    source, staging, lambda event, **_fields: events.append(event)
                )
                second, _ = nest_speaker.prepare_cached_media(
                    source, staging, lambda event, **_fields: events.append(event)
                )
            self.assertEqual(transcode.call_count, 1)
            self.assertEqual(first, second)
            self.assertEqual(second.read_bytes(), b"encoded")


class TranscodeIntegrationTests(unittest.TestCase):
    def test_mp3_uses_zero_transcode_fast_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.mp3"
            staging = root / "staging"
            staging.mkdir()
            source.write_bytes(b"not-decoded-by-this-fast-path")
            args = mock.Mock(json=True)
            with mock.patch.object(nest_speaker, "transcode_audio") as transcode:
                media, content_type = nest_speaker.prepare_local_media(
                    source, staging, False, args
                )
            transcode.assert_not_called()
            self.assertEqual(content_type, "audio/mpeg")
            self.assertEqual(media.read_bytes(), source.read_bytes())

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg is required")
    def test_extracts_audio_track_from_video(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            video = directory / "sample.mp4"
            audio = directory / "sample.mp3"
            subprocess.run(
                [
                    shutil.which("ffmpeg"),
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-f",
                    "lavfi",
                    "-i",
                    "color=c=blue:s=160x90:d=0.25",
                    "-f",
                    "lavfi",
                    "-i",
                    "sine=frequency=440:duration=0.25",
                    "-shortest",
                    "-c:v",
                    "h264",
                    "-c:a",
                    "aac",
                    "-y",
                    str(video),
                ],
                check=True,
            )
            nest_speaker.transcode_audio(video, audio)
            probe = subprocess.run(
                [
                    shutil.which("ffprobe"),
                    "-v",
                    "error",
                    "-select_streams",
                    "a:0",
                    "-show_entries",
                    "stream=codec_type",
                    "-of",
                    "default=nw=1:nk=1",
                    str(audio),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(probe.stdout.strip(), "audio")


if __name__ == "__main__":
    unittest.main()
