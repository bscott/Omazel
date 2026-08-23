#!/usr/bin/env bash
#
# Executes exactly one Omazel action against one file, and appends the outcome
# to the activity log. The QML service builds the argument list from a rule's
# action plan (see Model.js buildPlan); nothing here re-implements matching.
#
# Usage: omazel-act.sh <verb> <file> [args...]
#   move    <file> <destDir> [newName]
#   copy    <file> <destDir> [newName]
#   rename  <file> <newName>
#   trash   <file>
#   delete  <file>
#   run     <file> <command>          command runs with the file as $1 and $OMAZEL_FILE
#   notify  <file> <message>
#   extract <file> <destDir> <deleteArchive 0|1>
#   compress <file> <destDir> <archiveName>
#   encrypt <file> <recipientSpec> <identity|-> <deleteOriginal 0|1> <verify 0|1>
#           recipientSpec is r:<age recipient> or R:<recipients file>
#   upload  <file> <taildrop|dropbox|protondrive> <device-or-remote> <remotePath>
#
# Environment:
#   OMAZEL_DRYRUN=1   compute and log what would happen, touch nothing
#   OMAZEL_RULE       rule name, recorded in the log
#   OMAZEL_LOG        activity log path (default ~/.local/state/omazel/activity.log)
#
# Output: tab-separated key/value lines (status / dest / message), matching the
# parseFields format the service already reads. Exit 0 for ok and dryrun,
# non-zero for errors — the log line carries the same verdict either way.

set -uo pipefail

VERB="${1:-}"
FILE="${2:-}"
RULE="${OMAZEL_RULE:-}"
LOG="${OMAZEL_LOG:-$HOME/.local/state/omazel/activity.log}"
DRY="${OMAZEL_DRYRUN:-0}"

emit() { printf '%s\t%s\n' "$1" "$2"; }

# One TSV line per action. Tabs and newlines inside fields would corrupt the
# format, so they are flattened to spaces.
log_result() { # status dest message
  local dir clean_dest clean_msg
  dir="$(dirname -- "$LOG")"
  mkdir -p "$dir" 2>/dev/null || true
  clean_dest="$(printf '%s' "${2:-}" | tr '\t\n' '  ')"
  clean_msg="$(printf '%s' "${3:-}" | tr '\t\n' '  ')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "$1" "$VERB" "$RULE" "$FILE" "$clean_dest" "$clean_msg" >>"$LOG" 2>/dev/null || true
}

ok() { # dest [message]
  log_result ok "${1:-}" "${2:-}"
  emit status ok
  [[ -n ${1:-} ]] && emit dest "$1"
  [[ -n ${2:-} ]] && emit message "$2"
  exit 0
}

dryrun() { # dest [message]
  log_result dryrun "${1:-}" "${2:-}"
  emit status dryrun
  [[ -n ${1:-} ]] && emit dest "$1"
  [[ -n ${2:-} ]] && emit message "$2"
  exit 0
}

fail() { # message
  log_result error "" "$1"
  emit status error
  emit message "$1"
  exit 1
}

need() { # tool
  command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed"
}

[[ -n $VERB && -n $FILE ]] || { emit status error; emit message "usage: omazel-act.sh <verb> <file> ..."; exit 2; }
[[ -e $FILE ]] || fail "file no longer exists: $FILE"

# Picks a destination path that does not collide with an existing file, Hazel
# style: "name (2).ext", "name (3).ext", ...
free_dest() { # dir name -> prints path
  local dir="$1" name="$2" base ext candidate n
  if [[ $name == *.* && ${name%.*} != "" ]]; then
    base="${name%.*}"
    ext=".${name##*.}"
  else
    base="$name"
    ext=""
  fi
  candidate="$dir/$name"
  n=2
  while [[ -e $candidate ]]; do
    candidate="$dir/$base ($n)$ext"
    n=$((n + 1))
  done
  printf '%s' "$candidate"
}

