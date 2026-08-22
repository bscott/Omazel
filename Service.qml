import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless singleton that owns the Omazel engine: loading the rules file,
// watching folders, and executing actions. The bar widget (one per monitor)
// only reads state from here and calls the functions below, so there is a
// single watcher per folder and a single action runner no matter how many
// bars are on screen.
//
// Files reach the engine along two paths that deliberately overlap:
//
//   inotify (scripts/omazel-watch.sh) reacts the moment a file finishes
//   arriving. Its events go through a short settle delay, then a stat, then
//   rule evaluation — so a download that just closed is not judged while a
//   post-processing step is still renaming it.
//
//   The sweep (scripts/omazel-sweep.sh) walks each folder on a slow timer and
//   at startup. It is the only way age-based rules ever fire (files do not
//   emit events by getting older), and it catches anything that arrived while
//   the shell was off.
//
// Both paths meet at evaluate(), and a per-file-per-rule cooldown keeps the
// overlap from double-running actions.
Item {
  id: root

  property var shell: null

  // Inline widget settings, pushed in by the bar widget since the shell only
  // injects settings into widget slots, not services.
  property var settings: ({})

  property string pluginId: "io.github.bscott.omazel"

  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string rulesPath: Model.expandHome(
    String(setting("rulesPath", "~/.config/omazel/rules.toml")), home)
  readonly property string activityLog: home + "/.local/state/omazel/activity.log"

  readonly property int sweepIntervalSec: {
    var raw = intSetting("sweepIntervalSec", 300, 0, 86400)
    return raw === 0 ? 0 : Math.max(60, raw)
  }
  readonly property int settleSec: intSetting("settleSec", 3, 0, 60)
  readonly property int cooldownSec: intSetting("cooldownSec", 60, 10, 3600)
  readonly property bool startPaused: boolSetting("startPaused", false)

  // 0 disables update checking entirely.
  readonly property int updateCheckIntervalSec: {
    var raw = intSetting("updateCheckIntervalSec", 21600, 0, 604800)
    return raw === 0 ? 0 : Math.max(900, raw)
  }

  // Resolved from this file's own location so the plugin works wherever it is
  // checked out, including a symlinked development tree.
  readonly property string watchScript: scriptPath("scripts/omazel-watch.sh")
  readonly property string sweepScript: scriptPath("scripts/omazel-sweep.sh")
  readonly property string actScript: scriptPath("scripts/omazel-act.sh")
  readonly property string capsScript: scriptPath("scripts/omazel-caps.sh")
  readonly property string updateCheckScript: scriptPath("scripts/plugin-update-check.sh")
  readonly property string exampleRules: scriptPath("rules.example.toml")

  function scriptPath(relative) {
    var url = String(Qt.resolvedUrl(relative))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  // -------------------------------------------------------------- rule state

  property bool configLoaded: false
  property bool rulesFileExists: true
  property string configError: ""
  property var configErrors: []
  property var folders: []

  // The rules file exactly as last read, for the visual editor — it parses
  // this itself so hand-written structure survives the GUI round trip.
  property string rulesText: ""
  property bool saving: false

  // Warn the editor about clobbering hand-written commentary, but not about
  // the header the editor itself writes.
  readonly property bool rulesHasComments: rulesText.indexOf("# Omazel rules — written by the visual editor.") !== 0
    && /(^|\n)[ \t]*#/.test(rulesText)

  readonly property int ruleCount: {
    var n = 0
    for (var i = 0; i < folders.length; i++) n += folders[i].rules.length
    return n
  }

  // ------------------------------------------------------------ engine state

  property bool paused: false
  property bool dryRun: false
  property var pausedFolders: ({})
  property var caps: ({})
  property bool capsLoaded: false
  property var missing: []
  property string lastError: ""
  property bool sweeping: false

  // Newest first, capped. Seeded from the activity log at startup so the
  // popup shows history from before this shell session.
  property var activity: []
  property int actionsSession: 0
  property int errorsSession: 0

  property int nowSec: Math.floor(Date.now() / 1000)

  readonly property bool watchable: caps["inotifywait"] === true
  readonly property int activeFolderCount: {
    var n = 0
    for (var i = 0; i < folders.length; i++) {
      if (folders[i].enabled && pausedFolders[folders[i].path] !== true) n++
    }
    return n
  }

  // "ok" | "paused" | "error" | "unconfigured" — drives the bar icon.
  readonly property string level: {
    if (!configLoaded) return "unconfigured"
    if (configError !== "") return "error"
    if (paused) return "paused"
    if (lastError !== "") return "error"
    return "ok"
  }

  // -------------------------------------------------------------- update state

  property string updateState: ""
  property int updateBehind: 0
  property string updateSubject: ""
  property bool updateLinked: false
  property bool updateDirty: false
  property bool updateChecking: false
  property bool updating: false
  property string updateStatus: ""
  property int lastUpdateCheckSec: 0

  readonly property bool updateAvailable: updateState === "ok" && updateBehind > 0
  readonly property bool updateBlocked: updateLinked || updateDirty
  readonly property bool canUpdate: updateAvailable && !updateBlocked && !updating

  readonly property string updateBlockedReason: {
    if (updateLinked) return "Development checkout — update with git instead"
    if (updateDirty) return "Local changes present — commit or discard them first"
    return ""
  }

  // ---------------------------------------------------------- internal queues

  // Plain JS state, not bindings: these change constantly and nothing in the
  // UI needs to react to the intermediate steps.
  property var _pendingEvents: ({})   // path -> { due, folderIndex }
  property int _pendingCount: 0
  property var _statQueue: []
  property var _actQueue: []
  property var _currentPlan: null
  property var _cooldown: ({})        // path \0 rule -> epoch
  property var _recentOutputs: ({})   // produced path -> epoch
  property var _sweepQueue: []

  // -------------------------------------------------------------------- config

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function boolSetting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value === true
  }

  // ------------------------------------------------------------------- loading

  function reload() {
    if (readRulesProcess.running) return
    readRulesProcess.command = ["bash", "-c",
      'if [[ -f "$1" ]]; then cat -- "$1"; else echo __OMAZEL_MISSING__; fi', "_", rulesPath]
    readRulesProcess.running = true
  }

  function applyRules(text) {
    if (text.indexOf("__OMAZEL_MISSING__") === 0) {
      rulesFileExists = false
      configLoaded = false
      configError = "No rules file at " + rulesPath
      configErrors = []
      folders = []
      rulesText = ""
      return
    }
    rulesFileExists = true
    rulesText = text
    var parsed = Model.parseToml(text)
    if (!parsed.ok) {
      configLoaded = false
      configError = "Rules file: " + parsed.error
      configErrors = []
      folders = []
      return
    }
    var compiled = Model.compileConfig(parsed.value, home)
    configError = ""
    configErrors = compiled.errors
    folders = compiled.folders
    configLoaded = true
    refreshMissing()
    // A fresh config means fresh intent: evaluate everything already sitting
    // in the watched folders rather than waiting out the sweep timer.
    sweepAll()
  }

  // Writes the rules file the editor produced: previous version to .bak,
  // new content through a temp file and rename so a crash mid-write can
  // never leave a half-written config. The rename lands as a moved_to event
  // on the rules watcher, which reloads for us.
  function saveRules(text) {
    if (saveProcess.running) return
    saving = true
    saveProcess.command = ["bash", "-c",
      'set -e; dir="$(dirname -- "$2")"; mkdir -p -- "$dir"; ' +
      'if [[ -f "$2" ]]; then cp -f -- "$2" "$2.bak"; fi; ' +
      'tmp="$2.tmp.$$"; printf "%s" "$1" > "$tmp"; mv -f -- "$tmp" "$2"',
      "_", text, rulesPath]
    saveProcess.running = true
  }

  function createStarterRules() {
    Quickshell.execDetached(["bash", "-c",
      'mkdir -p -- "$(dirname -- "$1")" && cp -n -- "$2" "$1"', "_", rulesPath, exampleRules])
    reloadSoon.restart()
  }

  function editRules() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      '${EDITOR:-nvim} "' + rulesPath + '"'])
  }

  function refreshMissing() {
    if (!capsLoaded) return
    missing = Model.missingTools(Model.requiredTools(folders), caps)
  }

  // -------------------------------------------------------------------- control

  function setPaused(on) {
    paused = on === true
    return paused
  }

  function toggleFolderPause(path) {
    var next = {}
    for (var key in pausedFolders) next[key] = pausedFolders[key]
    if (next[path] === true) delete next[path]
    else next[path] = true
    pausedFolders = next
    return next[path] === true
  }

  function setDryRun(on) {
    dryRun = on === true
    return dryRun
  }

  // ------------------------------------------------------------------ watching

  function onWatchLine(folderIndex, line) {
    var tab = line.indexOf("\t")
    if (tab < 0) return
    var path = line.substring(tab + 1)
    if (path === "" || path === rulesPath) return
    // Ignore what we ourselves just produced, or events inside a directory we
    // just produced (an extract target, say) — acting on our own output is how
    // rule loops start.
    if (isRecentOutput(path)) return
    var folder = folders[folderIndex]
    if (!folder || !folder.enabled) return
    if (paused || pausedFolders[folder.path] === true) return

    _pendingEvents[path] = {
      due: Math.floor(Date.now() / 1000) + settleSec,
      folderIndex: folderIndex
    }
    recountPending()
  }

  function isRecentOutput(path) {
    var cutoff = Math.floor(Date.now() / 1000) - 20
    for (var out in _recentOutputs) {
      if (_recentOutputs[out] < cutoff) continue
      if (path === out || path.indexOf(out + "/") === 0) return true
    }
    return false
  }

  function recountPending() {
    var n = 0
    for (var key in _pendingEvents) n++
    _pendingCount = n
  }

  function processDueEvents() {
    var now = Math.floor(Date.now() / 1000)
    for (var path in _pendingEvents) {
      if (_pendingEvents[path].due > now) continue
      _statQueue.push({ path: path, folderIndex: _pendingEvents[path].folderIndex })
      delete _pendingEvents[path]
    }
    recountPending()
    kickStat()
  }

  function kickStat() {
    if (statProcess.running || _statQueue.length === 0) return
    var job = _statQueue.shift()
    statProcess.job = job
    statProcess.command = ["stat", "-c", "%F\t%s\t%Y", "--", job.path]
    statProcess.running = true
  }

  // ------------------------------------------------------------------ sweeping

  function sweepAll() {
    _sweepQueue = []
    for (var i = 0; i < folders.length; i++) {
      if (!folders[i].enabled) continue
      if (paused || pausedFolders[folders[i].path] === true) continue
      _sweepQueue.push(i)
    }
    sweeping = _sweepQueue.length > 0
    kickSweep()
  }

  function kickSweep() {
    if (sweepProcess.running) return
    if (_sweepQueue.length === 0) { sweeping = false; return }
    var index = _sweepQueue.shift()
    sweepProcess.folderIndex = index
    sweepProcess.command = ["bash", sweepScript, folders[index].path,
      folders[index].recursive ? "1" : "0", "2000"]
    sweepProcess.running = true
  }

  function applySweep(folderIndex, text) {
    var folder = folders[folderIndex]
    if (!folder) return
    var now = Math.floor(Date.now() / 1000)
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 3) continue
      var path = parts.slice(2).join("\t")
      var mtime = parseInt(parts[1], 10) || 0
      // Fresh files are the watcher's job; the sweep holding back for the
      // settle window means a file being written right now is not judged from
      // a half-complete state.
      if (now - mtime < settleSec) continue
      if (isRecentOutput(path)) continue
      evaluate(Model.fileRecord(path, parseInt(parts[0], 10) || 0, mtime), folderIndex)
    }
  }

  // ---------------------------------------------------------------- evaluation

  function evaluate(file, folderIndex) {
    var folder = folders[folderIndex]
    if (!folder) return
    if (paused || pausedFolders[folder.path] === true) return
    var now = Math.floor(Date.now() / 1000)
    var plans = Model.planFile(file, folder, now)
    for (var i = 0; i < plans.length; i++) {
      var key = plans[i].file + "\u0000" + plans[i].rule
      if (_cooldown[key] !== undefined && now - _cooldown[key] < cooldownSec) continue
      _cooldown[key] = now
      if (!alreadyQueued(plans[i])) _actQueue.push(plans[i])
    }
    kickAct()
  }

  function alreadyQueued(plan) {
    for (var i = 0; i < _actQueue.length; i++) {
      if (_actQueue[i].file === plan.file && _actQueue[i].verb === plan.verb) return true
    }
    return false
  }

  function kickAct() {
    if (actProcess.running || _actQueue.length === 0) return
    var plan = _actQueue.shift()
    _currentPlan = plan
    actProcess.command = ["env",
      "OMAZEL_RULE=" + plan.rule,
      "OMAZEL_LOG=" + activityLog,
      "OMAZEL_DRYRUN=" + (dryRun ? "1" : "0"),
      "bash", actScript].concat(plan.argv)
    actProcess.running = true
  }

  function recordOutcome(plan, fields, exitCode) {
    var now = Math.floor(Date.now() / 1000)
    var status = String(fields.status || (exitCode === 0 ? "ok" : "error"))
    var dest = String(fields.dest || "")
    var entry = {
      epoch: now,
      status: status,
      verb: plan.verb,
      rule: plan.rule,
      path: plan.file,
      file: plan.file.substring(plan.file.lastIndexOf("/") + 1),
      dest: dest,
      message: String(fields.message || "")
    }
    var next = activity.slice()
    next.unshift(entry)
    if (next.length > 60) next.length = 60
    activity = next

    if (status === "ok" || status === "dryrun") {
      actionsSession += 1
      if (dest !== "") _recentOutputs[dest] = now
      pruneRecentOutputs(now)
    } else {
      errorsSession += 1
      lastError = Model.elide(plan.rule + ": " + (entry.message || plan.verb + " failed"), 140)
    }
  }

  function pruneRecentOutputs(now) {
    for (var key in _recentOutputs) {
      if (now - _recentOutputs[key] > 60) delete _recentOutputs[key]
    }
    for (var cool in _cooldown) {
      if (now - _cooldown[cool] > cooldownSec * 4) delete _cooldown[cool]
    }
  }

  function clearError() { lastError = "" }

  // --------------------------------------------------------------------- update

  function checkForUpdate(force) {
    if (updateCheckIntervalSec === 0 && force !== true) return
    if (updateCheckProcess.running || updating) return
    if (force !== true && lastUpdateCheckSec > 0
        && nowSec - lastUpdateCheckSec < updateCheckIntervalSec) return
    updateChecking = true
    updateCheckProcess.command = ["bash", updateCheckScript]
    updateCheckProcess.running = true
  }

  function applyUpdate() {
    if (!canUpdate) return
    updating = true
    updateStatus = "Updating…"
    updateProcess.command = ["omarchy", "plugin", "update", pluginId, "--yes"]
    updateProcess.running = true
  }

  function applyUpdateCheck(text) {
    var f = Model.parseFields(text)
    updateState = String(f.state || "")
    updateLinked = String(f.linked || "") === "true"
    updateDirty = String(f.dirty || "") === "true"
    updateBehind = parseInt(f.behind, 10) || 0
    updateSubject = String(f.subject || "")
    lastUpdateCheckSec = nowSec
  }

  // -------------------------------------------------------------------- timers

  Timer {
    // Keeps relative times in the popup honest, and drives the update-check
    // rate limit.
    interval: 5000
    repeat: true
    running: true
    onTriggered: root.nowSec = Math.floor(Date.now() / 1000)
  }

  Timer {
    // The settle delay between an inotify event and rule evaluation.
    interval: 1000
    repeat: true
    running: root._pendingCount > 0
    onTriggered: root.processDueEvents()
  }

  Timer {
    interval: Math.max(60, root.sweepIntervalSec) * 1000
    repeat: true
    running: root.sweepIntervalSec > 0 && root.configLoaded && !root.paused
    onTriggered: root.sweepAll()
  }

  Timer {
    id: reloadSoon
    interval: 600
    repeat: false
    onTriggered: root.reload()
  }

  Timer {
    id: updateCheckTimer
    interval: Math.max(900, root.updateCheckIntervalSec) * 1000
    repeat: true
    running: root.updateCheckIntervalSec > 0
    triggeredOnStart: true
    onTriggered: root.checkForUpdate(true)
  }

  Timer {
    id: updateStatusTimer
    interval: 4000
    repeat: false
    onTriggered: root.updateStatus = ""
  }

  // ----------------------------------------------------------------- processes

  Process {
    id: readRulesProcess
    running: false
    command: []
    stdout: StdioCollector { id: readRulesStdout; waitForEnd: true }
    onExited: function (exitCode) {
      root.applyRules(String(readRulesStdout.text || ""))
    }
  }

  Process {
    id: saveProcess
    running: false
    command: []
    stderr: StdioCollector { id: saveStderr; waitForEnd: true }
    onExited: function (exitCode) {
      root.saving = false
      if (exitCode !== 0) {
        root.lastError = Model.elide("Saving rules failed: "
          + String(saveStderr.text || "").split("\n").pop(), 140)
      }
      // The rules watcher normally catches the rename; reloading anyway
      // covers the first save, when the config directory itself was just
      // created and nothing was watching it yet.
      reloadSoon.restart()
    }
  }

  Process {
    id: capsProcess
    running: false
    command: []
    stdout: StdioCollector { id: capsStdout; waitForEnd: true }
    onExited: function (exitCode) {
      var fields = Model.parseFields(String(capsStdout.text || ""))
      var out = {}
      for (var tool in fields) out[tool] = fields[tool] === "1"
      root.caps = out
      root.capsLoaded = true
      root.refreshMissing()
    }
  }

  Process {
    id: tailProcess
    running: false
    command: []
    stdout: StdioCollector { id: tailStdout; waitForEnd: true }
    onExited: function (exitCode) {
      var entries = Model.parseActivityLines(String(tailStdout.text || ""))
      entries.reverse()
      if (root.activity.length === 0) root.activity = entries.slice(0, 60)
    }
  }

  Process {
    id: statProcess
    property var job: null
    running: false
    command: []
    stdout: StdioCollector { id: statStdout; waitForEnd: true }
    onExited: function (exitCode) {
      var job = statProcess.job
      statProcess.job = null
      if (exitCode === 0 && job) {
        var parts = String(statStdout.text || "").trim().split("\t")
        // Only regular files are ruled on: directories moving into a watched
        // folder are left alone, matching what people expect from Hazel.
        if (parts.length >= 3 && parts[0] === "regular file") {
          root.evaluate(Model.fileRecord(job.path,
            parseInt(parts[1], 10) || 0, parseInt(parts[2], 10) || 0), job.folderIndex)
        }
      }
      root.kickStat()
    }
  }

  Process {
    id: sweepProcess
    property int folderIndex: -1
    running: false
    command: []
    stdout: StdioCollector { id: sweepStdout; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 0) root.applySweep(sweepProcess.folderIndex, String(sweepStdout.text || ""))
      root.kickSweep()
    }
  }

  Process {
    id: actProcess
    running: false
    command: []
    stdout: StdioCollector { id: actStdout; waitForEnd: true }
    stderr: StdioCollector { id: actStderr; waitForEnd: true }
    onExited: function (exitCode) {
      var plan = root._currentPlan
      root._currentPlan = null
      if (plan) {
        var fields = Model.parseFields(String(actStdout.text || ""))
        if (fields.status === undefined && exitCode !== 0) {
          fields.message = Model.elide(String(actStderr.text || "").split("\n").pop(), 140)
        }
        root.recordOutcome(plan, fields, exitCode)
      }
      root.kickAct()
    }
  }

  // One watcher per active folder. `running` is bound to the pause state, so
  // pausing a folder actually stops its inotify process rather than just
  // discarding its events.
  Instantiator {
    model: root.folders
    delegate: Process {
      required property var modelData
      required property int index
      running: root.watchable && modelData.enabled && !root.paused
        && root.pausedFolders[modelData.path] !== true
      command: ["bash", root.watchScript, modelData.path, modelData.recursive ? "1" : "0"]
      stdout: SplitParser {
        onRead: function (line) { root.onWatchLine(index, line) }
      }
    }
  }

  // Watches the rules file's own directory so edits apply without anyone
  // having to find a reload button. The watch script only reports writes and
  // renames, which is exactly what saving from an editor produces.
  Process {
    id: rulesWatchProcess
    running: root.configLoaded || root.rulesFileExists === false
    command: ["bash", root.watchScript, root.rulesPath.substring(0, root.rulesPath.lastIndexOf("/")), "0"]
    stdout: SplitParser {
      onRead: function (line) {
        var tab = line.indexOf("\t")
        if (tab < 0) return
        if (line.substring(tab + 1) === root.rulesPath) reloadSoon.restart()
      }
    }
  }

  Process {
    id: updateCheckProcess
    running: false
    command: []
    stdout: StdioCollector { id: updateCheckStdout; waitForEnd: true }
    onExited: function (exitCode) {
      root.updateChecking = false
      if (exitCode === 0) {
        root.applyUpdateCheck(String(updateCheckStdout.text || ""))
        return
      }
      root.updateState = "fetchfailed"
      root.lastUpdateCheckSec = root.nowSec
    }
  }

  Process {
    id: updateProcess
    running: false
    command: []
    stderr: StdioCollector { id: updateStderr; waitForEnd: true }
    onExited: function (exitCode) {
      root.updating = false
      if (exitCode === 0) {
        root.updateStatus = "Updated — reloading"
        root.updateBehind = 0
        // The QML on disk has changed; ask the shell to pick it up. This
        // replaces the running widget, so nothing after it is guaranteed to run.
        Quickshell.execDetached(["omarchy-shell", "shell", "rescanPlugins"])
      } else {
        var stderr = String(updateStderr.text || "").trim()
        root.updateStatus = stderr !== ""
          ? Model.elide(stderr.split("\n").pop(), 140)
          : "Update failed"
      }
      updateStatusTimer.restart()
    }
  }

  // Scriptable surface, e.g. `omarchy-shell omazel pause` from a keybinding.
  IpcHandler {
    target: "omazel"

    function status(): string {
      return JSON.stringify({
        loaded: root.configLoaded,
        paused: root.paused,
        dryRun: root.dryRun,
        folders: root.folders.length,
        rules: root.ruleCount,
        actions: root.actionsSession,
        errors: root.errorsSession,
        lastError: root.lastError
      })
    }

    function pause(): string { root.setPaused(true); return "paused" }
    function resume(): string { root.setPaused(false); return "running" }
    function toggle(): string { return root.setPaused(!root.paused) ? "paused" : "running" }
    function dryRunOn(): string { root.setDryRun(true); return "on" }
    function dryRunOff(): string { root.setDryRun(false); return "off" }
    function dryRunToggle(): string { return root.setDryRun(!root.dryRun) ? "on" : "off" }
    function reload(): string { root.reload(); return "ok" }
    function sweep(): string { root.sweepAll(); return "ok" }
    function ping(): string { return "ok" }
  }

  Component.onCompleted: {
    paused = startPaused
    capsProcess.command = ["bash", capsScript]
    capsProcess.running = true
    tailProcess.command = ["bash", "-c", 'tail -n 60 -- "$1" 2>/dev/null || true', "_", activityLog]
    tailProcess.running = true
    reload()
  }
}
