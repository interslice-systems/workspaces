import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Rename-with-taste: the SUPER+ALT+N prompt, upgraded from omarchy-menu-input to
// a panel that shows, live as you type, the PILL YOU WOULD GET -- the sanitized
// name in its colorhash colour -- next to the current neighbour pills, so a
// colour collision or a surprising canonicalization is visible before Enter.
//
// THE DIALOG DISPLAYS, THE SCRIPT DECIDES. sanitizeName here is a preview
// mirror of wsid_session_name; Enter hands the RAW text to `ws-rename --apply`,
// which re-runs the real sanitizer and the real guards (bare number, special:,
// clash) and owns the tmux-vs-Hyprland rename plumbing. Duplicating the rules
// for pixels is fine; duplicating them for decisions would be drift.
//
// Built on KeyboardPanel, not PopupCard: this panel is keyboard-summoned
// (ws-rename calls `omarchy-shell shell summon interslice.workspaces`), and
// xdg-popups only receive keys after a click routes focus through their parent.
// KeyboardPanel's Exclusive-then-OnDemand focus prime exists for exactly this.
KeyboardPanel {
  id: dlg

  required property var ws   // the Workspaces widget root

  focusTarget: field
  centerOnBar: true
  contentWidth: fittedContentWidth(Style.space(440))
  contentHeight: fittedContentHeight(col.implicitHeight, Style.space(400))

  readonly property var fw: Hyprland.focusedWorkspace
  readonly property string currentName: fw ? ws.wsName(fw) : ""
  readonly property string cleaned: ws.sanitizeName(field.text)
  readonly property bool bareNumber: /^[0-9]+$/.test(cleaned)
  readonly property bool differs: cleaned !== "" && cleaned !== String(field.text)

  onOpenChanged: {
    if (open) {
      field.text = ws.renameSuggestion
      field.selectAll()
    }
  }

  Column {
    id: col
    width: parent.width
    spacing: Style.space(10)

    // The cwd/git suggestion arrives async (ws runs ws-name-suggest on open);
    // adopt it only while the field is still untouched. Lives inside the
    // Column because KeyboardPanel's contentItem alias takes Items only.
    Connections {
      target: dlg.ws
      function onRenameSuggestionChanged() {
        if (dlg.open && field.text === "") {
          field.text = dlg.ws.renameSuggestion
          field.selectAll()
        }
      }
    }

    Text {
      text: "Rename task space " + (dlg.fw ? dlg.fw.id : "")
            + (dlg.currentName ? "  (now: " + dlg.currentName + ")" : "")
      color: Color.foreground
      opacity: 0.7
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
    }

    TextField {
      id: field
      width: parent.width
      placeholderText: "task-space name"
      onAccepted: {
        if (dlg.cleaned === "" || dlg.cleaned === dlg.currentName) { dlg.close(); return }
        dlg.ws.applyRename(field.text)
      }
      Keys.onEscapePressed: dlg.close()
    }

    // The live preview: the bar as it WILL look, id order preserved -- the
    // preview pill sits in the renamed workspace's own slot among its real
    // neighbours, all one geometry so the row reads as the bar. Collisions
    // are a fact you can see, not a surprise you discover later.
    //
    // NEIGHBOURS USE THE BAR'S OWN UNFOCUSED GRAMMAR: flat text in the
    // cell's lightFg/darkFg, no fill. The first cut dimmed the filled pills
    // to 0.45 opacity instead, and the same orange cell read as brown next
    // to the full-strength preview -- Chris caught it as a "hash bug", which
    // is exactly what opacity-on-identity-colour looks like. De-emphasis must
    // never travel through the colour channel.
    Flow {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: dlg.open ? dlg.ws.workspaceList() : []
        Rectangle {
          id: slot
          required property var modelData
          readonly property bool isPreview: dlg.fw && modelData.id === dlg.fw.id
          readonly property string previewLabel: dlg.cleaned !== ""
            ? modelData.id + "·" + dlg.cleaned : String(modelData.id)

          readonly property var cell: dlg.ws.cellFor(dlg.ws.wsKey(modelData))
          readonly property bool lightGround:
            (0.2126 * Color.popups.background.r + 0.7152 * Color.popups.background.g
             + 0.0722 * Color.popups.background.b) > 0.5

          implicitHeight: slotText.implicitHeight + Style.space(8)
          implicitWidth: slotText.implicitWidth + height
          radius: height / 2
          color: isPreview && dlg.cleaned !== "" ? dlg.ws.fillFor(dlg.cleaned) : "transparent"
          border.width: isPreview && dlg.cleaned === "" ? 1 : 0
          border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.3)

          Text {
            id: slotText
            anchors.centerIn: parent
            text: slot.isPreview ? slot.previewLabel : dlg.ws.wsLabel(slot.modelData, false)
            color: slot.isPreview
              ? (dlg.cleaned !== "" ? dlg.ws.fillTextFor(dlg.cleaned) : Color.foreground)
              : (slot.cell ? (slot.lightGround ? slot.cell.lightFg : slot.cell.darkFg)
                           : Color.foreground)
            font.family: dlg.ws.nerdFamily
            font.pixelSize: Style.font.body
            font.bold: true
            renderType: Text.NativeRendering
          }
        }
      }
    }

    // Sanitizer and guard hints, shown before the script would notify.
    Text {
      visible: dlg.differs
      width: parent.width
      text: "will become '" + dlg.cleaned + "'"
      color: Color.foreground
      opacity: 0.6
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      renderType: Text.NativeRendering
    }
    Text {
      visible: dlg.bareNumber
      width: parent.width
      text: "bare numbers shadow workspace ids -- this will be refused"
      color: Color.foreground
      opacity: 0.6
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
    }
  }
}
