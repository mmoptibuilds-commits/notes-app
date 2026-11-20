#!/bin/sh
# Removes the program. Your notes (~/.local/share/com.mmoptibuilds.notes) and
# the key in the system keyring are kept; delete them yourself to erase data.
set -eu
prefix="${HOME}/.local"
app="${prefix}/opt/notes"
previous="${prefix}/opt/notes.previous"
launcher="${prefix}/bin/notes"
desktop="${prefix}/share/applications/com.mmoptibuilds.notes.desktop"
icon="${prefix}/share/icons/hicolor/512x512/apps/com.mmoptibuilds.notes.png"

# Only ever remove something that is plainly an installed copy of Notes: made
# by the installer (marker file) or by the first installer (the same layout),
# a real directory, owned by this user. Anything else is left untouched.
is_notes_install() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = "$(id -u)" ] || return 1
  [ -f "$1/.managed-install" ] && return 0
  [ -x "$1/notes" ] && [ -d "$1/lib" ] && [ -d "$1/data/flutter_assets" ]
}
launcher_is_notes() {
  [ -L "$1" ] || return 1
  target="$(readlink "$1")"
  case "${target}" in "${app}/"*) return 0;; esac
  return 1
}

if [ -e "${app}" ] || [ -L "${app}" ]; then
  is_notes_install "${app}" || {
    echo "Not removed: ${app} does not look like an installed copy of Notes." >&2
    echo "Nothing was changed." >&2
    exit 10
  }
fi
if [ -e "${app}" ]; then rm -rf "${app}"; fi
if [ -e "${previous}" ] || [ -L "${previous}" ]; then
  if is_notes_install "${previous}"; then
    rm -rf "${previous}"
  else
    echo "Previous program directory was not removed because it is not a Notes install: ${previous}" >&2
  fi
fi
if [ -e "${launcher}" ] || [ -L "${launcher}" ]; then
  if launcher_is_notes "${launcher}"; then rm -f "${launcher}"; else echo "Not removed; launcher is not owned by Notes: ${launcher}" >&2; fi
fi
# The desktop file and icon are named by the Notes app id, so they are ours.
rm -f "${desktop}" "${icon}"
echo "Notes removed. Your notes were not deleted."
