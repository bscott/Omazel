#!/usr/bin/env bash
#
# Streams file-arrival events for one watched folder, one per line:
#
#   EVENTS<TAB>/full/path/to/file
#
# Only close_write and moved_to are watched: between them they cover a download
# finishing, a save completing, and a file being moved into the folder, without
# firing on every intermediate write the way `create` + `modify` would. The
# service applies its own settle delay on top before evaluating rules.
#
# Usage: omazel-watch.sh <dir> [recursive 0|1]

set -uo pipefail

DIR="${1:-}"
RECURSIVE="${2:-0}"

[[ -n $DIR ]] || { echo "usage: omazel-watch.sh <dir> [recursive]" >&2; exit 2; }
[[ -d $DIR ]] || { echo "not a directory: $DIR" >&2; exit 1; }
command -v inotifywait >/dev/null 2>&1 || { echo "inotifywait is not installed" >&2; exit 1; }

ARGS=(-m -q --format '%e	%w%f' -e close_write -e moved_to)
[[ $RECURSIVE == 1 ]] && ARGS+=(-r)

exec inotifywait "${ARGS[@]}" -- "$DIR"
