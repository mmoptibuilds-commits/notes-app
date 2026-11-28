import 'dart:async';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../core/version_vector.dart';
import '../../core/ids.dart';
import '../../data/editor_save_barrier.dart';
import '../../data/editor_draft.dart';
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
class EditorSession extends ChangeNotifier implements EditorSaveParticipant {
  EditorSession({
    required this.repo,
    this.saveBarrier,
    String? noteId,
    String? folderId,
    this.useCompletedSection = true,
    PendingEditorDraft? recoveredDraft,
    this.autosaveDelay = const Duration(milliseconds: 700),
    this.retryDelay = const Duration(seconds: 3),
    this.onConflictCopy,
  }) : _id = recoveredDraft?.noteId ?? noteId,
       _draftId = recoveredDraft?.id ?? newId(),
       _recoveringDraft = recoveredDraft != null,
       folderId = recoveredDraft == null ? folderId : recoveredDraft.folderId {
    _draftLease = repo.acquireEditorDraftLease(_draftId);
    var draftToLoad = recoveredDraft;
    try {
      if (_draftLease == null && recoveredDraft != null) {
        _readOnly = true;
        loadError =
            'This recovery draft is already open in another Notes window.';
      } else if (_draftLease == null) {
        throw StateError('Notes could not claim a new editor session.');
      } else {
        if (recoveredDraft != null) {
          // The recovery list may hold an older snapshot than the latest failed
          // save. Read the durable row only after claiming the per-draft lease.
          draftToLoad = repo.pendingEditorDraft(_draftId);
          if (draftToLoad == null) {
            _id = null;
            _recoveringDraft = false;
            _readOnly = true;
            recoveryDraftUnavailable = true;
            loadError = const EditorDraftUnavailableException().toString();
          } else {
            _id = draftToLoad.noteId;
            this.folderId = draftToLoad.folderId;
          }
        }
      }
      _load(draftToLoad);
    } on Object {
      _draftLease?.release();
      _draftLease = null;
      rethrow;
    }
    saveBarrier?.register(this);
    if (draftToLoad != null && loadError == null) {
      _lastSerializedBody = draftToLoad.body;
      _serializedCurrent = true;
      recoveryCopySaved = true;
      recoveryCopyCurrent = true;
      _markDirty();
    }
  }

  final NoteRepository repo;
  final EditorSaveBarrier? saveBarrier;
  String? folderId;
  final String _draftId;
  bool _recoveringDraft;
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
  bool _frozenForUpdate = false;
  Timer? _timer;
  bool _extractScheduled = false;
  SaveStatus status = SaveStatus.idle;
  Object? lastError;
  Object? recoverySaveError;
  bool recoveryCopySaved = false;
  bool recoveryCopyCurrent = false;
  bool recoveryCopyIsPlainTextFallback = false;
  bool recoveryDraftUnavailable = false;
  String? _lastSerializedBody;
  bool _serializedCurrent = false;

  /// Set when the stored body could not be read as a document. The editor is
  /// then read-only and nothing is ever written, so the stored bytes survive.
  String? loadError;

  /// The note being edited; null until the first save of a new note.
  String? get noteId => _id;

  /// True for a note in Trash: shown read-only until restored.
  bool get readOnly => _readOnly || _frozenForUpdate;
  bool get isTrashed =>
      _readOnly && loadError == null && !recoveryDraftUnavailable;
  bool get frozenForUpdate => _frozenForUpdate;
  bool _readOnly = false;
  EditorDraftLease? _draftLease;

  @override
  bool get hasUnconfirmedSaves => _dirty;

  /// Checked items currently held in the completed section.
  List<CompletedLine> get completed => _projection.completed;

