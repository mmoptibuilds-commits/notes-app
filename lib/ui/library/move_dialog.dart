import '../../data/models.dart';
import '../material.dart';
import '../theme/app_theme.dart';
import '../widgets/dialogs.dart';

/// Result of the move dialog: a folder, "no folder", or "make a new one".
sealed class MoveChoice {
  const MoveChoice();
}

class MoveToFolder extends MoveChoice {
  const MoveToFolder(this.folderId);

  /// Null means "No folder".
  final String? folderId;
}

class MoveToNewFolder extends MoveChoice {
  const MoveToNewFolder();
}

/// Lists folders, "No folder" and "New folder" for moving notes.
/// [currentIds] marks the folder(s) the notes are already in.
Future<MoveChoice?> showMoveDialog(
  BuildContext context, {
  required List<Folder> folders,
  required Set<String?> currentIds,
}) => showDialog<MoveChoice>(
  context: context,
  animationStyle: animationStyleOf(context),
  builder: (ctx) {
    final p = AppPalette.of(ctx);
    Widget tile({
      required String label,
      required MoveChoice choice,
      IconData icon = Icons.folder_outlined,
      bool checked = false,
      String? trailing,
      Color? color,
    }) => InkWell(
      onTap: () => Navigator.pop(ctx, choice),
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Icon(icon, size: 19, color: color ?? p.textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: color ?? p.text),
                ),
              ),
              if (trailing != null)
                Text(
                  trailing,
                  style: TextStyle(fontSize: 12, color: p.textFaint),
                ),
              if (checked) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_rounded, size: 18, color: p.accent),
              ],
            ],
          ),
        ),
      ),
    );

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                'Move to folder',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: p.text,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  tile(
                    label: 'No folder',
                    icon: Icons.folder_off_outlined,
                    choice: const MoveToFolder(null),
                    checked: currentIds.length == 1 && currentIds.first == null,
                  ),
                  for (final f in folders)
                    tile(
                      label: f.name,
                      choice: MoveToFolder(f.id),
                      checked:
                          currentIds.length == 1 && currentIds.first == f.id,
                      trailing: '${f.noteCount}',
                    ),
                  tile(
                    label: 'New folder…',
                    icon: Icons.create_new_folder_outlined,
                    choice: const MoveToNewFolder(),
                    color: p.accent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  },
);
