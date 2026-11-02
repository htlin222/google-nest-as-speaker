# Nest Player Product and Technical Specification

- **Status:** v0.1.0 implementation; Cloudflare extension remains proposed
- **Last updated:** 2026-11-03
- **Target platform:** macOS 14 or later
- **Primary Cast target:** Google Nest Mini and Google Cast audio groups

## 1. Summary

Nest Player is a native macOS media player that plays media locally while
simultaneously sending its audio track to a Google Cast speaker on the same
local network.

For video, the Mac displays the picture while the Cast device plays the audio.
Mac audio is muted by default to avoid duplicate sound, but the user can enable
Mac audio for simultaneous output in separate rooms. For audio-only media, the
Mac shows a player artwork view and follows the same output rules.

The first release is a local-first application. A later Cloudflare-based remote
control may expose the player UI outside the Mac, but all file access, media
conversion, LAN discovery, and Cast control remain in a local helper.

## 2. Goals

1. Play common audio and video files through an IINA-like native Mac interface.
2. Display video locally while casting its audio track to a selected Nest or
   Cast audio group.
3. Support a persistent, reorderable playlist with automatic advancement.
4. Keep local and Cast playback controls and timelines reasonably synchronized.
5. Accept media formats supported by FFmpeg for Cast audio extraction.
6. Keep local media private and avoid uploading it to a cloud service by
   default.
7. Expose a stable machine-readable helper interface that can later support a
   web remote, automation, or another native client.

## 3. Non-goals for the first release

- Casting video or mirroring the Mac display to a television.
- Acting as a system-wide Mac audio output device.
- Sample-accurate multi-room synchronization.
- DRM-protected media playback or audio extraction.
- Editing, trimming, transcoding presets, subtitles, or video filters.
- App Store sandboxing, notarization, or automatic updates.
- A cloud-only implementation that directly discovers private LAN devices.

## 4. Primary user experience

### 4.1 First launch

1. The app discovers Google Cast devices through mDNS.
2. It prefers the previously selected device; otherwise it selects the first
   audio device, with `客廳` as the initial preference.
3. The app restores playlist entries whose files still exist.
4. Local Mac audio starts disabled.

### 4.2 Adding media

The user can:

- select one or more audio or video files with the macOS file importer;
- drag files from Finder into the app;
- add more files without replacing the existing playlist;
- remove an item, clear the list, or reorder items.

Duplicate paths are ignored. Missing persisted files are omitted on the next
launch.

### 4.3 Starting playback

1. The user selects a playlist item and presses Play or double-clicks it.
2. The local player prepares the file but does not begin advancing yet.
3. The helper directly serves Cast-compatible audio, extracts compatible audio
   streams without re-encoding, or converts unsupported audio to MP3. Previously
   converted audio can be reused from the disk cache.
4. The helper exposes only the prepared file through a temporary HTTP server on
   the LAN.
5. The Cast device loads that URL.
6. When Cast reports `PLAYING`, local playback begins at the reported Cast
   position.

For video, the picture appears in the Mac window. Local audio remains muted
unless **Mac audio** is enabled.

### 4.4 Playback controls

The app provides:

- play and pause;
- stop;
- previous and next item;
- timeline seeking;
- Cast volume from 0 to 100;
- a **Mac audio** toggle, off by default;
- Cast device selection and rediscovery.

Previous restarts the current item when its position is greater than three
seconds; otherwise it selects the preceding playlist item. A naturally
completed item advances to the next item.

## 5. Functional requirements

### FR-1: Cast discovery

- Discover devices by friendly name through mDNS.
- Display the device name and retain the user's last selection.
- Support audio devices and Google Cast audio groups.
- Permit a known IP address or hostname as a diagnostic fallback.
- Never persist a DHCP-assigned device IP as the primary identity.

### FR-2: Supported inputs

- Accept local files classified by macOS as audio or audiovisual content.
- Use FFmpeg as the authoritative decoder for Cast audio extraction.
- Use AVFoundation for local rendering.
- Common MP4, MOV, and M4V video must render locally.
- If FFmpeg supports a file but AVFoundation cannot render its picture, Cast
  audio may continue, but the app must disclose that local video is unavailable.
- HTTP(S) media URLs remain supported by the helper API; a URL entry field is
  optional for the first native UI release.

### FR-3: Local playback

- Use one local player instance for the selected item.
- Render video without separate native transport controls; the app's unified
  controls remain authoritative.
