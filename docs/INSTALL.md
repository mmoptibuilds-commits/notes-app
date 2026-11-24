# Linux installation

## Requirements

Notes targets Linux x64. Install the GTK 3 and GLib runtime libraries supplied
by your distribution. The app also needs a working desktop keyring for its
local encryption key. LAN sync pairing may need TCP 47380 and UDP 47381 allowed
on the local network. Optional cloud sync requires no separate Linux service or
port; it is off until you sign in with the owner's Google account and upload a
library. The cloud server stores readable note JSON, so cloud sync is not
end-to-end encrypted. LAN sync remains available. See
[Cloud sync troubleshooting](TROUBLESHOOTING.md#cloud-sync) and
[product privacy details](PRODUCT.md#sync).

Download the files from the latest release on the
[Releases page](https://github.com/mmoptibuilds-commits/notes-app/releases/latest).

## Install or upgrade

1. Download `notes-<version>-linux-x64.tar.gz` and its checksum sidecar from a
   stable GitHub release.
2. Before extracting, verify the manifest signature with OpenSSL 3 or later.
   Follow the [Verify a Linux download](../README.md#verify-a-linux-download)
   instructions. Save the public key from the README as `notes-release.pem` and
   check its SHA-256 fingerprint against the fingerprint printed there.
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
It refuses symlinks, directories it cannot identify as a Notes install, or an
install directory not owned by your user. No administrator privileges are
needed.

Maintainers can also use `dart tool/release/verify_manifest.dart`; ordinary
Linux users do not need Dart or a source checkout.

For keyring, firewall, update and installer errors, see
[Troubleshooting](TROUBLESHOOTING.md).

The encrypted database at `~/.local/share/com.mmoptibuilds.notes/notes.db`,
its SQLite sidecar files, keyring key, backups, and pairing state are separate
from program files. Installation, upgrade, and uninstall preserve them.

## In-app updates on Linux

Open **Settings → About → App updates** to check for a stable release. Automatic
updates are enabled by default: Notes downloads a verified update in the
background and shows a prompt when it is ready. You choose whether to install
it; Notes never installs an update without confirmation.

On Linux, in-app updates work only for a managed install at
`~/.local/opt/notes`. Notes closes while the helper replaces the program files,
then relaunches. Startup waits briefly if the helper still holds its update
lock. For other Linux installs, download and install the new archive using the
steps above.

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
