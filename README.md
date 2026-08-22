# Omazel

Hazel for [Omarchy](https://omarchy.org). Omazel watches folders and acts on
the files that land in them — sorting downloads, filing documents, expiring
old clutter, unpacking archives, encrypting drop folders, and shipping files
to your phone or cloud — driven by rules you write once in a small TOML file.

If you have used [Hazel](https://www.noodlesoft.com/) on macOS, this is that
workflow for your Omarchy desktop: rules run in the background, and a bar
widget shows what happened, lets you pause everything, and offers a dry-run
mode that logs what rules *would* do without touching anything.

## Features

- **Watch any folders** — instant reaction to new files via inotify, plus a
  periodic sweep that fires age-based rules and catches files that arrived
  while the shell was off.
- **Hazel-style rules** — ordered rules per folder with `all` / `any` / `none`
  condition groups over name, extension, kind, size, age, and path; first
  rule that relocates a file wins.
- **Actions** — move, copy, rename, sort into subfolders, trash, delete,
  extract archives, compress, desktop notifications, and run arbitrary
  commands.
- **age encryption** — encrypt files on arrival with
  [age](https://age-encryption.org), with a checksum-verified round trip
  before the plaintext original may be removed (removal is opt-in and
  refuses to run unverified unless you explicitly say so).
- **Cloud handoff** — send files via Taildrop (`tailscale file cp`), or to
  Dropbox / Proton Drive through configured `rclone` remotes.
- **Safe by default** — collision-safe naming (`report (2).pdf`), partial
  downloads ignored, settle delay before judging fresh files, loop protection
  so rules do not chew on their own output, and a global dry-run switch.
- **Bar widget** — engine status at a glance, per-folder pause toggles, a
  recent-activity feed, rule-file error reporting, missing-tool warnings, and
  one-click plugin updates.
- **Scriptable** — pause, resume, dry-run, reload, and sweep over
  `omarchy-shell` IPC for keybindings.

## Install

```bash
omarchy plugin add https://github.com/bscott/Omazel.git --enable
```

Then place the **Omazel** widget in your bar from the Omarchy bar settings
(category *System*). Open the popup and hit **Create starter rules**, or copy
[`rules.example.toml`](rules.example.toml) to `~/.config/omazel/rules.toml`
yourself. Edits to the rules file apply automatically on save.

`inotify-tools` is the one hard dependency for live watching (the sweep works
without it): `sudo pacman -S inotify-tools`. Everything else is only needed by
the actions you actually use — `age`, `tailscale`, `rclone`, `zip`/`unzip`,
`7zip`, `unrar` — and the popup tells you if a rule needs a tool that is
missing.

## Rules

```toml
[[folder]]
path = "~/Downloads"

  [[folder.rule]]
  name = "Sort screenshots"
  all = [
    { field = "name", contains = "screenshot" },
    { field = "kind", is = "image" },
  ]
  actions = [
    { do = "move", to = "~/Pictures/Screenshots" },
  ]

  [[folder.rule]]
  name = "Expire old downloads"
  all = [{ field = "age", gt = "30d" }]
  actions = [{ do = "trash" }]
```

Rules are checked top-down for every file. When a rule matches, its actions
run in order; once a rule moves, renames, trashes, or deletes the file, later
rules are skipped for it.

### Conditions

| Field | What it sees | Operators |
|-------|--------------|-----------|
| `name` | basename without extension | `is`, `is_not`, `contains`, `not_contains`, `starts_with`, `ends_with`, `matches` (regex), `in`, `not_in` |
| `fullname` | basename with extension | same as `name` |
| `extension` | lowercase, no dot | same as `name` |
| `path` | absolute path | same as `name` |
| `kind` | `image`, `video`, `audio`, `document`, `archive`, `code`, `other` | same as `name` |
| `size` | file size — values like `"500 KB"`, `"10 MB"`, `"1.5gb"` | `is`, `is_not`, `gt`, `lt`, `gte`, `lte` |
| `age` | time since last modification — `"45s"`, `"90m"`, `"12h"`, `"14d"`, `"2w"`, bare number = days | same as `size` |

String matching ignores case. Group conditions with `all` (every), `any` (at
least one), and `none` (none); a rule with no conditions matches every file,
which makes a deliberate catch-all possible at the bottom of a folder.

### Actions

```toml
{ do = "move", to = "~/Documents/{year}" }         # collision-safe
{ do = "copy", to = "~/Backups", as = "{date} {name}.{ext}" }
{ do = "rename", pattern = "{date} {name}" }        # keeps the extension if omitted
{ do = "sort", into = "{ext}" }                     # subfolder of the watched dir
{ do = "trash" }                                    # gio trash — recoverable
{ do = "delete" }                                   # permanent; prefer trash
{ do = "extract", delete_archive = true }           # zip/tar/7z/rar, tarbomb-safe
{ do = "compress", name = "{name}.zip" }
{ do = "notify", message = "Filed {fullname}" }
{ do = "run", command = "~/bin/process-file" }      # file passed as $1 and $OMAZEL_FILE
{ do = "encrypt", recipient = "age1...", identity = "~/.config/age/key.txt", delete_original = true }
{ do = "upload", via = "taildrop", device = "phone" }
{ do = "upload", via = "dropbox", path = "Inbox" }              # rclone remote "dropbox:"
{ do = "upload", via = "protondrive", remote = "proton", path = "Backups" }
```

Patterns expand `{name}` `{ext}` `{fullname}` `{date}` `{year}` `{month}`
`{day}` `{time}` `{folder}`, with dates taken from the file's own modification
time — so `to = "~/Documents/{year}"` files things by when they arrived.

### Encryption safety

`encrypt` runs `age` against the recipient (or an `-R` recipients file) and
never removes the plaintext lightly. With `delete_original = true`, Omazel
decrypts the fresh ciphertext with your `identity` file and compares SHA-256
checksums; only a byte-identical round trip authorizes removal (to the trash,
so even that is recoverable). Asking for deletion without an identity to
verify against is a config error unless you opt out explicitly with
`verify = false`.

## Bar widget

| Input | Action |
|-------|--------|
| Left / right click | Open the popup |
| Middle click | Pause / resume the whole engine |

The popup shows engine status, pause and dry-run toggles, a manual sweep
button, a shortcut to edit the rules file, every watched folder with its own
pause toggle, the recent activity feed (including what dry-run would have
done), rule problems, and missing-tool warnings.

## Scripting

```bash
omarchy-shell omazel status     # JSON engine state
omarchy-shell omazel toggle     # pause / resume (also pause, resume)
omarchy-shell omazel dryRunToggle
omarchy-shell omazel sweep      # evaluate everything now
omarchy-shell omazel reload     # re-read the rules file
```

Example Hyprland binding (`~/.config/hypr/bindings.conf`):

```ini
bindd = SUPER SHIFT, O, Toggle Omazel, exec, omarchy-shell omazel toggle
```

## How it works

A headless service owns one `inotifywait` per watched folder and a slow sweep
timer. New files settle for a few seconds, get stat-ed, and run through the
rule engine (`Model.js` — pure JS, unit-tested); each resulting action is one
invocation of `scripts/omazel-act.sh`, which does the file work and appends a
TSV line to `~/.local/state/omazel/activity.log`. A per-file-per-rule cooldown
keeps the watcher and the sweep from double-firing, and freshly produced
outputs are ignored briefly so rules cannot loop on their own results.

## Development

Install the plugin with `omarchy plugin add` (above), then edit it in place
under `~/.config/omarchy/plugins/io.github.bscott.omazel`. After changes:

```bash
node tests/model.test.js   # rule engine unit tests
omarchy plugin validate ~/.config/omarchy/plugins/io.github.bscott.omazel
omarchy-restart-shell      # reload the shell so the service picks up edits
```

## License

[MIT](LICENSE)
