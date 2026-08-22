#!/usr/bin/env bash
#
# Lists the files in a watched folder with the metadata rule matching needs,
# one per line:
#
#   size<TAB>mtimeEpoch<TAB>/full/path
#
# This is the other half of the engine beside inotify: it catches files that
# arrived while the shell was not running, and it is the only path by which
# age-based rules ("trash downloads older than 2 weeks") ever fire, since a
# file does not emit an event by getting older.
#
# Usage: omazel-sweep.sh <dir> [recursive 0|1] [maxEntries]

set -uo pipefail

DIR="${1:-}"
RECURSIVE="${2:-0}"
MAX="${3:-2000}"

[[ -n $DIR ]] || { echo "usage: omazel-sweep.sh <dir> [recursive] [maxEntries]" >&2; exit 2; }
[[ -d $DIR ]] || exit 0   # a folder that does not exist yet simply has no files

DEPTH=()
[[ $RECURSIVE == 1 ]] || DEPTH=(-maxdepth 1)

# %T@ carries fractional seconds; the sed strips them so the service gets a
# clean integer epoch.
find "$DIR" -mindepth 1 "${DEPTH[@]}" -type f -printf '%s\t%T@\t%p\n' 2>/dev/null \
  | sed 's/\.[0-9]*\t/\t/' \
  | head -n "$MAX"
