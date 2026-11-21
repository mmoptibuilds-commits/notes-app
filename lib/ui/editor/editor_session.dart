import 'dart:async';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../core/version_vector.dart';
import '../../data/models.dart';
import '../../data/note_repository.dart';
import '../../doc/checklist_projection.dart';
import '../../doc/delta_text.dart';
import 'observed_document.dart';

enum SaveStatus {
  /// Nothing to save.
  idle,

  /// Edits waiting for the autosave timer.
  pending,

  /// Last write failed; will retry.
  failed,
}

/// Everything behind the editor screen except widgets: the document, the
/// completed-checklist projection, autosave and the note's identity.
///
/// Rules this class guarantees:
///  * Opening a note writes nothing.
///  * A new note is only stored once it has real content.
///  * The document the user sees is never replaced behind their back: sync
///    that lands while editing becomes a conflict copy at the next save.
///  * Whatever the checklist projection hides is saved back in place.
class EditorSession extends ChangeNotifier {
  EditorSession({
    required this.repo,
    String? noteId,
    this.folderId,
    this.useCompletedSection = true,
    this.autosaveDelay = const Duration(milliseconds: 700),
    this.retryDelay = const Duration(seconds: 3),
    this.onConflictCopy,
  }) : _id = noteId {
    _load();
  }

  final NoteRepository repo;
  final String? folderId;
  final bool useCompletedSection;
  final Duration autosaveDelay;
  final Duration retryDelay;

  /// Called when saving found that the stored note had changed underneath and
  /// kept that version as a separate note.
  final void Function(String conflictCopyId)? onConflictCopy;

  late final QuillController quill;
  late final TextEditingController title;
  late final ScrollController scroll = ScrollController();
  ChecklistProjection _projection = ChecklistProjection.split(
    Delta()..insert('\n'),
  ).projection;

  String? _id;
  VersionVector _base = VersionVector.empty;
  bool _dirty = false;
  bool _applying = false;
  bool _disposed = false;
  Timer? _timer;
  bool _extractScheduled = false;
  SaveStatus status = SaveStatus.idle;
  Object? lastError;

  /// Set when the stored body could not be read as a document. The editor is
  /// then read-only and nothing is ever written, so the stored bytes survive.
  String? loadError;

  /// The note being edited; null until the first save of a new note.
  String? get noteId => _id;

  /// True for a note in Trash: shown read-only until restored.
  bool get readOnly => _readOnly;
  bool _readOnly = false;

  /// Checked items currently held in the completed section.
  List<CompletedLine> get completed => _projection.completed;