- Start local playback after Cast reaches `PLAYING`.
- Mute local audio by default on every app launch.
- Allow the user to enable or disable local audio during playback.
- Prevent AVFoundation from redirecting video to a separate external playback
  target.

### FR-4: Cast media delivery

- Transcode local media to MP3 with the video stream disabled.
- Serve a single copied or transcoded file from a unique temporary directory.
- Support HTTP byte-range requests and advertise `Accept-Ranges: bytes`.
- Choose an available ephemeral port by default.
- Construct the media URL with the Mac's LAN address used to reach the Cast
  device, not `localhost`.
- Keep the HTTP server alive until playback finishes or is stopped.
- Delete temporary media when the owning command exits.

### FR-5: Playlist

- Add multiple files in one operation.
- Show title and file type for every item.
- Select and double-click to play an item.
- Reorder items by drag and drop.
- Remove the selected item or clear the full playlist.
- Provide previous and next controls.
- Advance automatically after natural completion.
- Persist ordered file paths locally and restore only existing files.

### FR-6: Synchronization

- Treat Cast status as the shared playback timeline after Cast starts.
- Receive event-driven Cast status from the owning local service; emit progress
  approximately once per second only while active.
- Update UI position and duration from Cast status.
- Correct local playback when its drift from Cast exceeds 750 milliseconds.
- Apply play, pause, stop, and seek to both local playback and Cast.
- Do not promise inaudible synchronization when Mac audio and Cast audio are
  enabled in the same room.

### FR-7: State and feedback

The UI must distinguish at least these states:

| State | Meaning |
| --- | --- |
| Ready | A device is available and no item is playing |
| Discovering | Searching the LAN for Cast devices |
| Preparing | FFmpeg is extracting or transcoding audio |
| Connecting | Cast is loading or buffering the media URL |
| Playing | Cast reports active playback |
| Paused | Playback is paused |
| Failed | A user-actionable error occurred |

Errors must state what failed and must not claim that sound was heard merely
because a command exited successfully.

## 6. System architecture

```text
┌─────────────────────────────────────────────┐
│ Native macOS app                            │
│ SwiftUI + Observation                       │
│                                             │
│  Playlist / controls / device selector      │
│                 │                           │
│                 ├── AVPlayer / AVPlayerLayer│
│                 │      local audio + video  │
│                 │                           │
│                 └── JSON / JSON-lines IPC   │
└─────────────────────────┬───────────────────┘
                          │ one persistent JSON-lines process
┌─────────────────────────▼───────────────────┐
│ Bundled local Cast service                  │
│ PyChromecast + FFmpeg + HTTP + media cache  │
└─────────────────────────┬───────────────────┘
                          │ Cast control + HTTP GET
┌─────────────────────────▼───────────────────┐
│ Google Nest / Cast audio group              │
└─────────────────────────────────────────────┘
```

### 6.1 Native app

- SwiftUI renders the window and playlist.
- An `@Observable`, main-actor model owns user-visible state.
- AVPlayer handles local media playback.
- AVPlayerLayer displays video inside the custom player surface.
- Foundation Process launches one bundled service when the app starts and
  captures structured output separately from diagnostics.

### 6.2 Local helper

- Python and PyChromecast are frozen into an onedir helper at build time; the
  packaged app does not resolve or install dependencies at runtime.
- PyChromecast is pinned to a tested exact version.
- FFmpeg performs media decoding and audio extraction.
- A threaded HTTP server provides full and range responses.
- A single session owner keeps discovery/connection state warm and serializes
  transitions using monotonically increasing generation IDs.
- Human-readable output is the CLI default; service mode uses stable JSON-lines
  requests, responses, and events.

### 6.3 IPC commands

The helper supports these commands:

| Command | Purpose |
| --- | --- |
| `list` | Discover Cast devices |
| `play <source>` | Prepare and play a local file or URL |
| `status` | Return playback position, duration, volume, and state |
| `pause` | Pause Cast playback |
| `resume` | Resume Cast playback |
| `seek <seconds>` | Seek Cast playback |
| `stop` | Stop Cast playback |
| `volume <0..100>` | Set Cast volume |

The app service accepts all commands on one JSON-lines channel. Each request has
an ID; each playback transition has a generation. Late commands and events for
older generations are discarded. Playback emits events such as `transcoding`,
`casting`, `state`, `progress`, `completed`, and `failed`.

## 7. Privacy and security

- Media remains on the Mac unless a future cloud-upload mode is explicitly
  enabled.
