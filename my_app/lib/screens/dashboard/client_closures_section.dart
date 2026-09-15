import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/closure_day.dart';
import '../../utils/date_formats.dart';

/// The next few days the facility is shut or running reduced, so an owner
/// isn't surprised by a bank holiday. Tapping the header opens the full list.
class ClientClosuresSection extends StatelessWidget {
  final DateTime today;
  final List<ClosureDay> closures;

  /// How many days ahead [closures] was fetched for; names the empty state.
  final int horizonDays;
  final VoidCallback? onOpen;

  static const int maxRows = 3;

  const ClientClosuresSection({
    super.key,
    required this.today,
    required this.closures,
    required this.horizonDays,
    this.onOpen,
  });

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static List<ClosureDay> upcoming(List<ClosureDay> all, DateTime today) {
    final day = _dateOnly(today);
    return all.where((c) => !_dateOnly(c.date).isBefore(day)).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
  }

  @override
  Widget build(BuildContext context) {
    final rows = upcoming(closures, today);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Holidays & Closures',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            if (onOpen != null)
              TextButton(onPressed: onOpen, child: const Text('All')),
          ],
        ),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text('No closures in the next $horizonDays days',
                    style: TextStyle(color: Colors.grey[500])),
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < rows.length && i < maxRows; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _row(rows[i]),
                ],
                if (rows.length > maxRows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('+${rows.length - maxRows} more',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(ClosureDay c) {
    final closed = c.closureType == ClosureType.closed;
    final color = closed ? AppColors.error : AppColors.warning;
    return ListTile(
      dense: true,
      leading: Picon(PiconsDuotone.calendarX, color: color),
      title: Text(ukDateWithDay(c.date)),
      subtitle: Text(
        c.reason.isNotEmpty ? '${c.closureType.displayName} · ${c.reason}' : c.closureType.displayName,
        style: TextStyle(fontSize: 12, color: color),
      ),
      onTap: onOpen,
    );
  }
}
