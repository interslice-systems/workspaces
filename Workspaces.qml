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

  // --- ws-blackbox overlay ---------------------------------------------------
  // bin/ws-blackbox (a 1-minute user timer) writes ledger.json + heartbeat.json atomically.
  // FileView watches them via inotify -- no polling. Absent files = recorder not installed =
  // this widget behaves exactly as before.
  readonly property string blackboxDir: Quickshell.env("HOME") + "/.local/state/ws-blackbox"
  property var ledger: null
  property var heartbeat: null
  property string bootId8: ""
  property real nowSec: Date.now() / 1000

  FileView {
    path: root.blackboxDir + "/ledger.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.ledger = WorkspaceMenuModel.parseLedger(text())
    onLoadFailed: root.ledger = null
  }

  FileView {
    path: root.blackboxDir + "/heartbeat.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.heartbeat = WorkspaceMenuModel.parseHeartbeat(text())
    onLoadFailed: root.heartbeat = null
  }

  Process {
    running: true
    command: ["cat", "/proc/sys/kernel/random/boot_id"]
    stdout: StdioCollector {
      onStreamFinished: root.bootId8 = String(text).trim().replace(/-/g, "").slice(0, 8)
    }
  }

  // The overlay's one standing cost: a 60 s tick, so "recorder stopped" can appear when the
  // heartbeat stops changing. Bindings only repaint when the stale state or text flips.
  Timer {
    interval: 60000
    running: root.heartbeat !== null
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  readonly property var recorder: WorkspaceMenuModel.recorderStatus(root.heartbeat, root.nowSec)
  // Memoized: the ledger is rewritten whenever a Claude flips busy/idle, and a fresh array
  // here would rebuild every bar pill each time. Reassign only when the ghosts really change
  // (a ledger write, or a workspace appearing / disappearing / being renamed).
  property var ghostList: []
  readonly property string liveNamesKey: JSON.stringify(Object.keys(root.liveWorkspaceNames()).sort())
  function refreshGhosts() {
    var next = WorkspaceMenuModel.ghostWorkspaces(root.ledger, root.liveWorkspaceNames())
    if (JSON.stringify(next) !== JSON.stringify(root.ghostList)) root.ghostList = next
  }
  onLedgerChanged: root.refreshGhosts()
  onLiveNamesKeyChanged: root.refreshGhosts()

  function liveWorkspaceNames() {
    var out = Object.create(null)
    var list = root.workspaceList()
    for (var i = 0; i < list.length; i++) {
      var nm = root.wsName(list[i])
      if (nm) out[nm] = true
    }
    return out
  }

  // argv runner (bash -lc 'exec "$@"'): names never pass through a shell parser. Runs as a
  // child of this shell, i.e. inside wayland-wm@hyprland.desktop.service.
  function blackbox(args) {
    Util.execArgv([Quickshell.env("HOME") + "/.local/bin/ws-blackbox"].concat(args))
    blackboxRefresh.restart()
  }
  Timer { id: blackboxRefresh; interval: 1500; onTriggered: root.refreshTmux() }

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
  // THE PILL EXPOSES ONLY THE BELL, deliberately -- not the Claude states the menu
  // shows. A workspace aggregates every window inside it, so ten Claudes would report
  // ten statuses into one slot. The pill answers "something in here rang"; the menu
  // answers "what, exactly". Placement matches the tmux bar as of 2026-09-16: after the
  // middot, one space before the name.
  function wsLabel(w, urgent) {
    return WorkspaceMenuModel.wsBarLabel(w.id, root.wsName(w), urgent)
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
  // tmuxWindows: session name -> [{session, idx, name, bell, state}]. state is the
  // pane option @claude_state (blocked/idle/waiting/busy), reduced across the window's
  // panes by WorkspaceMenuModel.tmuxWindowState with the bar's own priority.
  //
  // This replaced a U+2733-prefixed pane_title scrape on 2026-09-16. That rule had been
  // DEAD since Claude Code 2.1.267: a GrowthBook flag forces a static U+2733 into the
  // title whenever $TMUX is set, so every Claude window matched, always. The state now
  // comes from Claude Code's hooks via ~/oracle/scripts/claude-attn.
  // tmuxAddrs: Hyprland window address -> session, from tmux-local-clients --
  // the addresses the hover card must NOT list as bare windows.
  property var tmuxWindows: ({})
  property var tmuxAddrs: ({})
  property bool tmuxWindowsReady: false
  property bool tmuxClientsReady: false
  property bool tmuxLoading: false

  // The fetch also carries window ids, the server's pid/start_time (the ws-blackbox key) and
  // each pane's current command. Exit status matters: "no server running" is a valid empty
  // world (everything recorded is gone); any other failure must not make ghosts of everything.
  property var tmuxLiveKeys: ({})
  property bool tmuxLiveValid: false
  property string tmuxWinOut: ""
  property string tmuxWinErr: ""
  property int tmuxWinExitCode: -1
  property bool tmuxWinOutReady: false
  property bool tmuxWinErrReady: false
  property bool tmuxWinExitReady: false

  Process {
    id: tmuxWinProc
    command: ["tmux", "-N", "list-windows", "-a", "-F",
      "#{session_name}\u001f#{window_index}\u001f#{window_name}\u001f#{window_bell_flag}\u001f#{window_id}\u001f#{pid}\u001f#{start_time}\u001f#{P:#{pane_id}=#{pane_current_command};}\u001f#{P:|#{@claude_state}}"]
    stdout: StdioCollector {
      onStreamFinished: { root.tmuxWinOut = String(text); root.tmuxWinOutReady = true; root.finishTmuxWindows() }
    }
    stderr: StdioCollector {
      onStreamFinished: { root.tmuxWinErr = String(text); root.tmuxWinErrReady = true; root.finishTmuxWindows() }
    }
    // qmllint disable signal-handler-parameters
    onExited: function(exitCode) {
      root.tmuxWinExitCode = exitCode
      root.tmuxWinExitReady = true
      root.finishTmuxWindows()
    }
    // qmllint enable signal-handler-parameters
  }

  function finishTmuxWindows() {
    if (!root.tmuxWinOutReady || !root.tmuxWinErrReady || !root.tmuxWinExitReady) return
    var parsed = WorkspaceMenuModel.parseTmuxWindows(root.tmuxWinExitCode, root.tmuxWinOut, root.tmuxWinErr)
    if (!parsed.valid) {
      root.tmuxLiveValid = false
      root.tmuxWindowsReady = true
      root.finishTmuxRefresh()
      return
    }
    root.tmuxWindows = parsed.bySession
    root.tmuxLiveValid = parsed.valid
    root.tmuxLiveKeys = WorkspaceMenuModel.liveKeySet(root.bootId8, parsed.bySession)
    root.tmuxWindowsReady = true
    root.finishTmuxRefresh()
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
    root.tmuxWinOutReady = false
    root.tmuxWinErrReady = false
    root.tmuxWinExitReady = false
    root.nowSec = Date.now() / 1000
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
  // it open re-fetches the tmux half, so window_bell_flag/@claude_state marks appear live
  // instead of on the next open. Gated on the menu -- closed, zero listeners
  // doing work. Both event spellings, same as operatord (foot rings bell>>,
  // kitty urgent>>).
  Connections {
    target: Hyprland
    enabled: wsMenu.open
    function onRawEvent(event) {
      if (event.name === "bell" || event.name === "urgent"
          || event.name === "closewindow" || event.name === "openwindow") root.refreshTmux()
    }
  }

  // Right-click a workspace pill -> WsMenu slides down under it with that
  // workspace's windows. No dwell timers, no grace periods: the gesture is
  // deliberate, and PopupCard's click mode dismisses on any outside click via
  // HyprlandFocusGrab. Right-clicking the same pill again toggles it closed;
  // a different pill retargets (close, re-anchor next tick, reopen -- a live
  // PopupWindow does not re-anchor on anchorItem reassignment alone).
  // `ghost` ({name, id}) targets a workspace that exists only in the ws-blackbox ledger;
  // it has no toplevels, so the Firefox half is skipped entirely.
  function showWsMenu(item, w, ghost) {
    wsMenu.targetWs = w || null
    wsMenu.targetGhost = ghost || null
    wsMenu.anchorItem = item
    root.prepareTmuxRefresh()
    if (w) root.prepareFirefoxRefresh(w)
    else root.clearFirefoxSnapshot()
    wsMenu.open = true
    root.startTmuxRefresh()
    if (w) root.startFirefoxRefresh()
  }

  function toggleWsMenu(item, w, ghost) {
    var same = wsMenu.open && ((w && wsMenu.targetWs === w)
      || (ghost && wsMenu.targetGhost && wsMenu.targetGhost.name === ghost.name))
    if (same) {
      wsMenu.open = false
      return
    }
    root.renameOpen = false
    if (wsMenu.open) {
      wsMenu.open = false
      Qt.callLater(function() { root.showWsMenu(item, w, ghost) })
    } else {
      root.showWsMenu(item, w, ghost)
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
        // U+F071 (warning) appears only when an installed ws-blackbox recorder has gone stale;
        // the shape is the signal, not a colour (CVD).
        label: root.hostname + (root.recorder.installed && root.recorder.stale ? " \uf071" : "")
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

    // Live workspaces interleaved with ws-blackbox ghosts: a workspace that vanished but
    // still has recorded windows keeps an outlined pill in its old slot.
    Repeater {
      model: WorkspaceMenuModel.barEntries(root.workspaceList(), root.ghostList)

      Item {
        id: entry
        required property var modelData
        required property int index
        readonly property bool ghost: modelData.ghost === true
        readonly property var ws: ghost ? null : modelData.ws
        readonly property bool focused: !ghost && ws.focused
        readonly property bool urgent: !ghost && ws.urgent
        readonly property string key: ghost ? modelData.name : root.wsKey(ws)
        // The pill whose window menu is open gets a caret and an underline, so the card below
        // always reads as belonging to it -- shape, not hue.
        readonly property bool menuOpen: wsMenu.open && (ghost
          ? (wsMenu.targetGhost !== null && wsMenu.targetGhost.name === modelData.name)
          : wsMenu.targetWs === ws)
        readonly property string caret: (entry.menuOpen ? " \u25be" : "")
        readonly property string flatLabel: (ghost
          ? WorkspaceMenuModel.wsBarLabel(modelData.id, modelData.name, false)
          : root.wsLabel(ws, urgent)) + caret

        width: focused ? pill.implicitWidth : flat.implicitWidth
        height: root.barSize

        Pill {
          id: pill
          anchors.verticalCenter: parent.verticalCenter
          visible: entry.focused
          label: entry.ghost ? "" : root.wsLabel(entry.ws, false) + entry.caret
          color: root.fillFor(entry.key)
          textColor: root.fillTextFor(entry.key)
        }

        Item {
          id: flat
          anchors.verticalCenter: parent.verticalCenter
          visible: !entry.focused
          implicitWidth: flatText.implicitWidth + root.roundPad * 2
          implicitHeight: root.pillH

          // A ghost is an OUTLINE with no fill and dimmed text -- shape and opacity carry
          // the state, never hue alone.
          Rectangle {
            visible: entry.ghost
            anchors.fill: parent
            radius: height / 2
            color: "transparent"
            border.width: 1
            border.color: root.flatFgFor(entry.key)
            opacity: 0.6
          }

          Text {
            id: flatText
            anchors.centerIn: parent
            text: entry.flatLabel
            color: root.flatFgFor(entry.key)
            opacity: entry.ghost ? 0.45 : 1.0
            font.family: root.nerdFamily
            font.pixelSize: root.labelPx
            font.bold: true
            renderType: Text.NativeRendering
          }
        }

        Rectangle {
          visible: entry.menuOpen
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          width: Math.max(0, entry.width - root.roundPad)
          height: Math.max(2, Style.space(2))
          radius: height / 2
          color: entry.focused ? root.fillFor(entry.key) : root.flatFgFor(entry.key)
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton)
              root.toggleWsMenu(entry, entry.ws,
                entry.ghost ? {name: entry.modelData.name, id: entry.modelData.id} : null)
            else if (!entry.ghost) root.focusWorkspace(entry.ws.id)
          }
        }
      }
    }

    // Balance the left bleed so the last workspace keeps its existing edge.
    Item { width: root.leftBleed; height: 1 }
  }
}
