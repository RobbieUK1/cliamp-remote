#!/usr/bin/env python3
"""Helper for the robbie.cliamp bar widget.

Talks to the cliamp player (https://cliamp.stream) through its CLI/IPC and
covers three jobs that are awkward from QML:

  * `poll` — one call returning a normalized runtime snapshot plus the two
    station lists (the built-in "default" stations from radio.cliamp.stream
    and the favourites from ~/.config/cliamp/favorites.toml). The default
    station list is fetched from the upstream streams.m3u and cached so the
    widget does not wait on the network on every poll.
  * `start` — make sure a cliamp instance is serving the IPC socket, starting
    one headless (`cliamp --daemon`, no window) when nothing is running. The
    daemon is spawned fully detached so it outlives this process and the
    widget's terminal.
  * `open` — hand playback over to a cliamp TUI window, in sync with the
    player: snapshot the live stream, stop the headless daemon (cliamp
    allows only one socket owner), and launch the terminal UI on the same
    stream (`--auto-play` when it was playing, so it continues where the
    daemon left off). An already-open TUI window is focused instead.
  * `play <url>` — play a stream in the running instance right now (v2
    `url.load` with play=true).
  * `search <query>` — query the Radio Browser (radio-browser.info) directory
    for stations matching the query; prints a compact JSON list.
  * `favorite <url> <title>` — toggle a station in favourites.toml (add if
    absent, remove if already there); prints the updated favourites list.
  * `raw <args...>` — a pass-through to `cliamp <args>` for playback control
    commands (toggle/next/prev/stop/...). The exit code is the only output
    the widget cares about.

Every command prints one line of JSON (except `raw`, which stays silent so a
wall of error text never reaches the widget).
"""

import datetime
import json
import os
import re
import signal
import subprocess
import sys
import time
import tomllib
import urllib.parse
import urllib.request

CONFIG_DIR = os.path.expanduser("~/.config/cliamp")
STATE_DIR = os.path.expanduser("~/.local/state/omarchy/settings")
FAVORITES_PATH = os.path.join(CONFIG_DIR, "favorites.toml")
DAEMON_LOG = os.path.join(CONFIG_DIR, "cliamp.log")
STREAMS_URL = "https://radio.cliamp.stream/streams.m3u"
STREAMS_CACHE = os.path.join(STATE_DIR, "cliamp-default-stations.json")
STREAMS_TTL_SECONDS = 12 * 60 * 60
RADIO_BROWSER = "https://de1.api.radio-browser.info/json/stations/search"

# Fallback copy of the upstream streams.m3u in case the network is down. The
# cached copy (refreshed on a TTL) takes precedence as soon as it exists.
FALLBACK_STATIONS = [
    {"title": "Lofi", "url": "https://radio.cliamp.stream/lofi/stream"},
    {"title": "Meditative", "url": "https://radio.cliamp.stream/meditative/stream"},
    {"title": "Synthwave", "url": "https://radio.cliamp.stream/synthwave/stream"},
    {"title": "EDM", "url": "https://radio.cliamp.stream/edm/stream"},
    {"title": "Omarchy", "url": "https://radio.cliamp.stream/omarchy/stream"},
    {"title": "Chiptunes", "url": "https://radio.cliamp.stream/chiptune/stream"},
    {"title": "Amiga", "url": "https://radio.cliamp.stream/amiga/stream"},
    {"title": "NCS", "url": "https://radio.cliamp.stream/ncs/stream"},
    {"title": "NCS House", "url": "https://radio.cliamp.stream/ncs-house/stream"},
    {"title": "NCS Dubstep", "url": "https://radio.cliamp.stream/ncs-dubstep/stream"},
    {"title": "NCS Drum & Bass", "url": "https://radio.cliamp.stream/ncs-dnb/stream"},
    {"title": "NCS Trap", "url": "https://radio.cliamp.stream/ncs-trap/stream"},
    {"title": "NCS Phonk", "url": "https://radio.cliamp.stream/ncs-phonk/stream"},
    {"title": "NCS Pop", "url": "https://radio.cliamp.stream/ncs-pop/stream"},
    {"title": "NCS Chill", "url": "https://radio.cliamp.stream/ncs-chill/stream"},
]


