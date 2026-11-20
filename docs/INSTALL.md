# Linux installation

## Requirements

Notes targets Linux x64. Install the GTK 3 and GLib runtime libraries supplied
by your distribution. The app also needs a working desktop keyring for its
local encryption key. Sync pairing may need TCP 47380 and UDP 47381 allowed on
the local network.

## Install or upgrade

1. Download `notes-<version>-linux-x64.tar.gz` and its checksum sidecar from a
   stable GitHub release.
2. Before extracting, verify the manifest signature with OpenSSL 3 or later.
   Follow the [Verify a Linux download](../README.md#verify-a-linux-download)
   instructions. Once published, the public key will be `notes-release.pem`;
   check its SHA-256 fingerprint against the published DER SPKI fingerprint.
3. Check that the archive's SHA-256 appears in the signed manifest. Do not
   continue if signature verification or the hash check fails. The checksum
   sidecar alone only detects a damaged download because it comes from the
   same place as the archive.
4. Extract the archive and run `install.sh` from its top-level directory. If
   you installed Notes with the earlier installer, `install.sh` adopts that copy
   (it checks that it is a real Notes install owned by you) and keeps the old
   program as `~/.local/opt/notes.previous`.
5. Start Notes from the desktop app menu or run `notes`.

The installer is user-scoped and writes program files to
`~/.local/opt/notes`, a launcher to `~/.local/bin/notes`, and desktop/icon
entries under `~/.local/share`. Re-run it with a newer archive to upgrade.
If `~/.local/bin/notes` already exists and is not the Notes launcher, the
installer stops without changing anything and names the file; `uninstall.sh`
likewise leaves such a file alone. If another `notes` command comes earlier on
your `PATH`, the installer warns you.
It refuses to replace an existing program directory without the managed
install marker. No administrator privileges are needed.

Maintainers can also use `dart tool/release/verify_manifest.dart`; ordinary
Linux users do not need Dart or a source checkout.

The encrypted database at `~/.local/share/com.mmoptibuilds.notes/notes.db`,
its SQLite sidecar files, keyring key, backups, and pairing state are separate
from program files. Installation, upgrade, and uninstall preserve them.

## Uninstall

Run `uninstall.sh` from the extracted archive. It removes program files and
launcher/icon entries. It prints that notes are kept; delete user data yourself
only if you intend to erase it.

## Troubleshooting

- **Application does not launch / missing shared library:** install your
  distribution's GTK 3 and GLib runtime packages, then run `notes` in a
  terminal to see loader diagnostics.
- **No desktop icon:** log out and back in, or refresh desktop and icon caches.
- **Wayland display issues:** update the compositor and GTK runtime; XWayland
  can help on older systems.
- **Devices cannot pair:** allow TCP 47380 and UDP 47381 on the local network
  and check that both devices can reach one another.
- **Stable update unavailable:** the preview release is not a stable release.
  The app reports that no stable release is published until a stable release
  exists.
