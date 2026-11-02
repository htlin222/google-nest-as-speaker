# Google Nest speaker repo

## Purpose

This repository turns a Google Cast audio device on the local network into a
speaker for audio files on this computer.

## Commands

- Discover devices: `./nest-speaker list`
- Play a local file: `./nest-speaker play /absolute/path/to/audio`
- Run the macOS player: `./run-player`
- Run tests: `swift test && uv run python -m unittest discover -s tests -v`
- Build the app bundle: `./scripts/build_app.sh`
- Validate the repo skill with the installed `skill-creator` validator against
  `.agents/skills/google-nest-speaker`.

## Conventions and boundaries

- Use the `$google-nest-speaker` repo skill for Cast playback requests.
- Keep PyChromecast pinned in `pyproject.toml` and refresh `uv.lock` after a
  deliberate dependency update.
- Keep the HTTP server alive for the whole playback of local files. A Cast
  device fetches the URL from this computer; it does not receive file bytes
  through the Cast control socket.
- Bind the temporary media server to the LAN, but serve only a temporary
  directory containing the requested media file.
- Do not change speaker volume unless the user asks.
- Do not commit audio files, generated transcodes, credentials, or device IPs.
- The Mac player displays video locally and casts its audio. Local Mac audio is
  muted by default and must only be enabled through the explicit UI toggle.
