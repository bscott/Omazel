#!/usr/bin/env bash
#
# Reports which of the tools Omazel's actions can depend on are installed, as
# tab-separated `tool<TAB>0|1` lines. The service crosses this with the tools
# the loaded rules actually use (Model.requiredTools) so the popup only warns
# about absences that matter.

set -uo pipefail

for tool in inotifywait gio notify-send age tailscale rclone zip unzip 7z unrar tar file getfattr xdg-open; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s\t1\n' "$tool"
  else
    printf '%s\t0\n' "$tool"
  fi
done
