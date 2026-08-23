.pragma library

// Pure logic for Omazel: parsing the rules file, deciding which rules match a
// file, and planning the actions to run. Everything here is free of QML
// bindings and side effects so it can be tested under Node on its own, leaving
// Service.qml to own process lifetime and BarWidget.qml to own presentation.
//
// The flow is: parseToml() reads ~/.config/omazel/rules.toml into plain
// objects, compileConfig() validates and normalizes them into folders/rules,
// and planFile() turns one observed file into an ordered list of action plans,
// each of which maps 1:1 onto an invocation of scripts/omazel-act.sh.

// ------------------------------------------------------------------ TOML

// A deliberately small TOML reader covering what the rules file uses: tables,
// arrays of tables, basic and literal strings, integers/floats, booleans,
// arrays (multi-line, trailing commas allowed), and inline tables. Dates,
// dotted keys, and multi-line strings are not supported and error clearly
// instead of guessing.
function parseToml(text) {
  var root = {}
  var current = root
  var lines = String(text || "").split("\n")
  var i = 0

  function fail(lineNo, message) {
    return { ok: false, error: "line " + (lineNo + 1) + ": " + message }
  }

  while (i < lines.length) {
    var line = stripComment(lines[i]).trim()
    if (line === "") { i++; continue }

    if (line.charAt(0) === "[") {
      var isArray = line.indexOf("[[") === 0
      var close = isArray ? line.indexOf("]]") : line.indexOf("]")
      if (close < 0) return fail(i, "unterminated table header")
      var after = line.substring(close + (isArray ? 2 : 1)).trim()
      if (after !== "") return fail(i, "unexpected text after table header")
      var pathStr = line.substring(isArray ? 2 : 1, close).trim()
      if (pathStr === "") return fail(i, "empty table name")

      var keys = pathStr.split(".")
      for (var k = 0; k < keys.length; k++) {
        keys[k] = unquoteKey(keys[k].trim())
        if (keys[k] === "") return fail(i, "empty key in table name")
      }

      var node = root
      for (var d = 0; d < keys.length - 1; d++) {
        node = descend(node, keys[d])
        if (node === null) return fail(i, "cannot redefine '" + keys[d] + "' as a table")
      }
      var leaf = keys[keys.length - 1]
      if (isArray) {
        if (node[leaf] === undefined) node[leaf] = []
        if (!isArrayValue(node[leaf])) return fail(i, "'" + leaf + "' is not an array of tables")
        var table = {}
        node[leaf].push(table)
        current = table
      } else {
        if (node[leaf] === undefined) node[leaf] = {}
        if (isArrayValue(node[leaf]) || typeof node[leaf] !== "object")
          return fail(i, "cannot redefine '" + leaf + "' as a table")
        current = node[leaf]
      }
      i++
      continue
    }

    var eq = line.indexOf("=")
    if (eq < 0) return fail(i, "expected key = value")
    var key = unquoteKey(line.substring(0, eq).trim())
    if (key === "") return fail(i, "empty key")

    // A value may span lines (arrays of inline tables usually do). Keep
    // appending source lines until brackets and quotes balance.
    var joined = line.substring(eq + 1)
    var j = i
    while (!balanced(stripCommentPreserve(joined)) && j + 1 < lines.length) {
      j++
      joined += "\n" + lines[j]
    }
    joined = stripCommentPreserve(joined)
    if (!balanced(joined)) return fail(i, "unterminated value")

    var pv = parseValueAt(joined, 0)
    if (pv.error) return fail(i, pv.error)
    if (joined.substring(pv.next).trim() !== "") return fail(i, "unexpected text after value")
    current[key] = pv.value
    i = j + 1
  }

  return { ok: true, value: root }
}

function isArrayValue(v) {
  return Object.prototype.toString.call(v) === "[object Array]"
}

function descend(node, key) {
  var v = node[key]
  if (v === undefined) { node[key] = {}; return node[key] }
  if (isArrayValue(v)) return v.length > 0 ? v[v.length - 1] : null
  if (typeof v === "object" && v !== null) return v
  return null
}

function unquoteKey(key) {
  if (key.length >= 2) {
    var q = key.charAt(0)
    if ((q === '"' || q === "'") && key.charAt(key.length - 1) === q)
      return key.substring(1, key.length - 1)
  }
  return key
}

// Cuts a trailing # comment, respecting quotes. Used for single lines, where
// an unterminated string means the # cannot be trusted either way.
function stripComment(line) {
  var out = ""
  var inBasic = false
  var inLiteral = false
  for (var i = 0; i < line.length; i++) {
    var c = line.charAt(i)
    if (inBasic) {
      if (c === "\\") { out += c + (line.charAt(i + 1) || ""); i++; continue }
      if (c === '"') inBasic = false
    } else if (inLiteral) {
      if (c === "'") inLiteral = false
    } else {
      if (c === '"') inBasic = true
      else if (c === "'") inLiteral = true
      else if (c === "#") break
    }
    out += c
  }
  return out
}

// Same, but applied to a multi-line joined value where comments may appear on
// each source line.
function stripCommentPreserve(text) {
  var lines = String(text).split("\n")
  for (var i = 0; i < lines.length; i++) lines[i] = stripComment(lines[i])
  return lines.join("\n")
}

// True once every bracket opened outside a string is closed and no string is
// left open.
function balanced(text) {
  var depth = 0
  var inBasic = false
  var inLiteral = false
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i)
    if (inBasic) {
      if (c === "\\") { i++; continue }
      if (c === '"') inBasic = false
    } else if (inLiteral) {
      if (c === "'") inLiteral = false
    } else {
      if (c === '"') inBasic = true
      else if (c === "'") inLiteral = true
      else if (c === "[" || c === "{") depth++
      else if (c === "]" || c === "}") depth--
    }
  }
  return depth <= 0 && !inBasic && !inLiteral
}

// Recursive-descent value parser. Returns { value, next } or { error }.
function parseValueAt(s, i) {
  i = skipWs(s, i)
  if (i >= s.length) return { error: "missing value" }
  var c = s.charAt(i)

  if (c === '"') return parseBasicString(s, i)
  if (c === "'") return parseLiteralString(s, i)
  if (c === "[") return parseArray(s, i)
  if (c === "{") return parseInlineTable(s, i)

  var m = s.substring(i).match(/^(true|false)(?![A-Za-z0-9_-])/)
  if (m) return { value: m[1] === "true", next: i + m[1].length }

  m = s.substring(i).match(/^[+-]?[0-9][0-9_]*(\.[0-9][0-9_]*)?/)
  if (m) {
    var raw = m[0].replace(/_/g, "")
    return { value: m[1] ? parseFloat(raw) : parseInt(raw, 10), next: i + m[0].length }
  }

  return { error: "unrecognized value starting at '" + s.substring(i, i + 12) + "'" }
}

function skipWs(s, i) {
  while (i < s.length && " \t\n\r".indexOf(s.charAt(i)) >= 0) i++
  return i
}

function parseBasicString(s, i) {
  var out = ""
  i++
  while (i < s.length) {
    var c = s.charAt(i)
    if (c === '"') return { value: out, next: i + 1 }
    if (c === "\\") {
      var e = s.charAt(i + 1)
      if (e === "n") out += "\n"
      else if (e === "t") out += "\t"
      else if (e === "r") out += "\r"
      else if (e === '"') out += '"'
      else if (e === "\\") out += "\\"
      else if (e === "u") {
        var hex = s.substring(i + 2, i + 6)
        if (!/^[0-9A-Fa-f]{4}$/.test(hex)) return { error: "bad \\u escape" }
        out += String.fromCharCode(parseInt(hex, 16))
        i += 4
      } else return { error: "unsupported escape \\" + e }
      i += 2
      continue
    }
    out += c
    i++
  }
  return { error: "unterminated string" }
}

