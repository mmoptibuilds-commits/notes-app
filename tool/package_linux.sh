#!/bin/sh
# Builds the Linux release and packs it into dist/notes-<version>-linux-x64.tar.gz
# with a SHA-256 file. Usage: tool/package_linux.sh   (Flutter must be on PATH)
set -eu
cd "$(dirname "$0")/.."
version="$(sed -n 's/^version: \([^+]*\).*/\1/p' pubspec.yaml)"
build="$(sed -n 's/^version: [^+]*+\([0-9]*\).*/\1/p' pubspec.yaml)"
name="notes-${version}-linux-x64"
flutter build linux --release
rm -rf "dist/${name}"
mkdir -p "dist/${name}"
cp -a build/linux/x64/release/bundle "dist/${name}/bundle"
cp tool/linux/install.sh tool/linux/uninstall.sh tool/linux/com.mmoptibuilds.notes.desktop "dist/${name}/"
mkdir -p "dist/${name}/update"
cp tool/linux/notes-update-helper "dist/${name}/update/notes-update-helper"
printf '%s\n' "${build:-0}" > "dist/${name}/BUILD"
cp assets/icon/icon_512.png "dist/${name}/notes.png"
cp assets/fonts/*-OFL.txt "dist/${name}/" 2>/dev/null || true
chmod +x "dist/${name}/install.sh" "dist/${name}/uninstall.sh" "dist/${name}/update/notes-update-helper"
# Fixed timestamps and ordering so the same sources give the same archive.
(cd dist && tar --sort=name --mtime='2026-01-01 00:00:00' --owner=0 --group=0 --numeric-owner \
  -czf "${name}.tar.gz" "${name}")
(cd dist && sha256sum "${name}.tar.gz" > "${name}.tar.gz.sha256")
echo "Built dist/${name}.tar.gz"
cat "dist/${name}.tar.gz.sha256"
