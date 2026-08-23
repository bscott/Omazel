#!/usr/bin/env bash
#
# Gathers everything rule matching needs to know about one file, as
# tab-separated key/value lines. Every file gets the stat block; the optional
# probes run only when the folder's rules actually use the field they feed,
# so a folder with plain name/age rules costs exactly one stat.
#
#   omazel-probe.sh <file> [--mime] [--source]
#                          [--grep F|E <id> <pattern>]...
#                          [--script <id> <command>]...
#
# Output keys:
#   type / size / mtime / btime        from stat (btime 0 when unsupported)
#   mime                               `file --mime-type`
#   source                             user.xdg.origin.url xattr (browsers and
#                                      wget record the download origin there)
#   probe:<id>  1|0                    grep hit, or script exit-0, per probe

set -uo pipefail

FILE="${1:-}"
[[ -n $FILE ]] || { echo "usage: omazel-probe.sh <file> [probes...]" >&2; exit 2; }
shift

emit() { printf '%s\t%s\n' "$1" "$2"; }

STAT="$(stat -c '%F|%s|%Y|%W' -- "$FILE" 2>/dev/null)" || exit 1
IFS='|' read -r F_TYPE F_SIZE F_MTIME F_BTIME <<<"$STAT"
emit type "$F_TYPE"
emit size "$F_SIZE"
emit mtime "$F_MTIME"
emit btime "$F_BTIME"

# Everything below opens the file by path again, so it only runs for what
# stat just said is a regular file — and every reopening tool still gets a
# deadline and a byte ceiling, because the path can be swapped for a FIFO (or
# anything else unbounded) between that check and the open.
[[ $F_TYPE == "regular file" ]] || exit 0

# First 8 MB of the file, deadline-guarded. dd on a swapped FIFO would block
# forever; timeout turns that into an empty probe result instead of a stall.
read_head() {
  timeout 10 dd if="$FILE" bs=65536 count=128 2>/dev/null
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mime)
      emit mime "$(timeout 10 file -b --mime-type -- "$FILE" 2>/dev/null || true)"
      shift
      ;;
    --source)
      emit source "$(timeout 5 getfattr -n user.xdg.origin.url --only-values -- "$FILE" 2>/dev/null || true)"
      shift
      ;;
    --grep)
      MODE="${2:-F}" ID="${3:-0}" PATTERN="${4:-}"
      # grep exits 2 on trouble (unreadable file, bad regex); both non-hit and
      # trouble read as 0 so a broken pattern can never make a rule fire.
      if [[ $MODE == E ]]; then
        read_head | grep -qiE -- "$PATTERN" 2>/dev/null && HIT=1 || HIT=0
      else
        read_head | grep -qiF -- "$PATTERN" 2>/dev/null && HIT=1 || HIT=0
      fi
      emit "probe:$ID" "$HIT"
      shift 4
      ;;
    --script)
      ID="${2:-0}" CMD="${3:-}"
      # The condition script gets the file as $1 and $OMAZEL_FILE, same
      # contract as the run action. Timeboxed so one hung check cannot stall
      # the whole evaluation queue.
      if OMAZEL_FILE="$FILE" timeout 30 bash -c "$CMD" omazel "$FILE" >/dev/null 2>&1; then
        emit "probe:$ID" 1
      else
        emit "probe:$ID" 0
      fi
      shift 3
      ;;
    *)
      shift
      ;;
  esac
done