function parseLiteralString(s, i) {
  var end = s.indexOf("'", i + 1)
  if (end < 0) return { error: "unterminated literal string" }
  return { value: s.substring(i + 1, end), next: end + 1 }
}

function parseArray(s, i) {
  var out = []
  i++
  for (;;) {
    i = skipWs(s, i)
    if (i >= s.length) return { error: "unterminated array" }
    if (s.charAt(i) === "]") return { value: out, next: i + 1 }
    var pv = parseValueAt(s, i)
    if (pv.error) return pv
    out.push(pv.value)
    i = skipWs(s, pv.next)
    if (s.charAt(i) === ",") { i++; continue }
    if (s.charAt(i) === "]") return { value: out, next: i + 1 }
    return { error: "expected ',' or ']' in array" }
  }
}

function parseInlineTable(s, i) {
  var out = {}
  i++
  i = skipWs(s, i)
  if (s.charAt(i) === "}") return { value: out, next: i + 1 }
  for (;;) {
    i = skipWs(s, i)
    var eq = s.indexOf("=", i)
    if (eq < 0) return { error: "expected key = value in inline table" }
    var key = unquoteKey(s.substring(i, eq).trim())
    if (key === "") return { error: "empty key in inline table" }
    var pv = parseValueAt(s, eq + 1)
    if (pv.error) return pv
    out[key] = pv.value
    i = skipWs(s, pv.next)
    if (s.charAt(i) === ",") { i++; continue }
    if (s.charAt(i) === "}") return { value: out, next: i + 1 }
    return { error: "expected ',' or '}' in inline table" }
  }
}

// ------------------------------------------------------------------ config

// Condition operators, and the fields they may be applied to. Values for
// `size` accept human units ("25 MB"); values for `age` accept durations
// ("30d", "2w", "12h"). String comparisons are case-insensitive.
var STRING_OPS = {
  is: true, is_not: true, contains: true, not_contains: true,
  starts_with: true, ends_with: true, matches: true, "in": true, not_in: true
}
var NUMBER_OPS = { is: true, is_not: true, gt: true, lt: true, gte: true, lte: true }

// Probe fields cannot be answered from a stat alone — grep, `file`, xattrs,
// or a user script have to run against the file. They compile to per-folder
// probes (see compileConfig) whose results arrive on the file record.
var CONTENT_OPS = { contains: true, not_contains: true, matches: true }
var SCRIPT_OPS = { passes: true, fails: true }

var FIELDS = {
  name: "string",       // basename without extension
  fullname: "string",   // basename with extension
  extension: "string",  // lowercase, without the dot
  path: "string",       // absolute path
  kind: "string",       // image | video | audio | document | archive | code | other
  mime: "string",       // real content type via `file --mime-type` (probe)
  source: "string",     // download origin URL from the user.xdg.origin.url xattr (probe)
  size: "number",       // bytes
  age: "number",        // seconds since last modification
  created: "number",    // seconds since birth time (falls back to mtime)
  contents: "probe",    // text inside the file, via grep
  script: "probe"       // arbitrary command; exit 0 = the condition holds
}

var KIND_EXTENSIONS = {
  image: ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "tif", "heic", "avif", "ico"],
  video: ["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv"],
  audio: ["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac", "wma"],
  document: ["pdf", "doc", "docx", "odt", "txt", "md", "rtf", "xls", "xlsx", "ods",
    "ppt", "pptx", "odp", "csv", "epub", "pages", "numbers", "key"],
  archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"],
  code: ["js", "ts", "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "java", "sh",
    "bash", "qml", "json", "toml", "yaml", "yml", "html", "css", "sql", "lua"]
}

function kindOf(ext) {
  var e = String(ext || "").toLowerCase()
  for (var kind in KIND_EXTENSIONS) {
    if (KIND_EXTENSIONS[kind].indexOf(e) >= 0) return kind
  }
  return "other"
}

// Files nothing should ever act on: hidden files and the partial-download
// names browsers and download tools use while a file is still arriving.
var DEFAULT_IGNORE = ["*.part", "*.crdownload", "*.download", "*.opdownload",
  "*.aria2", "*.tmp", "*.partial", "*~"]

// "25 MB", "1.5gb", "300kb", or a bare number of bytes.
function parseSize(value) {
  if (typeof value === "number") return isFinite(value) ? value : null
  var m = String(value || "").trim().match(/^([0-9]+(?:\.[0-9]+)?)\s*(b|kb|mb|gb|tb)?$/i)
  if (!m) return null
  var units = { b: 1, kb: 1024, mb: 1048576, gb: 1073741824, tb: 1099511627776 }
  return Math.round(parseFloat(m[1]) * units[(m[2] || "b").toLowerCase()])
}

// "45s", "90m", "12h", "30d", "2w", or a bare number of days. Returns seconds.
function parseAgeSec(value) {
  if (typeof value === "number") return isFinite(value) ? Math.round(value * 86400) : null
  var m = String(value || "").trim().match(/^([0-9]+(?:\.[0-9]+)?)\s*(s|m|h|d|w)?$/i)
  if (!m) return null
  var units = { s: 1, m: 60, h: 3600, d: 86400, w: 604800 }
  return Math.round(parseFloat(m[1]) * units[(m[2] || "d").toLowerCase()])
}

function globToRegExp(glob) {
  var out = "^"
  for (var i = 0; i < glob.length; i++) {
    var c = glob.charAt(i)
    if (c === "*") out += ".*"
    else if (c === "?") out += "."
    else out += c.replace(/[.+^${}()|[\]\\]/g, "\\$&")
  }
  return new RegExp(out + "$", "i")
}

function matchesAnyGlob(name, globs) {
  for (var i = 0; i < globs.length; i++) {
    if (globToRegExp(globs[i]).test(name)) return true
  }
  return false
}

function expandHome(path, home) {
  var p = String(path || "")
  if (p === "~") return home
  if (p.indexOf("~/") === 0) return home + p.substring(1)
  return p
}

