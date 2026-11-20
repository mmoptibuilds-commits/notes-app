#!/bin/sh
# Removes the program. Your notes (~/.local/share/com.mmoptibuilds.notes) and
# the key in the system keyring are kept; delete them yourself to erase data.
set -eu
prefix="${HOME}/.local"
app="${prefix}/opt/notes"
previous="${prefix}/opt/notes.previous"

# Only ever remove something that is plainly an installed copy of Notes: made
# by the installer (marker file) or by the first installer (the same layout),
# a real directory, owned by this user. Anything else is left untouched.
is_notes_install() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = "$(id -u)" ] || return 1
  [ -f "$1/.managed-install" ] && return 0
  [ -x "$1/notes" ] && [ -d "$1/lib" ] && [ -d "$1/data/flutter_assets" ]
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
rm -f "${prefix}/bin/notes" \
      "${prefix}/share/applications/com.mmoptibuilds.notes.desktop" \
      "${prefix}/share/icons/hicolor/512x512/apps/com.mmoptibuilds.notes.png"
echo "Notes removed. Your notes were not deleted."
