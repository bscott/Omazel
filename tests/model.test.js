// Exercises Model.js under Node. The module is written as a QML JS library, so
// the only thing standing between it and Node is the `.pragma library` marker;
// stripping that line lets the same source that ships in the plugin be tested
// directly, with no parallel copy to drift out of sync.
//
// Run with: node tests/model.test.js

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs
  .readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")

const Model = {}
vm.createContext(Model)
vm.runInContext(source, Model)

let failures = 0
let checks = 0

function check(label, actual, expected) {
  checks += 1
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) {
    failures += 1
    console.error(`FAIL  ${label}\n        expected ${e}\n        actual   ${a}`)
  }
}

function ok(label, condition) {
  checks += 1
  if (!condition) {
    failures += 1
    console.error(`FAIL  ${label}`)
  }
}

const HOME = "/home/user"

// ---------------------------------------------------------------- TOML

{
  const parsed = Model.parseToml(`
# A comment
title = "Omazel"   # trailing comment
count = 42
ratio = 1.5
flag = true
tags = ["a", 'b', "c",]
`)
  ok("toml: parses scalars", parsed.ok)
  check("toml: string", parsed.value.title, "Omazel")
  check("toml: integer", parsed.value.count, 42)
  check("toml: float", parsed.value.ratio, 1.5)
  check("toml: boolean", parsed.value.flag, true)
  check("toml: array with trailing comma", parsed.value.tags, ["a", "b", "c"])
}

{
  const parsed = Model.parseToml(`
str = "tab\\there # not a comment \\"quoted\\""
lit = 'no \\ escapes # here'
`)
  ok("toml: parses escaped strings", parsed.ok)
  check("toml: basic string escapes", parsed.value.str, 'tab\there # not a comment "quoted"')
  check("toml: literal string keeps backslash", parsed.value.lit, "no \\ escapes # here")
}

{
  const parsed = Model.parseToml(`
[[folder]]
path = "~/Downloads"

  [[folder.rule]]
  name = "first"

  [[folder.rule]]
  name = "second"

[[folder]]
path = "~/Desktop"
`)
  ok("toml: arrays of tables", parsed.ok)
  check("toml: two folders", parsed.value.folder.length, 2)
  check("toml: nested rule array attaches to latest folder",
    parsed.value.folder[0].rule.map(r => r.name), ["first", "second"])
  check("toml: second folder has no rules", parsed.value.folder[1].rule, undefined)
}

{
  const parsed = Model.parseToml(`
conditions = [
  { field = "extension", is = "pdf" },   # inline table in a multi-line array
  { field = "size", gt = "10 MB" },
]
`)
  ok("toml: multi-line array of inline tables", parsed.ok)
  check("toml: inline table keys", parsed.value.conditions[0],
    { field: "extension", is: "pdf" })
  check("toml: second inline table", parsed.value.conditions[1].gt, "10 MB")
}

{
  ok("toml: reports unterminated string", !Model.parseToml('x = "oops').ok)
  ok("toml: reports missing value", !Model.parseToml("x =").ok)
  ok("toml: reports garbage after value", !Model.parseToml('x = 1 y = 2').ok)
  ok("toml: reports bad table header", !Model.parseToml("[folder").ok)
  ok("toml: error names the line", Model.parseToml('a = 1\nx = "oops').error.indexOf("line 2") >= 0)
}

// ------------------------------------------------------------ size / age

check("size: bare bytes", Model.parseSize(2048), 2048)
check("size: megabytes with space", Model.parseSize("10 MB"), 10485760)
check("size: fractional gigabytes", Model.parseSize("1.5gb"), 1610612736)
check("size: rejects nonsense", Model.parseSize("ten megs"), null)

check("age: bare number is days", Model.parseAgeSec(2), 172800)
check("age: weeks", Model.parseAgeSec("2w"), 1209600)
check("age: hours", Model.parseAgeSec("12h"), 43200)
check("age: seconds", Model.parseAgeSec("45s"), 45)
check("age: rejects nonsense", Model.parseAgeSec("soon"), null)

