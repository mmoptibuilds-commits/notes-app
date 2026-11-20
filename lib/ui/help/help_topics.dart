/// What a topic's body is made of. Most topics are plain text; these three
/// are drawn by the Help screen itself.
enum HelpTopicKind { text, welcome, shortcuts, about }

/// One expandable topic in Help. Every statement here was checked against the
/// app's code or docs/PRODUCT.md, and against docs/DECISIONS.md where it
/// describes storage or backup. Keep it that way when the app changes.
class HelpTopic {
  const HelpTopic({
    required this.id,
    required this.title,
    this.paragraphs = const [],
    this.bullets = const [],
    this.kind = HelpTopicKind.text,
  });

  final String id;
  final String title;
  final List<String> paragraphs;
  final List<String> bullets;
  final HelpTopicKind kind;
}

const helpTopics = <HelpTopic>[
  HelpTopic(id: 'welcome', title: 'Welcome', kind: HelpTopicKind.welcome),
  HelpTopic(
    id: 'getting-started',
    title: 'Getting started',
    paragraphs: [
      'Notes keeps your notes on this device. You do not need an account or '
          'an internet connection.',
    ],
    bullets: [
      'Tap the New note button (+) to start a note. It opens straight away, '
          'untitled.',
      'There is no save button. Notes are saved automatically as you type.',
      'Use the search button to find notes by title or text.',
      'To keep notes in step across devices, pair another device. See '
          '"Pairing another device".',
    ],
  ),
  HelpTopic(
    id: 'creating-editing',
    title: 'Creating and editing notes',
    paragraphs: ['Open a note to edit it. A note has a title and a body.'],
    bullets: [
      'Use the back button to return to the library. Your changes are '
          'already saved.',
      'The copy button copies the whole note.',
      'The menu (More) in a note has Move to folder, Archive, Move to Trash, '
          'Copy as Markdown and Save as Markdown file. Save as Markdown file '
          'saves that one note as a .md file.',
    ],
  ),
  HelpTopic(
    id: 'rich-text',
    title: 'Rich text and checklists',
    bullets: [
      'The toolbar has bold, italic, underline, strikethrough, three heading '
          'levels, bulleted, numbered and checklist lists, quotes, code '
          'blocks, inline code, links and images.',
      'Choose which toolbar buttons appear, and their order, in Settings → '
          'Editor → Customise toolbar.',
      'Tick a checklist item to mark it done. Done items can move to a '
          'collapsible Completed section. Turn this on or off in Settings → '
          'Editor.',
      'In the Completed section you can restore or delete items one at a '
          'time, or uncheck or delete them all together.',
    ],
  ),
  HelpTopic(
    id: 'folders-trash',
    title: 'Folders, pinned notes, archive and Trash',
    bullets: [
      'Folders are flat: there are no folders inside folders. A note is in '
          'one folder, or in none (Unfiled).',
      'Pinned notes stay at the top of the library.',
      'To act on several notes, long-press one to select it, then pick the '
          'action. Pin, Archive, Move to folder and Move to Trash work on the '
          'whole selection.',
      'Archive hides notes from the main list without deleting them. Open '
          'Archive from the library menu to see them.',
      'Move to Trash keeps a note recoverable. Open Trash from the library '
          'menu to restore a note or delete it forever.',
      'Trash is kept until you empty it with Empty Trash. Nothing in Trash is '
          'removed automatically.',
    ],
  ),
  HelpTopic(
    id: 'search-sorting',
    title: 'Search and sorting',
    bullets: [
      'Tap the search button in the library and type. Search looks at note '
          'titles and text.',
      'Use Sort by in the library menu to sort by Modified, Created or Title.',
      'In Settings → Library you can choose grid, masonry or list layout, and '
          'how many lines each card previews.',
    ],
  ),
  HelpTopic(
    id: 'auto-sync',
    title: 'Automatic synchronization',
    paragraphs: [
      'Paired devices sync directly with each other over your local network. '
          'There is no server and no account.',
    ],
    bullets: [
      'Sync starts by itself when the app opens or comes back to the front, '
          'about 20 seconds after you stop editing, and when you tap Sync now.',
      'Notes does not check on a timer. Both devices must be open at the same '
          'time on the same network for a change to reach the other one.',
      'If a device cannot be reached, Notes waits longer before trying it '
          'again, up to about 15 minutes.',
      'On Android, sync does not run in the background while the app is '
          'force-stopped. Open Notes again to sync.',
      'If the same note was changed on two devices, both versions are kept. '
          'The other version is kept as a conflict copy, which you can find '
          'under Conflicts in the library menu.',
    ],
  ),
  HelpTopic(
    id: 'manual-sync',
    title: 'Manual synchronization (Sync now)',
    bullets: [
      'Open Settings → Sync and data → Sync with other devices, then tap Sync '
          'now.',
      'Each paired device also has a menu with a Sync now item.',
      'The Sync screen then shows Syncing…, and ends with Up to date, Synced '
          'with the number of changes received, or Could not reach your other '
          'devices.',
    ],
  ),
  HelpTopic(
    id: 'pairing',
    title: 'Pairing another device',
    paragraphs: [
      'You can pair up to four other devices, five in total. Pairing needs '
          'both devices on the same local network.',
    ],
    bullets: [
      'On a device you already use, open Settings → Sync and data → Sync with '
          'other devices, tap Pair a device, then choose Show code.',
      'On Android, choose Scan code on the other device and point the camera '
          'at the code. Where there is no camera, tap Copy on the first device '
          'and choose Enter code on the other device, then paste the code.',
      'A code is valid for five minutes and works once. If it expires, start '
          'again.',
      'Firewall: a Linux computer must allow TCP port 47380 (sync) and UDP '
          'port 47381 (finding a paired device whose address changed) on the '
          'local network. If pairing or sync fails, check the firewall first.',
    ],
  ),
  HelpTopic(
    id: 'offline',
    title: 'Offline behaviour and reconnection',
    bullets: [
      'Notes works fully without a connection. Every note, folder and change '
          'is kept on the device.',
      'When another device cannot be reached, changes wait on this device '
          'until a sync can deliver them.',
      'While the device is offline, the Sync screen says: "No network '
          'connection. Changes are kept until one is available."',
      'When the network returns, the next sync starts when the app opens or '
          'resumes, or when you tap Sync now.',
      'Sync is designed for devices on the same local network. Other routes, '
          'including Tailscale, are not verified.',
    ],
  ),
  HelpTopic(
    id: 'import-notebook',
    title: 'Importing a Notebook backup',
    bullets: [
      'Open Settings → Sync and data → Import and export, then tap Import a '
          'backup or Notes export.',
      'Choose the backup file from the old Notebook app. You see what it '
          'contains before anything changes.',
      'Notes then reports what was imported and anything it could not carry '
          'over.',
      'Each import is listed under Past imports. Undo removes the notes it '
          'added, unless you have edited them since.',
      'Importing the same backup again does not create duplicates, and newer '
          'local changes are never overwritten.',
      'Some older Notebook fields, such as note colours, tags, reminders and '
          'the lock flag, are kept in the import record but are not shown in '
          'Notes yet.',
    ],
  ),
  HelpTopic(
    id: 'export-restore',
    title: 'Exporting and restoring Notes backups',
    bullets: [
      'Open Settings → Sync and data → Import and export, then tap Export all '
          'notes. This saves every note, folder and image, including Trash, as '
          'one JSON file. Choose where to save it.',
      'To restore, tap Import a backup or Notes export and pick the Notes '
          'export file. You see a preview and must confirm before anything '
          'changes.',
      'Before a restore changes anything, Notes takes a snapshot of the '
          'database. The restore then applies in one step, so it either '
          'completes or changes nothing.',
    ],
  ),
  HelpTopic(
    id: 'backup-limits',
    title: 'Backup limitations',
    bullets: [
      'Exported files are not encrypted. Anyone who can open the file can read '
          'your notes, so store it somewhere you trust.',
      'Android system backup cannot restore the encrypted database. Notes is '
          'excluded from Android backup and device transfer, so reinstalling or '
          'moving to a new phone does not bring your notes back.',
      'Keep your own copy. Export regularly, keep the file safe, and keep at '
          'least one paired device.',
      'If the key in the system keystore or keyring is lost, the local '
          'database cannot be opened. Paired devices and your exports are then '
          'the way back.',
    ],
  ),
  HelpTopic(
    id: 'shortcuts',
    title: 'Keyboard shortcuts',
    kind: HelpTopicKind.shortcuts,
  ),
  HelpTopic(
    id: 'troubleshooting',
    title: 'Common troubleshooting',
    bullets: [
      '"Your notes are locked": the database is on this device, but its key is '
          'not in the system keystore or keyring. Nothing has been changed or '
          'deleted. Restore the key, or recover your notes from another paired '
          'device.',
      '"Your notes could not be opened": the stored key does not open the '
          'database. Nothing has been changed or deleted.',
      '"This version of Notes is too old": your notes were last opened by a '
          'newer version of the app. Install the newer version.',
      'Devices do not sync: check that both are open on the same network, that '
          'the pairing code has not expired, and on Linux that TCP 47380 and '
          'UDP 47381 are allowed.',
      'The camera is not available for pairing: choose Enter code on the other '
          'device and paste the copied code.',
      'On Android, sync needs the app open. If you force-stopped Notes, open it '
          'again first.',
    ],
  ),
  HelpTopic(
    id: 'privacy',
    title: 'Privacy and data storage',
    bullets: [
      'Your notes are stored in a local database on this device, and the '
          'database is encrypted.',
      'The database key is held in the Android Keystore on Android, and in the '
          'Linux Secret Service (for example GNOME Keyring) on Linux.',
      'Notes has no accounts and no cloud service. Nothing is uploaded to a '
          'server.',
      'Notes contains no analytics.',
      'Sync sends notes only between your own paired devices, over an '
          'encrypted connection.',
      'Settings → About shows where the data folder is.',
    ],
  ),
  HelpTopic(
    id: 'about',
    title: 'About and open-source licences',
    paragraphs: ['Notes is a personal, offline-first notes app.'],
    kind: HelpTopicKind.about,
  ),
];