  void _load() {
    Delta visible;
    final id = _id;
    if (id == null) {
      visible = Delta()..insert('\n');
      title = TextEditingController();
    } else {
      final note = repo.getNote(id);
      if (note == null) {
        loadError = 'This note no longer exists.';
        visible = Delta()..insert('\n');
        title = TextEditingController();
        _readOnly = true;
      } else {
        title = TextEditingController(text: note.title);
        _base = note.contentVv;
        _readOnly = note.isTrashed;
        try {
          final canonical = deltaFromBody(note.body);
          if (useCompletedSection) {
            final s = ChecklistProjection.split(canonical);
            visible = s.visible;
            _projection = s.projection;
          } else {
            visible = canonical;
          }
        } on FormatException catch (e) {
          loadError = 'This note could not be read: ${e.message}';
          visible = Delta()..insert('\n');
          _readOnly = true;
        }
      }
    }
    final document = ObservedDocument.fromDelta(visible)
      ..onCompose = _onCompose;
    quill = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
      readOnly: _readOnly,
    );
    _lastTitle = title.text;
    title.addListener(_onTitleChanged);
  }

  String _lastTitle = '';
  void _onTitleChanged() {
    if (_applying || title.text == _lastTitle) return;
    _lastTitle = title.text;
    _markDirty();
  }

  /// Called synchronously for every change to the document.
  void _onCompose(Delta change) {
    if (_applying) return;
    _projection.transformBy(change);
    if (useCompletedSection &&
        !_extractScheduled &&
        ChecklistProjection.mayCheck(change)) {
      // Moving a line out of the document right now would pull the text
      // from under the editor while it is still finishing this edit (cursor
      // placement, checkbox handling). Do it as soon as the edit is over.
      _extractScheduled = true;
      // Quill restores its selection in a post-frame callback after handling
      // a checklist tap. Register our callback from a microtask so Quill's
      // callback is already queued and the final selection is transformed
      // against the removed line.
      scheduleMicrotask(() {
        if (_disposed) {
          _extractScheduled = false;
          return;
        }
        try {
          SchedulerBinding.instance.addPostFrameCallback((_) => _extract());
        } on FlutterError {
          // EditorSession is also exercised without a WidgetsBinding in its
          // pure session tests; there is no frame ordering to wait for there.
          _extract();
        }
      });
    }
    _markDirty();
  }

  void _extract() {
    _extractScheduled = false;
    if (_disposed) return;
    final change = _projection.extractChecked(quill.document.toDelta());
    if (change != null) _applyProjectionChange(change);
  }

  /// Applies a change that the projection already accounted for. Undo
  /// history is dropped: undoing across it would act on text that has moved.
  void _applyProjectionChange(Delta change) {
    _applying = true;
    try {
      quill.compose(change, quill.selection, ChangeSource.silent);
      quill.document.history.clear();
    } finally {
      _applying = false;
    }
    notifyListeners();
  }

  // --------------------------------------------------- completed section

  /// Puts completed items back into the document, unchecked, where they were.
  void restoreCompleted(Iterable<int> ids) {
    final change = _projection.restore(ids, quill.document.toDelta());
    if (change == null) return;
    _applyProjectionChange(change);
    _markDirty();
  }

  void uncheckAllCompleted() =>
      restoreCompleted([for (final c in completed) c.id]);

  /// Deletes completed items. Returns them so the caller can offer
  /// [undoDelete].
  List<CompletedLine> deleteCompleted(Iterable<int> ids) {
    final gone = _projection.remove(ids);
    if (gone.isNotEmpty) {
      _markDirty();
      notifyListeners();
    }
    return gone;
  }

  void undoDelete(List<CompletedLine> lines) {
    _projection.putBack(lines);
    _markDirty();
    notifyListeners();
  }

  // ------------------------------------------------------------- saving

  void _markDirty() {
    if (_disposed || _readOnly) return;
    _dirty = true;
    final wasPending = status == SaveStatus.pending;
    status = SaveStatus.pending;
    _timer?.cancel();
    _timer = Timer(autosaveDelay, flush);
    if (!wasPending) notifyListeners();
  }

  /// Drops pending edits after the repository reports a permanent deletion.
  /// Disposing this session must not flush those edits over the tombstone.
  void discardPendingChanges() {
    _timer?.cancel();
    _timer = null;
    _dirty = false;
    _readOnly = true;
    quill.readOnly = true;
    status = SaveStatus.idle;
  }

  /// The complete document as it should be stored.
  Delta canonicalDelta() => _projection.merge(quill.document.toDelta());

  /// Plain text of the whole note, title first, completed items included.
  String plainText() {
    final body = digestBody(bodyFromDelta(canonicalDelta())).plainText;
    final t = title.text.trim();
    return t.isEmpty ? body : (body.isEmpty ? t : '$t\n\n$body');
  }

  /// Writes pending edits now. Safe to call at any time; does nothing when
  /// there is nothing to write.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (!_dirty || _readOnly || _disposed) return;
    final body = bodyFromDelta(canonicalDelta());
    final t = title.text;
    try {
      final id = _id;
      if (id == null) {
        if (t.trim().isEmpty && digestBody(body).isBlank) {
          _dirty = false;
          status = SaveStatus.idle;
          notifyListeners();
          return;
        }
        final note = repo.createNote(title: t, body: body, folderId: folderId);
        _id = note.id;
        _base = note.contentVv;
      } else {
        final r = repo.saveContent(id, title: t, body: body, base: _base);
        _base = r.contentVv;
        if (r.conflictCopyId != null) onConflictCopy?.call(r.conflictCopyId!);
      }
      _dirty = false;
      lastError = null;
      status = SaveStatus.idle;
    } on Object catch (e) {
      lastError = e;
      status = SaveStatus.failed;
      _timer = Timer(retryDelay, flush);
    }
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------- note operations

  /// Makes sure the note exists in the library (saving pending text) and
  /// returns its id, or null if there is nothing to store yet.
  String? ensureStored() {
    flush();
    return _id;
  }

  NoteRecord? get stored => _id == null ? null : repo.getRecord(_id!);

  void setPinned(bool v) {
    final id = ensureStored();
    if (id != null) repo.setPinned([id], v);
  }

  void setArchived(bool v) {
    final id = ensureStored();
    if (id != null) repo.setArchived([id], v);
  }

  void trash() {
    final id = ensureStored();
    if (id != null) repo.trash([id]);
  }

  /// Takes a trashed note out of Trash and makes it editable.
  void restoreFromTrash() {
    final id = _id;
    if (id == null) return;
    repo.restore([id]);
    if (loadError == null) {
      _readOnly = false;
      quill.readOnly = false;
      notifyListeners();
    }
  }

  void moveToFolder(String? folderId) {
    final id = ensureStored();
    if (id != null) repo.moveToFolder([id], folderId);
  }

  @override
  void dispose() {
    flush();
    if (_dirty && !_readOnly && loadError == null) {
      // The last save failed (disk full, database busy...). The editor is
      // going away, so this is the only copy of the typed text: keep trying
      // in the background rather than drop it.
      _handOff(_id, title.text, bodyFromDelta(canonicalDelta()), _base);
    }
    _disposed = true;
    _timer?.cancel();
    title.dispose();
    scroll.dispose();
    quill.dispose();
    super.dispose();
  }

  /// Keeps retrying a save after the editor is closed.
  void _handOff(String? id, String t, String body, VersionVector base) {
    var attempts = 0;
    void attempt() {
      try {
        if (id == null) {
          if (t.trim().isEmpty && digestBody(body).isBlank) return;
          repo.createNote(title: t, body: body, folderId: folderId);
        } else {
          repo.saveContent(id, title: t, body: body, base: base);
        }
      } on Object {
        if (++attempts < 2000) Timer(retryDelay, attempt);
      }
    }

    Timer(retryDelay, attempt);
  }
}
