import 'dart:math' as math;

import '../../app.dart';
import '../../data/app_settings.dart';
import '../material.dart';
import '../shortcuts/shortcut_guards.dart';
import '../theme/app_theme.dart';
import '../widgets/touch.dart';
import '../toolbar_item_info.dart';

/// Choose which editor toolbar buttons show and in what order.
class ToolbarSettingsScreen extends StatefulWidget {
  const ToolbarSettingsScreen({super.key});

  @override
  State<ToolbarSettingsScreen> createState() => _ToolbarSettingsScreenState();
}

class _ToolbarSettingsScreenState extends State<ToolbarSettingsScreen> {
  late List<ToolbarItem> _order;
  late Set<ToolbarItem> _enabled;
  bool _ready = false;

  AppSettings get _settings => AppScope.of(context).settings;

  /// Enabled items in their saved order, then hidden ones in enum order.
  void _load(List<ToolbarItem> saved) {
    _enabled = saved.toSet();
    _order = [
      ...saved,
      for (final t in ToolbarItem.values)
        if (!_enabled.contains(t)) t,
    ];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_ready) {
      _ready = true;
      _load(_settings.toolbar);
    }
  }

  void _save() {
    _settings.toolbar = [
      for (final t in _order)
        if (_enabled.contains(t)) t,
    ];
  }

  void _toggle(ToolbarItem t, bool on) {
    setState(() => on ? _enabled.add(t) : _enabled.remove(t));
    _save();
  }

  void _reorder(int from, int to) {
    setState(() {
      _order.insert(to, _order.removeAt(from));
    });
    _save();
  }

  void _reset() {
    setState(() => _load(ToolbarItem.defaults));
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return backOnEscape(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Toolbar'),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: touchButtonMinimumSize(context),
                visualDensity: touchVisualDensity(context),
              ),
              onPressed: _reset,
              child: const Text('Reset to default'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, cons) {
            final side = math.max(12.0, (cons.maxWidth - 640) / 2);
            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(side + 4, 4, side + 4, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Drag to reorder. Switch buttons off to hide them.',
                      style: TextStyle(fontSize: 12.5, color: p.textMuted),
                    ),
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: EdgeInsets.fromLTRB(side, 0, side, 32),
                    buildDefaultDragHandles: false,
                    itemCount: _order.length,
                    onReorderItem: _reorder,
                    proxyDecorator: (child, _, _) =>
                        Material(color: Colors.transparent, child: child),
                    itemBuilder: (context, i) {
                      final t = _order[i];
                      final on = _enabled.contains(t);
                      return Padding(
                        key: ValueKey(t),
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Container(
                          height: 52,
                          decoration: BoxDecoration(
                            color: p.card,
                            borderRadius: BorderRadius.circular(
                              AppMetrics.controlRadius + 2,
                            ),
                            border: Border.all(color: p.cardBorder),
                          ),
                          child: Row(
                            children: [
                              ReorderableDragStartListener(
                                index: i,
                                child: SizedBox(
                                  width: 44,
                                  height: 52,
                                  child: Icon(
                                    Icons.drag_indicator_rounded,
                                    color: p.textFaint,
                                  ),
                                ),
                              ),
                              Icon(
                                t.icon,
                                size: 20,
                                color: on ? p.text : p.textFaint,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  t.label,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: on ? p.text : p.textMuted,
                                  ),
                                ),
                              ),
                              SizedBox(
                                height: 28,
                                child: FittedBox(
                                  child: Switch(
                                    value: on,
                                    onChanged: (v) => _toggle(t, v),
                                    activeThumbColor: p.onAccent,
                                    activeTrackColor: p.accent,
                                    inactiveThumbColor: p.textMuted,
                                    inactiveTrackColor: p.background,
                                    trackOutlineColor:
                                        WidgetStateProperty.resolveWith(
                                          (s) =>
                                              s.contains(WidgetState.selected)
                                              ? p.accent
                                              : p.cardBorder,
                                        ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
