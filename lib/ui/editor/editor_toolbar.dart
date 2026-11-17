import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../data/app_settings.dart';
import '../material.dart';
import '../theme/app_theme.dart';
import '../toolbar_item_info.dart';

/// The formatting bar above the keyboard. Which buttons appear, and in what
/// order, comes from the user's toolbar setting.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.controller,
    required this.items,
    required this.onLink,
    required this.onImage,
    this.bottom = true,
  });

  final QuillController controller;
  final List<ToolbarItem> items;
  final Future<void> Function() onLink;
  final Future<void> Function() onImage;

  /// Whether the bar sits at the bottom edge (true) or under the app bar.
  final bool bottom;

  static bool get _touch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final size = _touch ? 44.0 : 36.0;
    return Container(
      decoration: BoxDecoration(
        color: p.raised,
        border: Border(
          top: bottom ? BorderSide(color: p.cardBorder) : BorderSide.none,
          bottom: bottom ? BorderSide.none : BorderSide(color: p.cardBorder),
        ),
      ),
      child: SafeArea(
        top: false,
        bottom: bottom,
        // Buttons must never take focus from the text: that would close the
        // keyboard and lose the selection they act on.
        child: ExcludeFocus(
          child: SizedBox(
            height: size + 4,
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final attrs = controller.getSelectionStyle().attributes;
                return ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  children: [
                    for (final item in items)
                      _button(context, item, attrs, size, p),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  bool _active(ToolbarItem item, Map<String, Attribute> a) {
    final list = a[Attribute.list.key]?.value;
    final header = a[Attribute.header.key]?.value;
    return switch (item) {
      ToolbarItem.bold => a.containsKey(Attribute.bold.key),
      ToolbarItem.italic => a.containsKey(Attribute.italic.key),
      ToolbarItem.underline => a.containsKey(Attribute.underline.key),
      ToolbarItem.strike => a.containsKey(Attribute.strikeThrough.key),
      ToolbarItem.heading1 => header == 1,
      ToolbarItem.heading2 => header == 2,
      ToolbarItem.heading3 => header == 3,
      ToolbarItem.bulletList => list == 'bullet',
      ToolbarItem.numberedList => list == 'ordered',
      ToolbarItem.checklist => list == 'checked' || list == 'unchecked',
      ToolbarItem.quote => a.containsKey(Attribute.blockQuote.key),
      ToolbarItem.codeBlock => a.containsKey(Attribute.codeBlock.key),
      ToolbarItem.inlineCode => a.containsKey(Attribute.inlineCode.key),
      ToolbarItem.link => a.containsKey(Attribute.link.key),
      _ => false,
    };
  }

  void _toggle(Attribute on, Attribute off, bool active) =>
      controller.formatSelection(active ? off : on);

  Future<void> _press(ToolbarItem item, bool active) async {
    final c = controller;
    switch (item) {
      case ToolbarItem.bold:
        _toggle(Attribute.bold, Attribute.clone(Attribute.bold, null), active);
      case ToolbarItem.italic:
        _toggle(
          Attribute.italic,
          Attribute.clone(Attribute.italic, null),
          active,
        );
      case ToolbarItem.underline:
        _toggle(
          Attribute.underline,
          Attribute.clone(Attribute.underline, null),
          active,
        );
      case ToolbarItem.strike:
        _toggle(
          Attribute.strikeThrough,
          Attribute.clone(Attribute.strikeThrough, null),
          active,
        );
      case ToolbarItem.heading1:
        _toggle(Attribute.h1, Attribute.clone(Attribute.header, null), active);
      case ToolbarItem.heading2:
        _toggle(Attribute.h2, Attribute.clone(Attribute.header, null), active);
      case ToolbarItem.heading3:
        _toggle(Attribute.h3, Attribute.clone(Attribute.header, null), active);
      case ToolbarItem.bulletList:
        _toggle(Attribute.ul, Attribute.clone(Attribute.list, null), active);
      case ToolbarItem.numberedList:
        _toggle(Attribute.ol, Attribute.clone(Attribute.list, null), active);
      case ToolbarItem.checklist:
        _toggle(
          Attribute.unchecked,
          Attribute.clone(Attribute.list, null),
          active,
        );
      case ToolbarItem.quote:
        _toggle(
          Attribute.blockQuote,
          Attribute.clone(Attribute.blockQuote, null),
          active,
        );
      case ToolbarItem.codeBlock:
        _toggle(
          Attribute.codeBlock,
          Attribute.clone(Attribute.codeBlock, null),
          active,
        );
      case ToolbarItem.inlineCode:
        _toggle(
          Attribute.inlineCode,
          Attribute.clone(Attribute.inlineCode, null),
          active,
        );
      case ToolbarItem.link:
        await onLink();
      case ToolbarItem.image:
        await onImage();
      case ToolbarItem.indent:
        c.indentSelection(true);
      case ToolbarItem.outdent:
        c.indentSelection(false);
      case ToolbarItem.clearFormat:
        for (final a in c.getSelectionStyle().attributes.values.toList()) {
          c.formatSelection(Attribute.clone(a, null));
        }
      case ToolbarItem.undo:
        c.undo();
      case ToolbarItem.redo:
        c.redo();
    }
  }

  Widget _button(
    BuildContext context,
    ToolbarItem item,
    Map<String, Attribute> attrs,
    double size,
    AppPalette p,
  ) {
    final active = _active(item, attrs);
    final enabled = switch (item) {
      ToolbarItem.undo => controller.hasUndo,
      ToolbarItem.redo => controller.hasRedo,
      _ => true,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
      child: Tooltip(
        message: item.label,
        child: Material(
          color: active ? p.accent.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
            onTap: enabled ? () => _press(item, active) : null,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(
                item.icon,
                size: 21,
                color: !enabled
                    ? p.textFaint.withValues(alpha: 0.5)
                    : active
                    ? p.accent
                    : p.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
