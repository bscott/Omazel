import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar entry for Omazel: a broom glyph whose color says whether the engine is
// running, paused, or complaining, with an optional count of the actions run
// this session. Left click opens the popup — folders with pause toggles, the
// recent activity feed, dry-run mode, and rule-file errors. Middle click
// pauses or resumes everything without opening anything.
BarWidget {
  id: root
  moduleName: "io.github.bscott.omazel"

  readonly property var engine: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

  readonly property string level: engine ? engine.level : "unconfigured"
  readonly property bool paused: engine ? engine.paused : false
  readonly property bool dryRun: engine ? engine.dryRun : false
  readonly property var folders: engine ? engine.folders : []
  readonly property var activity: engine ? engine.activity : []
  readonly property int actionsSession: engine ? engine.actionsSession : 0
  readonly property int nowSec: engine ? engine.nowSec : 0

  readonly property bool showActionCount: setting("showActionCount", true) === true
  readonly property int activityRows: {
    var n = parseInt(String(setting("activityRows", 8)), 10)
    return isFinite(n) ? Math.max(3, Math.min(20, n)) : 8
  }

  property bool popupOpen: false
  property bool editing: false

  function close() {
    popupOpen = false
    editing = false
  }

  function openEditor() {
    editorView.load()
    editing = true
  }

  // The engine polls and watches on the widget's configured cadence, but the
  // shell only hands settings to widget slots, so relay them across.
  Binding {
    target: root.engine
    property: "settings"
    value: root.settings
    when: root.engine !== null
  }

  // `omarchy-shell omazel show` / `omazel editor` open the UI from a script
  // or keybinding.
  Connections {
    target: root.engine
    function onPopupRequest(mode) {
      root.popupOpen = true
      if (mode === "editor") root.openEditor()
      else root.editing = false
    }
  }

  function shortPath(path) {
    if (!root.engine) return path
    var home = root.engine.home
    if (home !== "" && String(path).indexOf(home) === 0)
      return "~" + String(path).substring(home.length)
    return path
  }

  readonly property string statusLine: {
    if (!engine) return "Starting…"
    if (engine.configError !== "") return engine.configError
    if (!engine.configLoaded) return "Loading rules…"
    var text = engine.activeFolderCount + " folder" + (engine.activeFolderCount === 1 ? "" : "s")
      + " · " + engine.ruleCount + " rule" + (engine.ruleCount === 1 ? "" : "s")
    if (paused) return "Paused — " + text
    if (dryRun) return "Dry run — " + text
    return "Watching " + text
  }

  readonly property color glyphColor: {
    if (!bar) return "white"
    if (level === "error") return bar.urgent
    if (level === "paused" || level === "unconfigured")
      return Qt.darker(bar.barForeground, 1.6)
    return bar.barForeground
  }

  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(5)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.paused ? "󰂛" : (root.dryRun ? "󰈈" : "󰃢")
      color: root.glyphColor
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showActionCount && root.actionsSession > 0 && !root.bar.vertical
      text: String(root.actionsSession)
      color: root.glyphColor
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function (mouse) {
      if (mouse.button === Qt.MiddleButton) {
        if (root.engine) root.engine.setPaused(!root.paused)
        return
      }
      root.popupOpen = !root.popupOpen
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, "Omazel — " + root.statusLine)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(root.editing ? 500 : 340))
    contentHeight: popup.fittedContentHeight(root.editing
      ? editorView.desiredHeight : column.implicitHeight)

    Editor {
      id: editorView
      anchors.fill: parent
      visible: root.editing
      engine: root.engine
      bar: root.bar
      onDone: root.editing = false
    }

    Column {
      id: column
      anchors.fill: parent
      visible: !root.editing
      spacing: Style.space(10)

      // ------------------------------------------------------------- header
      Row {
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: "󰃢"
          color: root.level === "error" ? root.bar.urgent : root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.displayLarge
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          width: parent.width - Style.space(30)
          spacing: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            text: "Omazel"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            text: root.statusLine
            color: Qt.darker(root.bar.foreground, 1.3)
            textFormat: Text.PlainText
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
        }
      }

      // ----------------------------------------------------------- controls
      Row {
        spacing: Style.space(6)

        Button {
          iconText: root.paused ? "󰐊" : "󰏤"
          text: root.paused ? "Resume" : "Pause"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: if (root.engine) root.engine.setPaused(!root.paused)
        }

        Button {
          iconText: "󰑓"
          tooltipText: "Sweep folders now"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.engine ? root.engine.configLoaded && !root.engine.sweeping : false
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.engine) root.engine.sweepAll()
        }

        Button {
          text: "Edit rules"
          tooltipText: "Open the visual rule editor"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.openEditor()
        }

        Button {
          iconText: "󰏫"
          tooltipText: "Open rules in text editor"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.engine ? root.engine.rulesFileExists : false
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.engine) root.engine.editRules()
        }

        Button {
          iconText: "󰋽"
          tooltipText: "Open documentation — rule reference and examples"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: if (root.engine) root.engine.openDocs()
        }
      }

      // Dry-run switch, styled like a toggle row so its state is obvious.
      BorderSurface {
        id: dryToggle
        width: parent.width
        height: dryRow.implicitHeight + Style.space(12)
        radius: Style.spacing.labelGap
        color: root.dryRun
          ? Style.selectedFillFor(root.bar.foreground, Color.accent) : "transparent"
        borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

        Row {
          id: dryRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: dryToggle.borderLeft + Style.space(10)
          anchors.rightMargin: dryToggle.borderRight + Style.space(10)
          spacing: Style.space(10)

          Text {
            text: "󰈈"
            color: root.dryRun ? Color.accent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            width: Style.space(18)
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - Style.space(80)
            spacing: Style.space(1)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              text: "Dry run"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: root.dryRun
            }

            Text {
              text: "Log what rules would do, touch nothing"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            text: root.dryRun ? "ON" : "OFF"
            color: root.dryRun ? Color.accent : Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: root.dryRun
            width: Style.space(30)
            horizontalAlignment: Text.AlignRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.engine) root.engine.setDryRun(!root.dryRun)
        }
      }

      // ------------------------------------------------- missing rules file
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.engine ? !root.engine.rulesFileExists : false

        Text {
          text: "No rules yet. Build them visually, or start from the commented example file."
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Row {
          spacing: Style.space(6)

          Button {
            text: "Build rules visually"
            foreground: root.bar.foreground
            bordered: true
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.openEditor()
          }

          Button {
            text: "Create starter rules"
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: if (root.engine) root.engine.createStarterRules()
          }
        }
      }

      // ------------------------------------------------------------ folders
      PanelSeparator {
        visible: root.folders.length > 0
        foreground: root.bar.foreground
      }

      Column {
        id: folderList
        width: parent.width
        spacing: Style.space(4)
        visible: root.folders.length > 0

        Repeater {
          model: root.folders

          BorderSurface {
            id: folderRow
            required property var modelData

            readonly property bool folderPaused: root.engine
              ? root.engine.pausedFolders[modelData.path] === true : false

            width: folderList.width
            height: folderInner.implicitHeight + Style.space(10)
            radius: Style.spacing.labelGap
            color: "transparent"
            borderSpec: Border.none()

            Row {
              id: folderInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(8)

              Text {
                text: "󰉋"
                color: folderRow.folderPaused
                  ? Qt.darker(root.bar.foreground, 1.8) : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                width: Style.space(18)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(52)
                spacing: Style.space(1)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: root.shortPath(folderRow.modelData.path)
            textFormat: Text.PlainText
                  color: folderRow.folderPaused
                    ? Qt.darker(root.bar.foreground, 1.6) : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideMiddle
                  width: parent.width
                }

                Text {
                  text: folderRow.modelData.rules.length + " rule"
                    + (folderRow.modelData.rules.length === 1 ? "" : "s")
                    + (folderRow.modelData.recursive ? " · recursive" : "")
                    + (folderRow.folderPaused ? " · paused" : "")
                  textFormat: Text.PlainText
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                text: folderRow.folderPaused ? "󰐊" : "󰏤"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: Style.space(18)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.engine) root.engine.toggleFolderPause(folderRow.modelData.path)
              onEntered: if (root.bar) root.bar.showTooltip(folderRow,
                folderRow.folderPaused ? "Resume this folder" : "Pause this folder")
              onExited: if (root.bar) root.bar.hideTooltip(folderRow)
            }
          }
        }
      }

      // ----------------------------------------------------------- activity
      PanelSeparator {
        visible: root.activity.length > 0
        foreground: root.bar.foreground
      }

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.activity.length > 0

        Repeater {
          model: root.activity.slice(0, root.activityRows)

          Row {
            id: activityRow
            required property var modelData

            readonly property bool isError: modelData.status === "error"
            readonly property bool isDry: modelData.status === "dryrun"

            width: parent.width
            spacing: Style.space(8)

            Text {
              text: Model.verbIcon(activityRow.modelData.verb)
              color: activityRow.isError ? root.bar.urgent
                : activityRow.isDry ? Color.accent
                : Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: Style.space(18)
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              width: parent.width - Style.space(70)
              spacing: 0

              Text {
                text: {
                  var m = activityRow.modelData
                  var head = (activityRow.isDry ? "Would have: " : "")
                    + Model.verbLabel(m.verb) + " " + m.file
                  if (m.dest !== "")
                    head += " → " + root.shortPath(m.dest)
                  return head
                }
                color: activityRow.isError
                  ? root.bar.urgent : root.bar.foreground
            textFormat: Text.PlainText
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
                width: parent.width
              }

              Text {
                text: activityRow.modelData.rule
                  + (activityRow.modelData.message !== ""
                    ? " · " + activityRow.modelData.message : "")
                textFormat: Text.PlainText
                color: activityRow.isError
                  ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
                visible: text !== ""
              }
            }

            Text {
              text: Model.fmtAgo(activityRow.modelData.epoch, root.nowSec)
              color: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              width: Style.space(44)
              horizontalAlignment: Text.AlignRight
            }
          }
        }
      }

      // ------------------------------------------------- warnings and errors
      Text {
        text: {
          if (!root.engine || root.engine.missing.length === 0) return ""
          var parts = []
          for (var i = 0; i < root.engine.missing.length; i++) {
            parts.push(root.engine.missing[i].tool + " (" + root.engine.missing[i].why + ")")
          }
          return "Missing tools: " + parts.join(", ")
        }
            textFormat: Text.PlainText
        color: root.bar.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
        visible: text !== ""
      }

      Text {
        text: {
          if (!root.engine || root.engine.configErrors.length === 0) return ""
          var shown = root.engine.configErrors.slice(0, 3)
          var out = "Rule problems:\n• " + shown.join("\n• ")
          if (root.engine.configErrors.length > 3)
            out += "\n… and " + (root.engine.configErrors.length - 3) + " more"
          return out
        }
        color: root.bar.urgent
            textFormat: Text.PlainText
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
        visible: text !== ""
      }

      Text {
        text: root.engine ? root.engine.lastError : ""
            textFormat: Text.PlainText
        color: root.bar.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
        visible: text !== ""

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.engine) root.engine.clearError()
        }
      }

      // --------------------------------------------------------- update row
      BorderSurface {
        id: updateRow
        width: parent.width
        height: updateInner.implicitHeight + Style.space(12)
        radius: Style.spacing.labelGap
        color: "transparent"
        borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)
        visible: root.engine
          ? (root.engine.updateAvailable || root.engine.updateStatus !== "") : false

        Row {
          id: updateInner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: updateRow.borderLeft + Style.space(10)
          anchors.rightMargin: updateRow.borderRight + Style.space(10)
          spacing: Style.space(10)

          Text {
            text: "󰚰"
            color: Color.accent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            width: Style.space(18)
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - Style.space(30)
            spacing: Style.space(1)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              text: {
                if (!root.engine) return ""
                if (root.engine.updateStatus !== "") return root.engine.updateStatus
                var head = "Update available"
                if (root.engine.updateSubject !== "") head += " — " + root.engine.updateSubject
                return head
              }
            textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.engine && root.engine.updateBlocked
                ? root.engine.updateBlockedReason
                : "Click to install"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              visible: root.engine ? root.engine.updateAvailable : false
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: root.engine && root.engine.canUpdate
            ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: if (root.engine && root.engine.canUpdate) root.engine.applyUpdate()
        }
      }
    }
  }
}