// Normalizes one raw condition into { field, op, value }. Accepts both the
// explicit form { field, op, value } and the shorthand where the operator is
// the key: { field = "extension", is = "pdf" }.
function compileCondition(raw) {
  if (typeof raw !== "object" || raw === null || isArrayValue(raw))
    return { error: "condition must be a table" }
  var field = String(raw.field || "")
  if (FIELDS[field] === undefined)
    return { error: "unknown field '" + field + "'" }

  var op = null
  var value
  if (raw.op !== undefined) {
    op = String(raw.op)
    value = raw.value
  } else {
    for (var key in raw) {
      if (key === "field") continue
      if (STRING_OPS[key] || NUMBER_OPS[key] || SCRIPT_OPS[key]) {
        if (op !== null) return { error: "condition has more than one operator" }
        op = key
        value = raw[key]
      }
    }
  }
  if (op === null) return { error: "condition on '" + field + "' has no operator" }

  var fieldType = FIELDS[field]

  if (field === "contents") {
    if (!CONTENT_OPS[op]) return { error: "operator '" + op + "' cannot apply to 'contents'" }
    var pattern = String(value === undefined ? "" : value)
    if (pattern === "") return { error: "contents condition needs text to look for" }
    return { value: { field: field, op: op, value: pattern } }
  }
  if (field === "script") {
    if (!SCRIPT_OPS[op]) return { error: "script conditions use 'passes' or 'fails'" }
    var command = String(value === undefined ? "" : value)
    if (command === "") return { error: "script condition needs a command" }
    return { value: { field: field, op: op, value: command } }
  }

  var validOps = fieldType === "number" ? NUMBER_OPS : STRING_OPS
  if (!validOps[op]) return { error: "operator '" + op + "' cannot apply to '" + field + "'" }

  if (fieldType === "number") {
    var parse = field === "size" ? parseSize : parseAgeSec
    var parsed = parse(value)
    if (parsed === null) return { error: "cannot read '" + value + "' as a " + field + " value" }
    return { value: { field: field, op: op, value: parsed } }
  }

  if (op === "in" || op === "not_in") {
    if (!isArrayValue(value)) return { error: "'" + op + "' needs an array value" }
    var list = []
    for (var i = 0; i < value.length; i++) list.push(String(value[i]).toLowerCase())
    return { value: { field: field, op: op, value: list } }
  }
  if (op === "matches") {
    try { new RegExp(String(value)) } catch (e) { return { error: "bad regex: " + String(value) } }
    return { value: { field: field, op: op, value: String(value) } }
  }
  return { value: { field: field, op: op, value: String(value).toLowerCase() } }
}

// Per-action required and optional keys, used both to validate the config and
// to reject typos loudly instead of silently doing nothing.
var ACTION_SPECS = {
  move:     { required: ["to"], optional: ["as"] },
  copy:     { required: ["to"], optional: ["as"] },
  rename:   { required: ["pattern"], optional: [] },
  sort:     { required: ["into"], optional: [] },
  trash:    { required: [], optional: [] },
  "delete": { required: [], optional: [] },
  open:     { required: [], optional: [] },
  run:      { required: ["command"], optional: [] },
  notify:   { required: [], optional: ["message"] },
  extract:  { required: [], optional: ["to", "delete_archive"] },
  compress: { required: [], optional: ["to", "name"] },
  encrypt:  { required: [], optional: ["recipient", "recipients_file", "identity",
    "delete_original", "verify"] },
  upload:   { required: ["via"], optional: ["device", "remote", "path"] }
}

var UPLOAD_PROVIDERS = { taildrop: true, dropbox: true, protondrive: true, rclone: true }

function compileAction(raw, home) {
  if (typeof raw !== "object" || raw === null || isArrayValue(raw))
    return { error: "action must be a table" }
  var verb = String(raw["do"] || "")
  var spec = ACTION_SPECS[verb]
  if (!spec) return { error: "unknown action '" + verb + "'" }

  for (var r = 0; r < spec.required.length; r++) {
    if (raw[spec.required[r]] === undefined)
      return { error: "action '" + verb + "' needs '" + spec.required[r] + "'" }
  }
  for (var key in raw) {
    if (key === "do") continue
    if (spec.required.indexOf(key) < 0 && spec.optional.indexOf(key) < 0)
      return { error: "action '" + verb + "' does not take '" + key + "'" }
  }

  var action = { verb: verb }
  if (raw.to !== undefined) action.to = expandHome(String(raw.to), home)
  if (raw.as !== undefined) action.as = String(raw.as)
  if (raw.pattern !== undefined) action.pattern = String(raw.pattern)
  if (raw.into !== undefined) action.into = String(raw.into)
  if (raw.command !== undefined) action.command = String(raw.command)
  if (raw.message !== undefined) action.message = String(raw.message)
  if (raw.name !== undefined) action.name = String(raw.name)
  if (raw.delete_archive !== undefined) action.deleteArchive = raw.delete_archive === true

  if (verb === "encrypt") {
    if (raw.recipient === undefined && raw.recipients_file === undefined)
      return { error: "encrypt needs 'recipient' or 'recipients_file'" }
    if (raw.recipient !== undefined) action.recipient = String(raw.recipient)
    if (raw.recipients_file !== undefined)
      action.recipientsFile = expandHome(String(raw.recipients_file), home)
    action.identity = raw.identity !== undefined ? expandHome(String(raw.identity), home) : ""
    action.deleteOriginal = raw.delete_original === true
    action.verify = raw.verify !== false
    // Deleting the original with verification off, or with nothing to verify
    // against, is a data-loss footgun; require the opt-out to be explicit.
    if (action.deleteOriginal && action.verify && action.identity === "")
      return { error: "encrypt with delete_original needs 'identity' to verify against " +
        "(or set verify = false to accept unverified deletion)" }
  }

  if (verb === "upload") {
    action.via = String(raw.via).toLowerCase()
    if (!UPLOAD_PROVIDERS[action.via])
      return { error: "upload 'via' must be taildrop, dropbox, protondrive, or rclone" }
    if (action.via === "taildrop") {
      if (raw.device === undefined) return { error: "upload via taildrop needs 'device'" }
      action.device = String(raw.device)
    } else {
      // The named providers default the remote to their own name; the generic
      // rclone provider has no sensible default, so it must be spelled out.
      if (action.via === "rclone" && raw.remote === undefined)
        return { error: "upload via rclone needs 'remote'" }
      action.remote = raw.remote !== undefined ? String(raw.remote) : action.via
      action.path = raw.path !== undefined ? String(raw.path) : ""
    }
  }

  return { value: action }
}

// Turns the parsed TOML into validated folders and rules. Invalid rules are
// dropped with an error message that names them, so one typo does not take the
// whole config down; a folder with no valid rules is still listed so the UI
// can show why nothing is happening.
function compileConfig(parsed, home) {
  var folders = []
  var errors = []
  var rawFolders = parsed && parsed.folder
  if (!isArrayValue(rawFolders) || rawFolders.length === 0) {
    return { folders: [], errors: ["no [[folder]] entries found"] }
  }

  for (var f = 0; f < rawFolders.length; f++) {
    var rawFolder = rawFolders[f]
    var where = "folder " + (f + 1)
    if (typeof rawFolder !== "object" || rawFolder === null) {
      errors.push(where + ": not a table")
      continue
    }
    if (rawFolder.path === undefined) {
      errors.push(where + ": missing 'path'")
      continue
    }
    var folder = {
      path: expandHome(String(rawFolder.path), home).replace(/\/+$/, ""),
      recursive: rawFolder.recursive === true,
      enabled: rawFolder.enabled !== false,
      ignore: DEFAULT_IGNORE.slice(),
      rules: []
    }
    where = "folder " + folder.path
    if (rawFolder.ignore !== undefined) {
      if (!isArrayValue(rawFolder.ignore)) {
        errors.push(where + ": 'ignore' must be an array of globs")
      } else {
        for (var g = 0; g < rawFolder.ignore.length; g++)
          folder.ignore.push(String(rawFolder.ignore[g]))
      }
    }

    var rawRules = rawFolder.rule
    if (rawRules === undefined) rawRules = []
    if (!isArrayValue(rawRules)) {
      errors.push(where + ": 'rule' must be [[folder.rule]] tables")
      rawRules = []
    }

    for (var r = 0; r < rawRules.length; r++) {
      var rawRule = rawRules[r]
      var ruleName = rawRule && rawRule.name ? String(rawRule.name) : "rule " + (r + 1)
      var ruleWhere = where + ", " + ruleName
      var rule = { name: ruleName, all: [], any: [], none: [], actions: [] }
      // Hazel's "continue matching rules": true keeps evaluating later rules
      // even after this one relocates the file (the caller's responsibility to
      // make sensible), false stops after this rule no matter what, and unset
      // keeps the default stop-only-when-relocated behaviour.
      if (rawRule["continue"] === true) rule.cont = "always"
      else if (rawRule["continue"] === false) rule.cont = "never"
      var bad = false

      var groups = ["all", "any", "none"]
      for (var gi = 0; gi < groups.length && !bad; gi++) {
        var groupName = groups[gi]
        var rawGroup = rawRule[groupName]
        if (rawGroup === undefined) continue
        if (!isArrayValue(rawGroup)) {
          errors.push(ruleWhere + ": '" + groupName + "' must be an array of conditions")
          bad = true
          break
        }
        for (var c = 0; c < rawGroup.length; c++) {
          var cond = compileCondition(rawGroup[c])
          if (cond.error) {
            errors.push(ruleWhere + ": " + cond.error)
            bad = true
            break
          }
          rule[groupName].push(cond.value)
        }
      }
      if (bad) continue

      var rawActions = rawRule.actions
      if (!isArrayValue(rawActions) || rawActions.length === 0) {
        errors.push(ruleWhere + ": needs a non-empty 'actions' array")
        continue
      }
      for (var a = 0; a < rawActions.length; a++) {
        var action = compileAction(rawActions[a], home)
        if (action.error) {
          errors.push(ruleWhere + ": " + action.error)
          bad = true
          break
        }
        rule.actions.push(action.value)
      }
      if (bad) continue

      folder.rules.push(rule)
    }

    attachProbes(folder)
    folders.push(folder)
  }

  return { folders: folders, errors: errors }
}

