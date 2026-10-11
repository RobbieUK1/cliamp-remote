# Cliamp

Bar widget for [cliamp](https://cliamp.stream), the terminal internet-radio
player, for the Omarchy shell bar.

The button lives permanently in the bar's **left** section, so it never costs
you bar space elsewhere. It stays quiet while cliamp is idle and lights up in
the accent colour while cliamp is running. Clicking it opens a dropdown with
prev / play-pause / next, a station picker, and a search box that queries the
[Radio Browser](https://radio-browser.info) directory so you can find any
station and favourite it without leaving the panel. **No cliamp window is
needed**: the widget starts cliamp headless (`cliamp --daemon`) the first time
you use it and controls it over the same IPC socket. The footer's **Open
Cliamp** button hands playback over to the terminal window when you do want
it, in sync with the player: it snapshots the live stream, stops the
headless daemon (cliamp allows only one socket owner, so a TUI started
alongside it would be a second, independent player) and launches the TUI on
the same stream — playing and seeked to where the daemon was, when it was
playing. A credit to the Cliamp player sits at the bottom of the dropdown.

The dropdown follows the system theme, and its card surface obeys the system
window transparency: its alpha tracks the `robbie.transparency` slider (the
`default-opacity` rule in `~/.config/hypr/looknfeel.lua`), the same way
`robbie.cpu-temp-compact`'s popup does — the shared `KeyboardPanel` hardcodes
an opaque themed fill, so the plugin vendors it as `ThemedKeyboardPanel.qml`
with an overridable card colour. While the dropdown is open during playback a
spectrum analyser (fed by `cliamp visstream`) dances above the station name.
The now-playing block shows the station under the same title the station
lists use — the default list, your favourites, or a search result — with the
stream's live now-playing song (ICY metadata) below it when the station
reports one.

## Requirements

- Omarchy shell
- [cliamp](https://cliamp.stream) installed
- `python3`

## Install

One command:

```sh
omarchy plugin add https://github.com/RobbieUK1/cliamp-remote.git --enable
```

The button appears in the bar's **left** section immediately — nothing to copy
and no `shell.json` to edit. Add `--yes` to run unattended: it skips both the
trust confirmation and the placement question, and is required when stdin is
not a terminal.

### Optional: survive `omarchy refresh shell`

`omarchy refresh shell` regenerates `shell.json` from the shipped defaults and
drops every widget that is not in them, which silently removes this one.
`ensure-bar.sh` puts it back. Wire it up with a systemd path unit that watches
`shell.json`:

`~/.config/systemd/user/omarchy-cliamp-bar.path`

```ini
[Unit]
Description=Watch shell.json and keep the Cliamp bar widget present

[Path]
PathChanged=%h/.config/omarchy/shell.json
Unit=omarchy-cliamp-bar.service

[Install]
WantedBy=default.target
```

`~/.config/systemd/user/omarchy-cliamp-bar.service`

```ini
[Unit]
Description=Re-add the Cliamp bar widget after shell.json changes

[Service]
Type=oneshot
ExecStart=%h/.config/omarchy/plugins/robbie.cliamp/ensure-bar.sh
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now omarchy-cliamp-bar.path
```

The script re-adds the widget only when the removal came from a refresh — it
keys on the `shell.json.bak.<epoch>` backup that only `omarchy refresh` writes,
which a removal you did on purpose never creates. A deliberate disable or
widget removal leaves no backup, so the script stays out of the way. (Note
that `omarchy bar defaults` on its own creates no backup either, so it is not
covered.)

## How it works

`Panel.qml` is a thin UI; the work happens in `cliamp.py`, which exists because
these things are awkward from QML:

| Subcommand  | What it does                                                        |
|-------------|---------------------------------------------------------------------|
| `poll`      | One call returning a normalized snapshot plus both station lists     |
| `start`     | Start cliamp headless (`cliamp --daemon`) if the IPC socket is dead  |
| `open`      | Stop the headless daemon and launch the TUI on the same stream       |
| `play <url>`| Play a stream in the running instance right now                      |
| `search <q>`| Query the Radio Browser directory for matching stations              |
| `favorite`  | Toggle a station in `~/.config/cliamp/favorites.toml`               |
| `raw <args>`| Pass-through to the `cliamp` CLI for playback control                |

Every subcommand prints a single line of JSON, except `raw`, which stays silent
so a wall of error text never reaches the widget.

The built-in station list comes from cliamp's upstream `streams.m3u` and is
cached, so the widget does not wait on the network on every poll. Favourites
are read from and written back to `~/.config/cliamp/favorites.toml`.

### Headless daemon

The first station pick (or play-pause press) while cliamp is stopped starts
`cliamp --daemon` in the background — no terminal window. It is spawned in its
own session, so it survives the widget and any closing terminal, and it keeps
running (idle costs almost nothing) until you stop it or log out:

```sh
pkill -TERM -f 'cliamp --daemon'   # stop it from a terminal
```

The daemon serves the same `~/.config/cliamp/cliamp.sock` the widget polls, so
everything — stations, favourites, prev/next, the bar icon, media keys via
MPRIS — works with no window open.

One cliamp limitation to know: only one instance can own the socket. If you
open the cliamp window by other means (the desktop entry / a terminal
`cliamp`) while the headless daemon is running, the TUI starts anyway as a
*second, independent* player that the widget cannot see. Use the widget's
**Open Cliamp** button instead — it stops the daemon first — or stop the
daemon yourself before opening the window.

## License

MIT
