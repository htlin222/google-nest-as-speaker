# Media sources

The app must accept pasted YouTube/Bilibili video links, provide an explicit
browser-session login flow when required, import local or mounted SMB folders,
and provide a paired LAN web controller for iPhone with QR-code onboarding.

Use yt-dlp 2026.10.26 in a cancellable subprocess to resolve direct streams.
Relay audio/video over a local range-capable proxy so playback can start without
downloading an entire video. Keep signed URLs and browser cookies in memory.
Use Finder to mount SMB and the existing local-file pipeline for mounted files.

Rejected: sending HTML page URLs to Cast (not playable), asking for website
passwords in the app, full-video downloads before playback, implementing SMB
authentication independently of macOS.

The LAN controller belongs to the existing service; it emits allowlisted commands
back to the Mac model. A QR capability token or rate-limited numeric pairing code
authorizes controls. No arbitrary filesystem access or shell commands are exposed.

Acceptance: both site extractors work in the packaged helper; public links work
without cookies; auth is explicit; cancellation terminates resolver/JS children;
folder scanning is asynchronous and deduplicates files; offline NAS entries stay
in the playlist; builds and meaningful source/HTTP tests pass.