// ----------------------------------------------------------------- globs

ok("glob: star matches", Model.matchesAnyGlob("photo.part", ["*.part"]))
ok("glob: case-insensitive", Model.matchesAnyGlob("FILE.TMP", ["*.tmp"]))
ok("glob: question mark", Model.matchesAnyGlob("a1.log", ["a?.log"]))
ok("glob: no match", !Model.matchesAnyGlob("photo.png", ["*.part", "*.tmp"]))
ok("glob: dots are literal", !Model.matchesAnyGlob("filexpart", ["file.part"]))

// ----------------------------------------------------------- file record

{
  const f = Model.fileRecord("/home/user/Downloads/Report Final.PDF", 1024, 1700000000)
  check("record: dir", f.dir, "/home/user/Downloads")
  check("record: fullname", f.fullname, "Report Final.PDF")
  check("record: name strips extension", f.name, "Report Final")
  check("record: extension lowercased", f.ext, "pdf")
}

{
  const f = Model.fileRecord("/tmp/.bashrc", 10, 0)
  check("record: leading-dot file has no extension", f.ext, "")
  check("record: leading-dot name intact", f.name, ".bashrc")
}

check("record: kind of pdf", Model.kindOf("pdf"), "document")
check("record: kind of PNG", Model.kindOf("PNG"), "image")
check("record: kind of unknown", Model.kindOf("xyz"), "other")

// ---------------------------------------------------------------- config

const RULES_TOML = `
[[folder]]
path = "~/Downloads"
ignore = ["*.iso"]

  [[folder.rule]]
  name = "Sort screenshots"
  all = [
    { field = "name", starts_with = "screenshot" },
    { field = "kind", is = "image" },
  ]
  actions = [
    { do = "move", to = "~/Pictures/Screenshots" },
  ]

  [[folder.rule]]
  name = "Old downloads to trash"
  all = [{ field = "age", gt = "2w" }]
  actions = [{ do = "trash" }]
`

const config = Model.compileConfig(Model.parseToml(RULES_TOML).value, HOME)
check("config: no errors", config.errors, [])
check("config: one folder", config.folders.length, 1)
check("config: home expanded", config.folders[0].path, "/home/user/Downloads")
check("config: custom ignore appended", config.folders[0].ignore.indexOf("*.iso") >= 0, true)
check("config: default ignores kept", config.folders[0].ignore.indexOf("*.part") >= 0, true)
check("config: two rules", config.folders[0].rules.length, 2)
check("config: action to expanded", config.folders[0].rules[0].actions[0].to,
  "/home/user/Pictures/Screenshots")
check("config: age compiled to seconds", config.folders[0].rules[1].all[0].value, 1209600)

{
  const bad = Model.compileConfig(Model.parseToml(`
[[folder]]
path = "~/Downloads"

  [[folder.rule]]
  name = "broken condition"
  all = [{ field = "flavour", is = "pdf" }]
  actions = [{ do = "trash" }]

  [[folder.rule]]
  name = "broken action"
  actions = [{ do = "teleport" }]

  [[folder.rule]]
  name = "still valid"
  actions = [{ do = "trash" }]
`).value, HOME)
  check("config: invalid rules dropped, valid kept", bad.folders[0].rules.length, 1)
  check("config: surviving rule", bad.folders[0].rules[0].name, "still valid")
  check("config: two errors collected", bad.errors.length, 2)
  ok("config: error names the rule", bad.errors[0].indexOf("broken condition") >= 0)
}

{
  const bad = Model.compileConfig(Model.parseToml(`
[[folder]]
path = "~/Vault"
  [[folder.rule]]
  name = "unsafe encrypt"
  actions = [{ do = "encrypt", recipient = "age1abc", delete_original = true }]
`).value, HOME)
  check("config: encrypt delete without identity rejected", bad.folders[0].rules.length, 0)
  ok("config: encrypt error explains the rail",
    bad.errors[0].indexOf("identity") >= 0)
}

