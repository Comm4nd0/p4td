import 'package:flutter/material.dart';

import '../../models/dog_change_log.dart';
import '../../widgets/dog_change_log_tile.dart';

/// The bottom of the staff dashboard: the newest few things anyone did —
/// a reply, an approval, a defect, a check, a dog's details — with "View
/// all" opening the full activity log.
class ChangeLogSection extends StatelessWidget {
  static const int summaryCount = 5;

  final List<DogChangeLog> entries;
  final bool loading;
  final bool failed;
  final VoidCallback? onViewAll;

  const ChangeLogSection({
    super.key,
    required this.entries,
    this.loading = false,
    this.failed = false,
    this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final rows = entries.take(summaryCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Recent Activity',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            if (onViewAll != null)
              TextButton(onPressed: onViewAll, child: const Text('View all')),
          ],
        ),
        const SizedBox(height: 8),
        if (failed)
          _message("Couldn't load recent activity — pull down to retry")
        else if (rows.isEmpty)
          _message(loading ? 'Loading…' : 'No activity recorded yet')
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  DogChangeLogTile(entry: rows[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _message(String text) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(child: Text(text, style: TextStyle(color: Colors.grey[500]))),
        ),
      );
}
