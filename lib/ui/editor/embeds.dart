import 'dart:typed_data';

import 'package:flutter_quill/flutter_quill.dart';

import '../../data/note_repository.dart';
import '../material.dart';
import '../theme/app_theme.dart';

/// Shows image embeds whose source is a stored attachment (`att:<hash>`).
///
/// Anything else (a file path or URL left over from an import, an attachment
/// that has not arrived from another device yet) renders as a labelled
/// placeholder. The embed stays in the document untouched either way.
class AttachmentImageEmbedBuilder extends EmbedBuilder {
  AttachmentImageEmbedBuilder(this.repo);

  final NoteRepository repo;
  final _cache = <String, Uint8List?>{};

  @override
  String get key => BlockEmbed.imageType;

  @override
  bool get expanded => false;

  Uint8List? _bytes(String source) {
    if (_cache.containsKey(source)) return _cache[source];
    final bytes = repo.getAttachment(source);
    if (_cache.length > 24) {
      _cache.remove(_cache.keys.first);
    }
    // A missing attachment is not cached: it may arrive later.
    if (bytes != null) _cache[source] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final source = '${embedContext.node.value.data}';
    final p = AppPalette.of(context);
    Widget placeholder(String text) => Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
        border: Border.all(color: p.cardBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_not_supported_outlined,
            size: 18,
            color: p.textFaint,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(color: p.textMuted, fontSize: 13),
            ),
          ),
        ],
      ),
    );

    if (!source.startsWith(attachmentScheme)) {
      return placeholder('Image not available (it was not part of the import)');
    }
    final bytes = _bytes(source);
    if (bytes == null) {
      return placeholder('Image has not arrived on this device yet');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder('Image could not be shown'),
          ),
        ),
      ),
    );
  }
}

/// Fallback for embed types the editor has no renderer for (for example
/// tables from the legacy app). Shown as a label; the embed is kept intact.
class UnknownEmbedBuilder extends EmbedBuilder {
  const UnknownEmbedBuilder();

  @override
  String get key => 'unknown';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final p = AppPalette.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.cardBorder),
      ),
      child: Text(
        'Unsupported content (${embedContext.node.value.type})',
        style: TextStyle(color: p.textMuted, fontSize: 13),
      ),
    );
  }
}
