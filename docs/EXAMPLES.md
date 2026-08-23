# Omazel Rule Cookbook

Ready-to-paste rules for `~/.config/omazel/rules.toml`. Every recipe is a
complete `[[folder.rule]]` block — drop it under a `[[folder]]` and adjust
paths. Field-by-field reference: [HOWTO.md](HOWTO.md).

> Tip: turn on **Dry run** in the widget popup and hit **sweep** to preview
> what any of these would do to your existing files before letting them loose.

## Downloads triage

### Screenshots out of Downloads

```toml
[[folder]]
path = "~/Downloads"

  [[folder.rule]]
  name = "Sort screenshots"
  all = [
    { field = "name", contains = "screenshot" },
    { field = "kind", is = "image" },
  ]
  actions = [{ do = "move", to = "~/Pictures/Screenshots" }]
```

### File documents by year, from the file's own date

```toml
  [[folder.rule]]
  name = "File documents by year"
  all = [{ field = "kind", is = "document" }]
  actions = [{ do = "move", to = "~/Documents/{year}" }]
```

### Unpack every archive, then bin it

```toml
  [[folder.rule]]
  name = "Unpack archives"
  all = [{ field = "kind", is = "archive" }]
  actions = [
    { do = "extract", delete_archive = true },
    { do = "notify", message = "Unpacked {fullname}" },
  ]
```

### Expire anything older than a month (recoverable)

```toml
  [[folder.rule]]
  name = "Expire old downloads"
  all = [{ field = "age", gt = "30d" }]
  actions = [{ do = "trash" }]
```

### Big disk hogs get flagged instead of moved

```toml
  [[folder.rule]]
  name = "Flag huge downloads"
  all = [{ field = "size", gt = "2 GB" }]
  actions = [{ do = "notify", message = "{fullname} is parked in Downloads" }]
```

## The Hazel classics

### Bank statements: match by origin, content, and type — file by captured year

Requires `file` (mime), `getfattr` (source), and nothing else. This is the
rule Hazel is famous for, working end-to-end on Linux:

```toml
  [[folder.rule]]
  name = "File bank statements"
  all = [
    { field = "mime", is = "application/pdf" },
    { field = "source", contains = "mybank.com" },
    { field = "contents", contains = "Account Statement" },
    { field = "name", matches = "statement-(\\d{4})-(\\d{2})" },
  ]
  actions = [
    { do = "move", to = "~/Documents/Bank/{1}", as = "{1}-{2} statement.pdf" },
  ]
```

### Invoices: capture groups drive both destination and name

```toml
  [[folder.rule]]
  name = "File invoices"
  all = [{ field = "name", matches = "^invoice-(\\d{4})-(\\d+)" }]
  actions = [
    { do = "move", to = "~/Documents/Invoices/{1}", as = "{2} {name}" },
    { do = "notify", message = "Filed invoice {2} for {1}" },
  ]
```

### A PDF is a PDF, whatever it's called

`mime` sees the real content type, so renamed or extension-less files still
get filed:

```toml
  [[folder.rule]]
  name = "PDFs by content, not extension"
  all = [
    { field = "mime", is = "application/pdf" },
    { field = "extension", is_not = "pdf" },
  ]
  actions = [{ do = "rename", pattern = "{name}.pdf" }]
```

## Security and shipping

### Encrypt-on-arrival drop folder, verified before the plaintext goes

Anything landing in `~/Vault/inbox` is encrypted with age; the original is
only trashed after the ciphertext round-trips to an identical checksum:

```toml
[[folder]]
path = "~/Vault/inbox"

  [[folder.rule]]
  name = "Encrypt on arrival"
  actions = [
    { do = "encrypt", recipient = "age1yourrecipientkey...",
      identity = "~/.config/age/key.txt", delete_original = true },
  ]
```

### Encrypt, then ship the ciphertext off-machine

Later actions follow a relocation, so the upload sends the `.age` file:

```toml
  [[folder.rule]]
  name = "Encrypt and back up"
  actions = [
    { do = "encrypt", recipients_file = "~/.config/omazel/recipients.txt",
      identity = "~/.config/age/key.txt", delete_original = true },
    { do = "upload", via = "rclone", remote = "s3-backup", path = "vault" },
  ]
```

### Photos from the phone folder straight back to the phone? No — the other way

Taildrop anything in a folder to another tailnet device:

```toml
[[folder]]
path = "~/Send-to-phone"

  [[folder.rule]]
  name = "Taildrop it"
  actions = [
    { do = "upload", via = "taildrop", device = "phone" },
    { do = "trash" },
  ]
```

### Mirror receipts to Dropbox and Proton Drive

Two same-verb actions are fine — each runs:

```toml
  [[folder.rule]]
  name = "Receipts everywhere"
  all = [{ field = "name", contains = "receipt" }]
  actions = [
    { do = "upload", via = "dropbox", path = "Receipts" },
    { do = "upload", via = "protondrive", remote = "proton", path = "Receipts" },
  ]
```

## Power moves

### Gate a rule on any command

`script` conditions pass the file as `$1` — exit 0 means the condition
holds. Here: only encrypted PDFs get quarantined:

```toml
  [[folder.rule]]
  name = "Quarantine password-protected PDFs"
  all = [
    { field = "extension", is = "pdf" },
    { field = "script", passes = "pdfinfo \"$1\" 2>/dev/null | grep -q 'Encrypted:.*yes'" },
  ]
  actions = [{ do = "move", to = "~/Documents/Locked" }]
```

### Hand a file to your own pipeline

```toml
  [[folder.rule]]
  name = "OCR incoming scans"
  all = [{ field = "name", starts_with = "scan" }]
  actions = [{ do = "run", command = "~/bin/ocr-and-file" }]
```

The command gets the file as `$1` and `$OMAZEL_FILE`.

### Copy to backup, keep processing

`copy` doesn't relocate, so the file falls through to later rules; an
explicit `continue = true` would do the same even after a move:

```toml
  [[folder.rule]]
  name = "Snapshot before anything else touches it"
  actions = [{ do = "copy", to = "~/Backups/intake", as = "{date} {fullname}" }]

  [[folder.rule]]
  name = "…then file normally"
  all = [{ field = "kind", is = "document" }]
  actions = [{ do = "move", to = "~/Documents/{year}" }]
```

### Catch-all at the bottom

A rule with no conditions matches everything that earlier rules left in
place:

```toml
  [[folder.rule]]
  name = "Everything else into a monthly box"
  actions = [{ do = "sort", into = "unsorted/{year}-{month}" }]
```

### Sort a dumping-ground folder by extension

```toml
[[folder]]
path = "~/Desktop"

  [[folder.rule]]
  name = "Desktop, by type"
  all = [{ field = "age", gt = "1d" }]      # give yourself a day of grace
  actions = [{ do = "sort", into = "{ext}" }]
```

### Recursive project watch, with exclusions

```toml
[[folder]]
path = "~/Sync/drop"
recursive = true
ignore = ["*.iso", "keep-*"]

  [[folder.rule]]
  name = "Fresh media to the NAS intake"
  all = [
    { field = "kind", in = ["video", "image"] },
    { field = "created", lt = "1d" },
  ]
  actions = [{ do = "copy", to = "/mnt/nas/intake/{date}" }]
```

Hidden files and anything under hidden directories are always skipped, and
partial downloads (`*.part`, `*.crdownload`, …) are ignored out of the box.