case "$VERB" in

  move | copy)
    DEST_DIR="${3:-}"
    NEW_NAME="${4:-}"
    [[ -n $DEST_DIR ]] || fail "missing destination directory"
    [[ -n $NEW_NAME ]] || NEW_NAME="$(basename -- "$FILE")"
    DEST="$(free_dest "$DEST_DIR" "$NEW_NAME")"
    # Moving a file onto itself means the rule's destination is where the file
    # already lives; that is a no-op, not an error, and logging it every sweep
    # would be noise.
    if [[ $VERB == move && $DEST_DIR/$NEW_NAME -ef $FILE ]]; then
      emit status ok
      emit message "already in place"
      exit 0
    fi
    [[ $DRY == 1 ]] && dryrun "$DEST"
    mkdir -p -- "$DEST_DIR" || fail "cannot create $DEST_DIR"
    if [[ $VERB == move ]]; then
      mv -n -- "$FILE" "$DEST" || fail "move failed"
    else
      cp -a -- "$FILE" "$DEST" || fail "copy failed"
    fi
    ok "$DEST"
    ;;

  rename)
    NEW_NAME="${3:-}"
    [[ -n $NEW_NAME ]] || fail "missing new name"
    DIR="$(dirname -- "$FILE")"
    if [[ "$DIR/$NEW_NAME" -ef "$FILE" ]]; then
      emit status ok
      emit message "already named"
      exit 0
    fi
    DEST="$(free_dest "$DIR" "$NEW_NAME")"
    [[ $DRY == 1 ]] && dryrun "$DEST"
    mv -n -- "$FILE" "$DEST" || fail "rename failed"
    ok "$DEST"
    ;;

  trash)
    need gio
    [[ $DRY == 1 ]] && dryrun "" "would trash"
    gio trash -- "$FILE" 2>/dev/null || fail "gio trash failed"
    ok "" "trashed"
    ;;

  delete)
    [[ -f $FILE ]] || fail "refusing to delete a non-regular file"
    [[ $DRY == 1 ]] && dryrun "" "would delete"
    rm -f -- "$FILE" || fail "delete failed"
    ok "" "deleted"
    ;;

  open)
    command -v xdg-open >/dev/null 2>&1 || fail "xdg-open is not installed"
    [[ $DRY == 1 ]] && dryrun "" "would open"
    # Detached: xdg-open hands off to the desktop opener, and whatever it
    # launches must not hold this action (and the queue behind it) open.
    setsid -f xdg-open -- "$FILE" >/dev/null 2>&1 || fail "xdg-open failed"
    ok "" "opened"
    ;;

  run)
    CMD="${3:-}"
    [[ -n $CMD ]] || fail "missing command"
    [[ $DRY == 1 ]] && dryrun "" "would run: $CMD"
    export OMAZEL_FILE="$FILE"
    if OUTPUT=$(timeout 600 bash -c "$CMD" omazel "$FILE" 2>&1); then
      ok "" "$(printf '%s' "$OUTPUT" | tail -n 1 | cut -c1-160)"
    else
      fail "command failed: $(printf '%s' "$OUTPUT" | tail -n 1 | cut -c1-160)"
    fi
    ;;

  notify)
    MESSAGE="${3:-$(basename -- "$FILE")}"
    need notify-send
    [[ $DRY == 1 ]] && dryrun "" "would notify: $MESSAGE"
    notify-send -a Omazel "Omazel" "$MESSAGE" || fail "notify-send failed"
    ok "" "$MESSAGE"
    ;;

  extract)
    DEST_DIR="${3:-$(dirname -- "$FILE")}"
    DELETE_ARCHIVE="${4:-0}"
    NAME="$(basename -- "$FILE")"
    # Extract into a directory named after the archive so a tarbomb cannot
    # scatter files across the watched folder (and re-trigger rules on each).
    STEM="$NAME"
    case "$STEM" in
      *.tar.gz | *.tar.bz2 | *.tar.xz | *.tar.zst) STEM="${STEM%.tar.*}" ;;
      *.*) STEM="${STEM%.*}" ;;
    esac
    TARGET="$(free_dest "$DEST_DIR" "$STEM")"
    [[ $DRY == 1 ]] && dryrun "$TARGET" "would extract"
    mkdir -p -- "$TARGET" || fail "cannot create $TARGET"
    case "$NAME" in
      *.zip)
        need unzip
        unzip -q -- "$FILE" -d "$TARGET" || { rmdir -- "$TARGET" 2>/dev/null; fail "unzip failed"; }
        ;;
      *.tar | *.tar.gz | *.tgz | *.tar.bz2 | *.tar.xz | *.tar.zst)
        tar -xf "$FILE" -C "$TARGET" || { rmdir -- "$TARGET" 2>/dev/null; fail "tar extraction failed"; }
        ;;
      *.7z)
        need 7z
        7z x -y -o"$TARGET" -- "$FILE" >/dev/null || { rmdir -- "$TARGET" 2>/dev/null; fail "7z extraction failed"; }
        ;;
      *.rar)
        need unrar
        unrar x -y -- "$FILE" "$TARGET/" >/dev/null || { rmdir -- "$TARGET" 2>/dev/null; fail "unrar failed"; }
        ;;
      *.gz)
        gunzip -k -c -- "$FILE" >"$TARGET/${STEM}" || { rm -rf -- "$TARGET"; fail "gunzip failed"; }
        ;;
      *)
        rmdir -- "$TARGET" 2>/dev/null
        fail "do not know how to extract $NAME"
        ;;
    esac
    if [[ $DELETE_ARCHIVE == 1 ]]; then
      # Trash when possible, but the user asked for the archive to go away, so
      # fall back to removal where trashing is unsupported (e.g. tmpfs).
      if command -v gio >/dev/null 2>&1; then
        gio trash -- "$FILE" 2>/dev/null || rm -f -- "$FILE"
      else
        rm -f -- "$FILE"
      fi
    fi
    ok "$TARGET"
    ;;

  compress)
    DEST_DIR="${3:-$(dirname -- "$FILE")}"
    ARCHIVE_NAME="${4:-$(basename -- "$FILE").zip}"
    need zip
    DEST="$(free_dest "$DEST_DIR" "$ARCHIVE_NAME")"
    [[ $DRY == 1 ]] && dryrun "$DEST" "would compress"
    mkdir -p -- "$DEST_DIR" || fail "cannot create $DEST_DIR"
    zip -q -j -- "$DEST" "$FILE" || { rm -f -- "$DEST"; fail "zip failed"; }
    ok "$DEST"
    ;;

  encrypt)
    SPEC="${3:-}"
    IDENTITY="${4:--}"
    DELETE_ORIGINAL="${5:-0}"
    VERIFY="${6:-1}"
    need age
    case "$SPEC" in
      r:*) AGE_ARGS=(-r "${SPEC#r:}") ;;
      R:*)
        [[ -r ${SPEC#R:} ]] || fail "recipients file not readable: ${SPEC#R:}"
        AGE_ARGS=(-R "${SPEC#R:}")
        ;;
      *) fail "bad recipient spec" ;;
    esac
    DIR="$(dirname -- "$FILE")"
    DEST="$(free_dest "$DIR" "$(basename -- "$FILE").age")"
    [[ $DRY == 1 ]] && dryrun "$DEST" "would encrypt"
    age "${AGE_ARGS[@]}" -o "$DEST" -- "$FILE" || { rm -f -- "$DEST"; fail "age encryption failed"; }
    [[ -s $DEST ]] || { rm -f -- "$DEST"; fail "age produced an empty file"; }

    VERIFIED=0
    if [[ $VERIFY == 1 && $IDENTITY != - ]]; then
      # Round-trip check: decrypt the ciphertext with the identity and compare
      # checksums against the original. Only a byte-identical round trip is
      # allowed to authorize deleting the plaintext.
      [[ -r $IDENTITY ]] || { rm -f -- "$DEST"; fail "identity file not readable: $IDENTITY"; }
      SUM_ORIG="$(sha256sum -- "$FILE" | cut -d' ' -f1)"
      SUM_BACK="$(age -d -i "$IDENTITY" -- "$DEST" 2>/dev/null | sha256sum | cut -d' ' -f1)"
      if [[ -z $SUM_ORIG || $SUM_ORIG != "$SUM_BACK" ]]; then
        rm -f -- "$DEST"
        fail "round-trip verification failed — original kept"
      fi
      VERIFIED=1
    fi

    if [[ $DELETE_ORIGINAL == 1 ]]; then
      if [[ $VERIFY == 1 && $VERIFIED != 1 ]]; then
        # The config compiler blocks this combination, but the rail belongs
        # here too: never remove a plaintext this script has not proven it can
        # get back.
        ok "$DEST" "encrypted, but original kept: nothing to verify against"
      fi
      if command -v gio >/dev/null 2>&1; then
        gio trash -- "$FILE" 2>/dev/null || rm -f -- "$FILE"
      else
        rm -f -- "$FILE"
      fi
      ok "$DEST" "$([[ $VERIFIED == 1 ]] && echo "verified, original removed" || echo "original removed (unverified)")"
    fi
    ok "$DEST" "$([[ $VERIFIED == 1 ]] && echo "verified" || echo "encrypted")"
    ;;

  upload)
    VIA="${3:-}"
    TARGET="${4:-}"
    RPATH="${5:-}"
    case "$VIA" in
      taildrop)
        need tailscale
        [[ -n $TARGET ]] || fail "missing taildrop device"
        [[ $DRY == 1 ]] && dryrun "$TARGET" "would taildrop"
        if OUTPUT=$(timeout 600 tailscale file cp -- "$FILE" "$TARGET:" 2>&1); then
          ok "$TARGET" "sent via Taildrop"
        else
          fail "taildrop failed: $(printf '%s' "$OUTPUT" | tail -n 1 | cut -c1-160)"
        fi
        ;;
      dropbox | protondrive | rclone)
        need rclone
        [[ -n $TARGET ]] || TARGET="$VIA"
        [[ $VIA == rclone && $TARGET == rclone ]] && fail "upload via rclone needs a remote name"
        rclone listremotes 2>/dev/null | grep -qx "$TARGET:" \
          || fail "rclone remote '$TARGET:' is not configured (rclone config)"
        DEST="$TARGET:$RPATH"
        [[ $DRY == 1 ]] && dryrun "$DEST" "would upload"
        if OUTPUT=$(timeout 600 rclone copy --quiet -- "$FILE" "$DEST" 2>&1); then
          ok "$DEST" "uploaded"
        else
          fail "rclone failed: $(printf '%s' "$OUTPUT" | tail -n 1 | cut -c1-160)"
        fi
        ;;
      *)
        fail "unknown upload provider: $VIA"
        ;;
    esac
    ;;

  *)
    fail "unknown verb: $VERB"
    ;;
esac