{
  const good = Model.compileConfig(Model.parseToml(`
[[folder]]
path = "~/Vault"
  [[folder.rule]]
  name = "verified encrypt"
  actions = [{ do = "encrypt", recipient = "age1abc", identity = "~/.age/key.txt", delete_original = true }]
  [[folder.rule]]
  name = "explicitly unverified"
  actions = [{ do = "encrypt", recipient = "age1abc", delete_original = true, verify = false }]
`).value, HOME)
  check("config: encrypt with identity accepted", good.folders[0].rules.length, 2)
  check("config: identity path expanded",
    good.folders[0].rules[0].actions[0].identity, "/home/user/.age/key.txt")
}

{
  const bad = Model.compileConfig(Model.parseToml(`
[[folder]]
path = "~/Sync"
  [[folder.rule]]
  name = "bad provider"
  actions = [{ do = "upload", via = "gdrive" }]
  [[folder.rule]]
  name = "taildrop no device"
  actions = [{ do = "upload", via = "taildrop" }]
`).value, HOME)
  check("config: bad upload rules dropped", bad.folders[0].rules.length, 0)
  check("config: both upload errors reported", bad.errors.length, 2)
}

// -------------------------------------------------------------- matching

const NOW = 1755900000
const downloadsFolder = config.folders[0]

function record(name, size, ageSec) {
  return Model.fileRecord("/home/user/Downloads/" + name, size, NOW - (ageSec || 0))
}

{
  const shot = record("Screenshot 2026-08-22.png", 50000, 5)
  const plans = Model.planFile(shot, downloadsFolder, NOW)
  check("match: screenshot rule fires", plans.length, 1)
  check("match: plan verb", plans[0].verb, "move")
  check("match: plan rule name", plans[0].rule, "Sort screenshots")
  check("match: plan argv", plans[0].argv,
    ["move", "/home/user/Downloads/Screenshot 2026-08-22.png",
      "/home/user/Pictures/Screenshots", ""])
}

{
  const old = record("stale.zip", 900, 30 * 86400)
  const plans = Model.planFile(old, downloadsFolder, NOW)
  check("match: age rule fires on old file", plans.map(p => p.verb), ["trash"])
}

{
  const fresh = record("fresh.zip", 900, 60)
  check("match: fresh file matches nothing", Model.planFile(fresh, downloadsFolder, NOW), [])
}

{
  const ignored = record("huge.iso", 1, 30 * 86400)
  check("match: ignored glob short-circuits", Model.planFile(ignored, downloadsFolder, NOW), [])
  const partial = record("video.mp4.part", 1, 30 * 86400)
  check("match: default partial ignore applies", Model.planFile(partial, downloadsFolder, NOW), [])
}

{
  // An old screenshot matches the first rule, which relocates — the trash rule
  // below it must not also fire.
  const oldShot = record("screenshot old.png", 100, 30 * 86400)
  const plans = Model.planFile(oldShot, downloadsFolder, NOW)
  check("match: relocating rule stops processing", plans.map(p => p.verb), ["move"])
}

{
  const rule = { name: "ops", all: [], any: [], none: [], actions: [] }
  const f = record("Invoice-2026 draft.PDF", 5 * 1048576, 3600)
  const cases = [
    [{ field: "fullname", contains: "invoice" }, true],
    [{ field: "name", ends_with: "draft" }, true],
    [{ field: "extension", in: ["pdf", "doc"] }, true],
    [{ field: "extension", not_in: ["png"] }, true],
    [{ field: "name", matches: "^invoice-\\d{4}" }, true],
    [{ field: "size", gt: "1 MB" }, true],
    [{ field: "size", lt: "1 MB" }, false],
    [{ field: "age", lt: "2h" }, true],
    [{ field: "kind", is_not: "image" }, true],
    [{ field: "path", contains: "downloads" }, true],
  ]
  for (const [raw, expected] of cases) {
    const cond = Model.compileCondition(raw)
    ok(`ops: ${JSON.stringify(raw)} compiles`, !cond.error)
    check(`ops: ${JSON.stringify(raw)}`, Model.matchCondition(f, cond.value, NOW), expected)
  }
  void rule
}

