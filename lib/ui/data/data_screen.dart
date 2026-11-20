import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../../app.dart';
import '../../importer/atomic_export.dart';
import '../../importer/legacy_backup.dart';
import '../../importer/notes_export.dart';
import '../../importer/notes_restore.dart';
import '../../platform/save_file.dart';
import '../material.dart';
import '../theme/app_theme.dart';

/// Import a legacy backup or this app's export, undo legacy imports, export.
class DataScreen extends StatefulWidget {
  const DataScreen({super.key, this.pickBackup, this.pickSaveFile});

  /// Replaceable for tests.
  final Future<XFile?> Function()? pickBackup;
  final Future<File?> Function(String suggestedName)? pickSaveFile;

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  bool _busy = false;
  static const _maxBackupBytes = 300 * 1024 * 1024;

  Future<XFile?> _pick() =>
      (widget.pickBackup ??
      () => openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Backup',
            extensions: ['json'],
            mimeTypes: ['application/json'],
          ),
        ],
      ))();

  void _setBusy(bool v) {
    if (mounted) setState(() => _busy = v);
  }

  Future<void> _import() async {
    final file = await _pick();
    if (file == null || !mounted) return;
    final name = file.name.isEmpty ? 'this backup' : file.name;
    String text;
    _setBusy(true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // A content URI may not support stat through dart:io. In that case,
      // XFile.readAsBytes() is the supported way to obtain its contents.
      try {
        if (await file.length() > _maxBackupBytes) {
          _say('That file is too large to be a notes backup.');
          return;
        }
      } on Object {
        // Check the byte length after reading when stat is unavailable.
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > _maxBackupBytes) {
        _say('That file is too large to be a notes backup.');
        return;
      }
      text = utf8.decode(bytes);
    } on FormatException catch (e) {
      _say('That file could not be read: ${e.message}');
      return;
    } on Object catch (e) {
      _say('That file could not be read: $e');
      return;
    } finally {
      _setBusy(false);
    }

    if (!mounted) return;
    if (_looksLikeNotesExport(text)) {
      await _restoreNotesExport(text, name);
    } else {
      await _importLegacy(text, name);
    }
  }

  Future<void> _restoreNotesExport(String text, String name) async {
    final app = AppScope.of(context);
    final restorer = NotesExportRestorer(app.notes);
    final NotesRestorePreview preview;
    _setBusy(true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      preview = restorer.inspect(text);
    } on FormatException catch (e) {
      _say('That Notes export could not be restored: ${e.message}');
      return;
    } finally {
      _setBusy(false);
    }
    if (!mounted) return;

    final go = await _confirm(
      title: 'Restore $name?',
      body:
          '${preview.summary()}\n\nSame-id records are merged using the '
          'sync rules. Newer local edits are kept, and concurrent edits get '
          'a conflict copy. A database snapshot is made before restore when '
          'the library is stored on disk.',
      action: 'Restore',
    );
    if (go != true || !mounted) return;
    _setBusy(true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final report = restorer.apply(
        text,
        snapshotPath: _snapshotPath(app.dataDir, app.db.path),
      );
      _setBusy(false);
      if (!mounted) return;
      await _info('Restore finished', report.summary());
    } on Object catch (e) {
      _say('The restore failed and nothing was changed. $e');
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _importLegacy(String text, String name) async {
    final app = AppScope.of(context);
    final importer = LegacyBackupImporter(app.notes);
    final ImportReport preview;
    _setBusy(true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      preview = importer.inspect(text, sourceName: name);
    } on LegacyBackupFormatException catch (e) {
      _say(e.message);
      return;
    } on FormatException catch (e) {
      _say('That file could not be read: ${e.message}');
      return;
    } finally {
      _setBusy(false);
    }
    if (!mounted) return;
    final go = await _confirm(
      title: 'Import $name?',
      body:
          '${preview.summary()}\n\nNothing is overwritten: notes you have '
          'edited here are kept, and you can undo the whole import afterwards.',
      action: 'Import',
    );
    if (go != true || !mounted) return;
    _setBusy(true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final report = importer.import(
        text,
        sourceName: name,
        snapshotPath: _snapshotPath(app.dataDir, app.db.path),
      );
      _setBusy(false);
      if (!mounted) return;
      await _info('Import finished', report.summary());
    } on Object catch (e) {
      _say('The import failed and nothing was changed. $e');
    } finally {
      _setBusy(false);
    }
  }

  String? _snapshotPath(String dataDir, String? dbPath) {
    if (dataDir.isEmpty || dbPath == null) return null;
    return p.join(
      dataDir,
      'backups',
      'before-import-${DateTime.now().millisecondsSinceEpoch}.db',
    );
  }

  bool _looksLikeNotesExport(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return false;
      return decoded['format'] == exportFormat ||
          (decoded.containsKey('deviceId') &&
              decoded.containsKey('folders') &&
              decoded.containsKey('attachments'));
    } on FormatException {
      return false;
    }
  }

  Future<void> _rollback(ImportBatchInfo b) async {
    final app = AppScope.of(context);
    final go = await _confirm(
      title: 'Undo this import?',
      body:
          'Notes it added are removed unless you have edited them since; '
          'notes it changed are put back as they were. Notes you edited stay.',
      action: 'Undo import',
      danger: true,
    );
    if (go != true || !mounted) return;
    final r = LegacyBackupImporter(app.notes).rollback(b.id);
    if (!mounted) return;
    setState(() {});
    await _info('Import undone', r.summary());
  }

  Future<void> _export() async {
    final app = AppScope.of(context);
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final name = 'notes-export-$stamp.json';
    File? target;
    final viaPicker = widget.pickSaveFile == null && usesNativeSavePicker;
    try {
      if (viaPicker) {
        // Android: the system "create document" picker; nothing to resolve here.
      } else if (widget.pickSaveFile != null) {
        target = await widget.pickSaveFile!(name);
      } else {
        final loc = await getSaveLocation(
          suggestedName: name,
          acceptedTypeGroups: const [
            XTypeGroup(label: 'JSON', extensions: ['json']),
          ],
        );
        if (loc != null) {
          final uri = Uri.tryParse(loc.path);
          target = uri?.scheme == 'file' ? File.fromUri(uri!) : File(loc.path);
        }
      }
    } on Object catch (e) {
      _say('The export could not start: $e');
      return;
    }
    if ((target == null && !viaPicker) || !mounted) return;
    setState(() => _busy = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final json = exportAll(app.notes);
      final count =
          app.notes.counts().active +
          app.notes.counts().archived +
          app.notes.counts().trash;
      if (viaPicker) {
        final saved = await saveBytesWithPicker(
          name: name,
          mime: 'application/json',
          bytes: Uint8List.fromList(utf8.encode(json)),
        );
        if (saved == null) return; // cancelled in the picker
        _say('Exported $count notes to $saved.');
      } else {
        await writeExportAtomically(target!, json);
        _say('Exported $count notes.');
      }
    } on Object catch (e) {
      _say('The export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
      );
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String action,
    bool danger = false,
  }) => showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: Text(
            action,
            style: danger ? TextStyle(color: AppPalette.of(c).danger) : null,
          ),
        ),
      ],
    ),
  );

  Future<void> _info(String title, String body) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    final batches = LegacyBackupImporter(app.notes).batches();
    return Scaffold(
      appBar: AppBar(title: const Text('Import and export')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
            children: [
              if (_busy) const LinearProgressIndicator(),
              _Group(
                title: 'Import',
                children: [
                  ListTile(
                    leading: const Icon(Icons.file_open_outlined),
                    title: const Text('Import a backup or Notes export'),
                    subtitle: const Text(
                      'Choose a Notebook backup from the old app or a Notes '
                      'export. You see what it contains before anything changes.',
                    ),
                    onTap: _busy ? null : _import,
                  ),
                ],
              ),
              if (batches.isNotEmpty)
                _Group(
                  title: 'Past imports',
                  children: [
                    for (final b in batches)
                      ListTile(
                        title: Text(b.sourceName ?? 'Backup'),
                        subtitle: Text(
                          '${DateTime.fromMillisecondsSinceEpoch(b.startedAt).toString().substring(0, 16)}'
                          '${b.report == null ? '' : ' · ${b.report!.sourceNotes} notes'}'
                          '${b.isRolledBack ? ' · undone' : ''}',
                          style: TextStyle(color: p.textMuted, fontSize: 12),
                        ),
                        trailing: b.isRolledBack
                            ? null
                            : TextButton(
                                onPressed: _busy ? null : () => _rollback(b),
                                child: const Text('Undo'),
                              ),
                      ),
                  ],
                ),
              _Group(
                title: 'Export',
                children: [
                  ListTile(
                    leading: const Icon(Icons.file_download_outlined),
                    title: const Text('Export all notes'),
                    subtitle: const Text(
                      'Saves every note, folder and image, including Trash, '
                      'as one JSON file. The file is not encrypted.',
                    ),
                    onTap: _busy ? null : _export,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text(
              title,
              style: TextStyle(
                color: p.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Material(
            color: p.card,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
              side: BorderSide(color: p.cardBorder),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}
