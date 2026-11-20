#!/bin/sh
# Removes the program. Your notes (~/.local/share/com.mmoptibuilds.notes) and
# the key in the system keyring are kept; delete them yourself to erase data.
set -eu
prefix="${HOME}/.local"
rm -rf "${prefix}/opt/notes"
previous="${prefix}/opt/notes.previous"
if [ -e "${previous}" ]; then
  if [ -f "${previous}/.managed-install" ] && [ "$(stat -c %u "${previous}")" = "$(id -u)" ]; then
    rm -rf "${previous}"
  else
    echo "Previous program directory was not removed because it is not a managed install: ${previous}" >&2
  fi
fi
rm -f "${prefix}/bin/notes" \
      "${prefix}/share/applications/com.mmoptibuilds.notes.desktop" \
      "${prefix}/share/icons/hicolor/512x512/apps/com.mmoptibuilds.notes.png"
echo "Notes removed. Your notes were not deleted."
