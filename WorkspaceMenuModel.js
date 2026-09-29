.pragma library

var MAX_RESULT_CHARS = 2 * 1024 * 1024
var MAX_TITLE_CODEPOINTS = 1024
var MAX_URL_CODEPOINTS = 4096
var MAX_FAVICON_CHARS = 90000
var MAX_FAVICON_BYTES = 64 * 1024
var TAB_KEYS = ["active", "displayUrl", "favicon", "index", "tabId", "title", "windowId"]
var NATIVE_KEYS = ["cls", "key", "title"]
var BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// --- attention marks, mirroring the tmux status bar -------------------------------
// These glyphs and this priority are a deliberate COPY of `@sb_mark`/`@sb_body` in
// ~/.config/tmux/statusbar.conf, so a window reads identically in the bar and in this
// menu. If that file's chain changes, change it here too -- there is no shared source,
// because tmux resolves its own format and Quickshell cannot call into it.
//
// The four Claude states come from the pane option @claude_state, written by
// ~/oracle/scripts/claude-attn from Claude Code's hooks. The seen/unseen split that
// separates `done` from `idle` is tmux's own window_bell_flag: set in a window you are
// not on, cleared the moment you visit it.
var TMUX_GLYPH = {
  blocked: "\uf256",  // hand      stalled until you answer
  done: "\uf00c",     // check     finished while you were elsewhere
  idle: "\u276f",     // chevron   finished, and you have looked
  working: "\uf252",  // hourglass busy, or waiting on something that is not you
  bell: "\uf0f3"      // bell      a bell where no Claude is running
}

// One window's state from `#{P:|#{@claude_state}}` -- every pane's value, concatenated
// with a leading "|" each. The delimiter is what keeps the match anchored: "|blocked"
// means some pane's value STARTS with blocked, not merely contains it.
function tmuxWindowState(panes) {
  var s = String(panes || "")
  if (s.indexOf("|blocked") !== -1) return "blocked"
  if (s.indexOf("|idle") !== -1) return "idle"
  if (s.indexOf("|waiting") !== -1) return "waiting"
  if (s.indexOf("|busy") !== -1) return "busy"
  return ""
}

function tmuxMark(state, bell) {
  switch (String(state || "")) {
    case "blocked": return TMUX_GLYPH.blocked
    case "idle": return bell ? TMUX_GLYPH.done : TMUX_GLYPH.idle
    case "waiting":
    case "busy": return TMUX_GLYPH.working
  }
  return bell ? TMUX_GLYPH.bell : ""
}

// The shared body shape: `2\u00b7<glyph> name`, or `2\u00b7<glyph>` unnamed, or a bare
// `2`. The middot is carried by the NAME, and kept without one only when there is a
// glyph to hang on it -- so a list of bare indices stays a list of bare indices. The
// space appears only when there is a glyph, so an unmarked entry stays flush.
function markedLabel(id, name, mark) {
  var nm = String(name || "")
  if (nm) return String(id) + "\u00b7" + (mark ? mark + " " : "") + nm
  return String(id) + (mark ? "\u00b7" + mark : "")
}

function tmuxWindowLabel(idx, name, state, bell) {
  return markedLabel(idx, name, tmuxMark(state, bell))
}

// The bar pill deliberately exposes ONLY the bell, not the Claude states: a workspace
// aggregates every window inside it, so ten Claudes would report ten statuses into one
// slot. The pill answers "something in here rang"; the menu answers "what, exactly".
function wsBarLabel(id, name, urgent) {
  return markedLabel(id, name, urgent ? TMUX_GLYPH.bell : "")
}

// Frozen colorhash contract: FNV1a32(UTF8(NFC(name))).
function fnv1a32(value) {
  var bytes = unescape(encodeURIComponent(String(value).normalize("NFC")))
  var hash = 0x811c9dc5
  for (var i = 0; i < bytes.length; i++) {
    hash ^= bytes.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193)
  }
  return hash >>> 0
}

function isPlainObject(value) {
  return value !== null
    && typeof value === "object"
    && !Array.isArray(value)
    && Object.getPrototypeOf(value) === Object.prototype
}

