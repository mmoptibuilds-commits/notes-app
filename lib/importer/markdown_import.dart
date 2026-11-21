import '../data/models.dart';
import '../data/note_repository.dart';
import '../doc/markdown.dart';

/// A Markdown file chosen for import: its file name and its text.
typedef MarkdownFile = ({String name, String text});

/// Creates one note per Markdown file, all in one transaction (either every
/// file becomes a note or none does). A leading `# Heading` becomes the title;
/// otherwise the file name without its extension does. Returns the new ids.
List<String> importMarkdownFiles(
  NoteRepository repo,
  List<MarkdownFile> files, {
  String? folderId,
}) {
  return repo.db.transaction(() {
    return [for (final f in files) _importOne(repo, f, folderId: folderId).id];
  });
}

/// Splits [text] into a title and the Markdown that remains.
({String title, String body}) splitMarkdownTitle(String text, String name) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  var i = 0;
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  final heading = i < lines.length
      ? RegExp(r'^#\s+(.+?)\s*#*\s*$').firstMatch(lines[i])
      : null;
  if (heading != null) {
    return (
      title: heading.group(1)!.trim(),
      body: lines.sublist(i + 1).join('\n'),
    );
  }
  final dot = name.lastIndexOf('.');
  return (title: dot > 0 ? name.substring(0, dot) : name, body: text);
}

Note _importOne(NoteRepository repo, MarkdownFile f, {String? folderId}) {
  final parts = splitMarkdownTitle(f.text, f.name);
  return repo.createNote(
    title: parts.title,
    body: markdownToDelta(parts.body),
    folderId: folderId,
  );
}
