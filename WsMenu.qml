import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "WorkspaceMenuModel.js" as WorkspaceMenuModel

// Right-click menu for ONE workspace pill: just the windows inside it,
// slid down under the pill --
//
//     ( 2·mirepoix )
//       1·oracle
//       2✳·shell
//       ──────────
//       firefox · Quickshell docs
//
// This replaced the hover-the-whole-switcher tree card (2026-08-28, Chris's
// call after living with it for a day): a deliberate gesture beats dwell
// timers, and per-pill scoping means no open/close choreography at all --
// PopupCard's click mode brings HyprlandFocusGrab, so clicking anywhere
// else dismisses it for free.
//
// ACTIONABLE ROWS ARE FULL-WIDTH HIT TARGETS (Fitts's law, same reasoning as
// the bar pills' full-height hit boxes). While Firefox activation is in flight,
// every row is disabled so a second action cannot replace its native target.
//
// Data contract is unchanged from the tree card: Hyprland toplevels live from
// the workspace's in-memory model; the tmux half (window list, @claude_state/bell marks,
// client addresses) is the owner's one-shot snapshot, fetched on open and
// re-fetched on bell/urgent raw events while open. Marks are glyphs, colour
// is identity: tmux rows hash the WINDOW NAME (cells[fnv1a32(name) % n],
// matching @wsid_wfg in the tmux bar -- never the index, see wsid-tmux-colors
// on the retired @wsid_win1..6); bare rows are plain foreground, class·title
// is nobody's chosen name.
PopupCard {
  id: card

  required property var ws       // the Workspaces widget root
  property var targetWs: null    // the HyprlandWorkspace this menu describes
  property var targetGhost: null // {name, id}: a workspace that exists only in the ws-blackbox ledger
  readonly property int targetId: targetWs ? targetWs.id : (targetGhost ? targetGhost.id : -1)

  triggerMode: "click"
  contentWidth: fittedContentWidth(Math.max(Style.space(280), col.implicitWidth + padding * 2), Style.space(560))
  contentHeight: fittedContentHeight(col.implicitHeight, Style.space(560))

  readonly property color cardGround: Color.popups.background
  readonly property bool lightCard: (0.2126 * cardGround.r + 0.7152 * cardGround.g + 0.0722 * cardGround.b) > 0.5
  readonly property url firefoxFallbackIcon: Qt.resolvedUrl("assets/firefox.png")

  function nameFg(name) {
    if (!ws.cells.length || !name) return Color.foreground
    var c = ws.cells[ws.fnv1a32(name) % ws.cells.length]
    return card.lightCard ? c.lightFg : c.darkFg
  }

  // Flat row model for the target workspace: tmux windows, a divider when
  // both groups are present, then native toplevels with unique Firefox matches
  // expanded in place. The Hyprland side re-renders live; the tmux side moves
  // when the owner replaces the snapshot.
  //
  // ws-blackbox: tmux rows are the live windows MERGED with the recorder's ledger, so a
  // window that disappeared keeps its place as a `gone` row. A ghost target (a workspace
  // that exists only in the ledger) has no toplevels: tmux rows only, plus its actions.
  function targetName() {
    return card.targetWs ? ws.wsName(card.targetWs) : (card.targetGhost ? card.targetGhost.name : "")
  }

  function rows() {
    var out = card.coreRows()
    try {
      if (ws.menuLoading || (!card.targetWs && !card.targetGhost)) return out
      var gone = 0
      for (var i = 0; i < out.length; i++)
        if (out[i].row && out[i].row.state === "gone") gone++
      if (gone >= 2) out.push({kind: "dismiss-all", name: card.targetName()})
      if (ws.recorder && ws.recorder.installed) out.push({kind: "recorder", text: ws.recorder.text})
    } catch (error) {}
    return out
  }

  function coreRows() {
    var out = []
    try {
      if (!card.targetWs && !card.targetGhost) return []
      if (ws.menuLoading) return []

      var workspaceName = card.targetName()
      var tmuxRows = (workspaceName && ws.tmuxWindows[workspaceName])
        ? ws.tmuxWindows[workspaceName] : []
      var merged = WorkspaceMenuModel.mergeWindows(tmuxRows, ws.tmuxLiveKeys,
        (ws.tmuxLiveValid && ws.bootId8) ? ws.ledger : null, workspaceName, ws.bootId8)
      if (card.targetGhost) out.push({kind: "ghost-actions", name: workspaceName})
      for (var i = 0; i < merged.length; i++)
        out.push({kind: "tmux", win: merged[i].win, row: merged[i]})
      if (!card.targetWs) return out

      var bareRows = []
      var nativeWindows = []
      var nativeEvidenceComplete = true
      var toplevels
      var toplevelCount
      try {
        var collection = card.targetWs.toplevels
        toplevels = collection ? collection.values : null
        if (!toplevels || typeof toplevels.length !== "number") return out
        toplevelCount = toplevels.length
        if (!isFinite(toplevelCount) || Math.floor(toplevelCount) !== toplevelCount
            || toplevelCount < 0) return out
      } catch (error) {
        return out
      }

      for (var j = 0; j < toplevelCount; j++) {
        try {
          var toplevel = toplevels[j]
          if (!toplevel || typeof toplevel !== "object") {
            nativeEvidenceComplete = false
            continue
          }
          var ipc = toplevel.lastIpcObject
          if (!ipc || typeof ipc !== "object") {
            nativeEvidenceComplete = false
            continue
          }

          var address = String(ipc.address || "")
          var key = "native-" + String(j)
          var cls = String(ipc["class"] || "")
          var title = String(toplevel.title || "")
          var tmuxOwned = false
          try {
            tmuxOwned = Boolean(address && ws.tmuxAddrs[address])
          } catch (error) {
            nativeEvidenceComplete = false
          }
          if (tmuxOwned) continue

          bareRows.push({kind: "bare", key: key, cls: cls, title: title, top: toplevel})
          nativeWindows.push({key: key, cls: cls, title: title})
        } catch (error) {
          nativeEvidenceComplete = false
        }
      }

      var correlations = nativeEvidenceComplete
        ? WorkspaceMenuModel.correlateFirefox(nativeWindows, ws.firefoxTabs)
        : Object.create(null)
      var expanded = []
      for (var k = 0; k < bareRows.length; k++) {
        var bare = bareRows[k]
        var match = correlations[bare.key]
        if (!match) {
          expanded.push(bare)
          continue
        }
        for (var tabIndex = 0; tabIndex < match.tabs.length; tabIndex++) {
          expanded.push({
            kind: "firefox-tab",
            tab: match.tabs[tabIndex],
            windowId: match.windowId,
            top: bare.top
          })
        }
      }

      if (tmuxRows.length && expanded.length) out.push({kind: "div"})
      return out.concat(expanded)
    } catch (error) {
      return out
    }
  }

  Flickable {
    id: menuFlick
    width: parent.width
    height: parent.height
    contentWidth: width
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: col
      width: menuFlick.width

      Repeater {
        model: card.open ? card.rows() : []

        Rectangle {
          id: rowRect
          required property var modelData
          readonly property bool isDiv: modelData.kind === "div"
          readonly property bool isTmux: modelData.kind === "tmux"
          readonly property bool isFirefox: modelData.kind === "firefox-tab"
          readonly property bool isActiveFirefox: isFirefox && modelData.tab.active === true
          readonly property string rowState: isTmux && modelData.row ? modelData.row.state : ""
          readonly property bool isGone: rowState === "gone"
          readonly property bool isAgentGone: rowState === "agent-gone"
          readonly property string caption: isTmux && modelData.row ? modelData.row.caption : ""
          readonly property bool isGhostActions: modelData.kind === "ghost-actions"
          readonly property bool isDismissAll: modelData.kind === "dismiss-all"
          readonly property bool isRecorder: modelData.kind === "recorder"
          // Each row reports its natural width so the card sizes to its widest row (between
          // the 280 floor and the 560 cap); anything longer elides in the middle.
          readonly property real naturalWidth: isDiv ? 0
            : (isFirefox
              ? Style.space(42) + Math.max(ffTitleMetrics.advanceWidth, ffUrlMetrics.advanceWidth)
              : (isGhostActions ? ghostActionsRow.implicitWidth + Style.space(8)
                : Style.space(16) + buttons.width
                  + Math.max(rowText.implicitWidth, captionText.visible ? captionText.implicitWidth + Style.space(12) : 0)))
          implicitWidth: rowRect.naturalWidth

          TextMetrics {
            id: ffTitleMetrics
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            text: rowRect.isFirefox ? rowRect.modelData.tab.title : ""
          }
          TextMetrics {
            id: ffUrlMetrics
            font.family: card.ws.nerdFamily
            font.pixelSize: Style.font.caption
            text: rowRect.isFirefox ? rowRect.modelData.tab.displayUrl : ""
          }

          width: col.width
          implicitHeight: isDiv ? Style.space(9)
            : (isFirefox ? Style.space(42)
              : rowText.implicitHeight + (captionText.visible ? captionText.implicitHeight : 0) + Style.space(12))
          radius: Style.space(4)
          color: !isDiv && rowArea.containsMouse
            ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
            : (isActiveFirefox
              ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
              : "transparent")

          Rectangle {
            visible: rowRect.isDiv
            anchors.centerIn: parent
            width: parent.width - Style.space(12)
            height: 1
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
          }

          Text {
            id: rowText
            visible: !rowRect.isDiv && !rowRect.isFirefox && !rowRect.isGhostActions
            anchors.verticalCenter: captionText.visible ? undefined : parent.verticalCenter
            anchors.top: captionText.visible ? parent.top : undefined
            anchors.topMargin: Style.space(6)
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            width: parent.width - Style.space(16) - buttons.width
            // State is carried by WORDS and opacity, never hue alone (the name keeps its colour).
            text: rowRect.isTmux
              ? WorkspaceMenuModel.tmuxWindowLabel(rowRect.modelData.win.idx,
                                                   rowRect.modelData.win.name,
                                                   rowRect.modelData.win.state,
                                                   rowRect.modelData.win.bell)
                + (rowRect.isGone ? " gone" : (rowRect.isAgentGone ? " agent gone" : ""))
              : (rowRect.isDismissAll ? "dismiss all gone"
                : (rowRect.isRecorder ? rowRect.modelData.text
                  : (rowRect.modelData.top && rowRect.modelData.top.urgent === true ? card.ws.bellGlyph + " " : "")
                    + rowRect.modelData.cls
                    + (rowRect.modelData.title ? " · " + rowRect.modelData.title : "")))
            textFormat: Text.PlainText
            color: rowRect.isTmux ? card.nameFg(rowRect.modelData.win.name) : Color.foreground
            opacity: rowRect.isGone ? 0.45 : (rowRect.isRecorder ? 0.5 : (rowRect.isTmux ? 1.0 : 0.85))
            font.family: card.ws.nerdFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideMiddle
            renderType: Text.NativeRendering
          }

          // What was running in the window, as of the recorder's last tick (read-only detail).
          Text {
            id: captionText
            visible: rowRect.caption !== ""
            anchors.top: rowText.bottom
            anchors.left: rowText.left
            anchors.leftMargin: Style.space(12)
            width: rowText.width - Style.space(12)
            text: rowRect.caption
            textFormat: Text.PlainText
            color: Color.foreground
            opacity: rowRect.isGone ? 0.35 : 0.6
            font.family: card.ws.nerdFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
            renderType: Text.NativeRendering
          }

          Item {
            id: faviconSlot
            visible: rowRect.isFirefox
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(18)
            height: Style.space(18)

            Image {
              anchors.fill: parent
              source: card.firefoxFallbackIcon
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              fillMode: Image.PreserveAspectFit
              smooth: true
              visible: faviconImage.status !== Image.Ready
            }

            Image {
              id: faviconImage
              anchors.fill: parent
              source: rowRect.isFirefox
                ? WorkspaceMenuModel.safeFavicon(rowRect.modelData.tab.favicon) : ""
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              visible: status === Image.Ready
            }
          }

          Column {
            visible: rowRect.isFirefox
            anchors.left: faviconSlot.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
              width: parent.width
              text: rowRect.isFirefox ? rowRect.modelData.tab.title : ""
              textFormat: Text.PlainText
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: rowRect.isActiveFirefox
              elide: Text.ElideMiddle
              wrapMode: Text.NoWrap
              renderType: Text.NativeRendering
            }

            Text {
              width: parent.width
              text: rowRect.isFirefox ? rowRect.modelData.tab.displayUrl : ""
              textFormat: Text.PlainText
              color: Color.foreground
              opacity: 0.55
              font.family: card.ws.nerdFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
              wrapMode: Text.NoWrap
              renderType: Text.NativeRendering
            }
          }

          MouseArea {
            id: rowArea
            enabled: !rowRect.isDiv && !card.ws.firefoxActivating
              && !rowRect.isGone && !rowRect.isRecorder && !rowRect.isGhostActions
            anchors.fill: parent
            anchors.rightMargin: buttons.width
            hoverEnabled: true
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              if (rowRect.isDismissAll) {
                card.ws.blackbox(["dismiss", "--workspace", rowRect.modelData.name])
                return
              }
              if (rowRect.isTmux) {
                card.ws.focusTmuxWindow(rowRect.modelData.win.session, rowRect.modelData.win.idx, card.targetId)
                card.close()
                return
              }
              if (rowRect.isFirefox) {
                card.ws.activateFirefoxTab(rowRect.modelData.windowId, rowRect.modelData.tab.tabId,
                                           rowRect.modelData.top, card.targetId)
                return
              }
              card.ws.focusToplevel(rowRect.modelData.top, card.targetId)
              card.close()
            }
          }

          // Declared AFTER rowArea so these sit on top of it and get their own clicks.
          // Ghost-workspace header: two full-height text buttons.
          Row {
            id: ghostActionsRow
            visible: rowRect.isGhostActions
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            spacing: Style.space(16)
            Repeater {
              model: rowRect.isGhostActions
                ? [{label: "Restore workspace", verb: "restore"}, {label: "Dismiss workspace", verb: "dismiss"}] : []
              Item {
                id: actionItem
                required property var modelData
                width: actionText.implicitWidth + Style.space(8)
                height: parent.height
                Text {
                  id: actionText
                  anchors.verticalCenter: parent.verticalCenter
                  text: actionItem.modelData.label
                  color: Color.foreground
                  font.family: card.ws.nerdFamily
                  font.pixelSize: Style.font.body
                  font.underline: actionArea.containsMouse
                  renderType: Text.NativeRendering
                }
                MouseArea {
                  id: actionArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    card.ws.blackbox([actionItem.modelData.verb, "--workspace", rowRect.modelData.name])
                    card.close()
                  }
                }
              }
            }
          }

          // restore / dismiss: full-height hit targets on the right edge.
          Row {
            id: buttons
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: visible ? implicitWidth : 0
            visible: rowRect.isGone || rowRect.isAgentGone
            Repeater {
              model: rowRect.isGone ? (card.targetGhost ? ["dismiss"] : ["restore", "dismiss"])
                : (rowRect.isAgentGone ? ["restore"] : [])
              Item {
                id: btn
                required property string modelData
                width: Style.space(28)
                height: buttons.height
                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(4)
                  color: btnArea.containsMouse
                    ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2) : "transparent"
                }
                Text {
                  anchors.centerIn: parent
                  text: btn.modelData === "restore" ? "\u21ba" : "\u2715"
                  color: Color.foreground
                  font.pixelSize: Style.font.body
                  renderType: Text.NativeRendering
                }
                MouseArea {
                  id: btnArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var r = rowRect.modelData.row
                    if (btn.modelData === "dismiss") card.ws.blackbox(["dismiss", r.key])
                    else if (r.state === "agent-gone") card.ws.blackbox(["restore", "--pane", r.key, r.paneId])
                    else card.ws.blackbox(["restore", r.key])
                  }
                }
              }
            }
          }
        }
      }

      Text {
        visible: card.open && card.rows().filter(function(r) { return r.kind !== "recorder" }).length === 0
        text: card.ws.menuLoading ? "loading..." : "no windows"
        color: Color.foreground
        opacity: 0.5
        leftPadding: Style.space(8)
        topPadding: Style.space(6)
        bottomPadding: Style.space(6)
        font.family: card.ws.nerdFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }
    }
  }
}
