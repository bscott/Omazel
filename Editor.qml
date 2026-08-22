import QtQuick
import qs.Ui
import qs.Commons
import "Model.js" as Model

// The visual rule editor, shown inside the widget's popup as an alternative
// to editing rules.toml by hand. It edits a plain-JS "draft" (see Model.js):
// text fields and toggles mutate the draft in place so typing never rebuilds
// the view, while structural changes — adding, removing, or reordering
// folders, rules, conditions, and actions — clone the draft to refresh the
// Repeaters. Save validates through the engine's own compiler and only
// writes a file the engine is guaranteed to load.
Item {
  id: root

  property var engine: null
  property QtObject bar: null

  signal done()

  property var draft: []
  property var errors: []
  property bool parseFailed: false

  // What the popup should size the card to; the Flickable scrolls once the
  // screen caps it.
  readonly property real desiredHeight: header.implicitHeight + Style.space(10)
    + body.implicitHeight + Style.space(10) + footer.implicitHeight

  readonly property color fg: bar ? bar.foreground : "white"

  function load() {
    errors = []
    parseFailed = false
    var raw = {}
    if (engine && engine.rulesText !== "") {
      var parsed = Model.parseToml(engine.rulesText)
      if (!parsed.ok) {
        // Overwriting a file we could not read would destroy whatever the
        // syntax error is hiding; send the user to the text editor instead.
        parseFailed = true
        errors = [parsed.error]
        draft = []
        return
      }
      raw = parsed.value
    }
    draft = Model.draftFromRaw(raw)
    if (draft.length === 0) draft = [Model.newDraftFolder()]
  }

  // Structural change: clone so every Repeater re-reads the draft.
  function commit() {
    draft = JSON.parse(JSON.stringify(draft))
  }

  function moveItem(list, index, delta) {
    var to = index + delta
    if (to < 0 || to >= list.length) return
    var item = list.splice(index, 1)[0]
    list.splice(to, 0, item)
    commit()
  }

  function save() {
    var result = Model.validateDraft(draft, engine ? engine.home : "")
    errors = result.errors
    if (result.errors.length > 0) return
    if (engine) engine.saveRules(result.text)
    done()
  }

  // ------------------------------------------------------------------ header

  Row {
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(8)

    Text {
      text: "Edit rules"
      color: root.fg
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - saveButton.width - cancelButton.width - Style.space(16)
      elide: Text.ElideRight
    }

    Button {
      id: cancelButton
      text: "Cancel"
      foreground: root.fg
      onClicked: root.done()
    }

    Button {
      id: saveButton
      text: "Save"
      foreground: root.fg
      bordered: true
      enabled: !root.parseFailed
      opacity: enabled ? 1.0 : 0.4
      onClicked: root.save()
    }
  }

  // -------------------------------------------------------------------- body

  Flickable {
    id: flick
    anchors.top: header.bottom
    anchors.topMargin: Style.space(10)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: footer.top
    anchors.bottomMargin: Style.space(10)
    contentWidth: width
    contentHeight: body.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: body
      width: flick.width
      spacing: Style.space(10)

      Text {
        visible: root.parseFailed
        text: "The rules file has a syntax error, so the visual editor cannot "
          + "load it without losing content. Fix it in the text editor first."
        color: root.bar ? root.bar.urgent : "red"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }

      // ---------------------------------------------------------- folders
      Repeater {
        model: root.draft

        BorderSurface {
          id: folderCard
          required property var modelData
          required property int index
          readonly property var folder: modelData

          width: body.width
          height: folderColumn.implicitHeight + Style.space(20)
          radius: Style.spacing.labelGap
          color: "transparent"
          borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

          Column {
            id: folderColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: folderCard.borderLeft + Style.space(10)
            anchors.rightMargin: folderCard.borderRight + Style.space(10)
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "󰉋"
                color: root.fg
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              TextField {
                width: parent.width - Style.space(64)
                foreground: root.fg
                text: folderCard.folder.path
                placeholderText: "~/Downloads"
                onTextEdited: folderCard.folder.path = text
              }

              Button {
                iconText: "󰅖"
                tooltipText: "Remove folder"
                foreground: root.fg
                anchors.verticalCenter: parent.verticalCenter
                onClicked: {
                  root.draft.splice(folderCard.index, 1)
                  root.commit()
                }
              }
            }

            Row {
              spacing: Style.space(14)

              Row {
                spacing: Style.space(6)
                Text {
                  text: "Recursive"
                  color: Qt.darker(root.fg, 1.4)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                ToggleSwitch {
                  foreground: root.fg
                  checked: folderCard.folder.recursive === true
                  onToggled: { checked = !checked; folderCard.folder.recursive = checked }
                }
              }

              Row {
                spacing: Style.space(6)
                Text {
                  text: "Enabled"
                  color: Qt.darker(root.fg, 1.4)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                ToggleSwitch {
                  foreground: root.fg
                  checked: folderCard.folder.enabled !== false
                  onToggled: { checked = !checked; folderCard.folder.enabled = checked }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "Ignore"
                color: Qt.darker(root.fg, 1.4)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                width: Style.space(52)
                anchors.verticalCenter: parent.verticalCenter
              }

              TextField {
                width: parent.width - Style.space(58)
                foreground: root.fg
                text: folderCard.folder.ignore
                placeholderText: "extra globs — *.iso, keep-*"
                onTextEdited: folderCard.folder.ignore = text
              }
            }

            // ------------------------------------------------------ rules
            Repeater {
              model: folderCard.folder.rules

              BorderSurface {
                id: ruleCard
                required property var modelData
                required property int index
                readonly property var rule: modelData

                width: folderColumn.width
                height: ruleColumn.implicitHeight + Style.space(16)
                radius: Style.spacing.labelGap
                color: Style.normalFillFor(root.fg, Color.accent)
                borderSpec: Border.none()

                Column {
                  id: ruleColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(6)

                  Row {
                    width: parent.width
                    spacing: Style.space(4)

                    TextField {
                      width: parent.width - Style.space(96)
                      foreground: root.fg
                      text: ruleCard.rule.name
                      placeholderText: "Rule name"
                      onTextEdited: ruleCard.rule.name = text
                    }

                    Button {
                      iconText: "󰅃"
                      tooltipText: "Move rule up"
                      foreground: root.fg
                      enabled: ruleCard.index > 0
                      opacity: enabled ? 1.0 : 0.3
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.moveItem(folderCard.folder.rules, ruleCard.index, -1)
                    }

                    Button {
                      iconText: "󰅀"
                      tooltipText: "Move rule down"
                      foreground: root.fg
                      enabled: ruleCard.index < folderCard.folder.rules.length - 1
                      opacity: enabled ? 1.0 : 0.3
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.moveItem(folderCard.folder.rules, ruleCard.index, 1)
                    }

                    Button {
                      iconText: "󰅖"
                      tooltipText: "Remove rule"
                      foreground: root.fg
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: {
                        folderCard.folder.rules.splice(ruleCard.index, 1)
                        root.commit()
                      }
                    }
                  }

                  Text {
                    text: "If…"
                    color: Qt.darker(root.fg, 1.4)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    visible: ruleCard.rule.conditions.length === 0
                    text: "No conditions — matches every file"
                    color: Qt.darker(root.fg, 1.6)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  // ---------------------------------------- conditions
                  Repeater {
                    model: ruleCard.rule.conditions

                    Row {
                      id: condRow
                      required property var modelData
                      required property int index
                      readonly property var cond: modelData

                      width: ruleColumn.width
                      spacing: Style.space(4)

                      Dropdown {
                        width: Style.space(64)
                        showLabel: false
                        foreground: root.fg
                        value: condRow.cond.group
                        options: Model.GROUP_OPTIONS
                        onChanged: function (v) { condRow.cond.group = v }
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Dropdown {
                        width: Style.space(100)
                        showLabel: false
                        foreground: root.fg
                        value: condRow.cond.field
                        options: Model.FIELD_OPTIONS
                        onChanged: function (v) {
                          condRow.cond.field = v
                          var ops = Model.opsForField(v)
                          var valid = false
                          for (var i = 0; i < ops.length; i++)
                            if (ops[i].value === condRow.cond.op) valid = true
                          if (!valid) condRow.cond.op = ops[0].value
                          opDrop.options = ops
                          opDrop.value = condRow.cond.op
                        }
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Dropdown {
                        id: opDrop
                        width: Style.space(110)
                        showLabel: false
                        foreground: root.fg
                        value: condRow.cond.op
                        options: Model.opsForField(condRow.cond.field)
                        onChanged: function (v) { condRow.cond.op = v }
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      TextField {
                        width: condRow.width - Style.space(64 + 100 + 110 + 30) - Style.space(16)
                        foreground: root.fg
                        text: condRow.cond.value
                        placeholderText: Model.valuePlaceholder(condRow.cond.field, condRow.cond.op)
                        onTextEdited: condRow.cond.value = text
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Button {
                        iconText: "󰅖"
                        tooltipText: "Remove condition"
                        foreground: root.fg
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: {
                          ruleCard.rule.conditions.splice(condRow.index, 1)
                          root.commit()
                        }
                      }
                    }
                  }

                  Button {
                    text: "+ condition"
                    foreground: Qt.darker(root.fg, 1.3)
                    onClicked: {
                      ruleCard.rule.conditions.push(Model.newDraftCondition())
                      root.commit()
                    }
                  }

                  Text {
                    text: "Then…"
                    color: Qt.darker(root.fg, 1.4)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  // ------------------------------------------- actions
                  Repeater {
                    model: ruleCard.rule.actions

                    Column {
                      id: actionRow
                      required property var modelData
                      required property int index
                      readonly property var act: modelData

                      // Bumped when the verb or provider changes so the
                      // params Repeater re-reads which inputs to show.
                      property int paramsRev: 0

                      width: ruleColumn.width
                      spacing: Style.space(4)

                      Row {
                        width: parent.width
                        spacing: Style.space(4)

                        Dropdown {
                          width: Style.space(150)
                          showLabel: false
                          foreground: root.fg
                          value: actionRow.act.verb
                          options: Model.ACTION_OPTIONS
                          onChanged: function (v) {
                            actionRow.act.verb = v
                            actionRow.act.params = Model.defaultParamsFor(v)
                            actionRow.paramsRev++
                          }
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Item { width: parent.width - Style.space(150 + 90) - Style.space(16); height: 1 }

                        Button {
                          iconText: "󰅃"
                          tooltipText: "Move action up"
                          foreground: root.fg
                          enabled: actionRow.index > 0
                          opacity: enabled ? 1.0 : 0.3
                          anchors.verticalCenter: parent.verticalCenter
                          onClicked: root.moveItem(ruleCard.rule.actions, actionRow.index, -1)
                        }

                        Button {
                          iconText: "󰅀"
                          tooltipText: "Move action down"
                          foreground: root.fg
                          enabled: actionRow.index < ruleCard.rule.actions.length - 1
                          opacity: enabled ? 1.0 : 0.3
                          anchors.verticalCenter: parent.verticalCenter
                          onClicked: root.moveItem(ruleCard.rule.actions, actionRow.index, 1)
                        }

                        Button {
                          iconText: "󰅖"
                          tooltipText: "Remove action"
                          foreground: root.fg
                          anchors.verticalCenter: parent.verticalCenter
                          onClicked: {
                            ruleCard.rule.actions.splice(actionRow.index, 1)
                            root.commit()
                          }
                        }
                      }

                      Repeater {
                        model: {
                          void actionRow.paramsRev
                          return Model.actionParams(actionRow.act.verb, actionRow.act.params)
                        }

                        Row {
                          id: paramRow
                          required property var modelData
                          readonly property var param: modelData

                          width: actionRow.width
                          spacing: Style.space(6)

                          Text {
                            text: paramRow.param.label
                            color: Qt.darker(root.fg, 1.4)
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            width: Style.space(110)
                            elide: Text.ElideRight
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          TextField {
                            visible: paramRow.param.type === "text"
                            width: paramRow.width - Style.space(122)
                            foreground: root.fg
                            text: {
                              var v = actionRow.act.params[paramRow.param.key]
                              return v === undefined ? "" : String(v)
                            }
                            placeholderText: paramRow.param.placeholder || ""
                            onTextEdited: actionRow.act.params[paramRow.param.key] = text
                          }

                          Dropdown {
                            visible: paramRow.param.type === "choice"
                            width: Style.space(160)
                            showLabel: false
                            foreground: root.fg
                            value: {
                              var v = actionRow.act.params[paramRow.param.key]
                              return v === undefined ? "" : String(v)
                            }
                            options: paramRow.param.options || []
                            onChanged: function (v) {
                              actionRow.act.params[paramRow.param.key] = v
                              actionRow.paramsRev++
                            }
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          ToggleSwitch {
                            visible: paramRow.param.type === "bool"
                            foreground: root.fg
                            checked: actionRow.act.params[paramRow.param.key] === true
                            onToggled: {
                              checked = !checked
                              actionRow.act.params[paramRow.param.key] = checked
                            }
                            anchors.verticalCenter: parent.verticalCenter
                          }
                        }
                      }
                    }
                  }

                  Button {
                    text: "+ action"
                    foreground: Qt.darker(root.fg, 1.3)
                    onClicked: {
                      ruleCard.rule.actions.push(Model.newDraftAction())
                      root.commit()
                    }
                  }
                }
              }
            }

            Button {
              text: "+ rule"
              foreground: Qt.darker(root.fg, 1.3)
              onClicked: {
                folderCard.folder.rules.push(Model.newDraftRule())
                root.commit()
              }
            }
          }
        }
      }

      Button {
        visible: !root.parseFailed
        text: "+ watched folder"
        foreground: root.fg
        bordered: true
        onClicked: {
          root.draft.push(Model.newDraftFolder())
          root.commit()
        }
      }
    }
  }

  // ------------------------------------------------------------------ footer

  Column {
    id: footer
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    spacing: Style.space(4)

    Text {
      visible: root.errors.length > 0
      text: {
        var shown = root.errors.slice(0, 3)
        var out = "• " + shown.join("\n• ")
        if (root.errors.length > 3) out += "\n… and " + (root.errors.length - 3) + " more"
        return out
      }
      color: root.bar ? root.bar.urgent : "red"
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Text {
      visible: root.engine ? root.engine.rulesHasComments && !root.parseFailed : false
      text: "Saving from here rewrites the file — comments in it will be lost "
        + "(a .bak copy of the previous version is kept)."
      color: Qt.darker(root.fg, 1.5)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }
  }
}
