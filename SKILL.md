---
name: omazel
description: >
  Create and manage Omazel file-automation rules on an Omarchy desktop.
  Use when the user asks to automate a folder ("move screenshots out of
  Downloads", "encrypt files that land here", "trash old downloads",
  "send this folder to my phone"), or mentions Omazel or Hazel-style file
  rules. Covers authoring ~/.config/omazel/rules.toml, validating rules,
  and driving the running engine over omarchy-shell IPC.
---

# Omazel — agent skill

Omazel is a Hazel-style file automation plugin for Omarchy (Quattro). It
watches folders and runs ordered rules against arriving files. As an agent
you interact with it through **one TOML file** and **a small IPC surface** —
no GUI automation needed.

## Ground truth

- Rules file: `~/.config/omazel/rules.toml` — the engine hot-reloads on
  save. A `.bak` of the previous version sits next to it after GUI saves.
- Activity log: `~/.local/state/omazel/activity.log` — TSV, one action per
  line: `epoch, status(ok|dryrun|error), verb, rule, file, dest, message`.
  Read this to verify what a rule actually did.
- Plugin install: `~/.config/omarchy/plugins/io.github.bscott.omazel`
  (contains `rules.example.toml` and `docs/HOWTO.md` for full reference).

## IPC (run these, they are cheap and safe)

```bash
omarchy-shell omazel status        # JSON: loaded, paused, dryRun, folders, rules, errors
omarchy-shell omazel reload        # re-read the rules file
omarchy-shell omazel sweep         # evaluate every watched file right now
omarchy-shell omazel dryRunOn      # log what rules WOULD do, touch nothing
omarchy-shell omazel dryRunOff
omarchy-shell omazel pause | resume | toggle
omarchy-shell omazel show          # open the widget popup for the user
omarchy-shell omazel editor        # open the visual rule editor for the user
```

## Authoring workflow (follow this order)

1. Read the current `~/.config/omazel/rules.toml` before editing — append
   rules to existing `[[folder]]` blocks rather than duplicating folders.
2. Write the rule (schema below). Rule order matters: first rule that
   relocates a file stops later rules for it.
3. For anything destructive (`trash`, `delete`, `delete_original`,
   `delete_archive`) or broad (age-based, catch-alls): turn on dry run
   first (`dryRunOn`), run `sweep`, then read the tail of the activity log
   and show the user what would happen. Only after they approve, `dryRunOff`.
4. `status` after saving — `errors` stays 0 and `rules` counts your
   addition when the file compiled; broken rules are dropped individually
   and reported in the widget.

## Rule schema

```toml
[[folder]]
path = "~/Downloads"
recursive = false               # optional
enabled = true                  # optional
ignore = ["*.iso"]              # optional extra globs

  [[folder.rule]]
  name = "Human-readable name"
  continue = false              # optional: true = keep matching after
                                # relocation, false = always stop, unset =
                                # stop only when the file was relocated
  all  = [ ...conditions ]      # every one must hold
  any  = [ ...conditions ]      # at least one (if present)
  none = [ ...conditions ]      # none may hold
  actions = [ ...actions ]      # run in order; required, non-empty
```

### Conditions — `{ field = "...", <operator> = value }`

| Field | Type | Operators | Value examples |
|-------|------|-----------|----------------|
| `name`, `fullname`, `extension`, `path` | text | `is, is_not, contains, not_contains, starts_with, ends_with, matches, in, not_in` | `"screenshot"`, `["pdf","docx"]` |
| `kind` | text | same | `image, video, audio, document, archive, code, other` |
| `mime` | text (needs `file`) | same | `"application/pdf"` |
| `source` | text (needs `getfattr`) | same | download origin URL, e.g. `"mybank.com"` |
| `size` | number | `gt, lt, gte, lte, is, is_not` | `"10 MB"`, `"500 KB"` |
| `age`, `created` | number | same | `"30d"`, `"2w"`, `"12h"` (bare number = days) |
| `contents` | probe (grep) | `contains, not_contains, matches` | text inside the file |
| `script` | probe | `passes, fails` | shell command; file passed as `$1`; exit 0 = passes |

Text matching is case-insensitive. Hidden files, files under hidden
directories, and partial downloads are never matched.

### Actions — `{ do = "...", ... }`

```toml
{ do = "move", to = "~/Docs/{year}", as = "{date} {name}.{ext}" }  # `as` optional
{ do = "copy", to = "...", as = "..." }
{ do = "rename", pattern = "{date} {name}" }
{ do = "sort", into = "{ext}" }                  # subfolder of watched dir
{ do = "trash" }                                 # recoverable — prefer over delete
{ do = "delete" }                                # permanent
{ do = "open" }                                  # xdg-open
{ do = "extract", delete_archive = true }        # zip/tar/7z/rar, tarbomb-safe
{ do = "compress", name = "{name}.zip" }
{ do = "notify", message = "Filed {fullname}" }
{ do = "run", command = "~/bin/script" }         # file as $1 and $OMAZEL_FILE
{ do = "encrypt", recipient = "age1...", identity = "~/.config/age/key.txt", delete_original = true }
{ do = "upload", via = "taildrop", device = "phone" }
{ do = "upload", via = "dropbox", path = "Inbox" }          # rclone remote "dropbox:"
{ do = "upload", via = "rclone", remote = "s3", path = "x" } # remote required
```

Patterns expand `{name} {fullname} {ext} {folder} {date} {year} {month}
{day} {time}` (dates from the file's mtime) plus `{1}`–`{9}`/`{0}` capture
groups from the rule's `matches` condition (original casing kept).

## Hard rules for agents

- **Never** write `{ do = "delete" }` or an age-based `trash` rule without
  the user explicitly asking for deletion/expiry; confirm the threshold.
- **`encrypt` with `delete_original = true` requires `identity`** (the
  engine verifies a decrypt round trip before removing the plaintext) —
  omitting it is a compile error unless `verify = false` is set, which you
  should not set unless the user insists and understands.
- After a relocating action (`move`/`rename`/`trash`/`delete`), later
  actions in the same rule automatically target the new path — put
  `notify`/`run` after the move freely, but there is nothing left to act on
  after `trash`/`delete`.
- A rule with **no conditions matches every file** in the folder — only
  write one deliberately, and last.
- Comments in `rules.toml` survive your edits but are dropped if the user
  later saves from the visual editor; do not rely on comments as state.

## Verifying your work

```bash
omarchy-shell omazel status                       # errors == 0, rule count right
omarchy-shell omazel dryRunOn && omarchy-shell omazel sweep
sleep 3 && tail -n 20 ~/.local/state/omazel/activity.log   # "dryrun" rows show the plan
omarchy-shell omazel dryRunOff
```

Full reference: `docs/HOWTO.md`; ready-made recipes: `docs/EXAMPLES.md`.
