#!/bin/sh
# Installs Notes for the current user. Safe to run again to upgrade: it only
# replaces the program files. Your notes live in
# ~/.local/share/com.mmoptibuilds.notes and are never touched here.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
prefix="${HOME}/.local"
app="${prefix}/opt/notes"
version="$(basename "${here}" | sed 's/^notes-//; s/-linux-x64$//')"
case "${version}" in ''|*[!0-9A-Za-z.+_-]*) echo "Invalid package version" >&2; exit 10;; esac
[ -x "${here}/bundle/notes" ] && [ -d "${here}/bundle/lib" ] && \
  [ -d "${here}/bundle/data" ] && [ -f "${here}/update/notes-update-helper" ] || {
    echo "Package is missing runtime files or updater helper" >&2; exit 10;
  }
mkdir -p "${prefix}/opt" "${prefix}/bin" "${prefix}/share/applications" "${prefix}/share/icons/hicolor/512x512/apps"
if [ -e "${app}" ]; then
  [ -f "${app}/.managed-install" ] || { echo "Refusing to replace an unmanaged install: ${app}" >&2; exit 10; }
  [ "$(stat -c %u "${app}")" = "$(id -u)" ] || { echo "Install is not owned by this user" >&2; exit 10; }
fi
staging="$(mktemp -d "${prefix}/opt/.notes-install-XXXXXX")"
trap 'rm -rf "$staging"' EXIT HUP INT TERM
cp -a "${here}/bundle/." "${staging}/"
mkdir -p "${staging}/update"
install -m 0755 "${here}/update/notes-update-helper" "${staging}/update/notes-update-helper"
printf '{"schema":1,"version":"%s","installedAt":"%s"}\n' "${version}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${staging}/.managed-install"
if [ -e "${app}" ]; then
  previous="${app}.previous"
  if [ -e "${previous}" ]; then
    [ -f "${previous}/.managed-install" ] && [ "$(stat -c %u "${previous}")" = "$(id -u)" ] || { echo "Refusing unsafe previous install" >&2; exit 10; }
    rm -rf "${previous}"
  fi
  mv "${app}" "${previous}"
fi
mv "${staging}" "${app}"
trap - EXIT HUP INT TERM
ln -sf "${app}/notes" "${prefix}/bin/notes"
cp "${here}/com.mmoptibuilds.notes.desktop" "${prefix}/share/applications/"
cp "${here}/notes.png" "${prefix}/share/icons/hicolor/512x512/apps/com.mmoptibuilds.notes.png"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${prefix}/share/applications" || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "${prefix}/share/icons/hicolor" || true
echo "Notes installed. Start it from the app menu or run: notes"
