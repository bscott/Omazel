import QtQuick
import qs.Ui
import qs.Commons
import "Model.js" as Model

// The visual rule editor, shown inside the widget's popup as an alternative
// to editing rules.toml by hand. It edits a plain-JS "draft" (see Model.js).
//
// Mutation model, and why it is index-based: Repeater converts a JS-array
// model into variant copies, so a delegate's modelData is a snapshot — good
// for display, but writing through it mutates a throwaway object. Every
// change therefore goes through the helpers below, which address the live
// draft by indices (folder, rule, condition/action). Text edits write in
// place with no visual side effects; structural changes (add, remove,
// reorder, or anything that alters which controls are shown) call commit(),
// which clones the draft so every Repeater re-reads it.
Item {
  id: root

  property var engine: null
  property QtObject bar: null

  signal done()

  property var draft: []
  property var errors: []
  property bool parseFailed: false
  property bool showHints: false

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

  // ------------------------------------------------------- draft mutations

  function addFolder() { draft.push(Model.newDraftFolder()); commit() }
  function removeFolder(fi) { draft.splice(fi, 1); commit() }
  function setFolder(fi, key, value) { draft[fi][key] = value }

  function addRule(fi) { draft[fi].rules.push(Model.newDraftRule()); commit() }
  function removeRule(fi, ri) { draft[fi].rules.splice(ri, 1); commit() }
  function setRule(fi, ri, key, value) { draft[fi].rules[ri][key] = value }
  function moveRule(fi, ri, delta) { moveIn(draft[fi].rules, ri, delta) }

  function addCondition(fi, ri) {
    draft[fi].rules[ri].conditions.push(Model.newDraftCondition())
    commit()
  }
  function removeCondition(fi, ri, ci) {
    draft[fi].rules[ri].conditions.splice(ci, 1)
    commit()
  }
  function setCondition(fi, ri, ci, key, value) {
    draft[fi].rules[ri].conditions[ci][key] = value
  }
  // Changing the field can invalidate the operator and always changes the
  // value placeholder, so the row is rebuilt.
  function setConditionField(fi, ri, ci, value) {
    var cond = draft[fi].rules[ri].conditions[ci]
    cond.field = value
    var ops = Model.opsForField(value)
    var valid = false
    for (var i = 0; i < ops.length; i++) if (ops[i].value === cond.op) valid = true
    if (!valid) cond.op = ops[0].value
    commit()
  }
  function setConditionOp(fi, ri, ci, value) {
    draft[fi].rules[ri].conditions[ci].op = value
    commit()
  }

  function addAction(fi, ri) {
    draft[fi].rules[ri].actions.push(Model.newDraftAction())
    commit()
  }
  function removeAction(fi, ri, ai) {
    draft[fi].rules[ri].actions.splice(ai, 1)
    commit()
  }
  function moveAction(fi, ri, ai, delta) { moveIn(draft[fi].rules[ri].actions, ai, delta) }
  function setActionVerb(fi, ri, ai, verb) {
    var action = draft[fi].rules[ri].actions[ai]
    action.verb = verb
    action.params = Model.defaultParamsFor(verb)
    commit()
  }
  function setActionParam(fi, ri, ai, key, value) {
    draft[fi].rules[ri].actions[ai].params[key] = value
  }
  // Choice params (upload's provider) decide which other inputs exist.
  function setActionChoice(fi, ri, ai, key, value) {
    draft[fi].rules[ri].actions[ai].params[key] = value
    commit()
  }

  function moveIn(list, index, delta) {
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
      width: parent.width - hintsButton.width - saveButton.width - cancelButton.width
        - Style.space(24)
      elide: Text.ElideRight
    }

    Button {
      id: hintsButton
      iconText: "󰋽"
      tooltipText: "Pattern variables and docs"
      foreground: root.showHints ? Color.accent : root.fg
      onClicked: root.showHints = !root.showHints
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

      // ⓘ hints: what the {tokens} in patterns expand to, and the way to the
      // full documentation.
      BorderSurface {
        visible: root.showHints
        width: body.width
        height: hintsColumn.implicitHeight + Style.space(16)
        radius: Style.spacing.labelGap
        color: Style.normalFillFor(root.fg, Color.accent)
        borderSpec: Border.none()

        Column {
          id: hintsColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(3)

          Text {
            text: "Pattern variables — usable in destinations, names, and messages"
            color: root.fg
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Repeater {
            model: Model.PATTERN_HINTS

            Row {
              required property var modelData
              width: hintsColumn.width
              spacing: Style.space(8)

              Text {
                text: modelData.token
                color: Color.accent
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                width: Style.space(120)
              }

              Text {
                text: modelData.hint
                color: Qt.darker(root.fg, 1.3)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width - Style.space(132)
              }
            }
          }

          Item { width: 1; height: Style.space(4) }

          Button {
            text: "Open full docs"
            iconText: "󰈙"
            foreground: root.fg
            onClicked: if (root.engine) root.engine.openDocs()
          }
        }
      }

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
          readonly property int fi: index

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
                text: folderCard.modelData.path
                placeholderText: "~/Downloads"
                onTextEdited: root.setFolder(folderCard.fi, "path", text)
              }

              Button {
                iconText: "󰅖"
                tooltipText: "Remove folder"
                foreground: root.fg
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.removeFolder(folderCard.fi)
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
                  checked: folderCard.modelData.recursive === true
                  onToggled: {
                    checked = !checked
                    root.setFolder(folderCard.fi, "recursive", checked)
                  }
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
                  checked: folderCard.modelData.enabled !== false
                  onToggled: {
                    checked = !checked
                    root.setFolder(folderCard.fi, "enabled", checked)
                  }
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
                text: folderCard.modelData.ignore
                placeholderText: "extra globs — *.iso, keep-*"
                onTextEdited: root.setFolder(folderCard.fi, "ignore", text)
              }
            }

            // ------------------------------------------------------ rules
            Repeater {
              model: folderCard.modelData.rules

              BorderSurface {
                id: ruleCard
                required property var modelData
                required property int index
                readonly property int ri: index

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
                      text: ruleCard.modelData.name
                      placeholderText: "Rule name"
                      onTextEdited: root.setRule(folderCard.fi, ruleCard.ri, "name", text)
                    }

                    Button {
                      iconText: "󰅃"
                      tooltipText: "Move rule up"
                      foreground: root.fg
                      enabled: ruleCard.ri > 0
                      opacity: enabled ? 1.0 : 0.3
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.moveRule(folderCard.fi, ruleCard.ri, -1)
                    }

                    Button {
                      iconText: "󰅀"
                      tooltipText: "Move rule down"
                      foreground: root.fg
                      enabled: ruleCard.ri < folderCard.modelData.rules.length - 1
                      opacity: enabled ? 1.0 : 0.3
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.moveRule(folderCard.fi, ruleCard.ri, 1)
                    }

                    Button {
                      iconText: "󰅖"
                      tooltipText: "Remove rule"
                      foreground: root.fg
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.removeRule(folderCard.fi, ruleCard.ri)
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
                    visible: ruleCard.modelData.conditions.length === 0
                    text: "No conditions — matches every file"
                    color: Qt.darker(root.fg, 1.6)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  // ---------------------------------------- conditions
                  Repeater {
                    model: ruleCard.modelData.conditions

                    Row {
                      id: condRow
                      required property var modelData
                      required property int index
                      readonly property int ci: index

                      width: ruleColumn.width
                      spacing: Style.space(4)

                      Dropdown {
                        width: Style.space(64)
                        showLabel: false
                        foreground: root.fg
                        value: condRow.modelData.group
                        options: Model.GROUP_OPTIONS
                        onChanged: function (v) {
                          root.setCondition(folderCard.fi, ruleCard.ri, condRow.ci, "group", v)
                        }
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Dropdown {
                        width: Style.space(100)
                        showLabel: false
                        foreground: root.fg
                        value: condRow.modelData.field
                        options: Model.FIELD_OPTIONS
                        onChanged: function (v) {
                          root.setConditionField(folderCard.fi, ruleCard.ri, condRow.ci, v)
                        }
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Dropdown {
                        width: Style.space(110)
                        showLabel: false
                        foreground: root.fg
                        value: condRow.modelData.op
                        options: Model.opsForField(condRow.modelData.field)
                        onChanged: function (v) {
                          root.setConditionOp(folderCard.fi, ruleCard.ri, condRow.ci, v)
                        }
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      TextField {
                        width: condRow.width - Style.space(64 + 100 + 110 + 30) - Style.space(16)
                        foreground: root.fg
                        text: condRow.modelData.value
                        placeholderText: Model.valuePlaceholder(condRow.modelData.field,
                          condRow.modelData.op)
                        onTextEdited: {
                          root.setCondition(folderCard.fi, ruleCard.ri, condRow.ci, "value", text)
                        }
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Button {
                        iconText: "󰅖"
                        tooltipText: "Remove condition"
                        foreground: root.fg
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: root.removeCondition(folderCard.fi, ruleCard.ri, condRow.ci)
                      }
                    }
                  }

                  Button {
                    text: "+ condition"
                    foreground: Qt.darker(root.fg, 1.3)
                    onClicked: root.addCondition(folderCard.fi, ruleCard.ri)
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
                    model: ruleCard.modelData.actions

                    Column {
                      id: actionRow
                      required property var modelData
                      required property int index
                      readonly property int ai: index

                      width: ruleColumn.width
                      spacing: Style.space(4)

                      Row {
                        width: parent.width
                        spacing: Style.space(4)

                        Dropdown {
                          width: Style.space(150)
                          showLabel: false
                          foreground: root.fg
                          value: actionRow.modelData.verb
                          options: Model.ACTION_OPTIONS
                          onChanged: function (v) {
                            root.setActionVerb(folderCard.fi, ruleCard.ri, actionRow.ai, v)
                          }
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Item {
                          width: parent.width - Style.space(150 + 90) - Style.space(16)
                          height: 1
                        }

                        Button {
                          iconText: "󰅃"
                          tooltipText: "Move action up"
                          foreground: root.fg
                          enabled: actionRow.ai > 0
                          opacity: enabled ? 1.0 : 0.3
                          anchors.verticalCenter: parent.verticalCenter
                          onClicked: root.moveAction(folderCard.fi, ruleCard.ri, actionRow.ai, -1)
                        }

                        Button {
                          iconText: "󰅀"
                          tooltipText: "Move action down"
                          foreground: root.fg
                          enabled: actionRow.ai < ruleCard.modelData.actions.length - 1
                          opacity: enabled ? 1.0 : 0.3
                          anchors.verticalCenter: parent.verticalCenter
                          onClicked: root.moveAction(folderCard.fi, ruleCard.ri, actionRow.ai, 1)
                        }

                        Button {
                          iconText: "󰅖"
                          tooltipText: "Remove action"
                          foreground: root.fg
                          anchors.verticalCenter: parent.verticalCenter
                          onClicked: root.removeAction(folderCard.fi, ruleCard.ri, actionRow.ai)
                        }
                      }

                      Repeater {
                        model: Model.actionParams(actionRow.modelData.verb,
                          actionRow.modelData.params)

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
                              var v = actionRow.modelData.params[paramRow.param.key]
                              return v === undefined ? "" : String(v)
                            }
                            placeholderText: paramRow.param.placeholder || ""
                            onTextEdited: {
                              root.setActionParam(folderCard.fi, ruleCard.ri, actionRow.ai,
                                paramRow.param.key, text)
                            }
                          }

                          Dropdown {
                            visible: paramRow.param.type === "choice"
                            width: Style.space(160)
                            showLabel: false
                            foreground: root.fg
                            value: {
                              var v = actionRow.modelData.params[paramRow.param.key]
                              return v === undefined ? "" : String(v)
                            }
                            options: paramRow.param.options || []
                            onChanged: function (v) {
                              root.setActionChoice(folderCard.fi, ruleCard.ri, actionRow.ai,
                                paramRow.param.key, v)
                            }
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          ToggleSwitch {
                            visible: paramRow.param.type === "bool"
                            foreground: root.fg
                            checked: actionRow.modelData.params[paramRow.param.key] === true
                            onToggled: {
                              checked = !checked
                              root.setActionParam(folderCard.fi, ruleCard.ri, actionRow.ai,
                                paramRow.param.key, checked)
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
                    onClicked: root.addAction(folderCard.fi, ruleCard.ri)
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      text: "After match"
                      color: Qt.darker(root.fg, 1.4)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      width: Style.space(70)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Dropdown {
                      width: parent.width - Style.space(82)
                      showLabel: false
                      foreground: root.fg
                      value: ruleCard.modelData.cont !== undefined ? ruleCard.modelData.cont : "auto"
                      options: Model.CONTINUE_OPTIONS
                      onChanged: function (v) {
                        root.setRule(folderCard.fi, ruleCard.ri, "cont", v)
                      }
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }

            Button {
              text: "+ rule"
              foreground: Qt.darker(root.fg, 1.3)
              onClicked: root.addRule(folderCard.fi)
            }
          }
        }
      }

      Button {
        visible: !root.parseFailed
        text: "+ watched folder"
        foreground: root.fg
        bordered: true
        onClicked: root.addFolder()
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