function hasExactKeys(value, expected) {
  if (!isPlainObject(value)) return false
  var actual = Object.keys(value).sort()
  if (actual.length !== expected.length) return false
  for (var i = 0; i < expected.length; i++)
    if (actual[i] !== expected[i]) return false
  return true
}

function isInteger(value) {
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value
    && Math.abs(value) <= 9007199254740991
}

function codePointLength(value) {
  var count = 0
  for (var i = 0; i < value.length; i++, count++) {
    var code = value.charCodeAt(i)
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
      var next = value.charCodeAt(i + 1)
      if (next >= 0xdc00 && next <= 0xdfff) i++
    }
  }
  return count
}

function validateTabs(value) {
  if (!Array.isArray(value)) return null

  var tabs = []
  var seenTabIds = Object.create(null)
  var seenIndexes = Object.create(null)
  var activeCounts = Object.create(null)

  for (var i = 0; i < value.length; i++) {
    var tab = value[i]
    if (!hasExactKeys(tab, TAB_KEYS)) return null

    var tabId = tab.tabId
    var windowId = tab.windowId
    var index = tab.index
    var title = tab.title
    var displayUrl = tab.displayUrl
    var favicon = tab.favicon
    var active = tab.active
    if (!isInteger(tabId) || tabId <= 0) return null
    if (!isInteger(windowId) || windowId <= 0) return null
    if (!isInteger(index) || index < 0) return null
    if (typeof title !== "string" || codePointLength(title) > MAX_TITLE_CODEPOINTS) return null
    if (typeof displayUrl !== "string" || codePointLength(displayUrl) > MAX_URL_CODEPOINTS) return null
    if (typeof favicon !== "string" || favicon.length > MAX_FAVICON_CHARS) return null
    if (typeof active !== "boolean") return null

    var tabKey = String(tabId)
    var indexKey = String(windowId) + ":" + String(index)
    var windowKey = String(windowId)
    if (seenTabIds[tabKey] || seenIndexes[indexKey]) return null
    seenTabIds[tabKey] = true
    seenIndexes[indexKey] = true
    activeCounts[windowKey] = (activeCounts[windowKey] || 0) + (active ? 1 : 0)

    tabs.push({
      tabId: tabId,
      windowId: windowId,
      index: index,
      title: title,
      displayUrl: displayUrl,
      favicon: favicon,
      active: active
    })
  }

  var windows = Object.keys(activeCounts)
  for (var j = 0; j < windows.length; j++)
    if (activeCounts[windows[j]] !== 1) return null

  tabs.sort(function(left, right) {
    return left.windowId === right.windowId
      ? left.index - right.index
      : left.windowId - right.windowId
  })
  return tabs
}

function parseSnapshot(raw) {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > MAX_RESULT_CHARS) return null

  var document
  try { document = JSON.parse(raw) } catch (error) { return null }
  if (!hasExactKeys(document, ["ok", "tabs"])) return null
  if (document.ok !== true || !Array.isArray(document.tabs)) return null
  return validateTabs(document.tabs)
}

function safeFavicon(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_FAVICON_CHARS) return ""
  var match = /^data:image\/(png|jpeg|gif|webp|avif|bmp|x-icon|vnd\.microsoft\.icon);base64,([A-Za-z0-9+/]*={0,2})$/i.exec(value)
  if (!match) return ""

  var payload = match[2]
  if (payload.length === 0 || payload.length % 4 !== 0) return ""
  var padding = payload.endsWith("==") ? 2 : (payload.endsWith("=") ? 1 : 0)
  if (padding === 2 && (BASE64_ALPHABET.indexOf(payload.charAt(payload.length - 3)) & 15) !== 0) return ""
  if (padding === 1 && (BASE64_ALPHABET.indexOf(payload.charAt(payload.length - 2)) & 3) !== 0) return ""
  var decodedBytes = payload.length / 4 * 3 - padding
  return decodedBytes <= MAX_FAVICON_BYTES ? value : ""
}

function isFirefoxClass(value) {
  return typeof value === "string" && value.toLowerCase() === "firefox"
}

function expectedNativeTitle(activeTitle) {
  return activeTitle + " \u2014 Mozilla Firefox"
}

