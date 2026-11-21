# Troubleshooting

## Sync is not working

**Symptom:** A paired device is unreachable, pairing cannot connect, or the
Sync screen says “No network connection. Changes are kept until one is
available.”

**Cause:** Notes syncs directly between paired devices. Both devices need a
working route to each other; on Android, Notes must be open in the foreground.
Linux firewalls must allow TCP port 47380 for sync and UDP port 47381 for
discovery. A pairing code also expires after five minutes and works once.

**Fix:** Open Notes on both devices and connect them to the same local network.
On Linux, allow the two ports on the interface and subnet used by Wi-Fi. Check
that the firewall rule matches the current subnet: a laptop rule limited to
`192.168.1.0/24` will stop matching after the LAN changes to `192.168.0.0/24`.
On 2026-11-21 this caused phone-to-laptop sync to fail. The laptop's UFW rules
were corrected with:

```sh
sudo ufw allow in on <wifi-iface> from 192.168.0.0/16 to any port 47380 proto tcp
sudo ufw allow in on <wifi-iface> from 192.168.0.0/16 to any port 47381 proto udp
```

Replace `<wifi-iface>` with the laptop's Wi-Fi interface. Use the subnet that
matches your network. Tailscale addresses are supported by the connection code,
but have not been verified on a real setup.

## “Your notes are locked”

**Symptom:** Startup shows “Your notes are locked” and says the database key is
no longer in the system keystore.

**Cause:** The database exists, but the Android Keystore or Linux Secret
Service/keyring does not have the key that encrypted it. This can happen after
a keyring reset or restoring app data without its key.

**Fix:** On Linux, start or unlock the desktop keyring and reopen Notes. If the
key was deleted or replaced, the existing database cannot be opened with a new
key. Restore the original key if you have it, or recover the notes from another
paired device or an exported Notes JSON file. The startup screen does not
change or delete the database.

## “This version of Notes is too old”

**Symptom:** Startup says “This version of Notes is too old” and shows a data
version higher than the version this app supports.

**Cause:** A newer Notes build has already migrated the database. Older builds
refuse to open a newer schema.

**Fix:** Install the newer Notes version that last opened the database. The
older app leaves the database unchanged.

## Linux app does not start

**Symptom:** Running `notes` exits with a missing library or GTK/GLib loader
error, sometimes before the Notes window appears.

**Cause:** The Linux runtime needs GTK 3 and GLib libraries from the
distribution. A missing or locked Secret Service can also prevent startup.

**Fix:** Install the distribution's GTK 3 and GLib runtime packages. If the
error mentions a keyring, start or unlock the desktop Secret Service (for
example GNOME Keyring). Run `notes` from a terminal to see the exact loader or
startup error.

## `install.sh` refuses `~/.local/bin/notes`

**Symptom:** The installer prints `Refusing to replace
~/.local/bin/notes: it is not a Notes launcher` and stops.

**Cause:** That path already belongs to a file or launcher that does not point
to this install at `~/.local/opt/notes`.

**Fix:** Check what owns the path. If it is an older launcher you no longer
need, move it aside, then rerun `install.sh` from the extracted Notes archive.
The installer leaves the existing path untouched so it does not replace an
unrelated command.

## Update check says “No stable release published”

**Symptom:** Settings → Updates shows “No stable release published.”

**Cause:** The release page has no published stable release. Notes does not
offer pre-releases through the in-app updater.

**Fix:** Use the download page when a stable release is published. Until then,
there is no in-app update to install.

## Update check says “Could not verify the update”

**Symptom:** Settings → Updates shows “Could not verify the update,” followed
by a reason, and says nothing was installed. One possible reason is “The
manifest has expired.”

**Cause:** Notes rejects a release if its signature, signed metadata, expiry,
version or downloaded artifact does not verify. A device clock set too far
ahead can make a valid manifest appear expired.

**Fix:** Check the device date and time, then try again. If the manifest is
expired or the signature/hash does not match, wait for corrected release files
or contact the project maintainer. Do not install an artifact that fails the
manual verification steps in the [README](../README.md#verify-a-linux-download).

## Android says “App not installed”

**Symptom:** Android refuses an APK and reports “App not installed.”

**Cause:** An update APK must have the same signing certificate as the
installed Notes app and a higher `versionCode`. Android rejects an APK signed
with a different key or one that would downgrade the installed version.

**Fix:** Use the official APK with the matching release certificate and a
higher build number. Check the installed versionCode read-only before choosing
an APK. If the installed copy was signed with another key, it cannot be
replaced in place by the official APK; export or sync your notes before
removing that copy.
