---
name: google-nest-speaker
description: Discover and control Google Cast speakers on this LAN, including playing local audio, extracting audio from video files, or playing media URLs on the Google Nest Mini named 客廳. Use when the user asks to find the Nest, play/send/cast media, inspect playback, pause, resume, stop, or change its volume.
---

# Google Nest speaker

Use the repository's `./nest-speaker` command. Run it from the repository root.

## Workflow

1. For the first request in a session, or when the named device may have
   changed, run `./nest-speaker list` and identify the requested audio device.
2. For a local audio or video file, resolve it to an absolute path and run
   `./nest-speaker --device '<friendly name>' play '<absolute path>'`.
3. For an HTTP(S) media URL, pass the URL to the same `play` command.
   YouTube and Bilibili video/share URLs are resolved with bundled yt-dlp before
   audio is relayed to Cast. YouTube requires a supported Deno or Node runtime.
4. Keep a local-file play command running until playback finishes. The command
   owns a temporary HTTP server needed by the Nest. If a long playback must run
   beyond the current shell session, use the shell's supported persistent
   process mechanism and retain its logs.
5. Report which device was used and whether playback reached `PLAYING`. If it
   fails, report the command's diagnostic; do not claim that sound was heard.

Use `status`, `pause`, `resume`, `seek`, and `stop` for playback control. Use
`volume 0..100` only when the user explicitly asks to change volume.

## Native app sources and remote

- Paste website links with **Paste & Play**, or use **Add** to queue them.
- For account-required videos, use the app's browser sign-in sheet. Only pass
  CLI `play --browser <name>` after explicit authorization to read that browser's
  session. Never extract personal cookies automatically as a diagnostic.
- Use **Add Folder** for local directories or **Connect SMB Folder** to let
  Finder handle network-share login, then choose the mounted folder.
- **Phone Remote** shows a LAN URL, QR capability link, and pairing code. Keep
  the app open and the Mac awake. Do not publish pairing codes or token URLs in
  Git, screenshots, logs, or public documentation.

## Important constraints

- Do not assume the current IP address. Prefer mDNS discovery by friendly name;
  add `--host <IP-or-hostname>` only when discovery fails or the user supplies
  a known host.
- Cast-native MP3, M4A/AAC, FLAC, Ogg/Opus, and WAV take a zero-transcode path.
  Other media is remuxed when possible, then transcoded with `ffmpeg` to MP3 as
  the compatibility fallback; this also extracts audio from video files. Use
  `--no-transcode` only when the Cast-compatible MIME type is known.
- Never expose the user's source directory. The command serves only a temporary
  directory containing one copied or transcoded file.
- Keep the existing speaker volume unless the user requests a change.
- Ctrl-C during local playback stops the Cast session and cleans up the
  temporary media.

For command flags, run `./nest-speaker --help` or
`./nest-speaker play --help`.
