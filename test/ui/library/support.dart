import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show OffsetLayer;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/models.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/library/desktop_sidebar.dart';
import 'package:notes/ui/library/note_card.dart';

import '../../support/screenshot.dart';

/// A clock the test moves by hand so note order and dates are deterministic.
class TestClock {
  int ms = DateTime.now().millisecondsSinceEpoch;
  int call() => ms;
}

class Seed {
  Seed(this.services, this.clock, this.ids, this.folders);
  final AppServices services;
  final TestClock clock;

  /// Note ids by short name.
  final Map<String, String> ids;

  /// Folder ids by name.
  final Map<String, String> folders;
}

String checklistBody(List<(String, bool)> items) => jsonEncode([
  for (final (text, done) in items) ...[
    {'insert': text},
    {
      'insert': '\n',
      'attributes': {'list': done ? 'checked' : 'unchecked'},
    },
  ],
]);

String paragraphs(List<String> lines) => bodyFromPlainText(lines.join('\n'));

Seed freshServices() {
  final clock = TestClock();
  final services = AppServices.inMemory(clock: clock.call);
  return Seed(services, clock, {}, {});
}

/// Synthetic library: pinned, untitled, long, short, checklists, folders.
Seed seedLibrary() {
  final s = freshServices();
  final repo = s.services.notes;
  final now = s.clock.ms;
  const min = 60 * 1000;
  const day = 24 * 60 * min;

  void at(int ago) => s.clock.ms = now - ago;
  Note add(
    String key,
    String title,
    String body, {
    int ago = 0,
    String? folder,
    bool pinned = false,
  }) {
    at(ago);
    final n = repo.createNote(
      title: title,
      body: body,
      folderId: folder == null ? null : s.folders[folder],
    );
    s.ids[key] = n.id;
    if (pinned) repo.setPinned([n.id], true);
    return n;
  }

  for (final f in ['Work', 'Home', 'Reading']) {
    s.folders[f] = repo.createFolder(f).id;
  }
  add(
    'groceries',
    'Groceries',
    checklistBody([
      ('Oat milk', true),
      ('Coffee beans', true),
      ('Lemons', true),
      ('Rye bread', false),
      ('Olive oil', false),
      ('Basil', false),
      ('Pasta', false),
    ]),
    ago: 5 * min,
    folder: 'Home',
    pinned: true,
  );
  add(
    'roadmap',
    'Quarter roadmap',
    paragraphs([
      'Ship the offline sync pairing flow',
      'Tidy the importer report',
      'Profile the library with ten thousand notes',
      'Write the release checklist',
      'Review the Android back-button behaviour',
      'Draft the data export format',
      'Collect feedback from the first week',
    ]),
    ago: 3 * 60 * min,
    folder: 'Work',
    pinned: true,
  );
  add(
    'plumber',
    '',
    paragraphs([
      'Call the plumber about the kitchen leak',
      'Bring the old washer',
    ]),
    ago: 26 * 60 * min,
  );
  add(
    'meeting',
    'Meeting notes, design review with the platform team',
    paragraphs([
      'Agreed to keep the library header to one overflow menu.',
      'Open question: should the folder strip scroll or wrap.',
      'Action: send the revised screenshots on Friday.',
      'Action: check contrast of the muted text on the light theme.',
    ]),
    ago: 4 * day,
    folder: 'Work',
  );
  add('short', 'Passport', paragraphs(['Renew before March']), ago: 9 * day);
  add(
    'book',
    'Reading list',
    checklistBody([
      ('A pattern language', true),
      ('The design of everyday things', false),
      ('Working in public', false),
    ]),
    ago: 20 * day,
    folder: 'Reading',
  );
  add(
    'recipe',
    'Tomato soup',
    paragraphs([
      'Roast tomatoes with garlic for forty minutes.',
      'Blend with stock, finish with cream and basil.',
    ]),
    ago: 40 * day,
    folder: 'Home',
  );
  add('empty-title', '', emptyBodyJson, ago: 60 * day);
  add(
    'old',
    'Packing list for the lake trip',
    checklistBody([
      ('Tent', true),
      ('Stove', true),
      ('Headlamp', true),
      ('Water filter', true),
    ]),
    ago: 500 * day,
  );
  add(
    'wifi',
    'Wifi',
    paragraphs(['Network: attic', 'Password is on the router']),
    ago: 12 * day,
  );
  add(
    'ideas',
    'Ideas',
    paragraphs([
      'A quiet timer app',
      'Seed packet tracker',
      'Walking route notes',
    ]),
    ago: 15 * day,
  );
  s.clock.ms = now;
  return s;
}

Future<void> pumpLibrary(
  WidgetTester tester,
  Seed seed, {
  Size size = const Size(412, 915),
}) async {
  await setWindow(tester, size);
  await pumpApp(tester, seed.services);
  await tester.pump();
}

/// Marks a note as the conflict copy of another (as sync would).
void markConflict(Seed s, String key) {
  final repo = s.services.notes;
  final rec = repo.getRecord(s.ids[key]!)!;
  s.services.db.transaction(
    () => repo.writeRecord(rec.copyWith(conflictOf: 'original-note')),
  );
}

/// Matches exactly one widget while the library shows All notes (not a
/// sub-view such as Archive): the FAB on a phone, the header title beside the
/// sidebar on desktop, where there is no FAB.
Finder libraryRoot() => find.byWidgetPredicate(
  (w) =>
      w is FloatingActionButton ||
      (w is Text &&
          w.key == const ValueKey('library-title') &&
          w.data == 'All notes'),
  description: 'library root marker',
);

/// The library header's title (not the sidebar entry of the same name).
Finder libraryTitle(String text) => find.byWidgetPredicate(
  (w) =>
      w is Text && w.key == const ValueKey('library-title') && w.data == text,
  description: 'library title "$text"',
);

/// Every note card or row currently built.
Finder noteItems() =>
    find.byWidgetPredicate((w) => w is NoteCard || w is NoteRow);

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
}

/// Views that live in the desktop sidebar rather than the overflow menu.
const _sidebarViews = {
  'All notes',
  'Archive',
  'Trash',
  'Conflicts',
  'Settings',
};

/// Goes to [label]. On a phone that is the overflow menu; with the desktop
/// sidebar on screen, navigation entries are taken from the sidebar (the menu
/// keeps layout, sort and Empty Trash only).
Future<void> menuTap(WidgetTester tester, String label) async {
  final side = find.byType(DesktopSidebar);
  if (side.evaluate().isNotEmpty && _sidebarViews.contains(label)) {
    await tester.tap(
      find.descendant(of: side, matching: find.text(label)).first,
    );
    await tester.pumpAndSettle();
    return;
  }
  await openMenu(tester);
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// Long-press the card showing [title] to start selecting.
Future<void> selectByLongPress(WidgetTester tester, String title) async {
  await tester.longPress(find.text(title));
  await tester.pumpAndSettle();
}

Future<void> tapTip(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
}

/// The library's vertical scroll position (not the folder strip's).
ScrollPosition scrollPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

/// Like `screenshot` from test/support, but captures the whole view including
/// menus, dialogs and snackbars (which live in overlay routes).
Future<void> shot(WidgetTester tester, String name) async {
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(
      Offset.zero & (view.size * tester.view.devicePixelRatio),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
