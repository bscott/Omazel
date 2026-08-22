#!/usr/bin/env bash
#
# Reports whether this plugin's checkout is behind its git remote, as
# tab-separated key/value lines.
#
# Read-only by design: it fetches and compares, and never merges. Applying an
# update is left to `omarchy plugin update`, which already diffs, fast-forwards,
# re-validates the manifest, and rolls back if validation fails — all behaviour
# worth reusing rather than reimplementing here.
#
# Usage: plugin-update-check.sh [plugin-dir]

set -uo pipefail

# Never let git block on a credential or host-key prompt. A widget that hangs
# waiting for input nobody can see is worse than one that reports it failed;
# omarchy-plugin-update sets the same two variables for the same reason.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes -oConnectTimeout=10}"

DIR="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

emit() { printf '%s\t%s\n' "$1" "$2"; }

emit dir "$DIR"

if [[ ! -d $DIR/.git ]]; then
  # The plugin was copied rather than cloned, so there is no remote to compare
  # against. Not an error, just nothing to offer.
  emit state nogit
  exit 0
fi

# A symlinked plugin directory points at a working checkout the user is likely
# editing, and fast-forwarding it would silently move their branch. The install
# path is tested rather than $DIR because resolving this script's own location
# follows the symlink and would always report the real directory.
INSTALLED="$HOME/.config/omarchy/plugins/io.github.bscott.omazel"
if [[ -L $INSTALLED ]]; then
  emit linked true
else
  emit linked false
fi

if [[ -n $(git -C "$DIR" status --porcelain 2>/dev/null) ]]; then
  emit dirty true
else
  emit dirty false
fi

emit branch "$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
emit local "$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)"

if ! fetch_err=$(timeout 30 git -C "$DIR" fetch --quiet origin HEAD 2>&1); then
  emit state fetchfailed
  emit error "$(printf '%s' "$fetch_err" | tail -n 1 | cut -c1-200)"
  exit 0
fi

emit remote "$(git -C "$DIR" rev-parse --short FETCH_HEAD 2>/dev/null)"

behind=$(git -C "$DIR" rev-list --count HEAD..FETCH_HEAD 2>/dev/null)
ahead=$(git -C "$DIR" rev-list --count FETCH_HEAD..HEAD 2>/dev/null)
emit behind "${behind:-0}"
emit ahead "${ahead:-0}"

# The newest subject line gives the panel something specific to show rather than
# a bare commit count.
if [[ ${behind:-0} -gt 0 ]]; then
  emit subject "$(git -C "$DIR" log -1 --format=%s FETCH_HEAD 2>/dev/null | cut -c1-120)"
fi

emit state ok
exit 0
