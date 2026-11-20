/// Creates deterministic, synthetic Notes databases for local performance work.
///
/// Usage: `dart tool/perf/seed_library.dart --dir <empty-directory>`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';

const _datasets = ['empty', '50', '500', 'large'];
const _words = [
  'meeting',
  'budget',
  'groceries',
  'travel',
  'recipe',
  'project',
  'idea',
  'draft',
  'invoice',
  'garden',
  'router',
  'password',
  'lecture',
  'workout',
  'receipt',
  'reading',
  'plan',
  'quarterly',
  'holiday',
  'backup',
];

/// Builds one dataset below [root]. Each database is named `notes.db`.
///
/// The root must be empty. [forceEmptyTemp] permits replacement of generated
/// dataset directories only when [root] is beneath the system temp directory.
void seedLibrary(Directory root, {bool forceEmptyTemp = false}) {
  final rootPath = _canonical(root.path);
  final configuredDataDir = Platform.environment['NOTES_DATA_DIR'];
  if (configuredDataDir != null) {
    final dataPath = _canonical(configuredDataDir);
    if (rootPath == dataPath || p.isWithin(dataPath, rootPath)) {
      throw ArgumentError('Refusing to seed inside NOTES_DATA_DIR.');
    }
  }
  final tempPath = _canonical(Directory.systemTemp.path);
  if (forceEmptyTemp && !p.isWithin(tempPath, rootPath)) {
    throw ArgumentError(
      '--force-empty-temp is allowed only under system temp.',
    );
  }

  root.createSync(recursive: true);
  final existing = root.listSync(followLinks: false).toList();
  if (existing.isNotEmpty) {
    if (!forceEmptyTemp) {
      throw ArgumentError('Output directory must be empty: $rootPath');
    }
    for (final entity in existing) {
      final name = p.basename(entity.path);
      const generatedFiles = [
        'notes.db',
        'notes.db-wal',
        'notes.db-shm',
        'dev.key',
      ];
      if (entity is File && generatedFiles.contains(name)) continue;
      if (entity is! Directory || !_datasets.contains(name)) {
        throw ArgumentError(
          'Refusing to replace unexpected path: ${entity.path}',
        );
      }
      final files = entity.listSync(followLinks: false);
      if (files.any(
        (file) => !generatedFiles.contains(p.basename(file.path)),
      )) {
        throw ArgumentError(
          'Refusing to replace unexpected files in ${entity.path}',
        );
      }
    }
    for (final entity in existing) {
      entity.deleteSync(recursive: true);
    }
  }

  _createDataset(root, 'empty', 0);
  _createDataset(root, '50', 50);
  _createDataset(root, '500', 500);
  _createDataset(root, 'large', 0, includeLarge: true);
}

void _createDataset(
  Directory root,
  String name,
  int count, {
  bool includeLarge = false,
}) {
  final dir = Directory(p.join(root.path, name))..createSync();
  final key = Uint8List.fromList(
    List.generate(32, (i) => (i * 29 + 17) & 0xff),
  );
  File(p.join(dir.path, 'dev.key')).writeAsStringSync(base64Encode(key));
  final db = AppDatabase.open(p.join(dir.path, 'notes.db'), key: key);
  try {
    final repo = NoteRepository(db);
    final random = Random(4107);
    db.transaction(() {
      for (var i = 0; i < count; i++) {
        final title =
            'Synthetic ${i.toString().padLeft(4, '0')} ${_phrase(random, 4)}';
        final ops = <Map<String, Object>>[
          {'insert': 'Dataset note $i: ${_phrase(random, 24)}\n'},
          {
            'insert': 'A formatted phrase\n',
            'attributes': {'bold': true},
          },
          {
            'insert': 'A checklist item\n',
            'attributes': {'list': i.isEven ? 'checked' : 'unchecked'},
          },
        ];
        repo.createNote(title: title, body: jsonEncode(ops));
      }
    });
    if (includeLarge) {
      repo.createNote(
        title: 'Synthetic large rich document',
        body: syntheticLargeBody(),
      );
    }
  } finally {
    db.close();
  }
}

/// A deterministic, mixed-format Delta JSON body between 180 and 220 KiB.
String syntheticLargeBody() {
  final random = Random(91231);
  final ops = <Map<String, Object>>[];
  for (var line = 0; line < 220; line++) {
    final text = List.generate(
      20,
      (_) => _words[random.nextInt(_words.length)],
    ).join(' ');
    final format = switch (line % 4) {
      0 => <String, Object>{'bold': true},
      1 => <String, Object>{'italic': true},
      2 => <String, Object>{'code': true},
      _ => <String, Object>{'link': 'https://example.invalid/$line'},
    };
    ops.add({'insert': '$text ' * 5, 'attributes': format});
    ops.add({
      'insert': '\n',
      'attributes': {'list': line % 2 == 0 ? 'unchecked' : 'checked'},
    });
  }
  return jsonEncode(ops);
}

String _phrase(Random random, int words) => List.generate(
  words,
  (_) => _words[random.nextInt(_words.length)],
).join(' ');

String _canonical(String path) {
  final absolute = p.normalize(p.absolute(path));
  final entityType = FileSystemEntity.typeSync(absolute, followLinks: true);
  return entityType == FileSystemEntityType.notFound
      ? absolute
      : Directory(absolute).resolveSymbolicLinksSync();
}

Future<void> main(List<String> args) async {
  String? path;
  var force = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--dir' && path == null && i + 1 < args.length) {
      path = args[++i];
    } else if (args[i] == '--force-empty-temp' && !force) {
      force = true;
    } else {
      stderr.writeln(
        'Usage: dart tool/perf/seed_library.dart --dir <empty-directory> [--force-empty-temp]',
      );
      exitCode = 2;
      return;
    }
  }
  if (path == null) {
    stderr.writeln(
      'Usage: dart tool/perf/seed_library.dart --dir <empty-directory> [--force-empty-temp]',
    );
    exitCode = 2;
    return;
  }
  try {
    seedLibrary(Directory(path), forceEmptyTemp: force);
    stdout.writeln(
      'Created empty, 50-note, 500-note and large-document datasets in ${p.absolute(path)}',
    );
  } on Object catch (error) {
    stderr.writeln('Synthetic dataset creation failed: $error');
    exitCode = 1;
  }
}
