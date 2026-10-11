import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button for the cliamp terminal music player (https://cliamp.stream).
//
// The button sits on the bar permanently. Clicking it opens a dropdown that
// controls playback (prev / play-pause / next) and lets you jump
// between stations from the built-in "default" list (radio.cliamp.stream/
// streams.m3u), a live Radio Browser search, or your favourites
// (~/.config/cliamp/favorites.toml). A bookmark toggle on each row adds or
// removes that station from favourites.
//
// State comes from a small helper script so the widget never needs to parse
// cliamp's raw IPC output itself. The socket is watched with a FileView, so
// the widget wakes up the moment cliamp starts or stops; a slow poll timer
// is the fallback and drives the fast poll while cliamp is active.
//
// No cliamp window is needed: when nothing is running, the helper starts
// cliamp headless (`cliamp --daemon`) and the widget controls it over the
// same socket.
//
// The dropdown follows the system theme, and its card surface obeys the
// system window transparency: the alpha tracks the robbie.transparency
// slider via looknfeel.lua's default-opacity rule (see ThemedKeyboardPanel).
// While the dropdown is open during playback, a spectrum analyser fed by
// `cliamp visstream` dances above the station name; the station is shown
// under the title its list entry uses (default list / favourites / search),
// not the raw stream name or URL.
Panel {
  id: root
  moduleName: "robbie.cliamp"
  ipcTarget: "robbie.cliamp"
  manageIpc: true

  readonly property string scriptPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/robbie.cliamp/cliamp.py"
  readonly property string socketPath: Quickshell.env("HOME") + "/.config/cliamp/cliamp.sock"

  // The dropdown paints on a vendored copy of the shared popup card
  // (ThemedKeyboardPanel) so its surface can obey the system transparency:
  // the card colour is the themed popup background with its alpha scaled by
  // the live window-opacity rule from robbie.transparency (looknfeel.lua's
  // default-opacity tag), matching how robbie.cpu-temp-compact's popup
  // behaves. Content uses the popup text token, not the bar's — the bar
  // tokens are contrast-matched to the bar face (and to the wallpaper when
  // the bar is transparent), which is the wrong reference for a popup card.
  property real windowOpacity: 1
  readonly property color popupBackground: Qt.rgba(
    Color.popups.background.r, Color.popups.background.g,
    Color.popups.background.b, Color.popups.background.a * root.windowOpacity)
  readonly property color foreground: Color.popups.text
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Follow the live default-opacity rule, including manual changes from the
  // transparency slider or direct looknfeel.lua edits.
  FileView {
    id: transparencyFile
    path: Quickshell.env("HOME") + "/.config/hypr/looknfeel.lua"
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var match = text().match(/tag\s*=\s*"default-opacity"\s*\}\s*,\s*\{\s*opacity\s*=\s*"([0-9.]+)/)
      root.windowOpacity = match && isFinite(Number(match[1])) ? Math.max(0, Math.min(1, Number(match[1]))) : 1
    }
    onLoadFailed: root.windowOpacity = 1
  }

  // Runtime snapshot, refreshed by pollTimer / socket watcher.
  property bool running: false
  property string pState: "stopped" // "playing" | "paused" | "stopped"
  property string currentTitle: "" // cliamp's logical track title (fallback)
  property string currentPath: ""

  // Display names for the now-playing block. stationName is the title the
  // station lists know the stream by (default list / favourites / search),
  // falling back to cliamp's own title when the stream is unknown. detail
  // carries the ICY now-playing song when the stream reports one, otherwise
  // the stream URL.
  property string stationName: ""
  property string nowDetail: ""
  property string icyTitle: ""
  property string icyArtist: ""

  // Spectrum analyser feed (cliamp visstream NDJSON), consumed only while
  // the dropdown is open and playback is running.
  property var spectrumBands: []
  property bool visSuppressed: false

  // Set when a station or a control is used while cliamp is stopped. The
  // helper starts the headless daemon; the queued action runs as soon as the
  // player socket appears (see applyPoll / launchTimer).
  property string pendingPlayUrl: ""
  property string pendingControl: ""
  property bool launcherArmed: false

  // The station sources. `default` comes from cliamp's streams.m3u,
  // `favorites` from favorites.toml (both delivered by the helper), and
  // `search` from a live Radio Browser (radio-browser.info) query.
  property var defaultStations: []
  property var favorites: []
  property var searchResults: []
  property string stationSource: "default"
  property bool searching: false
  // Last station payload seen in a poll, as JSON: lets applyPoll skip the
  // delegate-destroying rebuild when nothing changed (poll fires every
  // 2.5 s while playing, so rebuilding unconditionally would churn the
  // station Repeater continuously).
  property string lastStationsJson: ""

  // Keyboard-cursor state over the active station list.
  property var stRows: []
  property int cursorIndex: 0

  // Playback state label shown in the dropdown header.
  readonly property bool playing: root.running && (root.pState === "playing" || root.pState === "paused")

  function sourceList() {
    if (root.stationSource === "search") return root.searchResults
    return root.stationSource === "favorites" ? root.favorites : root.defaultStations
  }

  function isFavorite(url) {
    for (var i = 0; i < root.favorites.length; i++)
      if (root.favorites[i].url === url) return true
    return false
  }

  // The name the station lists know a stream by (default list, favourites,
  // search results), matched on the exact URL. Empty when unknown.
  function stationNameFor(url) {
    if (!url) return ""
    var lists = [root.defaultStations, root.favorites, root.searchResults]
    for (var l = 0; l < lists.length; l++) {
      var src = lists[l]
      for (var i = 0; i < src.length; i++)
        if (src[i].url === url) return String(src[i].title || "")
    }
    return ""
  }

  // Refresh the now-playing display names: prefer the list title over
  // cliamp's stream name, and show the ICY now-playing song (when the
  // stream reports one that is not just the station name) in the detail
  // line instead of the raw stream URL.
  function updateNowDisplay() {
    var listed = root.stationNameFor(root.currentPath)
    root.stationName = listed !== "" ? listed : root.currentTitle
    var song = ""
    if (root.icyTitle !== "" && root.icyTitle !== root.stationName) {
      song = root.icyTitle
      if (root.icyArtist !== "" && root.icyTitle.indexOf(root.icyArtist) !== 0)
        song = root.icyArtist + " - " + root.icyTitle
    }
    root.nowDetail = song !== "" ? song : root.currentPath
  }

  function stationRows() {
    var rows = []
    var src = root.sourceList()
    for (var i = 0; i < src.length; i++) {
      var s = src[i]
      var meta = ""
      if (s.country) meta = s.country
      if (s.tags) meta = meta !== "" ? meta + " · " + s.tags : s.tags
      if (s.bitrate) meta = meta !== "" ? meta + " · " + s.bitrate + "k" : s.bitrate + "k"
      rows.push({ kind: "station", title: s.title, url: s.url, active: false, fav: root.isFavorite(s.url), meta: meta })
      if (s.url === root.currentPath) rows[rows.length - 1].active = true
    }
    return rows
  }

  function rebuildStations() {
    root.stRows = root.stationRows()
    if (root.cursorIndex >= root.stRows.length) root.cursorIndex = Math.max(0, root.stRows.length - 1)
    root.updateNowDisplay()
    Qt.callLater(revealRow)
  }

  function currentRow() {
    return (root.cursorIndex >= 0 && root.cursorIndex < root.stRows.length) ? root.stRows[root.cursorIndex] : null
  }

  function moveCursor(step) {
    if (root.stRows.length === 0) return
    var n = root.stRows.length
    root.cursorIndex = (root.cursorIndex + step + n) % n
  }

  function activateRow(row) {
    if (row && row.kind === "station" && row.url) root.playStation(row.url)
  }

  // Type-to-search: any single-character key switches to the Search tab and
  // routes into the search field so it is visible/focused.
  function keyTyped(text) {
    if (!text) return
    if (root.stationSource !== "search") {
      root.stationSource = "search"
      root.rebuildStations()
    }
    searchField.insert(searchField.cursorPosition, text)
    searchField.forceActiveFocus()
  }

  function clickRow(index) {
    if (index < 0 || index >= root.stRows.length) return
    root.cursorIndex = index
    root.activateRow(root.stRows[index])
  }

  function refresh() {
    if (statusProc.running) return
    statusProc.command = ["python3", root.scriptPath, "poll"]
    statusProc.running = false
    statusProc.running = true
  }

  function applyPoll(raw) {
    var d = {}
    try { d = JSON.parse(raw) } catch (e) { d = {} }
    var oldPath = root.currentPath
    var newPath = String(d.path || "")
    // The helper always includes `stations`; compare as JSON so we only
    // rebuild the row delegates (and re-reveal the cursor) when the lists
    // or the active station actually changed.
    var stationsJson = d.stations ? JSON.stringify(d.stations) : ""
    var stationsChanged = stationsJson !== "" && stationsJson !== root.lastStationsJson
    root.running = !!d.running
    root.pState = String(d.state || "stopped")
    root.currentTitle = String(d.title || "")
    root.currentPath = newPath
    root.icyTitle = String(d.track_title || "")
    root.icyArtist = String(d.track_artist || "")
    root.updateNowDisplay()
    if (root.running && root.pendingPlayUrl !== "") {
      var queued = root.pendingPlayUrl
      root.pendingPlayUrl = ""
      root.pendingControl = ""
      root.launcherArmed = false
      root.playStation(queued)
    } else if (root.running && root.pendingControl !== "") {
      var queuedCtrl = root.pendingControl
      root.pendingControl = ""
      root.launcherArmed = false
      root.doControl(queuedCtrl)
    }
    if (stationsChanged) {
      root.lastStationsJson = stationsJson
      if (d.stations.default) root.defaultStations = d.stations.default
      if (d.stations.favorites) root.favorites = d.stations.favorites
    }
    if (stationsChanged || newPath !== oldPath) root.rebuildStations()
  }

  function runSearch() {
    var q = searchField.text.trim()
    if (q === "") {
      root.searching = false
      root.searchResults = []
      if (root.stationSource === "search") root.stationSource = "default"
      root.rebuildStations()
      return
    }
    if (searchProc.running) return
    root.searching = true
    searchProc.command = ["python3", root.scriptPath, "search", q]
    searchProc.running = false
    searchProc.running = true
  }

  function applySearch(raw) {
    root.searching = false
    var d = {}
    try { d = JSON.parse(raw) } catch (e) { d = {} }
    root.searchResults = (d.results || []).map(function(s) {
      return {
        title: String(s.title || ""),
        url: String(s.url || ""),
        country: String(s.country || ""),
        tags: String(s.tags || ""),
        bitrate: Number(s.bitrate) || 0,
        votes: Number(s.votes) || 0
      }
    })
    root.stationSource = "search"
    root.cursorIndex = 0
    root.rebuildStations()
  }

  function doControl(cmd) {
    if (root.running) {
      ctrlProc.command = ["python3", root.scriptPath, "raw", cmd]
      ctrlProc.running = false
      ctrlProc.running = true
      return
    }
    // Nothing is running. Lazy-start the headless daemon and apply the
    // control once it is up. Only play/pause makes sense without a player;
    // prev/next stay gated in the UI.
    if (cmd !== "toggle") return
    root.pendingControl = cmd
    root.ensureStarted()
  }

  // Start cliamp headless (no window) when nothing is running. The queued
  // action (pendingPlayUrl / pendingControl) is applied by applyPoll as soon
  // as the IPC socket appears; launchTimer gives up after a while.
  function ensureStarted() {
    if (root.launcherArmed) return
    root.launcherArmed = true
    launchTimer.restart()
    launchProc.command = ["python3", root.scriptPath, "start"]
    launchProc.running = false
    launchProc.running = true
  }

  // Hand playback over to a cliamp TUI window, in sync with the player: the
  // helper snapshots the live stream, stops the headless daemon (one socket
  // owner only), and launches the terminal UI on the same stream — playing
  // and seeked when the daemon was playing, loaded when it was paused.
  function openWindow() {
    if (openProc.running) return
    openProc.command = ["python3", root.scriptPath, "open"]
    openProc.running = false
    openProc.running = true
    root.close()
  }

  function playStation(url) {
    if (!url) return
    if (root.running) {
      root.pendingPlayUrl = ""
      playProc.command = ["python3", root.scriptPath, "play", url]
      playProc.running = false
      playProc.running = true
      return
    }
    root.pendingPlayUrl = url
    root.ensureStarted()
  }

  function toggleFavorite(url, title) {
    if (!url || favoriteProc.running) return
    favoriteProc.command = ["python3", root.scriptPath, "favorite", url, title || ""]
    favoriteProc.running = false
    favoriteProc.running = true
  }

  function applyFavorite(raw) {
    var d = {}
    try { d = JSON.parse(raw) } catch (e) { d = {} }
    if (d.favorites) root.favorites = d.favorites
    root.rebuildStations()
  }

  function stateLabel() {
    if (root.pState === "playing") return "Playing"
    if (root.pState === "paused") return "Paused"
    return "Stopped"
  }

  function barTooltip() {
    var name = root.stationName !== "" ? root.stationName : root.currentTitle
    if (name !== "") return "Cliamp · " + name
    return "Cliamp"
  }

  function revealRow() {
    if (!stRowsRepeater || !stScroll) return
    if (root.cursorIndex < 0 || root.cursorIndex >= stRowsRepeater.count) return
    var item = stRowsRepeater.itemAt(root.cursorIndex)
    if (!item) return
    var pos = item.mapToItem(stRowsColumn, 0, 0)
    var pad = Style.space(6)
    var top = stScroll.contentY
    var bottom = top + stScroll.height
    if (pos.y < top) stScroll.contentY = Math.max(0, pos.y - pad)
    else if (pos.y + item.height > bottom)
      stScroll.contentY = pos.y + item.height - stScroll.height + pad
  }

  Process {
    id: statusProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPoll(text)
    }
    onExited: function(code, status) {
      if (code !== 0) root.applyPoll("")
    }
  }

  Process {
    id: ctrlProc
    running: false
  }

  Process {
    id: playProc
    running: false
  }

  Process {
    id: launchProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.refresh()
    }
    onExited: function(code, status) {
      root.refresh()
    }
  }

  Process {
    id: openProc
    running: false
    onExited: function(code, status) {
      root.refresh()
    }
  }

  Timer {
    id: launchTimer
    interval: 15000
    repeat: false
    onTriggered: {
      root.launcherArmed = false
      root.pendingPlayUrl = ""
      root.pendingControl = ""
    }
  }

  Process {
    id: favoriteProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFavorite(text)
    }
  }

  // Spectrum feed: cliamp's `visstream` streams one NDJSON frame per line
  // ({"ok":true,"bands":[0..1,...]}). It only runs while the dropdown is
  // open and playback is running, so an idle widget costs nothing. The
  // stream rides on the same IPC socket, so it works headless too.
  Process {
    id: visProc
    running: root.opened && root.pState === "playing" && !root.visSuppressed
    command: ["cliamp", "visstream", "--fps", "15"]
    stdout: SplitParser {
      onRead: function(line) {
        if (!line || line.length > 65536) return
        try {
          var d = JSON.parse(String(line))
          if (d && d.ok) root.spectrumBands = Array.isArray(d.bands) ? d.bands : []
        } catch (e) { }
      }
    }
    onExited: function(code, status) {
      root.spectrumBands = []
      if (root.opened && root.pState === "playing") visRetryTimer.restart()
    }
  }

  // Restart the feed after an unexpected drop (e.g. the daemon died and a
  // poll has not re-evaluated the running binding yet).
  Timer {
    id: visRetryTimer
    interval: 1000
    repeat: false
    onTriggered: {
      root.visSuppressed = true
      Qt.callLater(function() { root.visSuppressed = false })
    }
  }

  Process {
    id: searchProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySearch(text)
    }
    onExited: function(code, status) {
      root.searching = false
    }
  }

  // Watch cliamp's Unix socket so the widget wakes up as soon as the player
  // starts/stops instead of waiting for the slow poll.
  FileView {
    id: sockView
    path: root.socketPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
    onLoaded: root.refresh()
    onLoadFailed: root.refresh()
  }

  Timer {
    id: pollTimer
    interval: root.running ? 2500 : 6000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    id: searchDebounce
    interval: 350
    repeat: false
    onTriggered: root.runSearch()
  }

  onOpenedChanged: {
    if (root.opened) {
      root.rebuildStations()
      Qt.callLater(revealRow)
    }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰝚"
    tooltipText: root.barTooltip()
    active: root.running && !root.opened
    activeColor: root.accent
    onPressed: function(buttonCode) {
      root.toggle()
    }
  }

  ThemedKeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    backgroundColor: root.popupBackground
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.cappedContentHeight(Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx); root.revealRow() }
      onActivateRequested: root.activateRow(root.currentRow())
      onDeleteRequested: root.activateRow(root.currentRow())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.keyTyped(t) }

      Column {
        id: column
        width: parent.width
        height: parent.height
        spacing: 0

        // ---- top spacing
        Item {
          id: topPad
          width: parent.width
          height: Style.space(10)
        }

        // ---- header
        Item {
          id: headerBox
          width: parent.width
          height: headerRow.implicitHeight + Style.space(8)

          Row {
            id: headerRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(8)

            Text {
              id: headerIconText
              text: "󰝚"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: headerTitleText
              text: "Cliamp"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: headerStatusText
              text: root.playing ? root.stateLabel() : (root.launcherArmed ? "Starting cliamp…" : "Not playing")
              color: root.pState === "playing" ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Item {
              id: headerCtrlSpace
              height: parent.height
              width: Math.max(0, parent.width - headerIconText.implicitWidth
                - headerTitleText.implicitWidth - headerStatusText.implicitWidth
                - headerRow.spacing * 3)

              Row {
                id: headerCtrls
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Button {
                  iconText: "󰒮"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX + 2
                  verticalPadding: Style.spacing.controlPaddingY
                  enabled: root.running
                  opacity: enabled ? 1.0 : 0.35
                  tooltipText: "Previous"
                  onClicked: root.doControl("prev")
                }

                Button {
                  iconText: root.pState === "playing" ? "󰏤" : "󰐊"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.panelGap
                  verticalPadding: Style.spacing.controlPaddingY
                  iconSize: Style.font.iconLarge
                  enabled: true
                  tooltipText: root.running ? "Play / Pause" : "Start cliamp"
                  onClicked: root.doControl("toggle")
                }

                Button {
                  iconText: "󰒭"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX + 2
                  verticalPadding: Style.spacing.controlPaddingY
                  enabled: root.running
                  opacity: enabled ? 1.0 : 0.35
                  tooltipText: "Next"
                  onClicked: root.doControl("next")
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- now playing
        Item {
          id: nowBox
          width: parent.width
          height: nowColumn.implicitHeight + Style.space(8)

          Column {
            id: nowColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(3)

            // Spectrum analyser above the station name; fed by visstream and
            // only present while playback runs (see visProc).
            Item {
              id: spectrumBox
              width: parent.width
              height: visible ? Style.space(16) : 0
              visible: root.spectrumBands.length > 0

              Repeater {
                model: root.spectrumBands.length > 0 ? root.spectrumBands : []

                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  x: index * (spectrumBox.width / root.spectrumBands.length)
                  width: Math.max(1, spectrumBox.width / root.spectrumBands.length - Style.space(2))
                  height: Math.max(Style.space(1), Math.min(1, Number(modelData) || 0) * spectrumBox.height)
                  anchors.bottom: parent.bottom
                  color: root.accent
                  opacity: 0.85
                  Behavior on height { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.stationName !== "" ? root.stationName : "Nothing playing yet"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: root.stationName !== ""
              elide: Text.ElideRight
              visible: text !== ""
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.nowDetail !== "" ? root.nowDetail : "Pick a station below"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              visible: text !== ""
            }
          }
        }

        // ---- station source tabs
        Item {
          id: chipsBox
          width: parent.width
          height: chipsRow.implicitHeight + Style.space(8)

          Row {
            id: chipsRow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "Default"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              selected: root.stationSource === "default"
              horizontalPadding: Style.spacing.controlPaddingX + 4
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                root.stationSource = "default"
                root.cursorIndex = 0
                root.rebuildStations()
              }
            }

            Button {
              text: root.searchResults.length > 0
                ? "Search (" + root.searchResults.length + ")"
                : "Search"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              selected: root.stationSource === "search"
              horizontalPadding: Style.spacing.controlPaddingX + 4
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                root.stationSource = "search"
                root.cursorIndex = 0
                root.rebuildStations()
                searchField.forceActiveFocus()
              }
            }

            Button {
              text: "Favourites (" + root.favorites.length + ")"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              selected: root.stationSource === "favorites"
              horizontalPadding: Style.spacing.controlPaddingX + 4
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                root.stationSource = "favorites"
                root.cursorIndex = 0
                root.rebuildStations()
              }
            }
          }
        }

        // ---- radio directory search (shown only on the Search tab)
        Item {
          id: searchBox
          visible: root.stationSource === "search"
          width: parent.width
          height: visible ? searchRow.implicitHeight + Style.space(8) : 0

          Row {
            id: searchRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(8)

            Text {
              id: searchIcon
              text: "󰛉"
              color: root.searching ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            TextField {
              id: searchField
              width: parent.width - searchIcon.implicitWidth - searchRow.spacing
              height: Style.space(26)
              verticalPadding: Math.max(2, Style.spacing.inputPaddingY - 4)
              accent: root.accent
              foreground: root.foreground
              placeholderText: root.searching ? "Searching…" : "Search radio stations…"
              onTextChanged: searchDebounce.restart()
              onAccepted: {
                searchDebounce.stop()
                root.runSearch()
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- picker
        Flickable {
          id: stScroll
          width: parent.width
          height: column.height - topPad.height - headerBox.height - nowBox.height
            - searchBox.height - chipsBox.height - footerBox.height - Style.space(2)
          clip: true
          contentWidth: width
          contentHeight: stRowsColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
            width: 6
          }

          Column {
            id: stRowsColumn
            width: parent.width
            spacing: 0

            Repeater {
              id: stRowsRepeater
              model: root.stRows

              delegate: Item {
                id: stRowItem
                required property var modelData
                required property int index

                readonly property var row: modelData
                readonly property bool hasCursor: root.cursorIndex === index
                readonly property bool isActive: row ? !!row.active : false
                readonly property bool hasMeta: row ? !!row.meta : false
                readonly property bool isFav: row ? !!row.fav : false

                width: stRowsColumn.width
                height: (stRowItem.hasMeta ? Style.space(40) : Style.spacing.popupRowHeight) + Style.space(4)

                Rectangle {
                  anchors.fill: parent
                  anchors.margins: Style.space(2)
                  radius: Style.cornerRadius
                  color: stRowItem.hasCursor
                    ? Style.hoverFillFor(root.foreground, root.accent)
                    : "transparent"

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: {
                      if (root.cursorIndex !== stRowItem.index) root.cursorIndex = stRowItem.index
                    }
                    onClicked: root.clickRow(stRowItem.index)
                  }
                }

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(8)

                  Text {
                    width: Style.space(18)
                    textFormat: Text.PlainText
                    text: stRowItem.isActive ? "󰐊" : ""
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Column {
                    width: parent.width - Style.space(18) - Style.space(8)
                      - favBtn.width - Style.space(8)
                      - (stRowItem.isActive ? playingTag.width + Style.space(8) : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: stRowItem.row ? String(stRowItem.row.title || "") : ""
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: stRowItem.isActive
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      visible: stRowItem.hasMeta
                      textFormat: Text.PlainText
                      text: stRowItem.hasMeta ? String(stRowItem.row.meta || "") : ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Item {
                    id: favBtn
                    width: Style.space(20)
                    height: Style.space(20)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: stRowItem.row ? !!stRowItem.row.url : false

                    Text {
                      anchors.centerIn: parent
                      text: stRowItem.isFav ? "󰃂" : "󰃃"
                      color: stRowItem.isFav ? root.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      hoverEnabled: true
                      onEntered: {
                        if (root.cursorIndex !== stRowItem.index) root.cursorIndex = stRowItem.index
                      }
                      onClicked: {
                        if (stRowItem.row && stRowItem.row.url)
                          root.toggleFavorite(stRowItem.row.url, stRowItem.row.title)
                      }
                      PanelToolTip {
                        visible: parent.containsMouse
                        text: stRowItem.isFav ? "Remove from favourites" : "Add to favourites"
                      }
                    }
                  }

                  Text {
                    id: playingTag
                    visible: stRowItem.isActive
                    textFormat: Text.PlainText
                    text: "playing"
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }
        }

        // ---- footer
        Item {
          id: footerBox
          width: parent.width
          height: footerColumn.implicitHeight + Style.space(8)

          Column {
            id: footerColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(2)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                id: footerLabel
                width: parent.width - openCliampBtn.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Click a row to play · bookmark toggles favourites · Esc closes"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Button {
                id: openCliampBtn
                text: "Open Cliamp"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX + 4
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Open the Cliamp window"
                onClicked: root.openWindow()
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.StyledText
              text: "<a href=\"https://github.com/bjarneo/cliamp\">Cliamp player by bjarneo · cliamp.stream</a>"
              color: root.foreground
              linkColor: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              onLinkActivated: function(link) {
                Quickshell.execDetached(["/usr/bin/xdg-open", link])
              }
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}