  void _load(PendingEditorDraft? recoveredDraft) {
    Delta visible;
    final id = _id;
    if (recoveredDraft != null) {
      _base = VersionVector.decode(recoveredDraft.baseVv);
      final original = recoveredDraft.noteId == null
          ? null
          : repo.getRecord(recoveredDraft.noteId!);
      if (original == null || original.purged || original.trashedAt != null) {
        // Do not write over a purged or trashed note when recovering old text.
        // Recover it as a new note instead.
        _id = null;
      }
      title = TextEditingController(text: recoveredDraft.title);
      try {
        final canonical = deltaFromBody(recoveredDraft.body);
        if (useCompletedSection) {
          final s = ChecklistProjection.split(canonical);
          visible = s.visible;
          _projection = s.projection;
        } else {
          visible = canonical;
        }
      } on FormatException catch (e) {
        loadError = 'This saved draft could not be read: ${e.message}';
        visible = Delta()..insert('\n');
        _readOnly = true;
      }
    } else if (id == null) {
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
    if (_frozenForUpdate) {
      _applying = true;
      try {
        title.text = _lastTitle;
      } finally {
        _applying = false;
      }
      return;
    }
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
    _markDirty(allowFrozen: true);
  }

  void _extract() {
    if (_disposed) {
      _extractScheduled = false;
      return;
    }
    if (_frozenForUpdate) return;
    _extractScheduled = false;
    final change = _projection.extractChecked(quill.document.toDelta());
    if (change != null) _applyProjectionChange(change);
  }

  /// Applies a change that the projection already accounted for. Undo
  /// history is dropped: undoing across it would act on text that has moved.
  void _applyProjectionChange(Delta change) {
    if (_frozenForUpdate) return;
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
    if (readOnly) return;
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
    if (readOnly) return const [];
    final gone = _projection.remove(ids);
    if (gone.isNotEmpty) {
      _markDirty();
      notifyListeners();
    }
    return gone;
  }

  void undoDelete(List<CompletedLine> lines) {
    if (readOnly) return;
    _projection.putBack(lines);
    _markDirty();
    notifyListeners();
  }

  // ------------------------------------------------------------- saving

  void _markDirty({bool allowFrozen = false}) {
    if (_disposed || _readOnly || (_frozenForUpdate && !allowFrozen)) return;
    _dirty = true;
    _serializedCurrent = false;
    recoveryCopyCurrent = false;
    recoveryCopyIsPlainTextFallback = false;
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

  String _plainTextForRecovery() {
    try {
      final merged = _projection.merge(quill.document.toDelta());
      final text = StringBuffer();
      for (final op in merged.toList()) {
        final value = op.data;
        if (value is String) {
          text.write(value);
        } else if (value is Map && value.containsKey('image')) {
          text.write('[Image]');
        }
      }
      return text.toString();
    } on Object {
      final visible = quill.document.toPlainText().trimRight();
      final completed = _projection.completed
          .map((line) => line.text)
          .where((line) => line.isNotEmpty)
          .join('\n');
      return [visible, completed].where((part) => part.isNotEmpty).join('\n');
    }
  }

  @override
  void freezeForUpdate() {
    if (_disposed || _frozenForUpdate) return;
    _frozenForUpdate = true;
    quill.readOnly = true;
    notifyListeners();
  }

  @override
  void unfreezeAfterUpdate() {
    if (_disposed || !_frozenForUpdate) return;
    _frozenForUpdate = false;
    quill.readOnly = _readOnly;
    if (_extractScheduled) _extract();
    notifyListeners();
  }

  @override
  Future<void> flushForUpdate() async {
    if (_disposed) return;
    _flushPending(duringUpdateBarrier: true);
    if (_dirty) throw const EditorSaveBarrierException();
  }

  /// Plain text of the whole note, title first, completed items included.
  String plainText() {
    final body = digestBody(bodyFromDelta(canonicalDelta())).plainText;
    final t = title.text.trim();
    return t.isEmpty ? body : (body.isEmpty ? t : '$t\n\n$body');
  }

  /// Writes pending edits now. Safe to call at any time; does nothing when
  /// there is nothing to write.
  void flush() {
    _flushPending();
  }

  void _flushPending({bool duringUpdateBarrier = false}) {
    _timer?.cancel();
    _timer = null;
    if (!_dirty ||
        _readOnly ||
        (_frozenForUpdate && !duringUpdateBarrier) ||
        _disposed) {
      return;
    }
    final t = title.text;
    String? body;
    try {
      body = bodyFromDelta(canonicalDelta());
      _lastSerializedBody = body;
      _serializedCurrent = true;
      final id = _id;
      if (id == null) {
        if (t.trim().isEmpty && digestBody(body).isBlank) {
          repo.discardPendingEditorDraft(_draftId);
          _recoveringDraft = false;
          recoveryCopySaved = false;
          recoveryCopyCurrent = false;
          recoveryCopyIsPlainTextFallback = false;
          _dirty = false;
          status = SaveStatus.idle;
          notifyListeners();
          return;
        }
      }
      final r = repo.writeEditorContent(
        draftId: _draftId,
        noteId: id,
        title: t,
        body: body,
        base: _base,
        requirePendingDraft: _recoveringDraft || recoveryCopySaved,
        recoveringDraft: _recoveringDraft,
        folderId: folderId,
      );
      _id = r.noteId;
      _base = VersionVector.decode(r.baseVv);
      _recoveringDraft = false;
      if (r.conflictCopyId != null) onConflictCopy?.call(r.conflictCopyId!);
      _dirty = false;
      lastError = null;
      recoverySaveError = null;
      recoveryCopySaved = false;
      recoveryCopyCurrent = false;
      recoveryCopyIsPlainTextFallback = false;
      status = SaveStatus.idle;
    } on EditorDraftUnavailableException catch (e) {
      // Another screen recovered or discarded this row first. In particular,
      // do not turn its confirmed discard back into a new recovery copy.
      _markRecoveryDraftUnavailable(e);
    } on Object catch (e) {
      lastError = e;
      status = SaveStatus.failed;
      if (body == null) {
        try {
          // Keep the latest title and visible text if canonical Delta encoding
          // itself fails. Formatting and embeds may need checking on recovery,
          // but the typed words survive closing or an update.
          body = bodyFromPlainText(_plainTextForRecovery());
          _lastSerializedBody = body;
          _serializedCurrent = true;
          recoveryCopyIsPlainTextFallback = true;
          recoverySaveError = e;
        } on Object catch (fallbackError) {
          _serializedCurrent = false;
          recoveryCopyCurrent = false;
          recoverySaveError = fallbackError;
        }
      }
      if (body != null) {
        recoveryCopyCurrent = false;
        try {
          final pending = repo.savePendingEditorDraftFromHandoff(
            PendingEditorDraft(
              id: _draftId,
              noteId: _id,
              folderId: folderId,
              title: t,
              body: body,
              baseVv: _base.encode(),
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
            requireExisting: _recoveringDraft || recoveryCopySaved,
          );
          if (pending) {
            recoveryCopySaved = true;
            recoveryCopyCurrent = true;
            if (!recoveryCopyIsPlainTextFallback) recoverySaveError = null;
          } else {
            _markRecoveryDraftUnavailable(
              const EditorDraftUnavailableException(),
            );
          }
        } on Object catch (draftError) {
          recoverySaveError = draftError;
        }
      }
      if (!recoveryDraftUnavailable) _timer = Timer(retryDelay, flush);
    }
    if (!_disposed) notifyListeners();
  }

  void _markRecoveryDraftUnavailable(Object error) {
    _timer?.cancel();
    _timer = null;
    _dirty = false;
    _readOnly = true;
    quill.readOnly = true;
    recoveryDraftUnavailable = true;
    recoveryCopySaved = false;
    recoveryCopyCurrent = false;
    lastError = error;
    recoverySaveError = error;
    status = SaveStatus.failed;
  }

  // ---------------------------------------------------- note operations

  /// Makes sure the note exists in the library (saving pending text) and
  /// returns its id, or null if there is nothing to store yet.
  String? ensureStored() {
    if (_frozenForUpdate) return _id;
    flush();
    return _id;
  }

  NoteRecord? get stored => _id == null ? null : repo.getRecord(_id!);

  void setPinned(bool v) {
    if (readOnly) return;
    final id = ensureStored();
    if (id != null) repo.setPinned([id], v);
  }

  void setArchived(bool v) {
    if (readOnly) return;
    final id = ensureStored();
    if (id != null) repo.setArchived([id], v);
  }

  void trash() {
    if (readOnly) return;
    final id = ensureStored();
    if (id != null) repo.trash([id]);
  }

  /// Takes a trashed note out of Trash and makes it editable.
  void restoreFromTrash() {
    final id = _id;
    if (id == null || _frozenForUpdate || recoveryDraftUnavailable) return;
    repo.restore([id]);
    if (loadError == null) {
      _readOnly = false;
      quill.readOnly = false;
      notifyListeners();
    }
  }

  void moveToFolder(String? folderId) {
    if (readOnly) return;
    final id = ensureStored();
    if (id != null) repo.moveToFolder([id], folderId);
  }

  @override
  void dispose() {
    try {
      flush();
    } on Object catch (e) {
      lastError ??= e;
      status = SaveStatus.failed;
    }
    try {
      if (_dirty &&
          !_readOnly &&
          loadError == null &&
          _serializedCurrent &&
          _lastSerializedBody != null &&
          !recoveryCopyCurrent) {
        // The last save failed (disk full, database busy...). The editor is
        // going away. The background retry uses the already serialized
        // snapshot rather than serializing a second time during disposal. If
        // saving the recovery row also failed, the handoff keeps retrying it.
        final handoff = _PendingEditorSave(
          repo: repo,
          barrier: saveBarrier,
          draftId: _draftId,
          lease: _draftLease!,
          noteId: _id,
          title: title.text,
          body: _lastSerializedBody!,
          base: _base,
          folderId: folderId,
          requireExisting: recoveryCopySaved,
          retryDelay: retryDelay,
        );
        _draftLease = null;
        try {
          handoff.start();
        } on Object {
          handoff.release();
          rethrow;
        }
      }
    } on Object catch (e) {
      recoverySaveError = e;
    } finally {
      _disposed = true;
      try {
        _draftLease?.release();
      } on Object {
        // Continue disposing every editor resource.
      } finally {
        _draftLease = null;
      }
      _timer?.cancel();
      _timer = null;
      try {
        saveBarrier?.unregister(this);
      } on Object {
        // Continue disposing every editor resource.
      }
      try {
        title.dispose();
      } on Object {
        // Continue disposing every editor resource.
      }
      try {
        scroll.dispose();
      } on Object {
        // Continue disposing every editor resource.
      }
      try {
        quill.dispose();
      } on Object {
        // Continue disposing every editor resource.
      }
      super.dispose();
    }
  }
}

/// Keeps a failed snapshot visible to the update barrier after its editor has
/// been disposed, while continuing the normal background retry.
class _PendingEditorSave implements EditorSaveParticipant {
  _PendingEditorSave({
    required this.repo,
    required this.barrier,
    required this.draftId,
    required this.lease,
    required this.noteId,
    required this.title,
    required this.body,
    required this.base,
    required this.folderId,
    required this.requireExisting,
    required this.retryDelay,
  });

  final NoteRepository repo;
  final EditorSaveBarrier? barrier;
  final String draftId;
  final EditorDraftLease lease;
  final String? noteId;
  final String? folderId;
  final bool requireExisting;
  final Duration retryDelay;
  final String title;
  final String body;
  final VersionVector base;
  Timer? _retry;
  Future<void>? _inFlight;
  var _pending = true;
  var _attempts = 0;

  @override
  bool get hasUnconfirmedSaves => _pending;

  void start() {
    if (barrier != null) barrier!.register(this);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_pending) return;
    _retry?.cancel();
    var delayMilliseconds = retryDelay.inMilliseconds;
    if (delayMilliseconds < 1) delayMilliseconds = 1;
    for (var i = 0; i < _attempts && delayMilliseconds < 60000; i++) {
      delayMilliseconds *= 2;
    }
    if (delayMilliseconds > 60000) delayMilliseconds = 60000;
    _retry = Timer(
      Duration(milliseconds: delayMilliseconds),
      () => unawaited(_attempt()),
    );
  }

  Future<void> _attempt() {
    final current = _inFlight;
    if (current != null) return current;
    final flight = _writeSnapshot();
    late final Future<void> tracked;
    tracked = flight.whenComplete(() {
      if (identical(_inFlight, tracked)) _inFlight = null;
    });
    _inFlight = tracked;
    return tracked;
  }

  Future<void> _writeSnapshot() async {
    if (!_pending) return;
    try {
      if (noteId == null && title.trim().isEmpty && digestBody(body).isBlank) {
        _finish();
        return;
      }
      repo.savePendingEditorDraftFromHandoff(
        PendingEditorDraft(
          id: draftId,
          noteId: noteId,
          folderId: folderId,
          title: title,
          body: body,
          baseVv: base.encode(),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        requireExisting: requireExisting,
      );
      _finish();
    } on Object {
      _attempts++;
      // Retry through the same conditional operation. A consumed or discarded
      // row must never be recreated by a delayed handoff.
      _scheduleRetry();
    }
  }

  void _finish() {
    _pending = false;
    _retry?.cancel();
    _retry = null;
    barrier?.unregister(this);
    lease.release();
  }

  void release() => _finish();

  @override
  void freezeForUpdate() {}

  @override
  void unfreezeAfterUpdate() {}

  @override
  Future<void> flushForUpdate() async {
    if (!_pending) return;
    _retry?.cancel();
    _retry = null;
    final current = _inFlight;
    if (current != null) await current;
    if (_pending) await _attempt();
    if (_pending) throw const EditorSaveBarrierException();
  }
}
