.pragma library

var MAX_RESULT_CHARS = 2 * 1024 * 1024
var MAX_TITLE_CODEPOINTS = 1024
var MAX_URL_CODEPOINTS = 4096
var MAX_FAVICON_CHARS = 90000
var MAX_FAVICON_BYTES = 64 * 1024
var TAB_KEYS = ["active", "displayUrl", "favicon", "index", "tabId", "title", "windowId"]
var NATIVE_KEYS = ["cls", "key", "title"]
var BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

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