function correlateFirefox(nativeWindows, tabs) {
  var empty = Object.create(null)

  try {
    if (!Array.isArray(nativeWindows) || !Array.isArray(tabs)) return empty
    var validatedTabs = validateTabs(tabs)
    if (validatedTabs === null) return empty

    var nativeByTitle = Object.create(null)
    var seenNativeKeys = Object.create(null)
    for (var i = 0; i < nativeWindows.length; i++) {
      var nativeWindow = nativeWindows[i]
      if (!hasExactKeys(nativeWindow, NATIVE_KEYS)) return empty

      var key = nativeWindow.key
      var cls = nativeWindow.cls
      var nativeTitle = nativeWindow.title
      if (typeof key !== "string" || typeof cls !== "string" || typeof nativeTitle !== "string") return empty
      if (seenNativeKeys[key]) return empty
      seenNativeKeys[key] = true
      if (!isFirefoxClass(cls)) continue
      if (!nativeByTitle[nativeTitle]) nativeByTitle[nativeTitle] = []
      nativeByTitle[nativeTitle].push({key: key, title: nativeTitle})
    }

    var groups = Object.create(null)
    for (var j = 0; j < validatedTabs.length; j++) {
      var tab = validatedTabs[j]
      var windowKey = String(tab.windowId)
      if (!groups[windowKey]) groups[windowKey] = []
      groups[windowKey].push(tab)
    }

    var internalByTitle = Object.create(null)
    Object.keys(groups).forEach(function(windowKey) {
      var active = groups[windowKey].filter(function(tab) { return tab.active === true })
      var title = expectedNativeTitle(active[0].title)
      if (!internalByTitle[title]) internalByTitle[title] = []
      internalByTitle[title].push({windowId: Number(windowKey), tabs: groups[windowKey]})
    })

    var matches = Object.create(null)
    Object.keys(internalByTitle).forEach(function(title) {
      var internal = internalByTitle[title]
      var native = nativeByTitle[title] || []
      if (internal.length !== 1 || native.length !== 1) return
      matches[native[0].key] = {
        windowId: internal[0].windowId,
        tabs: internal[0].tabs.slice()
      }
    })
    return matches
  } catch (error) {
    return empty
  }
}

// --- ws-blackbox overlay ------------------------------------------------------------
// The recorder (bin/ws-blackbox, a 1-minute user timer) keeps ledger.json: every tmux
// window it has seen and nobody dismissed. The menu overlays it on the LIVE tmux fetch:
// a ledger key missing from the server-wide live key set is a ghost. Keys must match
// the Python side's window_key() byte for byte.
var MAX_LEDGER_CHARS = 8 * 1024 * 1024
var LEDGER_SHELLS = {bash: true, sh: true, zsh: true, fish: true, dash: true}
var STALE_AFTER_SECONDS = 300

function blackboxKey(boot8, serverPid, serverStart, windowId) {
  return String(boot8) + ":" + String(serverPid) + ":" + String(serverStart) + ":" + String(windowId)
}

function parseLedger(raw) {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > MAX_LEDGER_CHARS) return null
  var doc
  try { doc = JSON.parse(raw) } catch (error) { return null }
  if (!isPlainObject(doc) || doc.version !== 1) return null
  if (!isPlainObject(doc.windows) || !isPlainObject(doc.workspaces)) return null
  var windows = Object.create(null)
  var keys = Object.keys(doc.windows)
  for (var i = 0; i < keys.length; i++) {
    var e = doc.windows[keys[i]]
    if (validLedgerWindow(e)) windows[keys[i]] = e
  }
  return {windows: windows, workspaces: doc.workspaces}
}

// Every field the merge and the menu read is checked here, so a malformed entry is dropped
// instead of throwing (or rendering) further down.
function validLedgerWindow(e) {
  if (!isPlainObject(e) || !isInteger(e.index) || typeof e.name !== "string"
      || typeof e.session !== "string" || !Array.isArray(e.panes)) return false
  if (e.workspace !== null && e.workspace !== undefined
      && (!isPlainObject(e.workspace) || typeof e.workspace.name !== "string"
          || !isInteger(e.workspace.id))) return false
  for (var i = 0; i < e.panes.length; i++) {
    var p = e.panes[i]
    if (!isPlainObject(p) || typeof p.pane_id !== "string") return false
    if (p.claude !== null && p.claude !== undefined && !isPlainObject(p.claude)) return false
    if (p.children !== undefined && !Array.isArray(p.children)) return false
  }
  return true
}

