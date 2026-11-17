import '../data/app_settings.dart';
import 'material.dart';

/// Label and icon for each editor toolbar button. Shared by the editor and
/// the toolbar settings page.
extension ToolbarItemInfo on ToolbarItem {
  String get label => switch (this) {
    ToolbarItem.bold => 'Bold',
    ToolbarItem.italic => 'Italic',
    ToolbarItem.underline => 'Underline',
    ToolbarItem.strike => 'Strikethrough',
    ToolbarItem.heading1 => 'Heading 1',
    ToolbarItem.heading2 => 'Heading 2',
    ToolbarItem.heading3 => 'Heading 3',
    ToolbarItem.bulletList => 'Bulleted list',
    ToolbarItem.numberedList => 'Numbered list',
    ToolbarItem.checklist => 'Checklist',
    ToolbarItem.quote => 'Quote',
    ToolbarItem.codeBlock => 'Code block',
    ToolbarItem.inlineCode => 'Inline code',
    ToolbarItem.link => 'Link',
    ToolbarItem.image => 'Image',
    ToolbarItem.indent => 'Indent',
    ToolbarItem.outdent => 'Outdent',
    ToolbarItem.clearFormat => 'Clear formatting',
    ToolbarItem.undo => 'Undo',
    ToolbarItem.redo => 'Redo',
  };

  IconData get icon => switch (this) {
    ToolbarItem.bold => Icons.format_bold_rounded,
    ToolbarItem.italic => Icons.format_italic_rounded,
    ToolbarItem.underline => Icons.format_underlined_rounded,
    ToolbarItem.strike => Icons.strikethrough_s_rounded,
    ToolbarItem.heading1 => Icons.looks_one_outlined,
    ToolbarItem.heading2 => Icons.looks_two_outlined,
    ToolbarItem.heading3 => Icons.looks_3_outlined,
    ToolbarItem.bulletList => Icons.format_list_bulleted_rounded,
    ToolbarItem.numberedList => Icons.format_list_numbered_rounded,
    ToolbarItem.checklist => Icons.checklist_rounded,
    ToolbarItem.quote => Icons.format_quote_rounded,
    ToolbarItem.codeBlock => Icons.code_rounded,
    ToolbarItem.inlineCode => Icons.data_object_rounded,
    ToolbarItem.link => Icons.link_rounded,
    ToolbarItem.image => Icons.image_outlined,
    ToolbarItem.indent => Icons.format_indent_increase_rounded,
    ToolbarItem.outdent => Icons.format_indent_decrease_rounded,
    ToolbarItem.clearFormat => Icons.format_clear_rounded,
    ToolbarItem.undo => Icons.undo_rounded,
    ToolbarItem.redo => Icons.redo_rounded,
  };
}
