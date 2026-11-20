#!/bin/sh
# Installs Notes for the current user. Safe to run again to upgrade: it only
# replaces the program files. Your notes live in
# ~/.local/share/com.mmoptibuilds.notes and are never touched here.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
prefix="${HOME}/.local"
app="${prefix}/opt/notes"
launcher="${prefix}/bin/notes"
version="$(basename "${here}" | sed 's/^notes-//; s/-linux-x64$//')"
case "${version}" in ''|*[!0-9A-Za-z.+_-]*) echo "Invalid package version" >&2; exit 10;; esac
build=0
[ -f "${here}/BUILD" ] && build="$(sed -n '1p' "${here}/BUILD" | tr -cd '0-9')"
[ -n "${build}" ] || build=0
[ -x "${here}/bundle/notes" ] && [ -d "${here}/bundle/lib" ] && \
  [ -d "${here}/bundle/data" ] && [ -f "${here}/update/notes-update-helper" ] || {
    echo "Package is missing runtime files or updater helper" >&2; exit 10;
  }
# A copy of Notes made by the first installer (before updates existed) has no
# marker. It is adopted only if it plainly is a Notes install owned by this
# user; anything else at this path is left alone.
legacy_notes_install() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ -x "$1/notes" ] && [ -d "$1/lib" ] && \
    [ -d "$1/data/flutter_assets" ]
}
launcher_is_notes() {
  [ -L "$1" ] || return 1
  target="$(readlink "$1")"
  case "${target}" in "${app}/"*) return 0;; esac
  return 1
}
if [ -e "${launcher}" ] || [ -L "${launcher}" ]; then
  launcher_is_notes "${launcher}" || {
    echo "Refusing to replace ${launcher}: it is not a Notes launcher. Move or remove it, then run install.sh again." >&2; exit 10;
  }
fi
mkdir -p "${prefix}/opt" "${prefix}/bin" "${prefix}/share/applications" "${prefix}/share/icons/hicolor/512x512/apps"
if [ -e "${app}" ] || [ -L "${app}" ]; then
  [ ! -L "${app}" ] || { echo "Refusing to replace a symlink: ${app}" >&2; exit 10; }
  [ "$(stat -c %u "${app}")" = "$(id -u)" ] || { echo "Install is not owned by this user" >&2; exit 10; }
  if [ ! -f "${app}/.managed-install" ]; then
    legacy_notes_install "${app}" || { echo "Refusing to replace something that is not a Notes install: ${app}" >&2; exit 10; }
  fi
fi
staging="$(mktemp -d "${prefix}/opt/.notes-install-XXXXXX")"
trap 'rm -rf "$staging"' EXIT HUP INT TERM
cp -a "${here}/bundle/." "${staging}/"
mkdir -p "${staging}/update"
install -m 0755 "${here}/update/notes-update-helper" "${staging}/update/notes-update-helper"
printf '{"schema":1,"version":"%s","build":%s,"installedAt":"%s"}\n' "${version}" "${build}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${staging}/.managed-install"
if [ -e "${app}" ]; then
  previous="${app}.previous"
  if [ -e "${previous}" ]; then
    { [ -f "${previous}/.managed-install" ] || legacy_notes_install "${previous}"; } && [ "$(stat -c %u "${previous}")" = "$(id -u)" ] || { echo "Refusing unsafe previous install" >&2; exit 10; }
    rm -rf "${previous}"
  fi
  mv "${app}" "${previous}"
fi
if ! mv "${staging}" "${app}"; then
  if [ -e "${previous}" ]; then
    mv "${previous}" "${app}" || { echo "Install failed and previous Notes install could not be restored: ${previous}" >&2; exit 10; }
  fi
  echo "Failed to move staged Notes program into place." >&2
  exit 10
fi
trap - EXIT HUP INT TERM
ln -sf "${app}/notes" "${launcher}"
cp "${here}/com.mmoptibuilds.notes.desktop" "${prefix}/share/applications/"
cp "${here}/notes.png" "${prefix}/share/icons/hicolor/512x512/apps/com.mmoptibuilds.notes.png"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${prefix}/share/applications" || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "${prefix}/share/icons/hicolor" || true
echo "Notes installed. Start it from the app menu or run: notes"
resolved_bin="$(command -v notes 2>/dev/null || true)"
case "${resolved_bin}" in "${launcher}") :;; '') :;; *) echo "Warning: ${resolved_bin} appears earlier on PATH and may shadow ${launcher}." >&2;; esac
