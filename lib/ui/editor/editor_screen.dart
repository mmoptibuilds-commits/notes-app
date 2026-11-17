import '../material.dart';

/// Opens the editor. With [noteId] it edits that note; without, it starts a
/// new untitled note (stored on the first real content) in [folderId].
Future<void> openEditor(
  BuildContext context, {
  String? noteId,
  String? folderId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => EditorScreen(noteId: noteId, folderId: folderId),
  ),
);

/// Placeholder until the editor lands.
class EditorScreen extends StatelessWidget {
  const EditorScreen({super.key, this.noteId, this.folderId});

  final String? noteId;
  final String? folderId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: Center(child: Text(noteId ?? 'New note')),
  );
}
