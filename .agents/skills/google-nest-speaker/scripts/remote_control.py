"""Paired LAN controller. Only allowlisted player actions cross into the UI."""
from __future__ import annotations

import contextlib
import http.server
import json
import os
import secrets
import socket
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


PAGE = r'''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="referrer" content="no-referrer"><meta name="theme-color" content="#101025"><meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-title" content="Nest Player"><meta name="apple-mobile-web-app-status-bar-style" content="black-translucent"><title>Nest Player Remote</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#101025;color:#f5f4ff;font:16px -apple-system,BlinkMacSystemFont,sans-serif;padding:env(safe-area-inset-top) 20px 30px}
main{max-width:480px;margin:32px auto}header{display:flex;align-items:center;gap:12px;margin-bottom:32px}.mark{background:#33218c;color:#25e1c3;font-size:26px;padding:10px 17px;border-radius:18px}
h1{font-size:22px;margin:0}small,.muted{color:#aaa9c2;font-size:13px}h2{font-size:24px;line-height:1.3;overflow-wrap:anywhere}section{background:#1c1c35;border:1px solid #30304b;border-radius:22px;padding:22px;margin:16px 0}
button,input,select{font:inherit}button{border:0;color:white;background:#343451;border-radius:14px;padding:13px 17px;touch-action:manipulation;cursor:pointer}button:disabled{opacity:.4}.primary{background:#6552dc}.transport{display:flex;justify-content:center;gap:16px;margin:22px 0}.transport button{font-size:22px}.transport .primary{min-width:78px}input[type=range]{width:100%;accent-color:#32dec5;margin:15px 0}
input[type=text],input[type=url],input[type=tel],select{border:1px solid #44435e;background:#121227;color:white;border-radius:12px;padding:13px;width:100%;margin:10px 0}.times,.row{display:flex;justify-content:space-between;align-items:center;gap:12px}.times{font:12px ui-monospace,monospace;color:#aaa9c2}.row button{white-space:nowrap}.modes{display:flex;gap:10px;align-items:center;margin:4px 0 18px}.modes select{margin:0;flex:1}.modes button.on{background:#6552dc}#sleepLeft{color:#32dec5;font:13px ui-monospace,monospace;min-width:46px;text-align:right}#error{color:#ffb4b4;min-height:20px;font-size:14px}.status{color:#b4b0d3;font-size:14px;line-height:1.4}#pair button{width:100%}#code{font-size:26px;text-align:center;letter-spacing:.3em}a{color:#35dfc7}[hidden]{display:none!important}label{font-size:14px}
</style><main><header><div class="mark">▶</div><div><h1>Nest Player</h1><small>Mac → Cast · iPhone remote</small></div></header>
<section id="pair"><h2>Connect to your Mac</h2><p class="status">Scan the QR code in Nest Player, or enter the six-digit code shown on your Mac.</p>
<form id="pairForm"><input id="code" type="tel" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="000000" aria-label="Pairing code"><button class="primary">Connect</button></form></section>
<div id="player" hidden><section><small id="speaker">Cast speaker</small><h2 id="title">Ready to play</h2><p class="status" id="detail"></p>
<input id="seek" type="range" min="0" max="1" step="1" value="0" aria-label="Playback position"><div class="times"><span id="position">0:00</span><span id="duration">0:00</span></div>
<div class="transport"><button onclick="sendPlayerCommand('previous')" aria-label="Previous">⏮</button><button class="primary" id="play" onclick="sendPlayerCommand('toggle')" aria-label="Play or pause">▶</button><button onclick="sendPlayerCommand('next')" aria-label="Next">⏭</button><button onclick="sendPlayerCommand('stop')" aria-label="Stop">■</button></div>
<div class="modes"><button id="repeat" aria-label="Repeat mode">Repeat off</button><select id="sleep" aria-label="Sleep timer"><option value="off">Sleep timer off</option><option value="15">Sleep in 15 min</option><option value="30">Sleep in 30 min</option><option value="45">Sleep in 45 min</option><option value="60">Sleep in 60 min</option><option value="90">Sleep in 90 min</option><option value="track">Sleep after this track</option></select><span id="sleepLeft"></span></div>
<label for="volume">Speaker volume <span id="volumeLabel"></span></label><input id="volume" type="range" min="0" max="100" step="1" aria-label="Cast volume">
<label class="row"><span>Mac audio</span><input id="macAudio" type="checkbox"></label></section>
<section><label for="playlists">Playlist</label><select id="playlists" aria-label="Playlist"></select><label for="tracks">Track</label><select id="tracks"><option value="">No tracks</option></select><button onclick="sendPlayerCommand('playTrack',document.getElementById('tracks').value)">Play selected</button></section>
<section><label for="link">YouTube / Bilibili link</label><form id="linkForm"><input id="link" type="url" placeholder="https://youtu.be/…" required><button class="primary">Add & Play</button></form><p class="muted">If a video needs login, continue in Nest Player on the Mac.</p></section>
<button onclick="disconnect()">Disconnect this browser</button><p class="muted" id="homeHint">Tip: Share → Add to Home Screen, open it from the Home Screen and enter the Mac's code once. It stays paired until you reset pairing on the Mac.</p></div><p id="error" role="status" aria-live="polite"></p><p class="muted">Keep Nest Player open. Your phone and Mac need the same local network.</p></main>
<script>
const $=id=>document.getElementById(id);const store={get(){try{return localStorage.getItem('nestToken')||''}catch(e){return''}},set(v){try{v?localStorage.setItem('nestToken',v):localStorage.removeItem('nestToken')}catch(e){}}};
let token=new URLSearchParams(location.search).get('token')||store.get(),timer,editing=new Set();
history.replaceState({},'',location.pathname);if(token)store.set(token);
const repeatLabels={off:'Repeat off',all:'🔁 Repeat all',one:'🔂 Repeat one'},nextRepeat={off:'all',all:'one',one:'off'};
const time=s=>{s=Math.max(0,Math.floor(s||0));return Math.floor(s/60)+':'+String(s%60).padStart(2,'0')};
async function api(path,body){const r=await fetch('/api/'+path,{method:body?'POST':'GET',headers:{'Authorization':'Bearer '+token,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,cache:'no-store'});const j=await r.json();if(!r.ok){if(r.status===401)disconnect();throw Error(j.error||'Could not connect')}return j}
function disconnect(){token='';store.set('');$('pair').hidden=false;$('player').hidden=true;clearTimeout(timer)}
async function poll(){clearTimeout(timer);if(!token||document.hidden)return;try{const s=await api('state');$('pair').hidden=true;$('player').hidden=false;$('title').textContent=s.title||'Ready to play';$('detail').textContent=s.detail||'';$('speaker').textContent=s.speaker||'Cast speaker';$('play').textContent=s.playing?'Ⅱ':'▶';if(!editing.has('seek')){$('seek').max=Math.max(1,s.duration||0);$('seek').value=s.position||0}$('position').textContent=time(s.position);$('duration').textContent=time(s.duration);if(!editing.has('volume'))$('volume').value=s.volume||0;$('volumeLabel').textContent=Math.round(s.volume||0)+'%';$('macAudio').checked=!!s.macAudio;const tracks=s.tracks||[],signature=JSON.stringify(tracks);if($('tracks').dataset.signature!==signature){$('tracks').replaceChildren(...tracks.map(t=>new Option(t.title,t.id,false,t.selected)));$('tracks').dataset.signature=signature}const lists=s.playlists||[],listSig=JSON.stringify(lists);if($('playlists').dataset.signature!==listSig){$('playlists').replaceChildren(...lists.map(p=>new Option(p.name,p.id,false,p.current)));$('playlists').dataset.signature=listSig}const mode=s.repeat||'off';$('repeat').textContent=repeatLabels[mode]||repeatLabels.off;$('repeat').dataset.mode=mode;$('repeat').classList.toggle('on',mode!=='off');if(!editing.has('sleep'))$('sleep').value=s.sleep?s.sleep.choice:'off';$('sleepLeft').textContent=s.sleep&&s.sleep.remaining!=null?time(s.sleep.remaining):'';$('error').textContent=''}catch(e){$('error').textContent=e.message}if(token)timer=setTimeout(poll,1000)}
async function sendPlayerCommand(action,value=''){try{await api('command',{action,value:String(value)});clearTimeout(timer);timer=setTimeout(poll,150)}catch(e){$('error').textContent=e.message}}
$('pairForm').onsubmit=async e=>{e.preventDefault();try{const j=await api('pair',{code:$('code').value});token=j.token;store.set(token);poll()}catch(e){$('error').textContent=e.message}};
$('linkForm').onsubmit=e=>{e.preventDefault();sendPlayerCommand('addLink',$('link').value);$('link').value=''};
for(const id of ['seek','volume']){$(id).oninput=()=>editing.add(id);$(id).onchange=()=>{editing.delete(id);sendPlayerCommand(id,$(id).value)}}
$('macAudio').onchange=()=>sendPlayerCommand('macAudio',$('macAudio').checked?'1':'0');
$('playlists').onchange=()=>sendPlayerCommand('selectPlaylist',$('playlists').value);
$('repeat').addEventListener('click',()=>sendPlayerCommand('repeat',nextRepeat[$('repeat').dataset.mode||'off']));
$('sleep').onfocus=()=>editing.add('sleep');$('sleep').onblur=()=>editing.delete('sleep');$('sleep').onchange=()=>{editing.delete('sleep');sendPlayerCommand('sleep',$('sleep').value)};document.addEventListener('visibilitychange',()=>{if(!document.hidden)poll();else clearTimeout(timer)});poll();
</script></html>'''