// Walks a folder's compiled conditions and works out what the per-file probe
// has to gather: birth time, mime type, origin xattr, and one grep or script
// run per distinct contents/script condition. Identical probes are shared so
// two rules greping for the same text cost one grep.
function attachProbes(folder) {
  folder.probes = []
  folder.probeNeeds = { btime: false, mime: false, source: false }
  var seen = {}
  for (var r = 0; r < folder.rules.length; r++) {
    var rule = folder.rules[r]
    var groups = [rule.all, rule.any, rule.none]
    for (var g = 0; g < groups.length; g++) {
      for (var c = 0; c < groups[g].length; c++) {
        var cond = groups[g][c]
        if (cond.field === "created") folder.probeNeeds.btime = true
        if (cond.field === "mime") folder.probeNeeds.mime = true
        if (cond.field === "source") folder.probeNeeds.source = true
        if (FIELDS[cond.field] !== "probe") continue
        var mode = cond.field === "script" ? "script"
          : (cond.op === "matches" ? "E" : "F")
        var key = mode + "\u0000" + cond.value
        if (seen[key] === undefined) {
          seen[key] = folder.probes.length
          folder.probes.push({ id: seen[key], mode: mode, value: cond.value })
        }
        cond.probeId = seen[key]
      }
    }
  }
  folder.needsProbe = folder.probes.length > 0 || folder.probeNeeds.btime
    || folder.probeNeeds.mime || folder.probeNeeds.source
}

// The extra arguments omazel-probe.sh needs for this folder's rules, beyond
// the stat every file gets.
function probeArgs(folder) {
  var out = []
  if (folder.probeNeeds && folder.probeNeeds.mime) out.push("--mime")
  if (folder.probeNeeds && folder.probeNeeds.source) out.push("--source")
  var probes = folder.probes || []
  for (var i = 0; i < probes.length; i++) {
    if (probes[i].mode === "script") out.push("--script", String(probes[i].id), probes[i].value)
    else out.push("--grep", probes[i].mode, String(probes[i].id), probes[i].value)
  }
  return out
}

// --------------------------------------------------------------- matching

// Derives the fields conditions can see from a path and stat results.
function fileRecord(path, sizeBytes, mtimeSec) {
  var p = String(path)
  var slash = p.lastIndexOf("/")
  var fullname = slash >= 0 ? p.substring(slash + 1) : p
  var dir = slash > 0 ? p.substring(0, slash) : "/"
  var dot = fullname.lastIndexOf(".")
  var hasExt = dot > 0 && dot < fullname.length - 1
  return {
    path: p,
    dir: dir,
    fullname: fullname,
    name: hasExt ? fullname.substring(0, dot) : fullname,
    ext: hasExt ? fullname.substring(dot + 1).toLowerCase() : "",
    size: Number(sizeBytes) || 0,
    mtimeSec: Number(mtimeSec) || 0
  }
}

// Field value with original casing, for regex capture extraction — a capture
// used in a rename should keep the case the filename actually has.
function rawConditionValue(file, field) {
  if (field === "name") return file.name
  if (field === "fullname") return file.fullname
  if (field === "extension") return file.ext
  if (field === "path") return file.path
  if (field === "kind") return kindOf(file.ext)
  if (field === "mime") return String(file.mime || "")
  if (field === "source") return String(file.source || "")
  return ""
}

function conditionValue(file, field, nowSec) {
  if (field === "size") return file.size
  if (field === "age") return Math.max(0, nowSec - file.mtimeSec)
  if (field === "created") {
    // Not every filesystem records birth time; mtime is the honest fallback
    // and matches what `age` would say for an untouched file.
    var born = file.btimeSec > 0 ? file.btimeSec : file.mtimeSec
    return Math.max(0, nowSec - born)
  }
  return rawConditionValue(file, field).toLowerCase()
}

function matchCondition(file, cond, nowSec) {
  if (FIELDS[cond.field] === "probe") {
    // Probe results are computed outside the matcher (grep, `file`, or the
    // user's script) and delivered on the record. A missing result means the
    // probe could not run, which must read as "did not match" for positive
    // and negative operators alike — inverting an unknown would invent a hit.
    var probes = file.probes || {}
    if (probes[cond.probeId] === undefined) return false
    var hit = probes[cond.probeId] === true
    return (cond.op === "not_contains" || cond.op === "fails") ? !hit : hit
  }

  var actual = conditionValue(file, cond.field, nowSec)

  if (FIELDS[cond.field] === "number") {
    if (cond.op === "is") return actual === cond.value
    if (cond.op === "is_not") return actual !== cond.value
    if (cond.op === "gt") return actual > cond.value
    if (cond.op === "lt") return actual < cond.value
    if (cond.op === "gte") return actual >= cond.value
    if (cond.op === "lte") return actual <= cond.value
    return false
  }

  var s = String(actual)
  if (cond.op === "is") return s === cond.value
  if (cond.op === "is_not") return s !== cond.value
  if (cond.op === "contains") return s.indexOf(cond.value) >= 0
  if (cond.op === "not_contains") return s.indexOf(cond.value) < 0
  if (cond.op === "starts_with") return s.indexOf(cond.value) === 0
  if (cond.op === "ends_with") return s.length >= cond.value.length
    && s.lastIndexOf(cond.value) === s.length - cond.value.length
  if (cond.op === "matches") return new RegExp(cond.value, "i").test(s)
  if (cond.op === "in") return cond.value.indexOf(s) >= 0
  if (cond.op === "not_in") return cond.value.indexOf(s) < 0
  return false
}

