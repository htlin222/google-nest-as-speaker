<p align="center"><strong>English</strong> · <a href="README.zh-TW.md">繁體中文（台灣）</a></p>

<p align="center">
  <img src="assets/nest-player.png" width="144" height="144" alt="Nest Player logo: a white play symbol and turquoise wireless audio waves on an indigo tile">
</p>

# Nest Player — Google Nest & Chromecast Audio Player for macOS

[![Latest release](https://img.shields.io/github/v/release/htlin222/google-nest-as-speaker)](https://github.com/htlin222/google-nest-as-speaker/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-14%2B-111827?logo=apple)](https://github.com/htlin222/google-nest-as-speaker/releases/latest)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-6366f1)](https://github.com/htlin222/google-nest-as-speaker/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/htlin222/google-nest-as-speaker)](https://github.com/htlin222/google-nest-as-speaker/stargazers)

**Play local music, podcasts, and video soundtracks from your Mac on Google Nest,
Google Home, and Chromecast-compatible speakers.** Nest Player is a native
SwiftUI media player with playlists, local video playback, and Google Cast audio
output over your local network.

Paste a **YouTube or Bilibili link**, add a local or **SMB network folder**, and
control playback from an **iPhone browser by scanning a QR code**.

Watch a video on your Mac while its sound plays on a Nest speaker in another
room. Mac audio is muted by default; enable **Mac audio** for simultaneous output
from both devices. A Python CLI is included for scripts and automation.

**[Download for Apple Silicon](https://github.com/htlin222/google-nest-as-speaker/releases/latest)**
· [CLI quick start](#command-line-quick-start)
· [Architecture & specification](SPEC.md)

![Nest Player feature overview: native Mac player, local and SMB library, website links, and an iPhone browser remote](assets/screenshots/feature-overview.png)

*GitHub edition product preview with fictional media and device data. The phone
controller is captured from the real interface using Playwright; the native view
uses an isolated demo fixture. [Capture sources and reproduction](docs/screenshots/README.md).*

## See it in action

| Native macOS playback panel | iPhone browser remote |
| --- | --- |
| ![Native Nest Player interface with a fictional playlist and Mac audio muted](assets/screenshots/native-player.png) | <img src="assets/screenshots/iphone-remote.png" width="270" alt="Playwright screenshot of the real iPhone remote: playback, volume, playlist and website link controls"> |

The examples demonstrate one shared playback queue: choose media on your Mac,
send its audio to a Cast speaker, then control the session from your phone.
No real account, NAS address, private media, or active pairing credential appears
in these screenshots. **Nest Player is distributed through GitHub Releases.**
Mac App Store submission is paused; YouTube and Bilibili remain in this edition.
The [Mac App Store preparation notes](docs/app-store/readiness.md) preserve the
separate sandboxed engineering work for possible future distribution.

## Download and install

The prebuilt `.app` requires **macOS 14 Sonoma or later on Apple Silicon
(M1 or newer)**. An Intel binary is not included in this release.

1. Open [Releases](https://github.com/htlin222/google-nest-as-speaker/releases/latest)
   and download `Nest-Player-0.2.1-macOS-arm64.zip`.
2. Extract the ZIP and move **Nest Player.app** to Applications.
3. Open the app and allow local-network access if macOS requests it.
4. Select your Cast speaker, add or drop a media file, then press Play.

The application bundles Python and PyChromecast. You do not need to install
Python or `uv` to run the downloaded app.

**FFmpeg is an additional requirement for video soundtrack extraction and
unsupported audio formats.** With [Homebrew](https://brew.sh/) installed:

```bash
brew install ffmpeg
```

Common Cast-supported audio files can play directly without FFmpeg. The Mac and
speaker must be on the same reachable LAN; guest-network isolation can prevent
discovery or streaming.

### First launch on macOS

This GitHub release is **ad-hoc signed and not notarized by Apple**. If macOS
blocks the app and you trust this download, attempt to open it, then use
**System Settings → Privacy & Security → Open Anyway**. See
[Apple's instructions for opening downloaded apps](https://support.apple.com/en-us/102445).

Each release includes a SHA-256 file. To verify the download before extracting:

```bash
shasum -a 256 -c Nest-Player-0.2.1-macOS-arm64.zip.sha256
```

## Features

- **YouTube and Bilibili:** paste a video link or share text, including short
  URLs; resolve audio for Cast and up-to-720p H.264 video for the local preview.
- **Browser-session login:** sign in through the website in your browser, then
  explicitly allow Nest Player to use that browser session.
- **Folders and SMB:** import media recursively from local folders or shares
  mounted by Finder, with background scanning and retained offline entries.
- **iPhone remote:** scan a QR code or enter the Mac's pairing code in a local
  browser controller, with transport, seeking, volume, playlist, and link input.
- **Cast local audio:** stream files to Google Nest, Google Home, and Google
  Cast audio groups without uploading them to a cloud service.
- **Local video + Cast sound:** watch supported videos on the Mac while their
  audio plays through the selected speaker.
- **Optional dual audio:** Mac audio starts muted; turn it on when both rooms
  should hear the media.
- **Persistent playlist:** drag and drop, add, remove, reorder, previous/next,
  and automatic advancement after natural completion.
- **Playback controls:** pause, resume, stop, seek, and adjust Cast volume.
- **Fast common-format path:** serve supported audio directly, remux compatible
  video audio tracks, and transcode only when necessary.
- **Conversion cache:** reuse prepared audio with a 2 GB LRU cache budget.
- **Warm service:** one local Cast service remains available while the app runs;
  button presses do not create new Python processes or install dependencies.
- **Automation:** use the CLI, JSON output, or the bundled
  [repo skill](.agents/skills/google-nest-speaker/SKILL.md).

## Paste YouTube or Bilibili links

Paste a URL into the sidebar and press Return, or click **Paste & Play**.
**Add** queues the link without starting it. Cmd-V also works when the playlist
has focus. Share text and multiple links are accepted; duplicate video links
are ignored. A video inside a YouTube playlist is treated as one video.

`yt-dlp` and its EJS scripts are bundled. YouTube also needs an external
JavaScript runtime; Deno is recommended (Node 22+ is supported as an alternative):

```bash
brew install deno
```

Playback uses a local range-capable relay, so it can begin after URL resolution
without waiting for a full-video download. Completed stream responses have a
separate **512 MB disk-cache budget**. Signed CDN URLs expire; stop and replay
to resolve a fresh URL if a stream becomes unavailable.

### When a website requires login

1. Nest Player opens a **Sign in** sheet when the extractor reports that account
   access is required. You can also right-click a website item and choose Sign in.
2. Choose an installed browser and click **Open in browser**. Complete the site's
   normal login, Google sign-in, Bilibili QR login, or two-factor verification.
3. Return to the app and click **Use Session & Play**. This explicitly permits
   reading that browser's cookies; macOS may request Keychain/file access.
4. Optionally remember the selected browser for that site until the app quits.
   **Forget Website Browser Access** clears that permission for future playback.

The app does not collect account passwords or persist browser cookies. Public
videos are tried without browser access. Login does not remove subscription,
regional, age, or other access requirements. Live streams and whole-channel /
playlist imports are not supported yet. Site changes can require a yt-dlp update.

## Local folders and SMB shares

Use **Add → Add Folder…** for a local folder, or **Add → Connect SMB Folder…**
for a server such as `smb://nas/media`. Finder handles mounting, authentication,
and optional Keychain storage. Once mounted, click **Choose Mounted Folder…**.

Scanning runs in the background, recursively finds known audio/video extensions,
skips hidden files and symlinks, sorts naturally, and deduplicates paths. A scan
is capped at 10,000 files and can be cancelled. Keep the share mounted while
playing. Offline NAS items stay in the playlist; reconnect through the SMB menu
and retry playback. No SMB password is entered or stored in Nest Player.

## iPhone browser remote and QR pairing

1. Keep the Mac and iPhone on the same reachable LAN/Wi-Fi.
2. Click **Phone Remote** in the Mac toolbar.
3. Scan its QR code with the iPhone camera. The link opens a paired controller.
4. Alternatively, type the displayed `http://<Mac-LAN-IP>:8989/` address into
   Safari and enter the six-digit pairing code shown on the Mac.

The controller supports play/pause/stop, previous/next, seeking, Cast volume,
Mac audio, playlist selection, and **Add & Play** for YouTube/Bilibili links.
Website login and mounting SMB shares are handled on the Mac.

The server uses port 8989 when available and chooses another free port if needed;
use the actual address shown in the app. QR links contain an app-session control
token. Manual pairing is rate limited, and browser access lasts until disconnect
or app restart. Keep the Mac awake and allow the app through the local firewall.
This is a LAN HTTP controller, not a public Internet service. Cloudflare remote
access remains a separate proposed extension.

## Media and device support

| Input or target | Behavior |
| --- | --- |
| MP3, M4A, FLAC, Ogg/Opus, WAV | Direct serving for Cast-compatible codecs and containers |
| Video containing AAC or MP3 audio | Extract the audio with FFmpeg stream copy when possible |
| Other FFmpeg-readable audio/video | Convert the audio to MP3 |
| MP4, MOV, M4V video | Local picture playback when supported by AVFoundation |
| Google Nest Mini | Tested on a real device |
| Other Google Home / Cast audio devices and groups | Discovered through PyChromecast; compatibility depends on the receiver |

Actual codec support depends on the receiver; see
[Google Cast supported media](https://developers.google.com/cast/docs/media).
Local video decoding uses AVFoundation, so a file may cast its audio successfully
even when macOS cannot display its picture.

This app sends media files and URLs to Cast. It does not capture system-wide
Mac audio, cast video to a TV, or guarantee sample-accurate dual-output sync.
Cloudflare remote control is a [proposed extension](SPEC.md#9-cloudflare-remote-control-extension),
not part of this release.

## Command-line quick start

The CLI works on macOS and Linux with Python 3.11+, [`uv`](https://docs.astral.sh/uv/),
and FFmpeg when conversion is needed. The native application is macOS-only.

```bash
git clone https://github.com/htlin222/google-nest-as-speaker.git
cd google-nest-as-speaker
uv sync --locked

# Discover speakers, then use the friendly name from the result.
./nest-speaker list
./nest-speaker --device 'Living Room' play /absolute/path/to/song.mp3

# Video files are accepted; only their soundtrack is cast.
./nest-speaker --device 'Living Room' play /absolute/path/to/movie.mp4

# Or play an already-hosted media URL.
./nest-speaker --device 'Living Room' play 'https://example.com/audio.mp3'
```

Keep the local-file `play` command running: its HTTP server supplies the media to
the speaker. Ctrl-C stops playback and cleans up its temporary directory.

```bash
export NEST_SPEAKER_DEVICE='Living Room'
./nest-speaker status
./nest-speaker pause
./nest-speaker resume
./nest-speaker seek 30
./nest-speaker stop
./nest-speaker volume 35

# Structured output for automation.
./nest-speaker --json list

# Optional known host when mDNS discovery needs help; use your device's address.
./nest-speaker --device 'Living Room' --host 192.0.2.10 play ./song.mp3
```

The initial device-name preference is `客廳`; discovery selects available devices
in the app. Override the CLI default with `--device` or `NEST_SPEAKER_DEVICE`.
See `./nest-speaker --help` and `./nest-speaker play --help` for all options.

## Build the macOS app

Install Xcode or the Swift 6 development toolchain, `uv`, and FFmpeg. The
qualified packaging target and published ZIP are currently Apple silicon (arm64).

```bash
uv sync --locked
./run-player                  # Development build
./scripts/build_app.sh        # Signed dist/Nest Player.app
./scripts/package_release.sh  # Versioned .app ZIP + SHA-256
open 'dist/Nest Player.app'
```

Packaging obtains the digest-pinned Python 3.12.16/OpenSSL 3.5.9 runtime under
`.build/runtimes` and uses `.build/packaging-venv`; the first build needs network
access. Global Python and the regular development `.venv` remain separate.

The build freezes the locked Python environment with PyInstaller, generates
the macOS icon, includes dependency license metadata, and ad-hoc signs the
result. No runtime package installer is used by the bundled app. FFmpeg and
FFprobe are resolved separately from the installed system tools.

Set `NEST_APP_OUTPUT` to an absolute `.app` path to stage a separate bundle.
Use the same value for packaging; the ZIP version comes from that bundle's plist.

## Architecture and privacy

```text
SwiftUI app ── JSON-lines IPC ── bundled Cast service ── Google Cast speaker
     │                              │
     └─ AVPlayer: local video       ├─ PyChromecast: discovery + controls
                                    ├─ HTTP: active media + byte ranges
                                    └─ FFmpeg: remux/transcode + disk cache
```

The app remembers its last discovered speakers and keeps a Cast connection
available during use. Playback commands and events carry generation IDs so old
requests cannot revive a stopped session. Completion is matched to the owned
Cast media session; buffering must reach playback before the startup deadline.

Source files stay on the Mac and are fetched over local HTTP by the receiver.
The server exposes the active media file during playback. Treat the LAN as
trusted; this media endpoint is not an authenticated Internet service.
Converted audio is cached under `~/Library/Caches/NestPlayer/media`, keyed by
source path, file size, modification time, and pipeline version. Direct-play
source files are not copied into that cache.

See [SPEC.md](SPEC.md) for behavior, acceptance criteria, architecture, and the
optional future Cloudflare Worker + local-agent design.

## Troubleshooting

- **No speakers:** confirm the same LAN, allow local-network access, check mDNS
  (UDP 5353), disable guest isolation, and use the discovery button again.
- **Preparing audio:** install FFmpeg and FFprobe with `brew install ffmpeg`.
  Video extraction or first-time conversion depends on file size; cached audio
  is reused on subsequent plays.
- **Mac is silent:** this is the default. Enable **Mac audio** for dual output.
- **No local picture:** try an AVFoundation-compatible format such as MP4/MOV.
- **Cast and Mac differ slightly:** Cast is the playback clock; local playback
  is corrected when drift exceeds 750 ms. Separate rooms are the intended use.
- **Download blocked:** follow the first-launch instructions above. The release
  does not have Apple notarization or an automatic updater.

## Tests and contributing

```bash
swift test
uv run python -m unittest discover -s tests -v
bash -n scripts/build_app.sh scripts/package_release.sh run-player nest-speaker
# Optional: real public-site resolution and range reads, without playing audio.
uv run python scripts/smoke_online.py
# Optional: packaged service/remote IPC and website extraction, without Cast audio.
uv run python scripts/smoke_bundle.py \
  'dist/Nest Player.app/Contents/Resources/nest-service/nest-service' --online
```

The tests cover byte-range delivery, active-file access, direct MP3 playback,
audio extraction, cache reuse, cancellation, stale-session rejection, and the
buffering startup deadline. LAN and audible playback checks require a real
Cast device and are separate from these tests.

Bug reports and contributions are welcome through
[GitHub Issues](https://github.com/htlin222/google-nest-as-speaker/issues) and pull
requests. Include macOS version, Mac architecture, media format, and the visible
error; leave out private media and network credentials.

## Citation

See [CITATION.cff](CITATION.cff), [citation.bib](citation.bib), and the optional
[AMA/APA citation styles](csl/).

```bibtex
@software{lin2026googlenestasspeaker,
  author = {Lin, Hsieh-Ting},
  title = {{Nest Player}: macOS audio player for Google Nest and Chromecast speakers},
  year = {2026},
  url = {https://github.com/htlin222/google-nest-as-speaker},
  version = {0.2.1}
}
```

## License and acknowledgments

Nest Player source is [MIT licensed](LICENSE). Bundled dependencies retain
their own licenses, included in the app's Resources and dependency metadata.
Built with [SwiftUI](https://developer.apple.com/xcode/swiftui/),
[AVFoundation](https://developer.apple.com/av-foundation/),
[PyChromecast](https://github.com/home-assistant-libs/pychromecast), and
[yt-dlp](https://github.com/yt-dlp/yt-dlp#embedding-yt-dlp), with
[FFmpeg](https://ffmpeg.org/) as an optional external media tool. YouTube's
runtime requirements follow [yt-dlp's EJS setup guide](https://github.com/yt-dlp/yt-dlp/wiki/EJS).

Nest Player is an independent project and is not affiliated with or endorsed by
Google. Google Nest, Google Home, Chromecast, and Google Cast are trademarks of
Google LLC.
