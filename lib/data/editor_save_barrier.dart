import 'dart:async';

/// A live editor or a save snapshot handed off by a disposed editor.
abstract interface class EditorSaveParticipant {
  bool get hasUnconfirmedSaves;

  void freezeForUpdate();
  void unfreezeAfterUpdate();
  Future<void> flushForUpdate();
}

/// Coordinates editor persistence before Linux replaces the running program.
/// A successful prepare keeps editors frozen until [release] is called; a
/// failed prepare releases them so the user can fix the save and retry.
class EditorSaveBarrier {
  EditorSaveBarrier({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;
  final Set<EditorSaveParticipant> _participants = {};
  Future<void>? _inFlight;
  bool _frozen = false;
  bool _prepared = false;

  bool get frozen => _frozen;

  void register(EditorSaveParticipant participant) {
    _participants.add(participant);
    if (_frozen) participant.freezeForUpdate();
  }

  void unregister(EditorSaveParticipant participant) {
    _participants.remove(participant);
  }

  /// Freezes all current and newly registered editors, then waits until every
  /// dirty editor and disposed-editor handoff confirms its save.
  Future<void> prepare() {
    if (_prepared) return Future<void>.value();
    final current = _inFlight;
    if (current != null) return current;

    final flight = _prepare();
    late final Future<void> tracked;
    tracked = flight.whenComplete(() {
      if (identical(_inFlight, tracked)) _inFlight = null;
    });
    _inFlight = tracked;
    return tracked;
  }

  Future<void> _prepare() async {
    _frozen = true;
    try {
      for (final participant in _participants.toList()) {
        participant.freezeForUpdate();
      }
      while (true) {
        final pending = _participants
            .where((participant) => participant.hasUnconfirmedSaves)
            .toList();
        if (pending.isEmpty) break;
        await Future.wait(
          pending.map((participant) => participant.flushForUpdate()),
        ).timeout(timeout);
        if (pending.any((participant) => participant.hasUnconfirmedSaves)) {
          throw const _SaveNotConfirmed();
        }
      }
      if (_participants.any((participant) => participant.hasUnconfirmedSaves)) {
        throw const _SaveNotConfirmed();
      }
      _prepared = true;
    } on Object {
      release();
      throw const EditorSaveBarrierException();
    }
  }

  /// Releases a successful prepare when helper setup fails, or an incomplete
  /// prepare after a save failure. Safe to call more than once.
  void release() {
    if (!_frozen && !_prepared) return;
    _frozen = false;
    _prepared = false;
    for (final participant in _participants.toList()) {
      try {
        participant.unfreezeAfterUpdate();
      } on Object {
        // Release every editor even if one listener fails during notification.
      }
    }
  }
}

/// A save could not be confirmed. Notes must remain open and the install must
/// not start its helper.
class EditorSaveBarrierException implements Exception {
  const EditorSaveBarrierException();

  @override
  String toString() => 'Editor saves were not confirmed.';
}

class _SaveNotConfirmed implements Exception {
  const _SaveNotConfirmed();
}
