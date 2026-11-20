import '../../data/models.dart';
import '../../data/note_repository.dart' show SearchHit;
import '../material.dart';
import '../theme/app_theme.dart';
import '../widgets/format.dart';
import '../widgets/touch.dart';
import 'library_controller.dart';

/// Shared callbacks of a library item.
typedef ItemTapCallback = void Function(NoteSummary note);
typedef ItemMenuCallback = void Function(
  NoteSummary note,
  Offset globalPosition,
);

/// Splits a note into the heavy first line and the lighter body text.
/// With no title, the first preview line carries the weight.
({String head, String body, bool untitled}) splitNote(NoteSummary n) {
  final title = n.title.trim();
  String clean(String l) =>
      l.startsWith(_todoMarker) ? l.substring(_todoMarker.length) : l;
  if (title.isNotEmpty) return (head: title, body: n.preview, untitled: false);
  final i = n.preview.indexOf('\n');
  if (n.preview.isEmpty) return (head: 'Untitled', body: '', untitled: true);
  if (i < 0) return (head: clean(n.preview), body: '', untitled: false);
  return (
    head: clean(n.preview.substring(0, i)),
    body: n.preview.substring(i + 1),
    untitled: false,
  );
}

const _todoMarker = '\u2610 ';

/// Preview text where the stored "unchecked" marker is drawn as a small box
/// (the glyph is missing from several fonts).
InlineSpan previewSpan(String text, TextStyle style, AppPalette p) {
  final children = <InlineSpan>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.startsWith(_todoMarker)) {
      line = line.substring(_todoMarker.length);
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 5),
            child: Icon(
              Icons.check_box_outline_blank_rounded,
              size: 14,
              color: p.textFaint,
            ),
          ),
        ),
      );
    }
    children.add(TextSpan(text: i < lines.length - 1 ? '$line\n' : line));
  }
  return TextSpan(style: style, children: children);
}

/// Body text with the search match emphasised.
InlineSpan snippetSpan(String snippet, TextStyle base, TextStyle emphasis) {
  final spans = <InlineSpan>[];
  final text = snippet.replaceAll('\n', ' ');
  var inMatch = false;
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    spans.add(TextSpan(text: buf.toString(), style: inMatch ? emphasis : null));
    buf.clear();
  }

  for (final unit in text.runes) {
    final c = String.fromCharCode(unit);
    if (c == SearchHit.matchStart) {
      flush();
      inMatch = true;
    } else if (c == SearchHit.matchEnd) {
      flush();
      inMatch = false;
    } else {
      buf.write(c);
    }
  }
  flush();
  return TextSpan(style: base, children: spans);
}

class _Styles {
  _Styles(this.p, {required this.untitled})
    : title = TextStyle(
        fontSize: 14.5,
        height: 1.28,
        fontWeight: FontWeight.w600,
        color: untitled ? p.textFaint : p.text,
      ),
      body = TextStyle(fontSize: 13, height: 1.35, color: p.textMuted),
      meta = TextStyle(fontSize: 11, height: 1.3, color: p.textFaint),
      progress = TextStyle(
        fontSize: 11,
        height: 1.3,
        fontWeight: FontWeight.w500,
        color: p.textMuted,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      match = TextStyle(
        fontWeight: FontWeight.w700,
        color: p.text,
        backgroundColor: p.accent.withValues(alpha: 0.22),
      );

  final AppPalette p;
  final bool untitled;
  final TextStyle title;
  final TextStyle body;
  final TextStyle meta;
  final TextStyle progress;
  final TextStyle match;
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 10.5,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    ),
  );
}

/// Conflict / archived marks for a note, or an empty list.
List<Widget> noteTags(AppPalette p, NoteSummary n, {required bool searching}) =>
    [
      if (n.isConflictCopy) _Tag('Conflict copy', color: p.danger),
      if (searching && n.archived) _Tag('Archived', color: p.textMuted),
    ];

