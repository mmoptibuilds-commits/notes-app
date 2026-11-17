import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// A [Document] that reports every change to [onCompose] synchronously,
/// before the call that caused it returns.
///
/// `Document.changes` is an asynchronous broadcast stream: by the time a
/// listener hears about a change, further changes may already have been
/// applied, so a listener cannot reliably pair a change with the document it
/// applies to. Everything that tracks positions (the checklist projection)
/// must see each change in order, against the right document. Typing, paste,
/// undo and redo all go through [compose].
class ObservedDocument extends Document {
  ObservedDocument.fromDelta(super.delta) : super.fromDelta();

  void Function(Delta change)? onCompose;

  @override
  void compose(Delta delta, ChangeSource changeSource) {
    super.compose(delta, changeSource);
    onCompose?.call(delta);
  }
}