- Never serve the source file's parent directory.
- Bind the temporary server only for the lifetime of playback.
- Do not store credentials, source media, generated transcodes, or device IPs
  in Git.
- Request macOS local-network access with a user-facing explanation.
- Treat filenames and media metadata as display data, never executable input.
- Launch FFmpeg and helper processes with argument arrays, not shell-expanded
  command strings.

## 8. Performance and reliability targets

- Device discovery completes within 10 seconds on a functioning LAN.
- The packaged app starts without `uv`, a system Python, or network dependency
  installation and keeps at most one Cast service process.
- Cast-native audio begins without copying or transcoding.
- Remuxed/transcoded outputs use a path/size/mtime/version cache capped at 2 GB;
  active media is the only file exposed by its HTTP server.
- After transcoding is ready, Cast reaches `PLAYING` or returns an actionable
  timeout within 20 seconds. BUFFERING alone does not satisfy the deadline.
- The app remains responsive during discovery, transcoding, and playback.
- Local/Cast drift is corrected whenever it exceeds 750 milliseconds.
- Playback cleanup runs after completion, stop, interruption, or app exit.
- Playback state and completion are accepted only for the content ID and media
  session created by the current generation; receiver takeover and explicit
  Cast error/cancellation are failures and never auto-advance the playlist.

## 9. Cloudflare remote-control extension

### 9.1 Purpose

Provide a browser-based remote control for the Mac player without making media
public or exposing inbound ports on the home router.

### 9.2 Recommended topology

```text
Browser
   │
   ▼
Cloudflare Worker + static assets
   │
   ▼
Durable Object with hibernating WebSockets
   │ outbound connection initiated by Mac
   ▼
Local Nest Player agent ──► Cast device
```

Cloudflare Pages may host the static UI, but a new implementation should prefer
a Worker with static assets unless Pages provides a project-specific advantage.

### 9.3 Requirements

- The Mac agent initiates the connection to Cloudflare.
- The Worker never attempts mDNS discovery or direct access to private LAN IPs.
- A Durable Object coordinates one authenticated household/player session.
- Commands and status use versioned JSON envelopes with request IDs.
- Pairing requires a short-lived code displayed by the Mac app.
- Reconnects restore state without replaying mutation commands.
- Remote destructive actions are limited to stopping playback or modifying the
  current playlist; arbitrary filesystem paths and shell commands are forbidden.

### 9.4 Optional cloud media mode

R2 uploads may allow playback when the Mac cannot serve media directly. This is
not the default because it adds upload delay, storage cost, and privacy risk.
If implemented, use short-lived presigned URLs and automatic object expiry.

## 10. Testing strategy

### 10.1 Unit tests

- Device and status JSON decoding.
- Playback event decoding.
- Time formatting and media type detection.
- HTTP byte-range parsing and responses.
- Volume and argument validation.
- Playlist ordering and missing-file restoration.

### 10.2 Integration tests

- Extract an audio stream from a generated video with FFmpeg.
- Discover the known Nest on the LAN.
- Play a short generated tone and observe `PLAYING` followed by `IDLE`.
- Verify pause, resume, seek, stop, and volume without changing volume unless
  the test explicitly requests it.
- Build and verify the signed `.app` bundle.

### 10.3 Manual acceptance

1. Add several audio and video files by picker and drag/drop.
2. Reorder the playlist and restart the app; verify the order is restored.
3. Play a video; verify video appears on the Mac and audio plays from Nest.
4. Verify Mac audio is silent by default.
5. Enable Mac audio; verify both outputs play.
6. Pause, resume, seek, select next/previous, and stop.
7. Allow one item to finish and verify automatic advancement.
8. Disconnect the Nest or Wi-Fi and verify an actionable error appears.

## 11. Release criteria

The first release is ready when:

- all automated Swift and Python tests pass;
- the repo-local skill validates;
- the release app builds and passes code-signature verification;
- the real Nest completes a short playback test;
- all manual acceptance steps pass for at least one audio file and one MP4;
- known limitations are documented in the README.

## 12. Open decisions

1. Whether to embed libmpv for local MKV and broader codec support.
2. Whether playlist persistence should use security-scoped bookmarks before
   sandboxing or distribution.
3. Whether to distribute outside the App Store with Developer ID notarization.
4. Whether the Cloudflare remote belongs in this repository or a separate web
   client repository.
5. Whether R2 upload mode is valuable enough to justify its privacy and cost.
