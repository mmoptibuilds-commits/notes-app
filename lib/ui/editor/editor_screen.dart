import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../app.dart';
import '../../platform/bootstrap.dart';
import '../material.dart';
import '../theme/app_theme.dart';
import 'completed_section.dart';
import 'editor_session.dart';
import 'editor_style.dart';
import 'editor_toolbar.dart';
import 'embeds.dart';

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

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, this.noteId, this.folderId});

  final String? noteId;
  final String? folderId;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with WidgetsBindingObserver {
  late final EditorSession session;
  final _editorFocus = FocusNode();
  final _titleFocus = FocusNode();
  late bool _completedCollapsed;
  AttachmentImageEmbedBuilder? _images;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final app = AppScope.of(context);
    _images = AttachmentImageEmbedBuilder(app.notes);
    _completedCollapsed = app.settings.completedCollapsed;
    session = EditorSession(
      repo: app.notes,
      noteId: widget.noteId,
      folderId: widget.folderId,
      useCompletedSection: app.settings.completedSection,
      onConflictCopy: _onConflictCopy,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  void _onConflictCopy(String id) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'This note changed on another device. Its version was kept as a '
          'separate note.',
        ),
        duration: Duration(seconds: 6),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) session.flush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.dispose();
    _editorFocus.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _toast(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  // ---------------------------------------------------------- actions

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: session.plainText()));
    if (mounted) _toast('Note copied');
  }

  void _trash() {
    final repo = AppScope.of(context).notes;
    session.trash();
    final id = session.noteId;
    Navigator.of(context).pop();
    if (id != null) {
      // The library's messenger outlives this route.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Moved to Trash'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => repo.restore([id]),
            ),
          ),
        );
    }
  }

  Future<void> _deleteForever() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete forever?'),
        content: const Text(
          'This note will be removed from all your devices. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              'Delete forever',
              style: TextStyle(color: AppPalette.of(c).danger),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final id = session.noteId;
    if (id != null) AppScope.of(context).notes.purge([id]);
    Navigator.of(context).pop();
  }

  Future<void> _moveToFolder() async {
    final repo = AppScope.of(context).notes;
    final current = session.stored?.folderId;
    final chosen = await showModalBottomSheet<_FolderChoice>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('No folder'),
                selected: current == null,
                onTap: () => Navigator.pop(c, const _FolderChoice(null)),
              ),
              for (final f in repo.listFolders())
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f.name),
                  selected: f.id == current,
                  onTap: () => Navigator.pop(c, _FolderChoice(f.id)),
                ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('New folder…'),
                onTap: () => Navigator.pop(c, const _FolderChoice.create()),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    if (chosen.create) {
      final name = await _ask(title: 'New folder', hint: 'Folder name');
      if (name == null || name.trim().isEmpty) return;
      session.moveToFolder(repo.createFolder(name).id);
    } else {
      session.moveToFolder(chosen.id);
    }
  }

  Future<String?> _ask({
    required String title,
    required String hint,
    String initial = '',
    String action = 'OK',
  }) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, c.text),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<void> _link() async {
    final q = session.quill;
    final existing = q
        .getSelectionStyle()
        .attributes[Attribute.link.key]
        ?.value;
    final url = await _ask(
      title: 'Link',
      hint: 'https://…',
      initial: existing is String ? existing : '',
      action: 'Apply',
    );
    if (url == null) return;
    final target = url.trim();
    if (target.isEmpty) {
      q.formatSelection(Attribute.clone(Attribute.link, null));
      return;
    }
    final sel = q.selection;
    if (sel.isCollapsed) {
      final at = sel.baseOffset;
      q.replaceText(
        at,
        0,
        target,
        TextSelection.collapsed(offset: at + target.length),
      );
      q.formatText(at, target.length, LinkAttribute(target));
    } else {
      q.formatSelection(LinkAttribute(target));
    }
  }

  static const _maxImageBytes = 25 * 1024 * 1024;

  Future<void> _image() async {
    final repo = AppScope.of(context).notes;
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
          mimeTypes: [
            'image/png',
            'image/jpeg',
            'image/gif',
            'image/webp',
            'image/bmp',
          ],
        ),
      ],
    );
    if (file == null || !mounted) return;
    if (await file.length() > _maxImageBytes) {
      if (mounted) _toast('That image is larger than 25 MB.');
      return;
    }
    final bytes = await file.readAsBytes();
    final ext = file.name.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      _ => 'image/png',
    };
    final source = repo.putAttachment(bytes, mime);
    if (!mounted) return;
    final sel = session.quill.selection;
    session.quill.replaceText(
      sel.start,
      sel.end - sel.start,
      BlockEmbed.image(source),
      null,
    );
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    final isNew = widget.noteId == null;
    // On a wide window the bar sits under the app bar, near the text; on a
    // phone it rides above the keyboard.
    final wide = MediaQuery.sizeOf(context).width > 640;
    final toolbar = ListenableBuilder(
      listenable: Listenable.merge([session, app.settings]),
      builder: (context, _) => session.readOnly
          ? const SizedBox.shrink()
          : EditorToolbar(
              controller: session.quill,
              items: app.settings.toolbar,
              onLink: _link,
              onImage: _image,
              bottom: !wide,
            ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: ListenableBuilder(
            listenable: session,
            builder: (context, _) => session.status == SaveStatus.failed
                ? Text(
                    'Not saved yet, retrying…',
                    style: TextStyle(color: p.danger, fontSize: 13),
                  )
                : const SizedBox.shrink(),
          ),
          actions: [
            IconButton(
              tooltip: 'Copy note',
              icon: const Icon(Icons.copy_rounded),
              onPressed: _copy,
            ),
            ListenableBuilder(
              listenable: Listenable.merge([app.notes.changes, session]),
              builder: (context, _) {
                final pinned = session.stored?.pinned ?? false;
                return IconButton(
                  tooltip: pinned ? 'Unpin' : 'Pin',
                  icon: Icon(
                    pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    color: pinned ? p.accent : null,
                  ),
                  onPressed: session.readOnly
                      ? null
                      : () => session.setPinned(!pinned),
                );
              },
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                switch (v) {
                  case 'archive':
                    final archived = session.stored?.archived ?? false;
                    session.setArchived(!archived);
                    Navigator.of(context).pop();
                  case 'folder':
                    _moveToFolder();
                  case 'trash':
                    _trash();
                }
              },
              itemBuilder: (context) {
                final archived = session.stored?.archived ?? false;
                return [
                  if (!session.readOnly) ...[
                    PopupMenuItem(
                      value: 'folder',
                      child: const Text('Move to folder…'),
                    ),
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(archived ? 'Unarchive' : 'Archive'),
                    ),
                    PopupMenuItem(
                      value: 'trash',
                      child: Text(
                        'Move to Trash',
                        style: TextStyle(color: p.danger),
                      ),
                    ),
                  ],
                ];
              },
            ),
          ],
        ),
        body: Column(
          children: [
            ListenableBuilder(
              listenable: session,
              builder: (context, _) {
                if (session.loadError != null) {
                  return _Banner(text: session.loadError!);
                }
                if (session.readOnly) {
                  return _Banner(
                    text: 'This note is in Trash',
                    actions: [
                      TextButton(
                        onPressed: session.restoreFromTrash,
                        child: const Text('Restore'),
                      ),
                      TextButton(
                        onPressed: _deleteForever,
                        child: Text(
                          'Delete forever',
                          style: TextStyle(color: p.danger),
                        ),
                      ),
                    ],
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            if (wide) toolbar,
            Expanded(child: _page(context, app, isNew)),
            if (!wide) toolbar,
          ],
        ),
      ),
    );
  }

  Widget _page(BuildContext context, AppServices app, bool isNew) {
    final p = AppPalette.of(context);
    final settings = app.settings;
    final wide = MediaQuery.sizeOf(context).width > 640;
    return Scrollbar(
      controller: session.scroll,
      child: SingleChildScrollView(
        controller: session.scroll,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
        padding: EdgeInsets.fromLTRB(wide ? 24 : 16, 4, wide ? 24 : 16, 0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppMetrics.editorMaxWidth,
            ),
            child: ListenableBuilder(
              listenable: settings,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: session.title,
                    focusNode: _titleFocus,
                    readOnly: session.readOnly,
                    minLines: 1,
                    maxLines: null,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) {
                      session.quill.moveCursorToStart();
                      _editorFocus.requestFocus();
                    },
                    style: TextStyle(
                      fontFamily: settings.editorFont.family,
                      fontSize: settings.editorFontSize * 1.45,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                      color: p.text,
                    ),
                    cursorColor: p.accent,
                    decoration: InputDecoration(
                      hintText: 'Title',
                      hintStyle: TextStyle(color: p.textFaint),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                  QuillEditor(
                    focusNode: _editorFocus,
                    scrollController: session.scroll,
                    controller: session.quill,
                    config: QuillEditorConfig(
                      scrollable: false,
                      showCodeBlockLineNumbers: false,
                      autoFocus: isNew,
                      placeholder: 'Start writing…',
                      customStyles: buildEditorStyles(context, settings),
                      embedBuilders: [_images!],
                      unknownEmbedBuilder: const UnknownEmbedBuilder(),
                      requestKeyboardFocusOnCheckListChanged: false,
                      textSelectionThemeData: TextSelectionThemeData(
                        cursorColor: p.accent,
                        selectionColor: p.accent.withValues(alpha: 0.3),
                        selectionHandleColor: p.accent,
                      ),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: session,
                    builder: (context, _) => CompletedSection(
                      items: session.completed,
                      collapsed: _completedCollapsed,
                      onToggle: () => setState(
                        () => _completedCollapsed = !_completedCollapsed,
                      ),
                      onRestore: (c) => session.restoreCompleted([c.id]),
                      onDelete: (c) => _deleteCompleted([c.id], 'Item deleted'),
                      onRestoreAll: session.uncheckAllCompleted,
                      onDeleteAll: () => _deleteCompleted([
                        for (final c in session.completed) c.id,
                      ], 'Completed items deleted'),
                    ),
                  ),
                  // Tapping the empty space below the text puts the cursor
                  // at the end, as in most editors.
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: session.readOnly
                        ? null
                        : () {
                            session.quill.moveCursorToEnd();
                            _editorFocus.requestFocus();
                          },
                    child: const SizedBox(height: 240),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _deleteCompleted(List<int> ids, String message) {
    final gone = session.deleteCompleted(ids);
    if (gone.isEmpty) return;
    _toast(
      message,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => session.undoDelete(gone),
      ),
    );
  }
}

class _FolderChoice {
  const _FolderChoice(this.id) : create = false;
  const _FolderChoice.create() : id = null, create = true;
  final String? id;
  final bool create;
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.actions = const []});

  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      decoration: BoxDecoration(
        color: p.card,
        border: Border(bottom: BorderSide(color: p.cardBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: p.textMuted, fontSize: 13),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