def run_cliamp(args, timeout=8):
    try:
        proc = subprocess.run(["cliamp", *args], capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout
    except Exception:
        return 1, ""


def ipc_running(timeout=5):
    """True when a cliamp instance answers on the IPC socket."""
    rc, out = run_cliamp(["remote", "state"], timeout=timeout)
    return rc == 0 and out.lstrip().startswith("{")


def parse_m3u(text):
    stations = []
    title = None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#EXTINF"):
            title = line.split(",", 1)[1] if "," in line else line
        elif line.startswith("#"):
            continue
        else:
            stations.append({"title": title or line, "url": line})
            title = None
    return stations


def fetch_streams():
    try:
        with urllib.request.urlopen(STREAMS_URL, timeout=8) as response:
            body = response.read().decode("utf-8", "replace")
        stations = parse_m3u(body)
        return stations if stations else None
    except Exception:
        return None


def default_stations():
    try:
        cached = None
        if os.path.exists(STREAMS_CACHE):
            with open(STREAMS_CACHE, "r", encoding="utf-8") as handle:
                cached = json.load(handle)
        fresh = cached and (cached.get("stations") or []) and \
            (cached.get("fetched_at") or 0) + STREAMS_TTL_SECONDS > _now()
        if fresh:
            return cached["stations"]
        stations = fetch_streams()
        if stations:
            try:
                os.makedirs(STATE_DIR, exist_ok=True)
                with open(STREAMS_CACHE, "w", encoding="utf-8") as handle:
                    json.dump({"fetched_at": _now(), "stations": stations}, handle)
            except Exception:
                pass
            return stations
        if cached and cached.get("stations"):
            return cached["stations"]
    except Exception:
        pass
    return FALLBACK_STATIONS


def favorite_stations():
    if not os.path.exists(FAVORITES_PATH):
        return []
    try:
        with open(FAVORITES_PATH, "rb") as handle:
            data = tomllib.load(handle)
    except Exception:
        return []
    entries = data.get("entry") or []
    out = []
    for entry in entries:
        if not isinstance(entry, dict) or not entry.get("path"):
            continue
        out.append({"title": entry.get("title") or entry["path"], "url": entry["path"]})
    return out


def _toml_quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_favorites(entries):
    """Rewrite favorites.toml in cliamp's own `[[entry]]` format, atomically."""
    lines = []
    for entry in entries:
        lines.append("[[entry]]")
        lines.append("favorited_at = %s" % _toml_quote(entry.get("favorited_at", "")))
        lines.append("path = %s" % _toml_quote(entry.get("path", "")))
        lines.append("title = %s" % _toml_quote(entry.get("title", "")))
        if entry.get("realtime"):
            lines.append("realtime = true")
        lines.append("")
    body = "\n".join(lines).rstrip() + "\n"
    tmp = FAVORITES_PATH + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.replace(tmp, FAVORITES_PATH)
        return True
    except Exception:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except Exception:
            pass
        return False


def read_favorites_entries():
    if not os.path.exists(FAVORITES_PATH):
        return []
    try:
        with open(FAVORITES_PATH, "rb") as handle:
            data = tomllib.load(handle)
    except Exception:
        return []
    entries = data.get("entry") or []
    return [e for e in entries if isinstance(e, dict)]


def cmd_favorite(url, title):
    """Toggle a station in favourites.toml (add if absent, remove if present)."""
    entries = read_favorites_entries()
    existed = any(e.get("path") == url for e in entries)
    if existed:
        entries = [e for e in entries if e.get("path") != url]
        added = False
    else:
        favorited_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        entries.append({
            "path": url,
            "title": title or url,
            "favorited_at": favorited_at,
            "realtime": True,
        })
        added = True
    ok = write_favorites(entries)
    result = {
        "ok": ok,
        "added": added,
        "favorites": [
            {"title": e.get("title") or e["path"], "url": e["path"]}
            for e in entries if e.get("path")
        ],
    }
    print(json.dumps(result))


def _now():
    return int(time.time())


def cmd_start():
    """Make sure a cliamp instance serves the IPC socket.

    Starts `cliamp --daemon` (headless, no window) when nothing is running.
    The daemon is spawned in its own session so it survives this process and
    never receives a SIGHUP from a closing terminal — cliamp treats SIGHUP as
    a shutdown signal. Stdout/stderr go to ~/.config/cliamp/cliamp.log.
    """
    if ipc_running():
        print(json.dumps({"ok": True, "started": False}))
        return
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(DAEMON_LOG, "ab") as log:
            subprocess.Popen(
                ["cliamp", "--daemon"],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                start_new_session=True,
                close_fds=True,
            )
    except Exception:
        print(json.dumps({"ok": False, "started": False}))
        return
    # The daemon can lose a startup race (or fail on the audio device), so
    # poll the socket instead of trusting the spawn. A second instance exits
    # with "cliamp is already running", which the next ipc_running() catches.
    for _ in range(40):
        time.sleep(0.25)
        if ipc_running():
            print(json.dumps({"ok": True, "started": True}))
            return
    print(json.dumps({"ok": False, "started": True}))


def current_stream():
    """Return {"state": ..., "path": ...} of the live instance, or empties."""
    rc, out = run_cliamp(["remote", "state"])
    if rc == 0 and out.lstrip().startswith("{"):
        try:
            snap = json.loads(out)
            snap = (snap.get("snapshot") or {}) if isinstance(snap, dict) else {}
            track = snap.get("logical_track") or {}
            if not isinstance(track, dict):
                track = {}
            return {"state": snap.get("state") or "", "path": track.get("path") or ""}
        except Exception:
            pass
    return {"state": "", "path": ""}


def focus_cliamp_window():
    """Focus an existing cliamp TUI window; True when one was found.

    Mirrors omarchy-launch-or-focus's word-boundary match on window class
    and title.
    """
    pattern = re.compile(r"\bcliamp\b", re.IGNORECASE)
    try:
        out = subprocess.run(["hyprctl", "clients", "-j"],
                             capture_output=True, text=True, timeout=5)
        clients = json.loads(out.stdout or "[]")
    except Exception:
        return False
    for client in clients if isinstance(clients, list) else []:
        if not isinstance(client, dict):
            continue
        if pattern.search(str(client.get("class") or "")) or \
                pattern.search(str(client.get("title") or "")):
            address = client.get("address")
            if not address:
                continue
            try:
                subprocess.run(["hyprctl", "dispatch", "focuswindow",
                                "address:%s" % address],
                               capture_output=True, timeout=5)
                return True
            except Exception:
                return False
    return False


def cmd_open():
    """Hand playback over to a cliamp TUI window, in sync with the player.

    cliamp allows only one socket owner: a TUI started while the headless
    daemon runs becomes a second, independent player the widget cannot
    control. So snapshot what is playing, stop the daemon (TERM is cliamp's
    graceful quit — it saves the resume position), then launch the terminal
    UI with the same stream: `--auto-play` when it was playing (the TUI
    also seeks to the saved position via its resume state), or just the
    stream loaded when it was paused/stopped. An already-open TUI window is
    focused instead of duplicated.
    """
    snapshot = current_stream()
    had_instance = ipc_running()
    if had_instance:
        stop_daemon()

    if focus_cliamp_window():
        print(json.dumps({"ok": True, "focused": True, "path": snapshot["path"]}))
        return

    args = []
    if snapshot["path"]:
        if snapshot["state"] == "playing":
            args.append("--auto-play")
        args.append(snapshot["path"])
    # Direct argv through uwsm-app rather than omarchy-launch-or-focus-tui:
    # that helper evals its command string, which mangles stream URLs that
    # carry & or ? in the query string.
    try:
        subprocess.Popen(
            ["uwsm-app", "--", "xdg-terminal-exec",
             "--app-id=org.omarchy.cliamp", "-e", "cliamp", *args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except Exception:
        print(json.dumps({"ok": False, "path": snapshot["path"]}))
        return
    print(json.dumps({"ok": True, "focused": False, "path": snapshot["path"]}))


def stop_daemon():
    """TERM the headless daemon (if one owns the socket) and wait for it.

    A TUI instance is left alone: the process match is exactly
    `cliamp --daemon`, so the interactive player never gets signalled.
    """
    try:
        out = subprocess.run(
            ["pgrep", "-f", "^cliamp --daemon$"],
            capture_output=True, text=True, timeout=5,
        )
        for pid in out.stdout.split():
            try:
                os.kill(int(pid), signal.SIGTERM)
            except Exception:
                pass
    except Exception:
        return
    for _ in range(24):
        time.sleep(0.25)
        if not ipc_running():
            return


def poll_status():
    rc, out = run_cliamp(["remote", "state"])
    running = rc == 0 and out.lstrip().startswith("{")
    if not running:
        return {
            "running": False,
            "state": "stopped",
            "title": "",
            "path": "",
            "position": None,
            "duration": None,
            "seekable": False,
            "total": 0,
            "index": -1,
        }
    try:
        snapshot = json.loads(out)
        if isinstance(snapshot, dict):
            snapshot = snapshot.get("snapshot") or {}
        else:
            snapshot = {}
    except Exception:
        snapshot = {}
    if not isinstance(snapshot, dict):
        snapshot = {}
    track = snapshot.get("logical_track") or {}
    # `track` is the live audio track: for a radio stream its title/artist
    # carry the ICY now-playing metadata (the current song), while
    # `logical_track` stays the station/stream row.
    live = snapshot.get("track") or {}
    if not isinstance(live, dict):
        live = {}
    return {
        "running": True,
        "state": snapshot.get("state") or "stopped",
        "title": (track.get("title") or "") if isinstance(track, dict) else "",
        "path": (track.get("path") or "") if isinstance(track, dict) else "",
        "track_title": live.get("title") or "",
        "track_artist": live.get("artist") or "",
        "track_station": live.get("station") or "",
        "position": snapshot.get("position"),
        "duration": snapshot.get("duration"),
        "seekable": bool(snapshot.get("seekable")),
        "total": snapshot.get("total") or 0,
        "index": snapshot.get("index"),
        "shuffle": snapshot.get("shuffle"),
        "repeat": snapshot.get("repeat"),
    }


def cmd_poll():
    status = poll_status()
    status["stations"] = {
        "default": default_stations(),
        "favorites": favorite_stations(),
    }
    print(json.dumps(status))


def search_radio_browser(name="", tag="", limit=60):
    params = {
        "order": "clickcount",
        "reverse": "true",
        "hidebroken": "true",
        "limit": str(limit),
    }
    if tag:
        params["tag"] = tag
    if name:
        params["name"] = name
    url = RADIO_BROWSER + "?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            payload = json.load(response)
    except Exception:
        return []
    if not isinstance(payload, list):
        return []
    return payload


def search_stations(query, limit=60):
    words = query.split()
    attempts = [" ".join(words[:i + 1]) for i in range(len(words) - 1, -1, -1)]
    attempts.append("")
    payload = []
    attempted = None
    for name_attempt in attempts:
        attempted = name_attempt
        payload = search_radio_browser(name=name_attempt, limit=limit)
        if payload:
            break
    if not payload:
        last = words[-1] if words else None
        if last:
            payload = search_radio_browser(name=last, limit=limit)
    out = []
    seen = set()
    for station in payload:
        if not isinstance(station, dict):
            continue
        title = (station.get("name") or "").strip()
        url = (station.get("url_resolved") or station.get("url") or "").strip()
        if not title or not url or url in seen:
            continue
        seen.add(url)
        out.append({
            "title": title,
            "url": url,
            "country": station.get("countrycode") or "",
            "tags": station.get("tags") or "",
            "votes": station.get("votes") or 0,
            "bitrate": station.get("bitrate") or 0,
        })
    return out


def cmd_search(query):
    print(json.dumps({"query": query, "results": search_stations(query)}))


def cmd_play(url):
    params = json.dumps({"path": url, "play": True})
    rc, out = run_cliamp(["remote", "call", "url.load", "--params", params])
    print(json.dumps({"ok": rc == 0, "output": out.strip()}))


def cmd_raw(args):
    rc, out = run_cliamp(args)
    if rc != 0 and out.strip():
        print(out.strip(), file=sys.stderr)
    sys.exit(rc)


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "error": "missing command"}), file=sys.stderr)
        sys.exit(2)
    command = sys.argv[1]
    if command == "poll":
        cmd_poll()
    elif command == "start":
        cmd_start()
    elif command == "open":
        cmd_open()
    elif command == "play":
        if len(sys.argv) < 3:
            print(json.dumps({"ok": False, "error": "missing url"}), file=sys.stderr)
            sys.exit(2)
        cmd_play(sys.argv[2])
    elif command == "search":
        if len(sys.argv) < 3:
            print(json.dumps({"ok": False, "error": "missing query"}), file=sys.stderr)
            sys.exit(2)
        cmd_search(sys.argv[2])
    elif command == "favorite":
        if len(sys.argv) < 3:
            print(json.dumps({"ok": False, "error": "missing url"}), file=sys.stderr)
            sys.exit(2)
        cmd_favorite(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    elif command == "raw":
        cmd_raw(sys.argv[2:])
    else:
        print(json.dumps({"ok": False, "error": "unknown command: " + command}), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()