// A rule matches when every `all` condition holds, at least one `any`
// condition holds (if any are given), and no `none` condition holds. A rule
// with no conditions matches every file — occasionally what you want for a
// catch-all at the bottom of a folder's list.
function ruleMatches(file, rule, nowSec) {
  for (var i = 0; i < rule.all.length; i++) {
    if (!matchCondition(file, rule.all[i], nowSec)) return false
  }
  if (rule.any.length > 0) {
    var hit = false
    for (var j = 0; j < rule.any.length; j++) {
      if (matchCondition(file, rule.any[j], nowSec)) { hit = true; break }
    }
    if (!hit) return false
  }
  for (var k = 0; k < rule.none.length; k++) {
    if (matchCondition(file, rule.none[k], nowSec)) return false
  }
  return true
}

// --------------------------------------------------------------- planning

// Capture groups from the rule's first successful `matches` condition, made
// available to patterns as {1}, {2}, … and {0} for the whole match — Hazel's
// custom match tokens. Extracted against the original-case field value so a
// captured "Invoice" does not come out as "invoice".
function ruleCaptures(file, rule) {
  var groups = [rule.all, rule.any]
  for (var g = 0; g < groups.length; g++) {
    for (var c = 0; c < groups[g].length; c++) {
      var cond = groups[g][c]
      if (cond.op !== "matches" || FIELDS[cond.field] !== "string") continue
      var m
      try { m = new RegExp(cond.value, "i").exec(rawConditionValue(file, cond.field)) }
      catch (e) { continue }
      if (!m) continue
      var out = {}
      for (var i = 0; i < m.length && i <= 9; i++) {
        out[String(i)] = m[i] === undefined ? "" : String(m[i])
      }
      return out
    }
  }
  return {}
}

// Expands the {tokens} a pattern may carry. Date tokens come from the file's
// own mtime so "sort into {year}/{month}" files things by when they arrived,
// not by when the rule happened to run.
function expandPattern(pattern, file, nowSec, captures) {
  var when = file.mtimeSec > 0 ? file.mtimeSec : nowSec
  var d = new Date(when * 1000)
  var pad = function (n) { return (n < 10 ? "0" : "") + n }
  var tokens = {
    name: file.name,
    fullname: file.fullname,
    ext: file.ext,
    folder: file.dir.substring(file.dir.lastIndexOf("/") + 1),
    year: String(d.getFullYear()),
    month: pad(d.getMonth() + 1),
    day: pad(d.getDate()),
    date: d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()),
    time: pad(d.getHours()) + "-" + pad(d.getMinutes())
  }
  if (captures) {
    for (var key in captures) tokens[key] = captures[key]
  }
  return String(pattern).replace(/\{(\w+)\}/g, function (m, token) {
    return tokens[token] !== undefined ? tokens[token] : m
  })
}

// A rename pattern that produced no extension keeps the original one, so
// "{date} {name}" does what people mean without them having to remember {ext}.
function expandRename(pattern, file, nowSec, captures) {
  var out = expandPattern(pattern, file, nowSec, captures)
  if (file.ext !== "" && out.lastIndexOf(".") <= 0) out += "." + file.ext
  return out
}

// Builds the omazel-act.sh invocation for one action against one file. Each
// plan is { verb, argv, summary, relocates }: argv is exactly what the script
// receives after its own path, and relocates marks actions after which the
// file is no longer at its original path.
function buildPlan(action, file, nowSec, captures) {
  var verb = action.verb

  if (verb === "move" || verb === "copy") {
    var destDir = expandPattern(action.to, file, nowSec, captures)
    var newName = action.as !== undefined ? expandRename(action.as, file, nowSec, captures) : ""
    return {
      verb: verb,
      argv: [verb, file.path, destDir, newName],
      summary: (verb === "move" ? "Move to " : "Copy to ") + destDir,
      relocates: verb === "move"
    }
  }
  if (verb === "rename") {
    var renamed = expandRename(action.pattern, file, nowSec, captures)
    return { verb: verb, argv: ["rename", file.path, renamed],
      summary: "Rename to " + renamed, relocates: true }
  }
  if (verb === "sort") {
    var sub = expandPattern(action.into, file, nowSec, captures)
    return { verb: "move", argv: ["move", file.path, file.dir + "/" + sub, ""],
      summary: "Sort into " + sub + "/", relocates: true }
  }
  if (verb === "trash") {
    return { verb: verb, argv: ["trash", file.path], summary: "Move to trash", relocates: true }
  }
  if (verb === "delete") {
    return { verb: verb, argv: ["delete", file.path], summary: "Delete", relocates: true }
  }
  if (verb === "open") {
    return { verb: verb, argv: ["open", file.path], summary: "Open", relocates: false }
  }
  if (verb === "run") {
    return { verb: verb, argv: ["run", file.path, action.command],
      summary: "Run: " + action.command, relocates: false }
  }
  if (verb === "notify") {
    var message = expandPattern(action.message !== undefined ? action.message : "{fullname}",
      file, nowSec, captures)
    return { verb: verb, argv: ["notify", file.path, message],
      summary: "Notify", relocates: false }
  }
  if (verb === "extract") {
    var extractTo = action.to !== undefined
      ? expandPattern(action.to, file, nowSec, captures) : file.dir
    return { verb: verb,
      argv: ["extract", file.path, extractTo, action.deleteArchive ? "1" : "0"],
      summary: "Extract to " + extractTo, relocates: action.deleteArchive === true }
  }
  if (verb === "compress") {
    var zipDir = action.to !== undefined
      ? expandPattern(action.to, file, nowSec, captures) : file.dir
    var zipName = action.name !== undefined
      ? expandPattern(action.name, file, nowSec, captures) : file.fullname + ".zip"
    return { verb: verb, argv: ["compress", file.path, zipDir, zipName],
      summary: "Compress to " + zipName, relocates: false }
  }
  if (verb === "encrypt") {
    var spec = action.recipientsFile !== undefined
      ? "R:" + action.recipientsFile : "r:" + action.recipient
    return { verb: verb,
      argv: ["encrypt", file.path, spec, action.identity !== "" ? action.identity : "-",
        action.deleteOriginal ? "1" : "0", action.verify ? "1" : "0"],
      summary: "Encrypt with age" + (action.deleteOriginal ? " (replace original)" : ""),
      relocates: action.deleteOriginal === true }
  }
  if (verb === "upload") {
    if (action.via === "taildrop") {
      return { verb: verb, argv: ["upload", file.path, "taildrop", action.device, ""],
        summary: "Taildrop to " + action.device, relocates: false }
    }
    return { verb: verb, argv: ["upload", file.path, action.via, action.remote, action.path],
      summary: "Upload to " + action.remote + (action.path !== "" ? ":" + action.path : ""),
      relocates: false }
  }
  return null
}

// The heart of the engine: one observed file in, an ordered list of action
// plans out. Rules run top-down; once a matching rule relocates the file,
// later rules no longer apply because the file they would examine is gone —
// unless the rule says `continue = true`, or says `continue = false` to stop
// even without relocating.
function planFile(file, folder, nowSec) {
  var out = []
  if (matchesAnyGlob(file.fullname, folder.ignore)) return out
  // Hidden files, and files inside hidden directories, are never acted on —
  // judged relative to the watched folder, so deliberately watching a hidden
  // folder like ~/.config/foo still works.
  var rel = file.path.indexOf(folder.path + "/") === 0
    ? file.path.substring(folder.path.length + 1) : file.fullname
  var segments = rel.split("/")
  for (var s = 0; s < segments.length; s++) {
    if (segments[s].charAt(0) === ".") return out
  }
  for (var r = 0; r < folder.rules.length; r++) {
    var rule = folder.rules[r]
    if (!ruleMatches(file, rule, nowSec)) continue
    var captures = ruleCaptures(file, rule)
    var relocated = false
    for (var a = 0; a < rule.actions.length; a++) {
      var plan = buildPlan(rule.actions[a], file, nowSec, captures)
      if (plan === null) continue
      plan.rule = rule.name
      // Position, not name, so two rules that happen to share a name cannot
      // share a cooldown entry.
      plan.ruleId = r
      plan.file = file.path
      out.push(plan)
      if (plan.relocates) relocated = true
    }
    if (rule.cont === "never") break
    if (relocated && rule.cont !== "always") break
  }
  return out
}

