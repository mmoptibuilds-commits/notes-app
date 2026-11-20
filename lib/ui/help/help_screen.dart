import '../material.dart';
import '../onboarding/welcome_points.dart';
import '../theme/app_theme.dart';
import 'help_shortcut.dart';
import 'help_topics.dart';

/// Offline help for the whole app. It has no network use and does not read
/// settings itself: the caller passes the keyboard shortcuts, the app version
/// and the action that opens the licence page.
class HelpScreen extends StatefulWidget {
  const HelpScreen({
    super.key,
    required this.shortcuts,
    this.appVersion,
    this.onOpenLicences,
  });

  final List<HelpShortcut> shortcuts;

  /// Shown on the About topic when set.
  final String? appVersion;

  /// Opens the open-source licence page. The button is hidden when null.
  final VoidCallback? onOpenLicences;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  String _query = '';

  List<HelpTopic> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return helpTopics;
    return [
      for (final t in helpTopics)
        if (_searchText(t).contains(q)) t,
    ];
  }

  String _searchText(HelpTopic t) {
    final buf = StringBuffer(t.title)
      ..write(' ')
      ..writeAll(t.paragraphs, ' ')
      ..write(' ')
      ..writeAll(t.bullets, ' ');
    if (t.kind == HelpTopicKind.welcome) {
      for (final point in welcomePoints) {
        buf
          ..write(' ')
          ..write(point.title)
          ..write(' ')
          ..write(point.body);
      }
    }
    if (t.kind == HelpTopicKind.shortcuts) {
      for (final s in widget.shortcuts) {
        buf
          ..write(' ')
          ..write(s.keys)
          ..write(' ')
          ..write(s.description);
      }
    }
    return buf.toString().toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final topics = _visible;
    final searching = _query.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search help',
                    prefixIcon: const Icon(Icons.search_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: topics.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No help topics match "${_query.trim()}".',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: p.textMuted),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
                        children: [
                          for (final t in topics)
                            _TopicTile(
                              key: ValueKey('${t.id}/$searching'),
                              topic: t,
                              expanded: searching,
                              shortcuts: widget.shortcuts,
                              appVersion: widget.appVersion,
                              onOpenLicences: widget.onOpenLicences,
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopicTile extends StatelessWidget {
  const _TopicTile({
    super.key,
    required this.topic,
    required this.expanded,
    required this.shortcuts,
    required this.appVersion,
    required this.onOpenLicences,
  });

  final HelpTopic topic;
  final bool expanded;
  final List<HelpShortcut> shortcuts;
  final String? appVersion;
  final VoidCallback? onOpenLicences;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
        border: Border.all(color: p.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: expanded,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Semantics(
          header: true,
          child: Text(
            topic.title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: p.text,
            ),
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TopicBody(
            topic: topic,
            shortcuts: shortcuts,
            appVersion: appVersion,
            onOpenLicences: onOpenLicences,
          ),
        ],
      ),
    );
  }
}

class _TopicBody extends StatelessWidget {
  const _TopicBody({
    required this.topic,
    required this.shortcuts,
    required this.appVersion,
    required this.onOpenLicences,
  });

  final HelpTopic topic;
  final List<HelpShortcut> shortcuts;
  final String? appVersion;
  final VoidCallback? onOpenLicences;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final style = TextStyle(fontSize: 14.5, height: 1.5, color: p.textMuted);
    final children = <Widget>[
      for (final t in topic.paragraphs) ...[
        Text(t, style: style),
        const SizedBox(height: 10),
      ],
    ];

    switch (topic.kind) {
      case HelpTopicKind.welcome:
        children.add(const WelcomeList());
      case HelpTopicKind.shortcuts:
        if (shortcuts.isEmpty) {
          children.add(
            Text('Keyboard shortcuts are not listed here yet.', style: style),
          );
        } else {
          for (final s in shortcuts) {
            children.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 120),
                      child: Text(
                        s.keys,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(s.description, style: style)),
                  ],
                ),
              ),
            );
          }
        }
      case HelpTopicKind.about:
        if (appVersion != null) {
          children.add(Text('Version $appVersion', style: style));
          children.add(const SizedBox(height: 10));
        }
        if (onOpenLicences != null) {
          children.add(
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  side: BorderSide(color: p.cardBorder),
                ),
                onPressed: onOpenLicences,
                child: const Text('Open-source licences'),
              ),
            ),
          );
        }
      case HelpTopicKind.text:
        break;
    }

    for (final b in topic.bullets) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Text('•  ', style: style.copyWith(color: p.textFaint)),
              ),
              Expanded(child: Text(b, style: style)),
            ],
          ),
        ),
      );
    }

    if (children.isNotEmpty && children.last is SizedBox) {
      children.removeLast();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
