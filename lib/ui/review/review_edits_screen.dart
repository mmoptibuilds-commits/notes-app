import '../../app.dart';
import '../../data/models.dart';
import '../../data/note_repository.dart';
import '../../doc/delta_text.dart';
import '../material.dart';
import '../theme/app_theme.dart';
import '../widgets/touch.dart';

Future<void> openReviewEdits(BuildContext context, String noteId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReviewEditsScreen(noteId: noteId),
      ),
    );

class ReviewEditsScreen extends StatefulWidget {
  const ReviewEditsScreen({super.key, required this.noteId});
  final String noteId;

  @override
  State<ReviewEditsScreen> createState() => _ReviewEditsScreenState();
}

class _ReviewEditsScreenState extends State<ReviewEditsScreen> {
  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).notes;
    final main = repo.getNote(widget.noteId);
    final copies = repo.conflictCopiesOf(widget.noteId);
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final p = AppPalette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Review edits')),
      body: main == null
          ? const Center(child: Text('The main note is no longer available.'))
          : copies.isEmpty
          ? const Center(child: Text('No edits to review.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  main.title.isEmpty ? 'Main note' : main.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                for (final copy in copies) ...[
                  _Comparison(main: main, copy: copy, wide: wide, p: p),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, touchTarget),
                        ),
                        onPressed: () => _use(repo, copy),
                        child: const Text('Use this version'),
                      ),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, touchTarget),
                        ),
                        onPressed: () {
                          repo.keepConflictCopy([copy.id]);
                          setState(() {});
                        },
                        child: const Text('Keep both'),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, touchTarget),
                        ),
                        onPressed: () => _dismiss(repo, copy),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                  const Divider(height: 32),
                ],
              ],
            ),
    );
  }

  void _use(NoteRepository repo, Note copy) {
    repo.useConflictCopy(widget.noteId, copy.id);
    if (mounted) setState(() {});
  }

  Future<void> _dismiss(NoteRepository repo, Note copy) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Dismiss this version?'),
        content: const Text('This competing version will be deleted forever.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      repo.purge([copy.id]);
      setState(() {});
    }
  }
}

class _Comparison extends StatelessWidget {
  const _Comparison({
    required this.main,
    required this.copy,
    required this.wide,
    required this.p,
  });
  final Note main;
  final Note copy;
  final bool wide;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    final a = _plain(main.body);
    final b = _plain(copy.body);
    final rows = <Widget>[
      _version('Main note', a, b, p),
      _version('Competing version', b, a, p),
    ];
    return wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < rows.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i == 0 ? 8 : 0),
                    child: rows[i],
                  ),
                ),
            ],
          )
        : Column(
            children: [
              for (final row in rows)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: row),
            ],
          );
  }

  static String _plain(String body) {
    try {
      final text = digestBody(body);
      final images = text.imageSources.length;
      return '${text.plainText}${images == 0 ? '' : '\n[Image × $images]'}';
    } on FormatException {
      return '[Unable to display this version]';
    }
  }

  static Widget _version(
    String label,
    String text,
    String other,
    AppPalette p,
  ) {
    final lines = text.split('\n');
    final otherLines = other.split('\n');
    return Semantics(
      container: true,
      header: true,
      label: label,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              for (var i = 0; i < lines.length; i++)
                Container(
                  width: double.infinity,
                  color: i >= otherLines.length || lines[i] != otherLines[i]
                      ? p.accent.withValues(alpha: .16)
                      : null,
                  padding: const EdgeInsets.symmetric(
                    vertical: 3,
                    horizontal: 4,
                  ),
                  child: Semantics(
                    label: i >= otherLines.length || lines[i] != otherLines[i]
                        ? 'Changed: ${lines[i]}'
                        : lines[i],
                    child: Text(lines[i].isEmpty ? ' ' : lines[i]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