// ------------------------------------------------------------ capabilities

// Which external tools the compiled config actually depends on, so the popup
// warns about the missing ones that matter and stays silent about the rest.
function requiredTools(folders) {
  var need = { inotifywait: "watching folders" }
  for (var f = 0; f < folders.length; f++) {
    if (folders[f].probeNeeds && folders[f].probeNeeds.mime) need["file"] = "mime conditions"
    if (folders[f].probeNeeds && folders[f].probeNeeds.source) need["getfattr"] = "source conditions"
    for (var r = 0; r < folders[f].rules.length; r++) {
      var actions = folders[f].rules[r].actions
      for (var a = 0; a < actions.length; a++) {
        var action = actions[a]
        if (action.verb === "trash") need["gio"] = "trash action"
        if (action.verb === "notify") need["notify-send"] = "notify action"
        if (action.verb === "extract") need["unzip"] = "extract action"
        if (action.verb === "compress") need["zip"] = "compress action"
        if (action.verb === "open") need["xdg-open"] = "open action"
        if (action.verb === "encrypt") {
          need["age"] = "encrypt action"
          if (action.deleteOriginal) need["gio"] = "trashing encrypted originals"
        }
        if (action.verb === "upload") {
          if (action.via === "taildrop") need["tailscale"] = "taildrop upload"
          else need["rclone"] = action.via + " upload"
        }
      }
    }
  }
  var out = []
  for (var tool in need) out.push({ tool: tool, why: need[tool] })
  return out
}

function missingTools(required, caps) {
  var out = []
  for (var i = 0; i < required.length; i++) {
    if (caps[required[i].tool] === false) out.push(required[i])
  }
  return out
}

// ---------------------------------------------------------------- activity

// The activity log is TSV, one action per line, written by omazel-act.sh:
//   epoch <TAB> status <TAB> verb <TAB> rule <TAB> path <TAB> dest <TAB> message
function parseActivityLines(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") continue
    var parts = line.split("\t")
    if (parts.length < 5) continue
    var path = parts[4]
    out.push({
      epoch: parseInt(parts[0], 10) || 0,
      status: parts[1],
      verb: parts[2],
      rule: parts[3],
      path: path,
      file: path.substring(path.lastIndexOf("/") + 1),
      dest: parts.length > 5 ? parts[5] : "",
      message: parts.length > 6 ? parts.slice(6).join(" ") : ""
    })
  }
  return out
}

// Tab-separated key/value lines, as emitted by the shell scripts.
function parseFields(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var tab = lines[i].indexOf("\t")
    if (tab <= 0) continue
    out[lines[i].substring(0, tab)] = lines[i].substring(tab + 1)
  }
  return out
}

// ------------------------------------------------------------------ editor

// Everything the visual rule editor needs, kept here so it stays pure and
// testable. The editor works on a "draft": a plain-JS mirror of the rules
// file where every value is a string exactly as the user typed it. Saving
// converts the draft back to the raw TOML structure, validates it through the
// same compileConfig the engine uses, and serializes it — so the GUI can
// never write a file the engine would then reject.

var GENERATED_HEADER = "# Omazel rules — written by the visual editor."

var FIELD_OPTIONS = [
  { value: "name", label: "Name" },
  { value: "fullname", label: "Full name" },
  { value: "extension", label: "Extension" },
  { value: "kind", label: "Kind" },
  { value: "path", label: "Path" },
  { value: "mime", label: "MIME type" },
  { value: "source", label: "Source URL" },
  { value: "size", label: "Size" },
  { value: "age", label: "Age" },
  { value: "created", label: "Created" },
  { value: "contents", label: "Contents" },
  { value: "script", label: "Script" }
]

var GROUP_OPTIONS = [
  { value: "all", label: "All" },
  { value: "any", label: "Any" },
  { value: "none", label: "None" }
]

var STRING_OP_OPTIONS = [
  { value: "is", label: "is" },
  { value: "is_not", label: "is not" },
  { value: "contains", label: "contains" },
  { value: "not_contains", label: "doesn't contain" },
  { value: "starts_with", label: "starts with" },
  { value: "ends_with", label: "ends with" },
  { value: "matches", label: "matches regex" },
  { value: "in", label: "is one of" },
  { value: "not_in", label: "is not one of" }
]

var NUMBER_OP_OPTIONS = [
  { value: "gt", label: "more than" },
  { value: "lt", label: "less than" },
  { value: "gte", label: "at least" },
  { value: "lte", label: "at most" },
  { value: "is", label: "exactly" },
  { value: "is_not", label: "not exactly" }
]

var CONTENT_OP_OPTIONS = [
  { value: "contains", label: "contains" },
  { value: "not_contains", label: "doesn't contain" },
  { value: "matches", label: "matches regex" }
]

var SCRIPT_OP_OPTIONS = [
  { value: "passes", label: "passes (exit 0)" },
  { value: "fails", label: "fails (non-zero)" }
]

function opsForField(field) {
  if (field === "contents") return CONTENT_OP_OPTIONS
  if (field === "script") return SCRIPT_OP_OPTIONS
  return FIELDS[field] === "number" ? NUMBER_OP_OPTIONS : STRING_OP_OPTIONS
}

var ACTION_OPTIONS = [
  { value: "move", label: "Move to folder" },
  { value: "copy", label: "Copy to folder" },
  { value: "rename", label: "Rename" },
  { value: "sort", label: "Sort into subfolder" },
  { value: "trash", label: "Move to trash" },
  { value: "delete", label: "Delete" },
  { value: "open", label: "Open" },
  { value: "extract", label: "Extract archive" },
  { value: "compress", label: "Compress" },
  { value: "notify", label: "Send notification" },
  { value: "run", label: "Run command" },
  { value: "encrypt", label: "Encrypt with age" },
  { value: "upload", label: "Upload / send" }
]

// Shown by the editor's ⓘ hints panel; one row per pattern token.
var PATTERN_HINTS = [
  { token: "{name}", hint: "file name without extension" },
  { token: "{fullname}", hint: "file name with extension" },
  { token: "{ext}", hint: "extension, lowercase, no dot" },
  { token: "{folder}", hint: "name of the file's folder" },
  { token: "{date}", hint: "file's date as 2026-08-22" },
  { token: "{year} {month} {day}", hint: "file's date, piecewise" },
  { token: "{time}", hint: "file's time as 16-45" },
  { token: "{1}…{9}, {0}", hint: "capture groups from a 'matches regex' condition" }
]

var DOCS_URL = "https://github.com/bscott/Omazel/blob/main/docs/HOWTO.md"

var CONTINUE_OPTIONS = [
  { value: "auto", label: "Stop if file was relocated (default)" },
  { value: "always", label: "Always keep matching later rules" },
  { value: "never", label: "Stop after this rule" }
]

