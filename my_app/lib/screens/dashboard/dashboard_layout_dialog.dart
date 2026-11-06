import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../models/dashboard_layout.dart';

/// Below this width the dashboard is one scrolling column, so any section can
/// go anywhere; at it and above, the date's sections sit in a left column and
/// the rest beside them.
const double dashboardWideLayoutWidth = 900;

/// The "Layout" quick action: drag the dashboard's sections into the order
/// this person wants. Pure UI — returns the new order, or null when cancelled,
/// and the caller saves it.
Future<List<DashboardSection>?> showDashboardLayoutDialog(
  BuildContext context, {
  required List<DashboardSection> current,
}) {
  return showDialog<List<DashboardSection>>(
    context: context,
    builder: (_) => _DashboardLayoutDialog(current: current),
  );
}

class _DashboardLayoutDialog extends StatefulWidget {
  final List<DashboardSection> current;
  const _DashboardLayoutDialog({required this.current});

  @override
  State<_DashboardLayoutDialog> createState() => _DashboardLayoutDialogState();
}

class _DashboardLayoutDialogState extends State<_DashboardLayoutDialog> {
  static const double _rowHeight = 52;

  late List<DashboardSection> _order = List.of(widget.current);

  void _move(int from, int to) {
    setState(() {
      _order.insert(to, _order.removeAt(from));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final isStandard = listEquals(_order, DashboardSection.values);
    return AlertDialog(
      title: const Text('Dashboard layout'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              size.width >= dashboardWideLayoutWidth
                  ? 'Drag to reorder. On a screen this wide the day\'s sections '
                      'stay on the left and the others on the right, each in '
                      'this order.'
                  : 'Drag to put what you use most at the top. This only '
                      'changes your dashboard.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: math.min(_order.length * _rowHeight, size.height * 0.5),
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: _order.length,
                onReorderItem: _move,
                itemBuilder: (context, index) {
                  final section = _order[index];
                  return SizedBox(
                    key: ValueKey(section),
                    height: _rowHeight,
                    child: Row(children: [
                      Expanded(
                        child: Text(section.label, style: theme.textTheme.bodyMedium),
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        // Coloured so the padding counts as the handle, not
                        // just the icon: this is a thumb target.
                        child: Container(
                          color: Colors.transparent,
                          padding: const EdgeInsets.all(12),
                          child: Picon(PiconsDuotone.dotsSixVertical,
                              size: 22, color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: isStandard
              ? null
              : () => setState(() => _order = List.of(DashboardSection.values)),
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_order),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
