# Media sources context

Base: public repo htlin222/google-nest-as-speaker, v0.1.0, commit 2f9197c.

SwiftUI PlayerModel owns a generation-based session and one CastBackend process.
The Python helper is in .agents/skills/google-nest-speaker/scripts/nest_speaker.py.
New website logic belongs in sibling online_media.py, keeping yt-dlp imports lazy.
CastBackend uses JSON-lines request IDs and playback generations. New events must
carry the same generation and never revive a stopped session.

2026-11-03: yt-dlp[default] 2026.10.26 resolves yt-dlp-ejs 0.8.0. YouTube needs a
JavaScript runtime; this Mac has Deno and Node. The packaged helper should discover
Deno/Node from the same standard PATH as FFmpeg. Browser-cookie access is opt-in.
Never test with personal browser cookies automatically. SMB login belongs to Finder.

Sources: https://github.com/yt-dlp/yt-dlp#embedding-yt-dlp and
https://github.com/yt-dlp/yt-dlp/wiki/EJS.

2026-11-03 completed: 9 Swift and 26 Python tests; both site resolvers and
audio/video range reads succeeded without cookies or audible playback. Packaged
helper and phone IPC passed after extracting the v0.2.0 ZIP. Mobile controller
was exercised at 390px width. Avoid a global function called command in inline
button handlers: newer HTMLButtonElement.command shadows it. Regression uses
a native-style string command property to validate all transport handlers.

Private account login, user NAS mounting, and physical iPhone camera pairing
remain manual environment-specific checks; never read personal cookies to test.