function valuePlaceholder(field, op) {
  if (field === "size") return "e.g. 10 MB"
  if (field === "age" || field === "created") return "e.g. 30d or 2w"
  if (field === "contents") return op === "matches" ? "regex to grep for" : "text to find in the file"
  if (field === "script") return "command — file passed as $1"
  if (field === "mime") return "e.g. application/pdf"
  if (field === "source") return "e.g. mybank.com"
  if (op === "in" || op === "not_in") return "comma-separated: pdf, docx"
  if (op === "matches") return "regex — captures usable as {1}, {2}"
  if (field === "kind") return "image, video, document, archive…"
  return "value"
}

// Which inputs the editor renders for an action. Upload's fields depend on
// the chosen provider, which is why the current params are passed in.
function actionParams(verb, params) {
  if (verb === "move" || verb === "copy") return [
    { key: "to", label: "To folder", type: "text", placeholder: "~/Documents/{year}", required: true },
    { key: "as", label: "Rename as", type: "text", placeholder: "optional — {date} {name}.{ext}" }
  ]
  if (verb === "rename") return [
    { key: "pattern", label: "Pattern", type: "text", placeholder: "{date} {name}", required: true }
  ]
  if (verb === "sort") return [
    { key: "into", label: "Subfolder", type: "text", placeholder: "{ext} or {year}/{month}", required: true }
  ]
  if (verb === "run") return [
    { key: "command", label: "Command", type: "text", placeholder: "file passed as $1", required: true }
  ]
  if (verb === "notify") return [
    { key: "message", label: "Message", type: "text", placeholder: "Filed {fullname}" }
  ]
  if (verb === "extract") return [
    { key: "to", label: "Extract to", type: "text", placeholder: "optional — same folder" },
    { key: "delete_archive", label: "Delete archive after", type: "bool" }
  ]
  if (verb === "compress") return [
    { key: "to", label: "Archive folder", type: "text", placeholder: "optional — same folder" },
    { key: "name", label: "Archive name", type: "text", placeholder: "{name}.zip" }
  ]
  if (verb === "encrypt") return [
    { key: "recipient", label: "Recipient", type: "text", placeholder: "age1…" },
    { key: "recipients_file", label: "Recipients file", type: "text", placeholder: "or a file of recipients" },
    { key: "identity", label: "Identity file", type: "text", placeholder: "for round-trip verification" },
    { key: "delete_original", label: "Delete original after", type: "bool" },
    { key: "verify", label: "Verify round trip", type: "bool" }
  ]
  if (verb === "upload") {
    var out = [{ key: "via", label: "Send via", type: "choice", options: [
      { value: "taildrop", label: "Taildrop" },
      { value: "dropbox", label: "Dropbox (rclone)" },
      { value: "protondrive", label: "Proton Drive (rclone)" },
      { value: "rclone", label: "Any rclone remote" }
    ] }]
    var via = params && params.via !== undefined ? String(params.via) : "taildrop"
    if (via === "taildrop") {
      out.push({ key: "device", label: "Device", type: "text", placeholder: "phone", required: true })
    } else if (via === "rclone") {
      out.push({ key: "remote", label: "rclone remote", type: "text",
        placeholder: "any configured remote", required: true })
      out.push({ key: "path", label: "Remote path", type: "text", placeholder: "Inbox" })
    } else {
      out.push({ key: "remote", label: "rclone remote", type: "text", placeholder: via })
      out.push({ key: "path", label: "Remote path", type: "text", placeholder: "Inbox" })
    }
    return out
  }
  return []
}

function defaultParamsFor(verb) {
  if (verb === "upload") return { via: "taildrop" }
  if (verb === "encrypt") return { verify: true }
  return {}
}

function newDraftCondition() {
  return { group: "all", field: "name", op: "contains", value: "" }
}

function newDraftAction() {
  return { verb: "move", params: {} }
}

function newDraftRule() {
  return { name: "New rule", cont: "auto",
    conditions: [newDraftCondition()], actions: [newDraftAction()] }
}

function newDraftFolder() {
  return { path: "~/Downloads", recursive: false, enabled: true, ignore: "", rules: [newDraftRule()] }
}

function rawConditionToDraft(c) {
  var d = newDraftCondition()
  if (typeof c !== "object" || c === null) return d
  if (FIELDS[String(c.field)] !== undefined) d.field = String(c.field)
  var op = null
  var value
  if (c.op !== undefined) {
    op = String(c.op)
    value = c.value
  } else {
    for (var key in c) {
      if (key === "field") continue
      if (STRING_OPS[key] || NUMBER_OPS[key] || SCRIPT_OPS[key]) { op = key; value = c[key]; break }
    }
  }
  if (op !== null) d.op = op
  d.value = isArrayValue(value) ? value.join(", ") : (value === undefined ? "" : String(value))
  return d
}

// Raw parsed TOML -> editable draft. Tolerant on purpose: a half-broken value
// becomes something editable rather than an error, because the whole point of
// the editor is fixing things.
function draftFromRaw(raw) {
  var out = []
  var rawFolders = raw && isArrayValue(raw.folder) ? raw.folder : []
  for (var f = 0; f < rawFolders.length; f++) {
    var rf = rawFolders[f]
    if (typeof rf !== "object" || rf === null) continue
    var folder = {
      path: rf.path !== undefined ? String(rf.path) : "",
      recursive: rf.recursive === true,
      enabled: rf.enabled !== false,
      ignore: isArrayValue(rf.ignore) ? rf.ignore.join(", ") : "",
      rules: []
    }
    var rawRules = isArrayValue(rf.rule) ? rf.rule : []
    for (var r = 0; r < rawRules.length; r++) {
      var rr = rawRules[r]
      if (typeof rr !== "object" || rr === null) continue
      var rule = {
        name: rr.name !== undefined ? String(rr.name) : "Rule " + (r + 1),
        cont: rr["continue"] === true ? "always" : (rr["continue"] === false ? "never" : "auto"),
        conditions: [],
        actions: []
      }
      var groups = ["all", "any", "none"]
      for (var g = 0; g < groups.length; g++) {
        if (!isArrayValue(rr[groups[g]])) continue
        for (var c = 0; c < rr[groups[g]].length; c++) {
          var cond = rawConditionToDraft(rr[groups[g]][c])
          cond.group = groups[g]
          rule.conditions.push(cond)
        }
      }
      var rawActions = isArrayValue(rr.actions) ? rr.actions : []
      for (var a = 0; a < rawActions.length; a++) {
        var ra = rawActions[a]
        if (typeof ra !== "object" || ra === null) continue
        var verb = ACTION_SPECS[String(ra["do"])] !== undefined ? String(ra["do"]) : "move"
        var spec = ACTION_SPECS[verb]
        var params = defaultParamsFor(verb)
        var keys = spec.required.concat(spec.optional)
        for (var k = 0; k < keys.length; k++) {
          if (ra[keys[k]] === undefined) continue
          params[keys[k]] = typeof ra[keys[k]] === "boolean" ? ra[keys[k]] : String(ra[keys[k]])
        }
        rule.actions.push({ verb: verb, params: params })
      }
      folder.rules.push(rule)
    }
    out.push(folder)
  }
  return out
}

function splitList(text) {
  var out = []
  var parts = String(text).split(",")
  for (var i = 0; i < parts.length; i++) {
    var t = parts[i].trim()
    if (t !== "") out.push(t)
  }
  return out
}