function parseHeartbeat(raw) {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 65536) return null
  try {
    var doc = JSON.parse(raw)
    return isPlainObject(doc) ? doc : null
  } catch (error) { return null }
}

function parsePaneCommands(text) {
  var out = Object.create(null)
  var parts = String(text || "").split(";")
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq > 0) out[parts[i].slice(0, eq)] = parts[i].slice(eq + 1)
  }
  return out
}

function isNoServer(err) {
  var s = String(err || "")
  return s.indexOf("no server running on") !== -1
    || (s.indexOf("error connecting to") !== -1 && s.indexOf("No such file or directory") !== -1)
}

function parseTmuxWindows(exitCode, out, err) {
  var map = Object.create(null)
  if (exitCode !== 0) return {bySession: map, valid: isNoServer(err)}
  var lines = String(out || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue
    var p = lines[i].split("\u001f")
    if (p.length < 9) continue
    var w = {session: p[0], idx: parseInt(p[1], 10), name: p[2], bell: p[3] === "1",
             windowId: p[4], serverPid: p[5], serverStart: p[6],
             paneCommands: parsePaneCommands(p[7]),
             state: tmuxWindowState(p.slice(8).join("\u001f"))}
    if (!map[w.session]) map[w.session] = []
    map[w.session].push(w)
  }
  return {bySession: map, valid: true}
}

function liveKeySet(boot8, bySession) {
  var out = Object.create(null)
  if (!boot8 || !bySession) return out
  var sessions = Object.keys(bySession)
  for (var s = 0; s < sessions.length; s++) {
    var rows = bySession[sessions[s]] || []
    for (var i = 0; i < rows.length; i++)
      if (rows[i] && rows[i].windowId)
        out[blackboxKey(boot8, rows[i].serverPid, rows[i].serverStart, rows[i].windowId)] = true
  }
  return out
}

function childLabel(child) {
  var session = child && isPlainObject(child.session) ? child.session : null
  if (!session) return child && typeof child.cmd === "string" ? child.cmd : ""
  var head = session.kind === "bg" ? "background" : "claude"
  var first = typeof session.name === "string" && session.name ? head + " " + session.name : head
  return typeof session.status === "string" && session.status ? first + " \u00b7 " + session.status : first
}

// What ran in a window, as display lines: one Claude session stays inline with the other
// processes; several each get their own line, with the other processes on a last line.
function captionLines(entry) {
  if (!entry || !Array.isArray(entry.panes)) return []
  var seen = Object.create(null)
  var claudes = []
  var others = []
  for (var i = 0; i < entry.panes.length; i++) {
    var kids = entry.panes[i] && Array.isArray(entry.panes[i].children) ? entry.panes[i].children : []
    for (var j = 0; j < kids.length; j++) {
      var label = childLabel(kids[j])
      if (!label || seen[label]) continue
      seen[label] = true
      if (kids[j].cmd === "claude") claudes.push(label)
      else others.push(label)
    }
  }
  if (claudes.length <= 1) {
    var inline = claudes.concat(others).join(" \u00b7 ")
    return inline ? [inline] : []
  }
  return others.length ? claudes.concat([others.join(" \u00b7 ")]) : claudes
}

