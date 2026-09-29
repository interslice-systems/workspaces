import QtQuick
import QtTest
import "../WorkspaceMenuModel.js" as Model

TestCase {
  name: "WorkspaceMenuModel"

  // Attention marks. These mirror statusbar.conf's @sb_mark chain; there is no shared
  // source, because tmux resolves its own format, so these cases are half of what holds
  // the tmux bar and this menu to the same reading.
  readonly property string glyphBlocked: "\uf256"
  readonly property string glyphDone: "\uf00c"
  readonly property string glyphIdle: "\u276f"
  readonly property string glyphWorking: "\uf252"
  readonly property string glyphBell: "\uf0f3"
  readonly property string middot: "\u00b7"

  function test_tmux_window_state_follows_the_bar_priority() {
    compare(Model.tmuxWindowState("|busy|blocked"), "blocked")
    compare(Model.tmuxWindowState("|waiting|idle"), "idle")
    compare(Model.tmuxWindowState("|busy"), "busy")
    compare(Model.tmuxWindowState("||"), "")
  }

  function test_tmux_window_state_is_anchored_by_the_leading_pipe() {
    compare(Model.tmuxWindowState("|xblocked"), "")
    compare(Model.tmuxWindowState("|blockedish"), "blocked")
  }

  function test_tmux_mark_splits_done_from_idle_on_the_bell() {
    compare(Model.tmuxMark("idle", true), glyphDone)
    compare(Model.tmuxMark("idle", false), glyphIdle)
  }

  function test_tmux_mark_outranks_the_bell_wherever_claude_has_a_state() {
    compare(Model.tmuxMark("blocked", true), glyphBlocked)
    compare(Model.tmuxMark("busy", true), glyphWorking)
    compare(Model.tmuxMark("waiting", true), glyphWorking)
    compare(Model.tmuxMark("", true), glyphBell)
    compare(Model.tmuxMark("", false), "")
  }

  function test_tmux_window_label_spaces_the_glyph_off_the_name() {
    compare(Model.tmuxWindowLabel(2, "oracle", "busy", false), "2" + middot + glyphWorking + " oracle")
    compare(Model.tmuxWindowLabel(2, "oracle", "", false), "2" + middot + "oracle")
  }

  function test_tmux_window_label_keeps_a_bare_index_bare() {
    compare(Model.tmuxWindowLabel(2, "", "busy", false), "2" + middot + glyphWorking)
    compare(Model.tmuxWindowLabel(2, "", "", false), "2")
  }

  function test_ws_bar_label_exposes_only_the_bell() {
    compare(Model.wsBarLabel(2, "mirepoix", true), "2" + middot + glyphBell + " mirepoix")
    compare(Model.wsBarLabel(2, "mirepoix", false), "2" + middot + "mirepoix")
    compare(Model.wsBarLabel(5, "", true), "5" + middot + glyphBell)
    compare(Model.wsBarLabel(5, "", false), "5")
  }

  function test_colorhash_matches_bash_nfc_contract() {
    verify(typeof Model.fnv1a32 === "function")
    compare(Model.fnv1a32("caf\u00e9"), 0xa82b5049)
    compare(Model.fnv1a32("cafe\u0301"), 0xa82b5049)
  }

  function tab(overrides) {
    var value = {
      tabId: 11,
      windowId: 101,
      index: 0,
      title: "Oracle",
      displayUrl: "example.test/oracle",
      favicon: "data:image/png;base64,AA==",
      active: true
    }
    overrides = overrides || {}
    Object.keys(overrides).forEach(function(key) { value[key] = overrides[key] })
    return value
  }

  function raw(tabs) {
    return JSON.stringify({ok: true, tabs: tabs})
  }

  function repeated(character, count) {
    var out = ""
    while (out.length < count) out += character
    return out
  }

  function copies(character, count) {
    var out = ""
    for (var i = 0; i < count; i++) out += character
    return out
  }

  function nativeWindow(overrides) {
    var value = {
      key: "native-0",
      cls: "firefox",
      title: "Oracle — Mozilla Firefox"
    }
    overrides = overrides || {}
    Object.keys(overrides).forEach(function(key) { value[key] = overrides[key] })
    return value
  }

  function test_parse_accepts_exact_projection_and_sorts_by_window_then_index() {
    var parsed = Model.parseSnapshot(raw([
      tab({tabId: 22, windowId: 202, index: 1, title: "second", active: false}),
      tab({tabId: 12, windowId: 101, index: 1, title: "later", active: false}),
      tab({tabId: 11, windowId: 101, index: 0, title: "first", active: true}),
      tab({tabId: 21, windowId: 202, index: 0, title: "other active", active: true})
    ]))

    verify(parsed !== null)
    compare(parsed.length, 4)
    compare(parsed[0].tabId, 11)
    compare(parsed[1].tabId, 12)
    compare(parsed[2].tabId, 21)
    compare(parsed[3].tabId, 22)
    compare(Object.keys(parsed[0]).sort().join(","),
            "active,displayUrl,favicon,index,tabId,title,windowId")
  }

  function test_parse_rejects_wrong_envelope_and_unprojected_fields() {
    compare(Model.parseSnapshot(""), null)
    compare(Model.parseSnapshot("[]"), null)
    compare(Model.parseSnapshot(JSON.stringify({ok: false, tabs: []})), null)
    compare(Model.parseSnapshot(JSON.stringify({ok: true, tabs: [], extra: true})), null)

    var leaked = tab({url: "https://secret.example/path"})
    compare(Model.parseSnapshot(raw([leaked])), null)
  }

  function test_parse_rejects_malformed_json_and_missing_projected_keys() {
    compare(Model.parseSnapshot("{"), null)

    var missingTitle = tab()
    delete missingTitle.title
    compare(Model.parseSnapshot(raw([missingTitle])), null)
  }

  function test_parse_rejects_invalid_ids_indexes_types_and_duplicates() {
    compare(Model.parseSnapshot(raw([tab({tabId: 0})])), null)
    compare(Model.parseSnapshot(raw([tab({windowId: -1})])), null)
    compare(Model.parseSnapshot(raw([tab({index: -1})])), null)
    compare(Model.parseSnapshot(raw([tab({active: "true"})])), null)
    compare(Model.parseSnapshot(raw([tab({title: 7})])), null)
    compare(Model.parseSnapshot(raw([tab({displayUrl: null})])), null)

    compare(Model.parseSnapshot(raw([
      tab({tabId: 11, index: 0, active: true}),
      tab({tabId: 11, index: 1, active: false})
    ])), null)
    compare(Model.parseSnapshot(raw([
      tab({tabId: 11, index: 0, active: true}),
      tab({tabId: 12, index: 0, active: false})
    ])), null)
  }

  function test_parse_rejects_duplicate_tab_ids_across_windows_but_allows_shared_indexes() {
    compare(Model.parseSnapshot(raw([
      tab({tabId: 11, windowId: 101, index: 0, title: "Oracle"}),
      tab({tabId: 11, windowId: 202, index: 0, title: "Mirepoix"})
    ])), null)

    var parsed = Model.parseSnapshot(raw([
      tab({tabId: 11, windowId: 101, index: 0, title: "Oracle"}),
      tab({tabId: 21, windowId: 202, index: 0, title: "Mirepoix"})
    ]))
    verify(parsed !== null)
    compare(parsed.length, 2)
  }

  function test_parse_rejects_bad_active_counts_and_length_bounds() {
    compare(Model.parseSnapshot(raw([
      tab({tabId: 11, index: 0, active: false}),
      tab({tabId: 12, index: 1, active: false})
    ])), null)
    compare(Model.parseSnapshot(raw([
      tab({tabId: 11, index: 0, active: true}),
      tab({tabId: 12, index: 1, active: true})
    ])), null)
    compare(Model.parseSnapshot(raw([tab({title: repeated("x", 1025)})])), null)
    compare(Model.parseSnapshot(raw([tab({displayUrl: repeated("x", 4097)})])), null)
    compare(Model.parseSnapshot(raw([tab({favicon: repeated("x", 90001)})])), null)
    compare(Model.parseSnapshot(repeated("x", 2097153)), null)
  }

  function test_parse_counts_astral_codepoints_at_exact_bounds() {
    var astral = "\ud83d\ude00"
    verify(Model.parseSnapshot(raw([tab({title: copies(astral, 1024)})])) !== null)
    compare(Model.parseSnapshot(raw([tab({title: copies(astral, 1025)})])), null)
    verify(Model.parseSnapshot(raw([tab({displayUrl: copies(astral, 4096)})])) !== null)
    compare(Model.parseSnapshot(raw([tab({displayUrl: copies(astral, 4097)})])), null)
  }

  function test_parse_returns_independent_projected_copies() {
    var source = tab({title: "Original"})
    var serialized = raw([source])
    var first = Model.parseSnapshot(serialized)
    var second = Model.parseSnapshot(serialized)

    source.title = "source changed"
    first[0].title = "first changed"
    first.push(tab({tabId: 12, index: 1, active: false}))

    compare(second.length, 1)
    compare(second[0].title, "Original")
    verify(first !== second)
    verify(first[0] !== second[0])
  }

  function test_favicon_accepts_only_bounded_base64_raster_data_urls() {
    compare(Model.safeFavicon("data:image/png;base64,AA=="), "data:image/png;base64,AA==")
    compare(Model.safeFavicon("data:image/jpeg;base64,AAAA"), "data:image/jpeg;base64,AAAA")
    compare(Model.safeFavicon("data:image/svg+xml;base64,AAAA"), "")
    compare(Model.safeFavicon("https://example.test/favicon.png"), "")
    compare(Model.safeFavicon("file:///tmp/favicon.png"), "")
    compare(Model.safeFavicon("moz-extension://id/favicon.png"), "")
    compare(Model.safeFavicon("data:image/png;base64,%%%"), "")
    compare(Model.safeFavicon("data:image/png;base64," + repeated("A", 87384)), "")
    compare(Model.safeFavicon(null), "")
  }

  function test_favicon_requires_canonical_padding_and_exact_byte_ceiling() {
    compare(Model.safeFavicon("data:image/png;base64,AA=="), "data:image/png;base64,AA==")
    compare(Model.safeFavicon("data:image/png;base64,AB=="), "")
    compare(Model.safeFavicon("data:image/png;base64,AAA="), "data:image/png;base64,AAA=")
    compare(Model.safeFavicon("data:image/png;base64,AAB="), "")

    var fullGroups = repeated("A", 87380)
    var exactLimit = "data:image/png;base64," + fullGroups + "AA=="
    var oneOver = "data:image/png;base64," + fullGroups + "AAA="
    compare(Model.safeFavicon(exactLimit), exactLimit)
    compare(Model.safeFavicon(oneOver), "")
  }

  function test_unique_exact_title_correlates_and_preserves_tab_order() {
    var tabs = Model.parseSnapshot(raw([
      tab({tabId: 12, windowId: 101, index: 1, title: "background", active: false}),
      tab({tabId: 11, windowId: 101, index: 0, title: "Oracle", active: true}),
      tab({tabId: 21, windowId: 202, index: 0, title: "Mirepoix", active: true})
    ]))
    var matches = Model.correlateFirefox([
      {key: "native-0", cls: "firefox", title: "Oracle — Mozilla Firefox"},
      {key: "native-1", cls: "kitty", title: "Oracle — Mozilla Firefox"}
    ], tabs)

    compare(Object.keys(matches).join(","), "native-0")
    compare(matches["native-0"].windowId, 101)
    compare(matches["native-0"].tabs.length, 2)
    compare(matches["native-0"].tabs[0].tabId, 11)
    compare(matches["native-0"].tabs[1].tabId, 12)
  }

  function test_duplicate_internal_or_native_titles_fail_closed() {
    var duplicateInternal = Model.parseSnapshot(raw([
      tab({tabId: 11, windowId: 101, title: "Same", active: true}),
      tab({tabId: 21, windowId: 202, title: "Same", active: true})
    ]))
    var oneNative = [{key: "native-0", cls: "firefox", title: "Same — Mozilla Firefox"}]
    compare(Object.keys(Model.correlateFirefox(oneNative, duplicateInternal)).length, 0)

    var oneInternal = Model.parseSnapshot(raw([
      tab({tabId: 11, windowId: 101, title: "Same", active: true})
    ]))
    var duplicateNative = [
      {key: "native-0", cls: "firefox", title: "Same — Mozilla Firefox"},
      {key: "native-1", cls: "Firefox", title: "Same — Mozilla Firefox"}
    ]
    compare(Object.keys(Model.correlateFirefox(duplicateNative, oneInternal)).length, 0)
  }

  function test_zero_dynamic_and_malformed_matches_fail_closed() {
    var tabs = Model.parseSnapshot(raw([
      tab({tabId: 11, windowId: 101, title: "Before", active: true})
    ]))
    compare(Object.keys(Model.correlateFirefox([
      {key: "native-0", cls: "firefox", title: "After — Mozilla Firefox"}
    ], tabs)).length, 0)
    compare(Object.keys(Model.correlateFirefox([], tabs)).length, 0)
    compare(Object.keys(Model.correlateFirefox([
      {key: "native-0", cls: "firefox", title: "Before — Mozilla Firefox"}
    ], null)).length, 0)
  }

  function test_correlation_rejects_non_finite_and_unsafe_numeric_ids() {
    var invalidIds = [NaN, Infinity, -Infinity, 9007199254740992]
    var fields = ["tabId", "windowId", "index"]

    for (var i = 0; i < invalidIds.length; i++) {
      for (var j = 0; j < fields.length; j++) {
        var overrides = {}
        overrides[fields[j]] = invalidIds[i]
        compare(Object.keys(Model.correlateFirefox([nativeWindow()], [
          tab(overrides)
        ])).length, 0)
      }
    }
  }

  function test_correlation_handles_prototype_sensitive_active_titles() {
    var matches = Model.correlateFirefox([
      nativeWindow({key: "native-proto", title: "__proto__ — Mozilla Firefox"}),
      nativeWindow({key: "native-constructor", title: "constructor — Mozilla Firefox"})
    ], [
      tab({tabId: 11, windowId: 101, title: "__proto__"}),
      tab({tabId: 21, windowId: 202, title: "constructor"})
    ])

    compare(Object.keys(matches).sort().join(","), "native-constructor,native-proto")
    compare(matches["native-proto"].windowId, 101)
    compare(matches["native-constructor"].windowId, 202)
  }

  function test_correlation_rejects_throwing_property_getters_without_throwing() {
    var throwing = tab()
    Object.defineProperty(throwing, "title", {
      enumerable: true,
      get: function() { throw new Error("getter must stay contained") }
    })

    var matches
    try {
      matches = Model.correlateFirefox([nativeWindow()], [throwing])
    } catch (error) {
      fail("throwing getter escaped correlateFirefox: " + error)
    }
    compare(Object.keys(matches).length, 0)
  }

  function test_correlation_returns_independent_tab_copies() {
    var source = tab()
    var first = Model.correlateFirefox([nativeWindow()], [source])
    var second = Model.correlateFirefox([nativeWindow()], [source])

    source.title = "source changed"
    first["native-0"].tabs[0].title = "first changed"
    first["native-0"].tabs.push(tab({tabId: 12, index: 1, active: false}))

    compare(second["native-0"].tabs.length, 1)
    compare(second["native-0"].tabs[0].title, "Oracle")
    verify(first["native-0"].tabs !== second["native-0"].tabs)
    verify(first["native-0"].tabs[0] !== second["native-0"].tabs[0])
  }

  function test_firefox_class_matching_is_exact() {
    verify(Model.isFirefoxClass("firefox"))
    verify(Model.isFirefoxClass("Firefox"))
    verify(!Model.isFirefoxClass("firefox-esr"))
    verify(!Model.isFirefoxClass("firefox "))
    verify(!Model.isFirefoxClass(7))
    verify(!Model.isFirefoxClass(null))
  }

  function test_correlation_rejects_every_malformed_tab_shape_without_throwing() {
    var native = [nativeWindow()]
    var inheritedOnly = Object.create(tab())
    var inheritedExtra = Object.create({leaked: true})
    var base = tab()
    Object.keys(base).forEach(function(key) { inheritedExtra[key] = base[key] })
    var cyclic = tab()
    cyclic.self = cyclic
    var cases = [
      {name: "missing", tabs: [{windowId: 101, title: "Oracle", active: true}]},
      {name: "null", tabs: [null]},
      {name: "inherited-only", tabs: [inheritedOnly]},
      {name: "inherited-extra", tabs: [inheritedExtra]},
      {name: "extra", tabs: [tab({extra: true})]},
      {name: "cyclic", tabs: [cyclic]}
    ]
    var failures = []

    cases.forEach(function(value) {
      try {
        var matches = Model.correlateFirefox(native, value.tabs)
        if (Object.keys(matches).length !== 0) failures.push(value.name + " correlated")
        if (Object.getPrototypeOf(matches) !== null) failures.push(value.name + " inherited map")
      } catch (error) {
        failures.push(value.name + " threw")
      }
    })

    compare(failures.join(", "), "")
  }

  function test_correlation_rejects_malformed_native_shapes_and_duplicate_keys() {
    var inheritedOnly = Object.create(nativeWindow())
    var inheritedExtra = Object.create({leaked: true})
    var base = nativeWindow()
    Object.keys(base).forEach(function(key) { inheritedExtra[key] = base[key] })
    var cases = [
      {name: "null", native: [null, nativeWindow()]},
      {name: "inherited-only", native: [inheritedOnly]},
      {name: "inherited-extra", native: [inheritedExtra]},
      {name: "extra", native: [nativeWindow({extra: true})]},
      {name: "key-type", native: [nativeWindow({key: 7}), nativeWindow()]},
      {name: "class-type", native: [nativeWindow({cls: 7}), nativeWindow()]},
      {name: "title-type", native: [nativeWindow({title: 7}), nativeWindow()]},
      {name: "duplicate-key", native: [
        nativeWindow(),
        nativeWindow({cls: "kitty", title: "terminal", key: "native-0"})
      ]}
    ]
    var failures = []

    cases.forEach(function(value) {
      try {
        var matches = Model.correlateFirefox(value.native, [tab()])
        if (Object.keys(matches).length !== 0) failures.push(value.name + " correlated")
        if (Object.getPrototypeOf(matches) !== null) failures.push(value.name + " inherited map")
      } catch (error) {
        failures.push(value.name + " threw")
      }
    })

    compare(failures.join(", "), "")
  }

  function test_correlation_uses_null_prototype_maps_and_sensitive_string_keys() {
    var emptyResults = [
      Model.correlateFirefox(null, null),
      Model.correlateFirefox([], []),
      Model.correlateFirefox([], [tab()])
    ]
    emptyResults.forEach(function(matches) {
      compare(Object.getPrototypeOf(matches), null)
      compare(Object.keys(matches).length, 0)
      verify(matches["__proto__"] === undefined)
      verify(matches["constructor"] === undefined)
    })

    var matches = Model.correlateFirefox([
      nativeWindow({key: "__proto__", title: "Proto — Mozilla Firefox"}),
      nativeWindow({key: "constructor", title: "Constructor — Mozilla Firefox"})
    ], [
      tab({tabId: 21, windowId: 202, title: "Constructor"}),
      tab({tabId: 11, windowId: 101, title: "Proto"})
    ])

    compare(Object.getPrototypeOf(matches), null)
    compare(Object.keys(matches).sort().join(","), "__proto__,constructor")
    verify(Object.prototype.hasOwnProperty.call(matches, "__proto__"))
    verify(Object.prototype.hasOwnProperty.call(matches, "constructor"))
    compare(matches["__proto__"].windowId, 101)
    compare(matches["constructor"].windowId, 202)
  }

  // --- ws-blackbox overlay --------------------------------------------------
  function ledgerFixture() {
    return JSON.stringify({version: 1, workspaces: {"mirepoix": {id: 1, last_seen: 5}, "old": {id: 3, last_seen: 5}},
      windows: {
        "b00b1e55:7:70:@1": {session: "mirepoix", index: 1, name: "a", workspace: {id: 1, name: "mirepoix"},
          restored_to: null, panes: [{pane_id: "%1", claude: {session_id: "u1"}, children: [{cmd: "claude"}, {cmd: "ruby bin/dev"}]}]},
        "b00b1e55:7:70:@2": {session: "mirepoix", index: 2, name: "b", workspace: {id: 1, name: "mirepoix"},
          restored_to: null, panes: [{pane_id: "%2", claude: null, children: []}]},
        "b00b1e55:6:60:@9": {session: "old", index: 1, name: "c", workspace: {id: 3, name: "old"},
          restored_to: null, panes: []},
        "bad": {index: "x"}
      }})
  }

  function test_parse_ledger_drops_bad_entries_and_rejects_junk() {
    var l = Model.parseLedger(ledgerFixture())
    verify(l !== null)
    compare(Object.keys(l.windows).length, 3)
    compare(Model.parseLedger("{"), null)
    compare(Model.parseLedger(JSON.stringify({version: 2, windows: {}, workspaces: {}})), null)
    compare(Model.parseLedger(""), null)
  }

  function test_parse_tmux_windows_exit_handling() {
    var line = ["mirepoix", "1", "a", "0", "@1", "7", "70", "%1=bash;%3=claude;", "|idle"].join("\u001f")
    var ok = Model.parseTmuxWindows(0, line + "\n", "")
    verify(ok.valid)
    compare(ok.bySession["mirepoix"][0].paneCommands["%1"], "bash")
    compare(ok.bySession["mirepoix"][0].windowId, "@1")
    var none = Model.parseTmuxWindows(1, "", "no server running on /tmp/tmux-1000/default\n")
    verify(none.valid)
    compare(Object.keys(none.bySession).length, 0)
    var broken = Model.parseTmuxWindows(1, "", "some other failure")
    verify(!broken.valid)
  }

  function test_merge_marks_live_agent_gone_and_gone_in_index_order() {
    var l = Model.parseLedger(ledgerFixture())
    var live = [{session: "mirepoix", idx: 1, name: "a", bell: false, state: "", windowId: "@1",
                 serverPid: "7", serverStart: "70", paneCommands: {"%1": "bash"}}]
    var keys = Model.liveKeySet("b00b1e55", {"mirepoix": live})
    var rows = Model.mergeWindows(live, keys, l, "mirepoix", "b00b1e55")
    compare(rows.length, 2)
    compare(rows[0].state, "agent-gone")
    compare(rows[0].paneId, "%1")
    compare(rows[0].caption, ["claude · exited", "ruby bin/dev"])
    compare(rows[1].state, "gone")
    compare(rows[1].win.name, "b")
  }

  function test_merge_with_null_ledger_shows_no_ghosts() {
    var live = [{session: "mirepoix", idx: 1, name: "a", windowId: "@1", serverPid: "7", serverStart: "70", paneCommands: {}}]
    var rows = Model.mergeWindows(live, {}, null, "mirepoix", "b00b1e55")
    compare(rows.length, 1)
    compare(rows[0].state, "live")
  }

  function test_server_restart_old_keys_become_ghosts_new_are_live() {
    var l = Model.parseLedger(ledgerFixture())
    var live = [{session: "mirepoix", idx: 1, name: "a", windowId: "@1", serverPid: "8", serverStart: "80",
                 paneCommands: {"%1": "bash"}}]
    var rows = Model.mergeWindows(live, Model.liveKeySet("b00b1e55", {"mirepoix": live}), l, "mirepoix", "b00b1e55")
    compare(rows.map(function(r) { return r.state }), ["live", "gone", "gone"])
  }

  function test_ghost_workspaces_and_bar_interleave() {
    var l = Model.parseLedger(ledgerFixture())
    var ghosts = Model.ghostWorkspaces(l, {"mirepoix": true})
    compare(ghosts.length, 1)
    compare(ghosts[0].name, "old")
    var bar = Model.barEntries([{id: 1}, {id: 3}, {id: 5}], ghosts)
    compare(bar.map(function(e) { return (e.ghost ? "g" : "w") + e.id }), ["w1", "w3", "g3", "w5"])
    compare(Model.ghostWorkspaces(null, {}).length, 0)
  }

  function test_recorder_status() {
    compare(Model.recorderStatus(null, 1000).installed, false)
    var fresh = Model.recorderStatus({last_full: 960}, 1000)
    verify(fresh.installed && !fresh.stale)
    compare(fresh.text, "recorded 40s ago")
    var stale = Model.recorderStatus({last_full: 280}, 1000)
    verify(stale.stale)
    compare(stale.text, "recorder stopped · 12m")
    verify(Model.recorderStatus({last_full: null}, 1000).stale)
  }

  function test_parse_ledger_drops_malformed_nested_entries() {
    var raw = JSON.stringify({version: 1, workspaces: {}, windows: {
      "ok": {session: "s", index: 1, name: "a", workspace: {id: 1, name: "s"}, panes: [{pane_id: "%1", claude: null, children: []}]},
      "badpane": {session: "s", index: 2, name: "b", workspace: null, panes: [5]},
      "badws": {session: "s", index: 3, name: "c", workspace: {id: "x", name: 3}, panes: []},
      "badkids": {session: "s", index: 4, name: "d", workspace: null, panes: [{pane_id: "%4", claude: null, children: "no"}]},
      "badclaude": {session: "s", index: 5, name: "e", workspace: null, panes: [{pane_id: "%5", claude: 7, children: []}]}
    }})
    var l = Model.parseLedger(raw)
    compare(Object.keys(l.windows), ["ok"])
  }

  function test_parse_tmux_windows_survives_prototype_session_names() {
    var lines = ["__proto__", "constructor"].map(function(name) {
      return [name, "1", "w", "0", "@1", "7", "70", "%1=bash;", "|"].join("\u001f")
    }).join("\n")
    var parsed = Model.parseTmuxWindows(0, lines, "")
    verify(parsed.valid)
    compare(parsed.bySession["__proto__"].length, 1)
    compare(parsed.bySession["constructor"].length, 1)
  }

  function test_caption_lines_one_claude_inline_several_on_their_own_lines() {
    var one = {panes: [{children: [
      {cmd: "claude", session: {name: "mirepoix-ios", status: "idle", kind: "interactive"}},
      {cmd: "ruby bin/dev"}]}]}
    compare(Model.captionLines(one), ["claude mirepoix-ios · idle · ruby bin/dev"])
    var two = {panes: [{children: [
      {cmd: "claude", session: {name: "android-21", status: "busy", kind: "interactive"}},
      {cmd: "claude", session: {name: "android", status: "idle", kind: "bg"}},
      {cmd: "npm run dev"}]}]}
    compare(Model.captionLines(two), ["claude android-21 · busy", "background android · idle", "npm run dev"])
    compare(Model.captionLines({panes: [{children: []}]}), [])
    compare(Model.captionLines(null), [])
  }

  // A JS array handed through a Repeater's modelData arrives array-LIKE (Array.isArray is
  // false, length and indexing work). The delegate must copy, never type-check.
  function test_string_list_copies_array_likes() {
    compare(Model.stringList({length: 2, 0: "a", 1: "b"}), ["a", "b"])
    compare(Model.stringList(["x"]), ["x"])
    compare(Model.stringList(null), [])
    compare(Model.stringList("oops"), [])
  }

  function test_open_label_swaps_the_middot_for_a_caret() {
    compare(Model.openLabel("2\u00b7mirepoix-native", true), "2\u25bemirepoix-native")
    compare(Model.openLabel("2\u00b7mirepoix-native", false), "2\u00b7mirepoix-native")
    compare(Model.openLabel("1\u00b7\uf0f3 mirepoix", true), "1\u25be\uf0f3 mirepoix")
    compare(Model.openLabel("7", true), "7")
  }

  function test_agent_gone_caption_names_the_exited_claude() {
    var l = Model.parseLedger(JSON.stringify({version: 1, workspaces: {}, windows: {
      "b00b1e55:7:70:@1": {session: "s", index: 1, name: "w", workspace: {id: 1, name: "s"}, restored_to: null,
        panes: [{pane_id: "%1", claude: {session_id: "u1", name: "home-folder-test"},
                 children: [{cmd: "claude", session: {name: "home-folder-test", status: "idle", kind: "interactive"}}]}]}}}))
    var live = [{session: "s", idx: 1, name: "w", windowId: "@1", serverPid: "7", serverStart: "70", paneCommands: {"%1": "bash"}}]
    var rows = Model.mergeWindows(live, Model.liveKeySet("b00b1e55", {"s": live}), l, "s", "b00b1e55")
    compare(rows[0].state, "agent-gone")
    compare(rows[0].caption, ["claude home-folder-test · exited"])
  }
}