class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.total, required this.p});
  final int done;
  final int total;
  final AppPalette p;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(1),
    child: SizedBox(
      height: 2,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: p.cardBorder),
          Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: total == 0 ? 0 : (done / total).clamp(0, 1),
              child: ColoredBox(color: p.accent),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Shared chrome of card and row: border, hover, focus ring, selection.
class _ItemSurface extends StatefulWidget {
  const _ItemSurface({
    required this.note,
    required this.selected,
    required this.radius,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
    required this.child,
  });

  final NoteSummary note;
  final bool selected;
  final double radius;
  final ItemTapCallback onTap;
  final ItemTapCallback onLongPress;
  final ItemMenuCallback onMenu;
  final Widget child;

  @override
  State<_ItemSurface> createState() => _ItemSurfaceState();
}

class _ItemSurfaceState extends State<_ItemSurface> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final motion = AppMotion.of(context);
    final ring =
        _focus &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final Color border;
    if (ring || widget.selected) {
      border = p.accent;
    } else if (_hover) {
      border = p.textFaint;
    } else {
      border = p.cardBorder;
    }
    final fill = widget.selected
        ? Color.alphaBlend(p.accent.withValues(alpha: 0.10), p.card)
        : p.card;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(widget.radius),
      side: BorderSide(
        color: border,
        width: (ring || widget.selected) ? 1.5 : 1,
      ),
    );
    return Material(
      color: fill,
      shape: shape,
      animationDuration: motion.fast,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => widget.onTap(widget.note),
        onLongPress: () => widget.onLongPress(widget.note),
        onSecondaryTapDown: (d) => widget.onMenu(widget.note, d.globalPosition),
        onHover: (h) => setState(() => _hover = h),
        onFocusChange: (f) => setState(() => _focus = f),
        hoverColor: p.text.withValues(alpha: 0.03),
        focusColor: Colors.transparent,
        child: Stack(
          children: [
            widget.child,
            if (widget.selected)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: p.accent,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.check_rounded, size: 13, color: p.onAccent),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A note as a card, for the grid and masonry layouts. With [fixedHeight]
/// the card fills the height its grid cell gives it (uniform grid).
class NoteCard extends StatelessWidget {
  const NoteCard({
    super.key,
    required this.item,
    required this.previewLines,
    required this.selected,
    required this.now,
    required this.byCreated,
    required this.searching,
    required this.fixedHeight,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  final LibraryItem item;
  final int previewLines;
  final bool selected;
  final DateTime now;
  final bool byCreated;
  final bool searching;
  final bool fixedHeight;
  final ItemTapCallback onTap;
  final ItemTapCallback onLongPress;
  final ItemMenuCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final n = item.note;
    final parts = splitNote(n);
    final st = _Styles(p, untitled: parts.untitled);
    final hasSnippet = item.snippet.isNotEmpty;
    final lines = hasSnippet
        ? (previewLines < 2 ? 2 : previewLines)
        : previewLines;
    final showBody = hasSnippet || (lines > 0 && parts.body.isNotEmpty);
    final tags = noteTags(p, n, searching: searching);
    final date = formatRelativeDate(
      byCreated ? n.createdAt : n.updatedAt,
      now: now,
    );

    Widget body() => Text.rich(
      hasSnippet
          ? snippetSpan(item.snippet, st.body, st.match)
          : previewSpan(parts.body, st.body, p),
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
    );

    final footer = Row(
      children: [
        if (n.pinned) ...[
          Icon(Icons.push_pin_rounded, size: 12, color: p.accent),
          const SizedBox(width: 3),
        ],
        Expanded(
          child: Text(
            date,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: st.meta,
          ),
        ),
        if (n.tasksTotal > 0)
          Text('${n.tasksDone}/${n.tasksTotal}', style: st.progress),
      ],
    );

    final content = Padding(
      padding: AppMetrics.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: fixedHeight ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (tags.isNotEmpty) ...[
            // One row, never wrapped: the grid card height reserves one line.
            Row(
              children: [
                for (var i = 0; i < tags.length; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Flexible(child: tags[i]),
                ],
              ],
            ),
            const SizedBox(height: 5),
          ],
          Padding(
            padding: EdgeInsets.only(right: selected ? 20 : 0),
            child: Text(
              parts.head,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: st.title,
            ),
          ),
          if (showBody) ...[
            const SizedBox(height: 5),
            if (fixedHeight)
              Expanded(
                child: ClipRect(
                  child: Align(alignment: Alignment.topLeft, child: body()),
                ),
              )
            else
              body(),
          ] else if (fixedHeight)
            const Spacer(),
          const SizedBox(height: 8),
          footer,
          const SizedBox(height: 6),
          n.tasksTotal > 0
              ? _Progress(done: n.tasksDone, total: n.tasksTotal, p: p)
              : const SizedBox(height: 2),
        ],
      ),
    );

    return _ItemSurface(
      note: n,
      selected: selected,
      radius: AppMetrics.cardRadius,
      onTap: onTap,
      onLongPress: onLongPress,
      onMenu: onMenu,
      child: content,
    );
  }
}

/// A note as a compact row, for the list layout.
class NoteRow extends StatelessWidget {
  const NoteRow({
    super.key,
    required this.item,
    required this.showPreview,
    required this.selected,
    required this.now,
    required this.byCreated,
    required this.searching,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  final LibraryItem item;
  final bool showPreview;
  final bool selected;
  final DateTime now;
  final bool byCreated;
  final bool searching;
  final ItemTapCallback onTap;
  final ItemTapCallback onLongPress;
  final ItemMenuCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final n = item.note;
    final parts = splitNote(n);
    final st = _Styles(p, untitled: parts.untitled);
    final hasSnippet = item.snippet.isNotEmpty;
    final firstBodyLine = parts.body.split('\n').first;
    final showBody = hasSnippet || (showPreview && firstBodyLine.isNotEmpty);
    final tags = noteTags(p, n, searching: searching);
    final date = formatRelativeDate(
      byCreated ? n.createdAt : n.updatedAt,
      now: now,
    );

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      // A one-line row still has to be a comfortable touch target.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: hitSize(context, desktop: 0) - 18,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LayoutBuilder(
                      builder: (context, box) => Row(
                        children: [
                          Flexible(
                            child: Text(
                              parts.head,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: st.title,
                            ),
                          ),
                          // Tags give way before the title does, but never take
                          // more than their share of a narrow row.
                          for (final t in tags) ...[
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: box.maxWidth * 0.45,
                              ),
                              child: t,
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (showBody) ...[
                      const SizedBox(height: 2),
                      Text.rich(
                        hasSnippet
                            ? snippetSpan(item.snippet, st.body, st.match)
                            : previewSpan(firstBodyLine, st.body, p),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: EdgeInsets.only(right: selected ? 24 : 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (n.pinned) ...[
                          Icon(
                            Icons.push_pin_rounded,
                            size: 12,
                            color: p.accent,
                          ),
                          const SizedBox(width: 3),
                        ],
                        Text(date, style: st.meta),
                      ],
                    ),
                    if (n.tasksTotal > 0) ...[
                      const SizedBox(height: 1),
                      Text(
                        '${n.tasksDone}/${n.tasksTotal}',
                        style: st.progress,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return _ItemSurface(
      note: n,
      selected: selected,
      radius: 12,
      onTap: onTap,
      onLongPress: onLongPress,
      onMenu: onMenu,
      child: n.tasksTotal > 0
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                content,
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: _Progress(
                    done: n.tasksDone,
                    total: n.tasksTotal,
                    p: p,
                  ),
                ),
              ],
            )
          : content,
    );
  }
}