{
  const parsed = Model.parseToml(`
[[folder]]
path = "~/Inbox"
  [[folder.rule]]
  name = "any/none groups"
  any = [
    { field = "extension", is = "pdf" },
    { field = "extension", is = "png" },
  ]
  none = [{ field = "name", contains = "keep" }]
  actions = [{ do = "trash" }]
`)
  const folder = Model.compileConfig(parsed.value, HOME).folders[0]
  const yes = Model.fileRecord("/home/user/Inbox/scan.pdf", 1, NOW)
  const wrongExt = Model.fileRecord("/home/user/Inbox/scan.txt", 1, NOW)
  const excluded = Model.fileRecord("/home/user/Inbox/keep this.png", 1, NOW)
  check("groups: any matches", Model.planFile(yes, folder, NOW).length, 1)
  check("groups: any misses", Model.planFile(wrongExt, folder, NOW).length, 0)
  check("groups: none excludes", Model.planFile(excluded, folder, NOW).length, 0)
}

// -------------------------------------------------------------- patterns

{
  const f = Model.fileRecord("/home/user/Downloads/Report.pdf", 1, 1755856800) // 2026-08-22 local
  const d = new Date(1755856800 * 1000)
  const pad = n => (n < 10 ? "0" : "") + n
  check("pattern: tokens expand",
    Model.expandPattern("{year}/{month} - {name}.{ext}", f, NOW),
    `${d.getFullYear()}/${pad(d.getMonth() + 1)} - Report.pdf`)
  check("pattern: unknown token left alone",
    Model.expandPattern("{name}-{nope}", f, NOW), "Report-{nope}")
  check("pattern: rename keeps extension when omitted",
    Model.expandRename("{date} {name}", f, NOW),
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} Report.pdf`)
  check("pattern: rename with explicit extension untouched",
    Model.expandRename("{name}.bak", f, NOW), "Report.bak")
}

// ---------------------------------------------------------------- plans

{
  const home = HOME
  const parsed = Model.parseToml(`
[[folder]]
path = "~/Vault"
  [[folder.rule]]
  name = "secure and ship"
  actions = [
    { do = "encrypt", recipients_file = "~/.config/omazel/recipients.txt", identity = "~/.age/key.txt", delete_original = true },
    { do = "upload", via = "taildrop", device = "phone" },
    { do = "upload", via = "dropbox", path = "Inbox" },
    { do = "notify", message = "Secured {fullname}" },
  ]
`)
  const folder = Model.compileConfig(parsed.value, home).folders[0]
  const f = Model.fileRecord("/home/user/Vault/secrets.db", 1, NOW)
  const plans = Model.planFile(f, folder, NOW)
  check("plans: all four actions planned", plans.length, 4)
  check("plans: encrypt argv", plans[0].argv,
    ["encrypt", "/home/user/Vault/secrets.db", "R:/home/user/.config/omazel/recipients.txt",
      "/home/user/.age/key.txt", "1", "1"])
  check("plans: taildrop argv", plans[1].argv,
    ["upload", "/home/user/Vault/secrets.db", "taildrop", "phone", ""])
  check("plans: dropbox argv defaults remote", plans[2].argv,
    ["upload", "/home/user/Vault/secrets.db", "dropbox", "dropbox", "Inbox"])
  check("plans: notify message expanded", plans[3].argv[2], "Secured secrets.db")
}

{
  const parsed = Model.parseToml(`
[[folder]]
path = "~/Downloads"
  [[folder.rule]]
  name = "sort by kind"
  actions = [{ do = "sort", into = "{ext}" }]
`)
  const folder = Model.compileConfig(parsed.value, HOME).folders[0]
  const f = Model.fileRecord("/home/user/Downloads/notes.pdf", 1, NOW)
  const plans = Model.planFile(f, folder, NOW)
  check("plans: sort becomes a move into a subfolder", plans[0].argv,
    ["move", "/home/user/Downloads/notes.pdf", "/home/user/Downloads/pdf", ""])
}

// ---------------------------------------------------------- capabilities

{
  const parsed = Model.parseToml(`
[[folder]]
path = "~/A"
  [[folder.rule]]
  name = "r"
  actions = [
    { do = "trash" },
    { do = "encrypt", recipient = "age1abc" },
    { do = "upload", via = "protondrive" },
  ]
`)
  const folders = Model.compileConfig(parsed.value, HOME).folders
  const required = Model.requiredTools(folders)
  const tools = required.map(t => t.tool).sort()
  check("caps: tools derived from actions", tools,
    ["age", "gio", "inotifywait", "rclone"])
  const missing = Model.missingTools(required,
    { inotifywait: true, gio: false, age: true, rclone: false })
  check("caps: only absent tools reported", missing.map(t => t.tool).sort(),
    ["gio", "rclone"])
}

// -------------------------------------------------------------- activity

{
  const log = [
    "1755900000\tok\tmove\tSort screenshots\t/home/u/Downloads/shot.png\t/home/u/Pictures/shot.png\t",
    "1755900100\terror\tupload\tShip it\t/home/u/Vault/db\t\ttailscale not found",
    "1755900200\tdryrun\ttrash\tOld stuff\t/home/u/Downloads/old.zip\t\t",
    "not a log line",
    ""
  ].join("\n")
  const entries = Model.parseActivityLines(log)
  check("activity: three entries", entries.length, 3)
  check("activity: basename derived", entries[0].file, "shot.png")
  check("activity: error message kept", entries[1].message, "tailscale not found")
  check("activity: dryrun status", entries[2].status, "dryrun")
}

check("fields: TSV parsed", Model.parseFields("state\tok\nbehind\t2\n"),
  { state: "ok", behind: "2" })

// ---------------------------------------------------------------- editor

{
  const raw = Model.parseToml(RULES_TOML).value
  const draft = Model.draftFromRaw(raw)
  check("editor: one folder in draft", draft.length, 1)
  check("editor: path kept as typed", draft[0].path, "~/Downloads")
  check("editor: ignore joined for editing", draft[0].ignore, "*.iso")
  check("editor: two rules", draft[0].rules.length, 2)
  const shot = draft[0].rules[0]
  check("editor: conditions flattened with group", shot.conditions,
    [{ group: "all", field: "name", op: "starts_with", value: "screenshot" },
     { group: "all", field: "kind", op: "is", value: "image" }])
  check("editor: action params extracted", shot.actions,
    [{ verb: "move", params: { to: "~/Pictures/Screenshots" } }])
  check("editor: age value stays as typed", draft[0].rules[1].conditions[0].value, "2w")
}

{
  // Full round trip: parse -> draft -> raw -> serialize -> parse -> compile
  // must land on exactly the compiled config of the original file.
  const raw1 = Model.parseToml(RULES_TOML).value
  const draft = Model.draftFromRaw(raw1)
  const text = Model.serializeRules(Model.draftToRaw(draft))
  const reparsed = Model.parseToml(text)
  ok("editor: serialized TOML reparses", reparsed.ok)
  const before = Model.compileConfig(raw1, HOME)
  const after = Model.compileConfig(reparsed.value, HOME)
  check("editor: round trip preserves compiled config", after, before)
  ok("editor: generated file carries the marker", text.indexOf("# Omazel rules — written by the visual editor.") === 0)
}

{
  const draft = [{
    path: "~/Vault", recursive: true, enabled: false, ignore: " *.iso , keep-* ",
    rules: [{
      name: "  ",
      conditions: [
        { group: "any", field: "extension", op: "in", value: "pdf, docx" },
        { group: "none", field: "name", op: "contains", value: "keep" },
      ],
      actions: [
        { verb: "encrypt", params: { recipient: "age1abc", identity: "~/.age/key.txt",
          delete_original: true, verify: true } },
        { verb: "upload", params: { via: "taildrop", device: "phone", remote: "stale", path: "stale" } },
      ]
    }]
  }]
  const raw = Model.draftToRaw(draft)
  check("editor: ignore list split and trimmed", raw.folder[0].ignore, ["*.iso", "keep-*"])
  check("editor: recursive/enabled emitted only off-default",
    [raw.folder[0].recursive, raw.folder[0].enabled], [true, false])
  check("editor: blank rule name defaulted", raw.folder[0].rule[0].name, "Untitled rule")
  check("editor: any/none groups rebuilt",
    [raw.folder[0].rule[0].any.length, raw.folder[0].rule[0].none.length], [1, 1])
  check("editor: in-op value split", raw.folder[0].rule[0].any[0]["in"], ["pdf", "docx"])
  const enc = raw.folder[0].rule[0].actions[0]
  check("editor: default-true verify omitted", enc.verify, undefined)
  check("editor: delete_original kept when true", enc.delete_original, true)
  const up = raw.folder[0].rule[0].actions[1]
  check("editor: taildrop strips rclone params", [up.remote, up.path], [undefined, undefined])
  check("editor: taildrop keeps device", up.device, "phone")
}

{
  const bad = Model.validateDraft([], HOME)
  ok("editor: empty draft rejected", bad.errors.length > 0)
  const noPath = Model.validateDraft([{ path: " ", rules: [] }], HOME)
  ok("editor: empty path rejected", noPath.errors[0].indexOf("path is empty") >= 0)
  const noDevice = Model.validateDraft([{
    path: "~/A", rules: [{ name: "r", conditions: [],
      actions: [{ verb: "upload", params: { via: "taildrop" } }] }]
  }], HOME)
  ok("editor: validation reuses the compiler",
    noDevice.errors.length === 1 && noDevice.errors[0].indexOf("device") >= 0)
  const good = Model.validateDraft([{
    path: "~/A", rules: [{ name: "r", conditions: [{ group: "all", field: "age", op: "gt", value: "30d" }],
      actions: [{ verb: "trash", params: {} }] }]
  }], HOME)
  check("editor: valid draft yields text", good.errors, [])
  ok("editor: text is non-empty TOML", good.text.indexOf("[[folder]]") > 0)
}

{
  check("editor: escaping survives quotes in names",
    Model.parseToml(Model.serializeRules({ folder: [{ path: 'a"b\\c', rule: [] }] })).value.folder[0].path,
    'a"b\\c')
  const uploadTaildrop = Model.actionParams("upload", { via: "taildrop" }).map(p => p.key)
  check("editor: upload params for taildrop", uploadTaildrop, ["via", "device"])
  const uploadRclone = Model.actionParams("upload", { via: "dropbox" }).map(p => p.key)
  check("editor: upload params for rclone", uploadRclone, ["via", "remote", "path"])
  check("editor: number ops for size", Model.opsForField("size")[0].value, "gt")
  check("editor: string ops for name", Model.opsForField("name")[0].value, "is")
  check("editor: encrypt defaults verify on", Model.defaultParamsFor("encrypt"), { verify: true })
}

// ------------------------------------------------------------ formatting

check("fmt: elide short", Model.elide("hello", 10), "hello")
check("fmt: elide long", Model.elide("abcdefghij", 5), "abcd…")
check("fmt: ago minutes", Model.fmtAgo(NOW - 300, NOW), "5m ago")
check("fmt: ago just now", Model.fmtAgo(NOW - 10, NOW), "just now")
check("fmt: size mb", Model.fmtSize(10485760), "10.0 MB")
ok("fmt: verb icon exists", Model.verbIcon("move").length > 0)
check("fmt: verb label", Model.verbLabel("encrypt"), "Encrypted")

// -----------------------------------------------------------------------

if (failures > 0) {
  console.error(`\n${failures} of ${checks} checks failed`)
  process.exit(1)
}
console.log(`ok — ${checks} checks passed`)