// Editable draft -> raw TOML structure, dropping empty optionals and any
// params that do not apply (e.g. an rclone remote left over after switching
// an upload to Taildrop).
function draftToRaw(draft) {
  var raw = { folder: [] }
  var list = isArrayValue(draft) ? draft : []
  for (var f = 0; f < list.length; f++) {
    var df = list[f]
    var folder = { path: String(df.path || "").trim() }
    if (df.recursive === true) folder.recursive = true
    if (df.enabled === false) folder.enabled = false
    var globs = splitList(df.ignore || "")
    if (globs.length > 0) folder.ignore = globs
    folder.rule = []
    var rules = isArrayValue(df.rules) ? df.rules : []
    for (var r = 0; r < rules.length; r++) {
      var dr = rules[r]
      var rule = { name: String(dr.name || "").trim() || "Untitled rule" }
      if (dr.cont === "always") rule["continue"] = true
      else if (dr.cont === "never") rule["continue"] = false
      var conds = isArrayValue(dr.conditions) ? dr.conditions : []
      for (var c = 0; c < conds.length; c++) {
        var dc = conds[c]
        var value = String(dc.value === undefined ? "" : dc.value).trim()
        var table = { field: String(dc.field || "name") }
        table[String(dc.op || "contains")] =
          (dc.op === "in" || dc.op === "not_in") ? splitList(value) : value
        var group = dc.group === "any" || dc.group === "none" ? dc.group : "all"
        if (rule[group] === undefined) rule[group] = []
        rule[group].push(table)
      }
      rule.actions = []
      var acts = isArrayValue(dr.actions) ? dr.actions : []
      for (var a = 0; a < acts.length; a++) {
        var da = acts[a]
        var verb = ACTION_SPECS[String(da.verb)] !== undefined ? String(da.verb) : "move"
        var spec = ACTION_SPECS[verb]
        var action = { "do": verb }
        var keys = spec.required.concat(spec.optional)
        for (var k = 0; k < keys.length; k++) {
          var pv = da.params ? da.params[keys[k]] : undefined
          if (pv === undefined) continue
          if (typeof pv === "boolean") {
            // Booleans only appear when they differ from the default, so a
            // hand-written file and a GUI-written one stay equally terse.
            if (keys[k] === "verify" ? pv === false : pv === true) action[keys[k]] = pv
          } else {
            var s = String(pv).trim()
            if (s !== "") action[keys[k]] = s
          }
        }
        if (verb === "upload") {
          if (String(action.via) === "taildrop") { delete action.remote; delete action.path }
          else delete action.device
        }
        rule.actions.push(action)
      }
      folder.rule.push(rule)
    }
    raw.folder.push(folder)
  }
  return raw
}

function tomlString(s) {
  return '"' + String(s)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\t/g, "\\t") + '"'
}

function tomlValue(v) {
  if (typeof v === "boolean") return v ? "true" : "false"
  if (typeof v === "number") return String(v)
  if (isArrayValue(v)) {
    var parts = []
    for (var i = 0; i < v.length; i++) parts.push(tomlValue(v[i]))
    return "[" + parts.join(", ") + "]"
  }
  return tomlString(v)
}

function tomlInline(table) {
  var parts = []
  for (var key in table) parts.push(key + " = " + tomlValue(table[key]))
  return "{ " + parts.join(", ") + " }"
}

function serializeRules(raw) {
  var lines = [GENERATED_HEADER,
    "# Hand edits are fine, but comments are dropped the next time the",
    "# visual editor saves. Field reference: rules.example.toml in the plugin.",
    ""]
  var rawFolders = raw && isArrayValue(raw.folder) ? raw.folder : []
  for (var f = 0; f < rawFolders.length; f++) {
    var folder = rawFolders[f]
    lines.push("[[folder]]")
    lines.push("path = " + tomlString(folder.path))
    if (folder.recursive === true) lines.push("recursive = true")
    if (folder.enabled === false) lines.push("enabled = false")
    if (isArrayValue(folder.ignore)) lines.push("ignore = " + tomlValue(folder.ignore))
    var rules = isArrayValue(folder.rule) ? folder.rule : []
    for (var r = 0; r < rules.length; r++) {
      var rule = rules[r]
      lines.push("")
      lines.push("  [[folder.rule]]")
      lines.push("  name = " + tomlString(rule.name))
      if (rule["continue"] === true) lines.push("  continue = true")
      else if (rule["continue"] === false) lines.push("  continue = false")
      var groups = ["all", "any", "none"]
      for (var g = 0; g < groups.length; g++) {
        if (!isArrayValue(rule[groups[g]]) || rule[groups[g]].length === 0) continue
        lines.push("  " + groups[g] + " = [")
        for (var c = 0; c < rule[groups[g]].length; c++)
          lines.push("    " + tomlInline(rule[groups[g]][c]) + ",")
        lines.push("  ]")
      }
      lines.push("  actions = [")
      var actions = isArrayValue(rule.actions) ? rule.actions : []
      for (var a = 0; a < actions.length; a++)
        lines.push("    " + tomlInline(actions[a]) + ",")
      lines.push("  ]")
    }
    lines.push("")
  }
  return lines.join("\n")
}

// The one gate between the editor and the file: converts, validates through
// the same compiler the engine uses, and only hands back text when the result
// would load cleanly.
function validateDraft(draft, home) {
  var errors = []
  var list = isArrayValue(draft) ? draft : []
  if (list.length === 0) errors.push("add at least one folder")
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].path || "").trim() === "")
      errors.push("folder " + (i + 1) + ": path is empty")
  }
  if (errors.length === 0) {
    var raw = draftToRaw(list)
    var compiled = compileConfig(raw, home)
    errors = compiled.errors
    if (errors.length === 0) return { errors: [], text: serializeRules(raw) }
  }
  return { errors: errors, text: "" }
}

// -------------------------------------------------------------- formatting

function elide(text, max) {
  var s = String(text || "").trim()
  var limit = max || 120
  return s.length <= limit ? s : s.substring(0, limit - 1) + "…"
}

function fmtAgo(epochSec, nowSec) {
  if (!epochSec || epochSec <= 0) return ""
  var delta = Math.max(0, nowSec - epochSec)
  if (delta < 60) return "just now"
  if (delta < 3600) return Math.floor(delta / 60) + "m ago"
  if (delta < 86400) return Math.floor(delta / 3600) + "h ago"
  return Math.floor(delta / 86400) + "d ago"
}

function fmtSize(bytes) {
  var n = Number(bytes) || 0
  if (n < 1024) return n + " B"
  if (n < 1048576) return (n / 1024).toFixed(1) + " KB"
  if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB"
  return (n / 1073741824).toFixed(2) + " GB"
}

var VERB_ICONS = {
  move: "󰉒", copy: "󰆏", rename: "󰑕", trash: "󰩹", "delete": "󰆴",
  open: "󰏌", run: "󰑮", notify: "󰂚", extract: "󰀼", compress: "󰗄",
  encrypt: "󰌾", upload: "󰅧"
}

function verbIcon(verb) {
  return VERB_ICONS[verb] !== undefined ? VERB_ICONS[verb] : "󰃢"
}

function verbLabel(verb) {
  var labels = {
    move: "Moved", copy: "Copied", rename: "Renamed", trash: "Trashed",
    "delete": "Deleted", open: "Opened", run: "Ran command", notify: "Notified",
    extract: "Extracted", compress: "Compressed", encrypt: "Encrypted",
    upload: "Uploaded"
  }
  return labels[verb] !== undefined ? labels[verb] : verb
}
