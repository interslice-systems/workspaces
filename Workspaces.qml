import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "WorkspaceMenuModel.js" as WorkspaceMenuModel

// interslice.workspaces -- the top bar's host/menu + workspace switcher, drawn to read as one
// system with the tmux status bar one layer up the tree:
//
//     |[omarchy] nexus )   ( 1·omni-space )   ( 2·mirepoix )
//
// Pills are NATIVE rounded Rectangles (radius = height/2 -> true semicircular ends),
// NOT emulated powerline half-circle glyphs. The glyph-cap approach broke at the seam:
// a cap glyph is sized by font metrics, the body by layout, and the two never matched.
// A Rectangle's rounded corners always align. (LCARS is rounded rectangles anyway.)
//
// The HOST CAPSULE is also the Omarchy menu button: flat left edge (square left corners,
// rounded right), the Omarchy mark + hostname, filled in the hostname's colorhash.
// Left-click opens the menu, right-click a terminal (the stock omarchy.menu affordances,
// folded in so the separate menu square can leave shell.json). Then one entry per
// workspace Hyprland reports: FOCUSED is a rounded pill, others are flat text, each
// "id·name" (just the id when unnamed) -- workspaces treated like tmux windows.
//
// Colour is the colorhash contract (~/.config/colorhash/palette.json): FNV-1a 32-bit of
// the UTF-8 NFC name mod the cell count, the same function the tmux bar, operator and
// workspace-identity-lib use, so every surface agrees by derivation. Palette missing ->
// theme foreground, names still render.
//
// ATTENTION BUBBLES UP THE TREE, AND THE COMPOSITOR DOES THE BOOKKEEPING. A bell anywhere
// inside a workspace (a Claude, a tmux window via bell-action any, a bare terminal) flags
// the workspace -- read straight off HyprlandWorkspace.urgent, Quickshell's view of
// Hyprland's own per-window urgency hint. The chain is all primitives: BEL (1870) ->
// terminal -> xdg-system-bell / xdg-activation -> Hyprland `urgent>>` -> this property.
// Verified 2026-08-26 on Hyprland 0.56.2 + Quickshell 0.3.1, foot AND kitty: true on ring,
// false when the window closes, false when you focus the workspace. An earlier version
// kept its own address ledger from the raw `urgent>>`/`bell>>` events, on the (then true)
// finding that foot's bell never set the flag; 0.56 emits `urgent>>` for foot too, so the
// ledger only ever won the race by one event and was deleted. An urgent entry wedges a
// bell after the id.
//
// THE BELL ASSERTS NO COLOUR OF ITS OWN. An urgent entry keeps the colour of its NAME --
// attention is the glyph, identity is the colour, and the two channels stay separate.
// This entry used to repaint to the theme's urgent colour on a bell, which read as the
// pill "recalculating its hash" every time a Claude finished. Colour here is keyed to a
// string the user chose; anything transient that repaints it makes it useless for
// recognition. Same rule and same reasoning as @sb_mark in statusbar.conf, where coloured
// markers were tried and abandoned (under retro-82 ANSI red and yellow are both orange,
// and the wsid hashes collide with both -- a marker could be camouflaged by the very
// workspace it marked).
//
// HIT BOXES ARE FULL BAR HEIGHT, PAINT IS NOT. Each pill is inset to 80% of the bar so
// the ground shows above and below it, but its MouseArea lives on the full-height wrapper
// Item, declared after the pill so it stacks on top. That puts the target flush against
// the top edge of the screen, where the pointer cannot overshoot it -- Fitts's law makes
// an edge target effectively infinitely deep, which is why the stock widgets feel
// clickable at the top pixel and hand-drawn pills did not. (The stock ones get it for
// free: Ui/WidgetButton.qml sets implicitHeight to barSize on a horizontal bar and fills
// it with a MouseArea.)
//
// RIGHT-CLICK A PILL FOR ITS WINDOW MENU. WsMenu.qml slides down under the
// clicked pill listing that workspace's tmux windows and bare toplevels (see
// that file for the data contract; it replaced a hover-the-whole-switcher
// tree card the same week -- deliberate gesture beat dwell timers). The tmux
// snapshot is fetched here, one-shot, on open -- no polling, no standing cost.
//
// SUPER+ALT+N LANDS HERE TOO. ws-rename summons RenameDialog.qml through
// `omarchy-shell shell summon interslice.workspaces`, which routes to the
// open/close/opened trio below (Bar.findPanelWidget's contract). The dialog
// previews; `ws-rename --apply` decides. If the shell is down, ws-rename
// falls back to the plain omarchy-menu-input prompt.
//
// Glyphs: U+E900 Omarchy mark (the shell's own "omarchy" font), U+F0F3 bell, U+00B7 middot.
BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  // --- colorhash ------------------------------------------------------------
  property var cells: []
  property string hostname: ""

  FileView {
    path: Quickshell.env("HOME") + "/.config/colorhash/palette.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var doc = JSON.parse(text())
        root.cells = (doc && doc.cells && doc.cells.length) ? doc.cells : []
      } catch (e) { root.cells = [] }
    }
    onLoadFailed: root.cells = []
  }

  FileView {
    path: "/etc/hostname"
    printErrors: false
    onLoaded: root.hostname = String(text()).trim().split(".")[0]
    onLoadFailed: root.hostname = Quickshell.env("HOSTNAME") || "host"
  }

  function fnv1a32(s) { return WorkspaceMenuModel.fnv1a32(s) }
  function cellFor(name) {
    if (!root.cells.length) return null
    return root.cells[root.fnv1a32(name) % root.cells.length]
  }

  readonly property color ground: root.bar ? root.bar.background : Color.background
  readonly property color plainFg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property bool lightTheme: (0.2126 * ground.r + 0.7152 * ground.g + 0.0722 * ground.b) > 0.5

  function fillFor(name) { var c = cellFor(name); return c ? c.bg : root.plainFg }
  function fillTextFor(name) { var c = cellFor(name); return c ? c.bgText : root.ground }
  function flatFgFor(name) { var c = cellFor(name); return c ? (root.lightTheme ? c.lightFg : c.darkFg) : root.plainFg }

  // --- workspaces -----------------------------------------------------------
  function workspaceList() {
    var out = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var w = values[i]
      if (w.id > 0 && w.id <= 10) out.push(w)
    }
    out.sort(function(a, b) { return a.id - b.id })
    return out
  }
  function wsName(w) {
    var n = String(w.name || "")
    return (n === "" || n === String(w.id)) ? "" : n
  }
  function wsLabel(w, urgent) {
    var nm = root.wsName(w)
    var mark = urgent ? root.bellGlyph : ""
    return String(w.id) + mark + (nm ? "·" + nm : "")
  }
  function wsKey(w) { var nm = root.wsName(w); return nm ? nm : String(w.id) }

  readonly property string bellGlyph: "\uf0f3"

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }
  function focusTmuxWindow(session, idx, wsId) {
    if (!root.bar) return
    root.bar.run("tmux select-window -t " + Util.shellQuote("=" + session + ":" + idx))
    root.focusWorkspace(wsId)
  }
  function focusToplevel(toplevel, workspaceId) {
    if (toplevel && toplevel.wayland && typeof toplevel.wayland.activate === "function")
      toplevel.wayland.activate()
    else root.focusWorkspace(workspaceId)
  }
  function openMenu() { if (root.bar) root.bar.run("omarchy-shell shell toggle omarchy.menu '{\"menu\":\"root\"}'") }
  function openTerminal() { if (root.bar) root.bar.run("xdg-terminal-exec") }

  // --- hover card: tmux snapshot, fetched one-shot on hover-open ------------
  // tmuxWindows: session name -> [{session, idx, name, bell, star}]. star is
  // @sb_mark's derivation (statusbar.conf): a U+2733-prefixed pane_title
  // anywhere in the window means a Claude awaits input; bell beats star.
  // tmuxAddrs: Hyprland window address -> session, from tmux-local-clients --
  // the addresses the hover card must NOT list as bare windows.
  property var tmuxWindows: ({})
  property var tmuxAddrs: ({})
  property bool tmuxWindowsReady: false
  property bool tmuxClientsReady: false
  property bool tmuxLoading: false

  Process {
    id: tmuxWinProc
    command: ["tmux", "list-windows", "-a", "-F",
      "#{session_name}\u001f#{window_index}\u001f#{window_name}\u001f#{window_bell_flag}\u001f#{P:|#{pane_title}}"]
    stdout: StdioCollector {
      onStreamFinished: {
        var map = {}
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
          if (lines[i] === "") continue
          var p = lines[i].split("\u001f")
          if (p.length < 5) continue
          var w = { session: p[0], idx: parseInt(p[1], 10), name: p[2],
                    bell: p[3] === "1",
                    star: p.slice(4).join("\u001f").indexOf("|✳") !== -1 }
          if (!map[w.session]) map[w.session] = []
          map[w.session].push(w)
        }
        root.tmuxWindows = map
        root.tmuxWindowsReady = true
        root.finishTmuxRefresh()
      }
    }
  }

  Process {
    id: tmuxClientsProc
    command: [Quickshell.env("HOME") + "/.local/bin/tmux-local-clients"]
    stdout: StdioCollector {
      onStreamFinished: {
        var map = {}
        try {
          var arr = JSON.parse(text)
          for (var i = 0; i < arr.length; i++)
            if (arr[i].address) map[String(arr[i].address)] = String(arr[i].session)
        } catch (e) {}
        root.tmuxAddrs = map
        root.tmuxClientsReady = true
        root.finishTmuxRefresh()
      }
    }
  }

  function finishTmuxRefresh() {
    if (root.tmuxWindowsReady && root.tmuxClientsReady) root.tmuxLoading = false
  }

  function prepareTmuxRefresh() {
    root.tmuxLoading = true
    root.tmuxWindowsReady = false
    root.tmuxClientsReady = false
  }

  function startTmuxRefresh() {
    if (!wsMenu.open) return
    tmuxWinProc.running = true
    tmuxClientsProc.running = true
  }

  function refreshTmux() {
    root.prepareTmuxRefresh()
    root.startTmuxRefresh()
  }

  // --- Firefox snapshot: one bounded request per applicable popup open -------
  readonly property string firefoxBridgePath:
    Quickshell.env("HOME") + "/.local/bin/omarchy-firefox-bridge"
  property var firefoxTabs: []
  property bool firefoxApplicable: false
  property bool firefoxLoading: false
  property int firefoxGeneration: 0
  property bool firefoxRestartPending: false
  property bool firefoxOutputReady: false
  property bool firefoxExitReady: false
  property int firefoxExitCode: -1
  property string firefoxRawOutput: ""
  readonly property bool menuLoading: root.tmuxLoading || root.firefoxLoading

  function workspaceHasFirefox(w) {
    try {
      if (!w || !w.toplevels) return false
      var values = w.toplevels.values
      if (!values || typeof values.length !== "number") return false
      var length = values.length
      if (!isFinite(length) || Math.floor(length) !== length || length < 0) return false
      var firefoxFound = false
      for (var i = 0; i < length; i++) {
        var toplevel = values[i]
        if (!toplevel || typeof toplevel !== "object") return false
        var ipc = toplevel.lastIpcObject
        if (!ipc || typeof ipc !== "object") return false
        if (WorkspaceMenuModel.isFirefoxClass(String(ipc["class"] || ""))) firefoxFound = true
      }
      return firefoxFound
    } catch (e) {
      return false
    }
  }

  function clearFirefoxSnapshot() {
    root.firefoxGeneration++
    root.firefoxTabs = []
    root.firefoxApplicable = false
    root.firefoxLoading = false
    root.firefoxRestartPending = false
    root.firefoxOutputReady = false
    root.firefoxExitReady = false
    root.firefoxExitCode = -1
    root.firefoxRawOutput = ""
    if (firefoxTabsProc.running) firefoxTabsProc.running = false
  }

  function startFirefoxRefresh() {
    if (!wsMenu.open || !root.firefoxApplicable || firefoxTabsProc.running) return
    root.firefoxRestartPending = false
    root.firefoxOutputReady = false
    root.firefoxExitReady = false
    root.firefoxExitCode = -1
    root.firefoxRawOutput = ""
    firefoxTabsProc.requestGeneration = root.firefoxGeneration
    firefoxTabsProc.running = true
  }

  function prepareFirefoxRefresh(w) {
    root.firefoxGeneration++
    root.firefoxTabs = []
    root.firefoxApplicable = root.workspaceHasFirefox(w)
    root.firefoxLoading = root.firefoxApplicable
    root.firefoxOutputReady = false
    root.firefoxExitReady = false
    root.firefoxExitCode = -1
    root.firefoxRawOutput = ""
    if (firefoxTabsProc.running) {
      root.firefoxRestartPending = root.firefoxApplicable
      firefoxTabsProc.running = false
      return
    }
    root.firefoxRestartPending = false
  }

  function finishFirefoxRefresh() {
    if (!root.firefoxOutputReady || !root.firefoxExitReady) return

    if (firefoxTabsProc.requestGeneration !== root.firefoxGeneration) {
      if (root.firefoxRestartPending && root.firefoxApplicable && wsMenu.open) {
        var restartGeneration = root.firefoxGeneration
        Qt.callLater(function() {
          if (root.firefoxRestartPending && root.firefoxApplicable && wsMenu.open
              && restartGeneration === root.firefoxGeneration) {
            root.startFirefoxRefresh()
          }
        })
      }
      return
    }

    root.firefoxLoading = false
    if (!wsMenu.open || root.firefoxExitCode !== 0) {
      root.firefoxTabs = []
      return
    }

    var parsed = WorkspaceMenuModel.parseSnapshot(root.firefoxRawOutput)
    root.firefoxTabs = parsed === null ? [] : parsed
  }

  Process {
    id: firefoxTabsProc
    property int requestGeneration: -1
    command: ["/usr/bin/env", root.firefoxBridgePath, "tabs"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!wsMenu.open) return
        if (firefoxTabsProc.requestGeneration !== root.firefoxGeneration && !root.firefoxRestartPending) return
        root.firefoxRawOutput = firefoxTabsProc.requestGeneration === root.firefoxGeneration
          ? String(text || "") : ""
        root.firefoxOutputReady = true
        root.finishFirefoxRefresh()
      }
    }
    // qmllint disable signal-handler-parameters
    onExited: function(exitCode) {
      if (!wsMenu.open) return
      if (firefoxTabsProc.requestGeneration !== root.firefoxGeneration && !root.firefoxRestartPending) return
      root.firefoxExitCode = exitCode
      root.firefoxExitReady = true
      root.finishFirefoxRefresh()
    }
    // qmllint enable signal-handler-parameters
    // Normal completion emits exited before runningChanged; exitReady keeps
    // this fallback exclusive to FailedToStart and equivalent missing exits.
    onRunningChanged: {
      if (firefoxTabsProc.running || root.firefoxExitReady) return
      if (!wsMenu.open) return
      if (firefoxTabsProc.requestGeneration !== root.firefoxGeneration && !root.firefoxRestartPending) return
      root.firefoxRawOutput = ""
      root.firefoxOutputReady = true
      root.firefoxExitCode = -1
      root.firefoxExitReady = true
      root.finishFirefoxRefresh()
    }
  }

  property bool firefoxActivating: false
  property var firefoxActivationTop: null
  property int firefoxActivationWorkspaceId: -1
  property int firefoxActivationGeneration: -1

  function finishFirefoxActivation(exitCode) {
    if (!root.firefoxActivating) return

    var toplevel = root.firefoxActivationTop
    var workspaceId = root.firefoxActivationWorkspaceId
    var activationGeneration = root.firefoxActivationGeneration
    root.firefoxActivating = false
    root.firefoxActivationTop = null
    root.firefoxActivationWorkspaceId = -1
    root.firefoxActivationGeneration = -1

    root.focusToplevel(toplevel, workspaceId)
    if (wsMenu.open && root.firefoxGeneration === activationGeneration
        && wsMenu.targetId === workspaceId) wsMenu.close()
  }

  function activateFirefoxTab(windowId, tabId, toplevel, workspaceId) {
    if (!Number.isInteger(windowId) || windowId <= 0 || windowId > 9007199254740991
        || !Number.isInteger(tabId) || tabId <= 0 || tabId > 9007199254740991) {
      root.focusToplevel(toplevel, workspaceId)
      if (wsMenu.open && wsMenu.targetId === workspaceId) wsMenu.close()
      return
    }
    if (root.firefoxActivating || firefoxActivateProc.running) return

    root.firefoxActivating = true
    root.firefoxActivationTop = toplevel
    root.firefoxActivationWorkspaceId = workspaceId
    root.firefoxActivationGeneration = root.firefoxGeneration
    firefoxActivateProc.command = ["/usr/bin/env", root.firefoxBridgePath, "activate", String(windowId), String(tabId)]
    firefoxActivateProc.running = true
  }

  Process {
    id: firefoxActivateProc
    command: []
    // qmllint disable signal-handler-parameters
    onExited: function(exitCode) { root.finishFirefoxActivation(exitCode) }
    // qmllint enable signal-handler-parameters
    onRunningChanged: {
      if (!firefoxActivateProc.running && root.firefoxActivating)
        root.finishFirefoxActivation(-1)
    }
  }

  // Keep the snapshot honest WHILE the menu is showing: a bell that rings with
  // it open re-fetches the tmux half, so window_bell_flag/✳ marks appear live
  // instead of on the next open. Gated on the menu -- closed, zero listeners
  // doing work. Both event spellings, same as operatord (foot rings bell>>,
  // kitty urgent>>).
  Connections {
    target: Hyprland
    enabled: wsMenu.open
    function onRawEvent(event) {
      if (event.name === "bell" || event.name === "urgent") root.refreshTmux()
    }
  }

  // Right-click a workspace pill -> WsMenu slides down under it with that
  // workspace's windows. No dwell timers, no grace periods: the gesture is
  // deliberate, and PopupCard's click mode dismisses on any outside click via
  // HyprlandFocusGrab. Right-clicking the same pill again toggles it closed;
  // a different pill retargets (close, re-anchor next tick, reopen -- a live
  // PopupWindow does not re-anchor on anchorItem reassignment alone).
  function showWsMenu(item, w) {
    wsMenu.targetWs = w
    wsMenu.anchorItem = item
    root.prepareTmuxRefresh()
    root.prepareFirefoxRefresh(w)
    wsMenu.open = true
    root.startTmuxRefresh()
    root.startFirefoxRefresh()
  }

  function toggleWsMenu(item, w) {
    if (wsMenu.open && wsMenu.targetId === w.id) {
      wsMenu.open = false
      return
    }
    root.renameOpen = false
    if (wsMenu.open) {
      wsMenu.open = false
      Qt.callLater(function() { root.showWsMenu(item, w) })
    } else {
      root.showWsMenu(item, w)
    }
  }

  WsMenu {
    id: wsMenu
    ws: root
    anchorItem: root
    bar: root.bar
    onOpenChanged: if (!open) root.clearFirefoxSnapshot()
  }

  // --- rename dialog: the summonable panel (SUPER+ALT+N via ws-rename) -----
  // open/close/opened is Bar.findPanelWidget's shape contract; summon routes
  // here. Opening kicks off the cwd/git name suggestion and parks the hover
  // card -- two popups at once would fight over the same anchor.
  property bool renameOpen: false
  readonly property bool opened: renameOpen
  function open() {
    wsMenu.open = false
    root.renameSuggestion = ""
    suggestProc.running = true
    root.renameOpen = true
  }
  function close() { root.renameOpen = false }
  function toggle() { root.renameOpen ? root.close() : root.open() }

  property string renameSuggestion: ""
  Process {
    id: suggestProc
    command: [Quickshell.env("HOME") + "/.local/bin/ws-name-suggest"]
    stdout: StdioCollector {
      onStreamFinished: root.renameSuggestion = String(text).trim()
    }
  }

  // Preview mirror of wsid_session_name (workspace-identity-lib). Display
  // only -- ws-rename --apply re-runs the real sanitizer and guards.
  function sanitizeName(s) {
    s = String(s).replace(/[.:\/#]/g, "-").replace(/[\x01-\x20\x7f]/g, "-")
    while (s.indexOf("--") !== -1) s = s.replace(/--/g, "-")
    return s.replace(/^-+/, "").replace(/-+$/, "")
  }

  function applyRename(raw) {
    if (root.bar) root.bar.run(Quickshell.env("HOME") + "/.local/bin/ws-rename --apply " + Util.shellQuote(raw))
    root.renameOpen = false
  }

  RenameDialog {
    id: renameDialog
    ws: root
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.renameOpen
  }

  // --- sizing: pills inset vertically so the bar ground shows top and bottom -------
  // Match the terminal/tmux bar (kitty is 0xProto Nerd Font) rather than the shell
// bar's monospace default (JetBrainsMono NF). The Omarchy mark keeps its own
// "omarchy" font (U+E900 lives only there).
  readonly property string nerdFamily: "0xProto Nerd Font"
  readonly property real pillH: Math.round(root.barSize * 0.80)
  readonly property real roundPad: Math.round(root.pillH * 0.5)   // clears the rounded end
  readonly property real flatPad: Math.round(root.pillH * 0.42)
  readonly property int labelPx: Style.font.body
  // The stock bar reserves Style.space(8) before every left-side module. The
  // host capsule is deliberately flat on its left edge, so let this widget
  // occupy that margin while keeping its right edge where it was.
  readonly property real leftBleed: Style.space(8)

  implicitWidth: row.implicitWidth + Style.spaceReal(1.5)
  implicitHeight: root.barSize

  // A native rounded pill. leftCap=false squares the left corners (host capsule).
  component Pill: Rectangle {
    property bool leftCap: true
    property string glyph: ""
    property string glyphFamily: root.nerdFamily
    property string label: ""
    property color textColor

    implicitHeight: root.pillH
    implicitWidth: body.implicitWidth + (leftCap ? root.roundPad : root.flatPad) + root.roundPad
    topRightRadius: height / 2
    bottomRightRadius: height / 2
    topLeftRadius: leftCap ? height / 2 : 0
    bottomLeftRadius: leftCap ? height / 2 : 0

    Row {
      id: body
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: parent.leftCap ? root.roundPad : root.flatPad
      spacing: Style.spaceReal(3)   // glyph-to-label gap (host capsule; workspaces have no glyph)
      Text {
        visible: text !== ""
        text: parent.parent.glyph
        color: parent.parent.textColor
        font.family: parent.parent.glyphFamily
        font.pixelSize: root.labelPx
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: parent.parent.label
        color: parent.parent.textColor
        font.family: root.nerdFamily
        font.pixelSize: root.labelPx
        font.bold: true
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  Row {
    id: row
    x: -root.leftBleed
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spaceReal(1)

    // Host / Omarchy-menu capsule: flat left, omarchy mark + hostname, rounded right.
    // Wrapped in a barSize-tall Item and vertical-centred, exactly like the workspace
    // entries below -- otherwise the Row top-aligns it and it rides high of the pills.
    Item {
      implicitWidth: hostPill.implicitWidth
      height: root.barSize
      Pill {
        id: hostPill
        anchors.verticalCenter: parent.verticalCenter
        leftCap: false
        glyph: ""
        glyphFamily: "omarchy"
        label: root.hostname
        color: root.fillFor(root.hostname)
        textColor: root.fillTextFor(root.hostname)
      }
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) { if (mouse.button === Qt.RightButton) root.openTerminal(); else root.openMenu() }
      }
    }

    Item { width: Style.spaceReal(5); height: 1 }

    Repeater {
      model: root.workspaceList()

      Item {
        id: entry
        required property var modelData
        required property int index
        readonly property bool focused: modelData.focused
        readonly property bool urgent: modelData.urgent

        width: focused ? pill.implicitWidth : flat.implicitWidth
        height: root.barSize

        Pill {
          id: pill
          anchors.verticalCenter: parent.verticalCenter
          visible: entry.focused
          label: root.wsLabel(entry.modelData, false)
          color: root.fillFor(root.wsKey(entry.modelData))
          textColor: root.fillTextFor(root.wsKey(entry.modelData))
        }

        Item {
          id: flat
          anchors.verticalCenter: parent.verticalCenter
          visible: !entry.focused
          implicitWidth: flatText.implicitWidth + root.roundPad * 2
          implicitHeight: root.pillH
          Text {
            id: flatText
            anchors.centerIn: parent
            text: root.wsLabel(entry.modelData, entry.urgent)
            color: root.flatFgFor(root.wsKey(entry.modelData))
            font.family: root.nerdFamily
            font.pixelSize: root.labelPx
            font.bold: true
            renderType: Text.NativeRendering
          }
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) root.toggleWsMenu(entry, entry.modelData)
            else root.focusWorkspace(entry.modelData.id)
          }
        }
      }
    }

    // Balance the left bleed so the last workspace keeps its existing edge.
    Item { width: root.leftBleed; height: 1 }
  }
}