class RemoteController:
    ACTIONS = {
        "toggle", "previous", "next", "stop", "seek", "volume", "macAudio", "addLink", "playTrack",
        "selectPlaylist", "repeat", "sleep",
    }

    def __init__(self, emit, token_path: Path | None = None) -> None:
        self.emit = emit
        # A persisted token keeps Home Screen remotes paired across app launches.
        self.token_path = token_path
        self.token = self._load_token() or self._new_token()
        self.code = f"{secrets.randbelow(1_000_000):06d}"
        self.state: dict = {}
        self.lock = threading.Lock()
        self.attempts: dict[str, list[float]] = {}
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def setup(self) -> None:
                super().setup()
                self.connection.settimeout(5)

            def log_message(self, *_args: object) -> None:
                pass

            def send_json(self, status: int, data: dict) -> None:
                body = json.dumps(data, ensure_ascii=False).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                self.wfile.write(body)

            def authorized(self) -> bool:
                return secrets.compare_digest(self.headers.get("Authorization", ""), "Bearer " + owner.token)

            def do_GET(self) -> None:
                path = urlsplit(self.path).path
                if path == "/":
                    body = PAGE.encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Referrer-Policy", "no-referrer")
                    self.send_header("X-Frame-Options", "DENY")
                    self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
                    self.end_headers()
                    self.wfile.write(body)
                elif path == "/api/state":
                    if not self.authorized():
                        self.send_json(401, {"error": "Connect using the Mac's QR code or pairing code."})
                        return
                    with owner.lock:
                        state = dict(owner.state)
                    self.send_json(200, state)
                else:
                    self.send_error(404)

            def do_POST(self) -> None:
                path = urlsplit(self.path).path
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= 8192:
                        raise ValueError()
                    data = json.loads(self.rfile.read(length))
                    if not isinstance(data, dict):
                        raise ValueError()
                except (ValueError, OSError):
                    self.send_json(400, {"error": "Invalid request"})
                    return
                if path == "/api/pair":
                    now = time.monotonic()
                    with owner.lock:
                        key = self.client_address[0]
                        recent = [stamp for stamp in owner.attempts.get(key, []) if now - stamp < 60]
                        owner.attempts[key] = recent + [now]
                        allowed = len(recent) < 6
                    if not allowed:
                        self.send_json(429, {"error": "Too many attempts. Wait one minute or scan the QR code."})
                    elif secrets.compare_digest(str(data.get("code", "")), owner.code):
                        self.send_json(200, {"token": owner.token})
                    else:
                        self.send_json(403, {"error": "That code does not match the code on your Mac."})
                    return
                if not self.authorized():
                    self.send_json(401, {"error": "Pair this browser with the Mac first."})
                    return
                if path != "/api/command" or data.get("action") not in owner.ACTIONS:
                    self.send_json(400, {"error": "Unknown player command"})
                    return
                value = data.get("value", "")
                if not isinstance(value, str) or len(value) > 4096:
                    self.send_json(400, {"error": "Invalid command value"})
                    return
                owner.emit("remoteCommand", action=data["action"], value=value)
                self.send_json(200, {"ok": True})

        requested_port = int(os.environ.get("NEST_PLAYER_REMOTE_PORT", "8989"))
        try:
            self.server = http.server.ThreadingHTTPServer(("0.0.0.0", requested_port), Handler)
        except OSError:
            self.server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, name="phone-remote", daemon=True)
        self.thread.start()

    def _load_token(self) -> str | None:
        if self.token_path is None:
            return None
        with contextlib.suppress(OSError, UnicodeDecodeError):
            saved = self.token_path.read_text(encoding="utf-8").strip()
            if len(saved) >= 32:
                return saved
        return None

    def _new_token(self) -> str:
        token = secrets.token_urlsafe(32)
        if self.token_path is not None:
            with contextlib.suppress(OSError):
                self.token_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                temporary = self.token_path.with_suffix(".tmp")
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                    handle.write(token)
                os.replace(temporary, self.token_path)
        return token

    def reset(self) -> None:
        """Unpair every browser: new token (persisted) and a new pairing code."""
        with self.lock:
            self.token = self._new_token()
            self.code = f"{secrets.randbelow(1_000_000):06d}"
            self.attempts.clear()

    def info(self) -> dict[str, str]:
        host = "127.0.0.1"
        with contextlib.suppress(OSError):
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                # Route lookup only: UDP connect sends no packet.
                sock.connect(("192.0.2.1", 9))
                host = sock.getsockname()[0]
        return {
            "remoteURL": f"http://{host}:{self.server.server_address[1]}/?token={self.token}",
            "pairingCode": self.code,
        }

    def update(self, state: dict) -> None:
        with self.lock:
            self.state = state

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=1)
