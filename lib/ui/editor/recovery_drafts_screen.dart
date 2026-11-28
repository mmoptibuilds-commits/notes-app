import '../../app.dart';
import '../../data/editor_draft.dart';
import '../../data/note_repository.dart';
import '../material.dart';
import '../shortcuts/shortcut_guards.dart';
import '../theme/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/touch.dart';
import 'editor_screen.dart';

/// Lists encrypted local snapshots left by editor saves that did not commit.
class RecoveryDraftsScreen extends StatelessWidget {
  const RecoveryDraftsScreen({super.key});

  Future<void> _recover(BuildContext context, PendingEditorDraft draft) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => EditorScreen(recoveredDraft: draft),
      ),
    );
  }

  Future<void> _discard(
    BuildContext context,
    NoteRepository repo,
    PendingEditorDraft draft,
  ) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Discard this recovery copy?',
      message:
          'Its unsaved text will be removed from this device. This does not '
          'change the saved note.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    repo.discardPendingEditorDraft(draft.id);
  }

  bool _willRecoverAsNew(NoteRepository repo, PendingEditorDraft draft) {
    final id = draft.noteId;
    if (id == null) return false;
    final record = repo.getRecord(id);
    return record == null || record.purged || record.trashedAt != null;
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).notes;
    final p = AppPalette.of(context);
    return backOnEscape(
      child: Scaffold(
        appBar: AppBar(title: const Text('Recover drafts')),
        body: ListenableBuilder(
          listenable: repo.draftChanges,
          builder: (context, _) {
            final drafts = repo.pendingEditorDrafts();
            if (drafts.isEmpty) {
              return const Center(child: Text('No pending drafts.'));
            }
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    Card(
                      color: p.card,
                      child: const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'These encrypted drafts were kept because a save did '
                          'not finish. Recovering one saves it to your library. '
                          'If its original note changed, Notes keeps both versions.',
                          style: TextStyle(height: 1.4),
                        ),
                      ),
                    ),
                    for (final draft in drafts)
                      _DraftTile(
                        draft: draft,
                        recoverAsNew: _willRecoverAsNew(repo, draft),
                        onRecover: () => _recover(context, draft),
                        onDiscard: () => _discard(context, repo, draft),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DraftTile extends StatelessWidget {
  const _DraftTile({
    required this.draft,
    required this.recoverAsNew,
    required this.onRecover,
    required this.onDiscard,
  });

  final PendingEditorDraft draft;
  final bool recoverAsNew;
  final VoidCallback onRecover;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final date = DateTime.fromMillisecondsSinceEpoch(draft.updatedAt)
        .toLocal()
        .toString()
        .substring(0, 16);
    final subtitle = recoverAsNew
        ? 'Original note unavailable; recovery will create a new note. Saved $date.'
        : 'Saved $date. This copy is stored only on this device.';
    return Card(
      color: p.card,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(Icons.restore_rounded, color: p.accent),
              title: Text(
                draft.title.trim().isEmpty ? 'Untitled draft' : draft.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(subtitle),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: touchButtonMinimumSize(context),
                    visualDensity: touchVisualDensity(context),
                  ),
                  onPressed: onDiscard,
                  child: const Text('Discard'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: touchButtonMinimumSize(context),
                    visualDensity: touchVisualDensity(context),
                  ),
                  onPressed: onRecover,
                  child: const Text('Recover draft'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