function mergeWindows(liveRows, liveKeys, ledger, workspaceName, boot8) {
  var rows = []
  var windows = ledger && ledger.windows ? ledger.windows : Object.create(null)
  var live = Array.isArray(liveRows) ? liveRows : []
  for (var i = 0; i < live.length; i++) {
    var w = live[i]
    var key = (boot8 && w.windowId) ? blackboxKey(boot8, w.serverPid, w.serverStart, w.windowId) : ""
    var entry = key && windows[key] ? windows[key] : null
    var row = {state: "live", win: w, key: key, paneId: "", caption: captionLines(entry)}
    if (entry && w.paneCommands) {
      for (var j = 0; j < entry.panes.length; j++) {
        var p = entry.panes[j]
        if (p && p.claude && p.claude.session_id && LEDGER_SHELLS[w.paneCommands[p.pane_id]] === true) {
          row.state = "agent-gone"
          row.paneId = String(p.pane_id)
          break
        }
      }
    }
    rows.push(row)
  }
  if (ledger) {
    var keys = Object.keys(windows).sort()
    for (var k = 0; k < keys.length; k++) {
      var e = windows[keys[k]]
      if (liveKeys[keys[k]] === true || e.restored_to) continue
      if (!e.workspace || e.workspace.name !== workspaceName) continue
      rows.push({state: "gone", key: keys[k], paneId: "", caption: captionLines(e),
                 win: {session: e.session, idx: e.index, name: e.name, bell: false, state: ""}})
    }
  }
  rows.sort(function(a, b) {
    if (a.win.idx !== b.win.idx) return a.win.idx - b.win.idx
    var ag = a.state === "gone" ? 1 : 0
    var bg = b.state === "gone" ? 1 : 0
    if (ag !== bg) return ag - bg
    return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0)
  })
  return rows
}

function ghostWorkspaces(ledger, liveNames) {
  if (!ledger) return []
  var counts = Object.create(null)
  var keys = Object.keys(ledger.windows)
  for (var i = 0; i < keys.length; i++) {
    var e = ledger.windows[keys[i]]
    if (e.restored_to || !e.workspace || typeof e.workspace.name !== "string") continue
    counts[e.workspace.name] = (counts[e.workspace.name] || 0) + 1
  }
  var out = []
  var names = Object.keys(ledger.workspaces)
  for (var n = 0; n < names.length; n++) {
    var meta = ledger.workspaces[names[n]]
    if (!counts[names[n]] || (liveNames && liveNames[names[n]] === true)) continue
    if (!isPlainObject(meta) || !isInteger(meta.id)) continue
    out.push({name: names[n], id: meta.id})
  }
  out.sort(function(a, b) { return a.id - b.id || (a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)) })
  return out
}

function barEntries(liveList, ghosts) {
  var out = []
  var live = liveList || []
  var gs = ghosts || []
  var g = 0
  for (var i = 0; i < live.length; i++) {
    while (g < gs.length && gs[g].id < live[i].id) { out.push({ghost: true, ws: null, name: gs[g].name, id: gs[g].id}); g++ }
    out.push({ghost: false, ws: live[i], name: "", id: live[i].id})
    while (g < gs.length && gs[g].id === live[i].id) { out.push({ghost: true, ws: null, name: gs[g].name, id: gs[g].id}); g++ }
  }
  for (; g < gs.length; g++) out.push({ghost: true, ws: null, name: gs[g].name, id: gs[g].id})
  return out
}

function shortAge(seconds) {
  var s = Math.max(0, Math.floor(seconds))
  return s < 60 ? s + "s" : (s < 3600 ? Math.floor(s / 60) + "m" : Math.floor(s / 3600) + "h")
}

// installed=false (no heartbeat file) keeps the bar unchanged on machines without the recorder.
function recorderStatus(heartbeat, nowSec) {
  if (!isPlainObject(heartbeat)) return {installed: false, stale: false, text: ""}
  if (!isInteger(heartbeat.last_full) || !isFinite(nowSec))
    return {installed: true, stale: true, text: "recorder not recording"}
  var age = nowSec - heartbeat.last_full
  var stale = age > STALE_AFTER_SECONDS
  return {installed: true, stale: stale,
          text: stale ? "recorder stopped · " + shortAge(age) : "recorded " + shortAge(age) + " ago"}
}

// Arrays handed through a Repeater's modelData arrive array-LIKE: Array.isArray is false while
// length and indexing work. Copy into a real array of strings instead of type-checking.
function stringList(value) {
  var out = []
  if (!value || typeof value === "string" || typeof value.length !== "number") return out
  for (var i = 0; i < value.length; i++) out.push(String(value[i]))
  return out
}

// The pill whose menu is open trades its middot for a caret -- same cell width in the
// monospace bar font, so nothing shifts. A bare id (no middot) is left as is.
function openLabel(label, open) {
  var s = String(label || "")
  return open ? s.replace("\u00b7", "\u25be") : s
}
