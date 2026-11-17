#!/bin/sh
# Installs Notes for the current user. Safe to run again to upgrade: it only
# replaces the program files. Your notes live in
# ~/.local/share/com.mmoptibuilds.notes and are never touched here.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
prefix="${HOME}/.local"
app="${prefix}/opt/notes"
mkdir -p "${prefix}/bin" "${prefix}/share/applications" "${prefix}/share/icons/hicolor/512x512/apps"
rm -rf "${app}.new"
mkdir -p "${app}.new"
cp -a "${here}/bundle/." "${app}.new/"
rm -rf "${app}"
mv "${app}.new" "${app}"
ln -sf "${app}/notes" "${prefix}/bin/notes"
cp "${here}/com.mmoptibuilds.notes.desktop" "${prefix}/share/applications/"
cp "${here}/notes.png" "${prefix}/share/icons/hicolor/512x512/apps/com.mmoptibuilds.notes.png"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${prefix}/share/applications" || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "${prefix}/share/icons/hicolor" || true
echo "Notes installed. Start it from the app menu or run: notes"
