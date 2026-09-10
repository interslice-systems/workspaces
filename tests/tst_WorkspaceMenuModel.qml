import QtQuick
import QtTest
import "../WorkspaceMenuModel.js" as Model

TestCase {
  name: "WorkspaceMenuModel"

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
}
