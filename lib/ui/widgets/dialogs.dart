import '../../data/app_settings.dart';
import '../material.dart';
import '../theme/app_theme.dart';
import 'touch.dart';

/// Maps the user's animation setting onto route/menu animation styles, so
/// "off" really means nothing slides, fades or scales.
AnimationStyle? animationStyleOf(BuildContext context) {
  final m = AppMotion.of(context);
  return switch (m.level) {
    AnimationLevel.off => AnimationStyle.noAnimation,
    AnimationLevel.reduced => AnimationStyle(
      duration: m.fast,
      reverseDuration: m.fast,
    ),
    AnimationLevel.full => null,
  };
}

/// Asks a yes/no question. Returns true only on an explicit confirm.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final p = AppPalette.of(context);
  final result = await showDialog<bool>(
    context: context,
    animationStyle: animationStyleOf(context),
    builder: (ctx) => AlertDialog(
      title: Text(title),
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
      content: SingleChildScrollView(child: Text(message)),
      contentTextStyle: TextStyle(
        fontSize: 13.5,
        height: 1.4,
        color: p.textMuted,
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: touchButtonMinimumSize(ctx),
            visualDensity: touchVisualDensity(ctx),
          ),
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: destructive ? p.danger : p.accent,
            minimumSize: touchButtonMinimumSize(ctx),
            visualDensity: touchVisualDensity(ctx),
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Shows an informational message with a touch-sized dismiss action.
Future<void> infoDialog(
  BuildContext context, {
  required String title,
  required String message,
  String actionLabel = 'OK',
}) async {
  final p = AppPalette.of(context);
  await showDialog<void>(
    context: context,
    animationStyle: animationStyleOf(context),
    builder: (ctx) => AlertDialog(
      title: Text(title),
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
      content: SingleChildScrollView(
        child: Text(
          message,
          style: TextStyle(fontSize: 13.5, height: 1.4, color: p.textMuted),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: touchButtonMinimumSize(ctx),
            visualDensity: touchVisualDensity(ctx),
          ),
          onPressed: () => Navigator.pop(ctx),
          child: Text(actionLabel),
        ),
      ],
    ),
  );
}

/// Asks for one line of text. Returns the trimmed text, or null if cancelled
/// or left empty (unless [allowEmpty] is true).
Future<String?> promptDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  required String confirmLabel,
  bool allowEmpty = false,
  int? maxLength = 60,
}) async {
  final result = await showDialog<String>(
    context: context,
    animationStyle: animationStyleOf(context),
    builder: (ctx) => _PromptDialog(
      title: title,
      initial: initial,
      hint: hint,
      confirmLabel: confirmLabel,
      maxLength: maxLength,
    ),
  );
  final t = result?.trim();
  return (t == null || (!allowEmpty && t.isEmpty)) ? null : t;
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.confirmLabel,
    required this.maxLength,
  });

  final String title;
  final String initial;
  final String hint;
  final String confirmLabel;
  final int? maxLength;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctl.text);

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return AlertDialog(
      title: Text(widget.title),
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _ctl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          maxLength: widget.maxLength,
          decoration: InputDecoration(hintText: widget.hint, counterText: ''),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: touchButtonMinimumSize(context),
            visualDensity: touchVisualDensity(context),
          ),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: touchButtonMinimumSize(context),
            visualDensity: touchVisualDensity(context),
          ),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// A snackbar with an Undo action that also auto-dismisses (Flutter keeps
/// snackbars that have an action on screen otherwise).
void showUndoSnack(BuildContext context, String message, VoidCallback onUndo) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      persist: false,
      duration: const Duration(seconds: 5),
      action: SnackBarAction(label: 'Undo', onPressed: onUndo),
    ),
    snackBarAnimationStyle: animationStyleOf(context),
  );
}

/// A plain snackbar.
void showInfoSnack(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    snackBarAnimationStyle: animationStyleOf(context),
  );
}
