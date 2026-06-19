import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../services/data_service.dart';

/// Read-only dialog listing the day's compatibility conflicts grouped by staff.
///
/// Extracted verbatim from [UnifiedDashboardScreen] (audit F14). Call
/// [showCompatibilityConflictsDialog] with the day's conflicts.
Future<void> showCompatibilityConflictsDialog(
  BuildContext context,
  List<CompatibilityConflict> conflicts,
) {
  final byStaff = <String, List<CompatibilityConflict>>{};
  for (final c in conflicts) {
    byStaff.putIfAbsent(c.staffMemberName, () => []).add(c);
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Grouping conflicts'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'These dogs are flagged as incompatible but are assigned to the same staff member. Reassign one of them or update the note.',
            ),
            const SizedBox(height: 12),
            ...byStaff.entries.map((entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.key,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      ...entry.value.map((c) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const Picon(PiconsDuotone.pawPrint, size: 16),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '${c.dogAName} + ${c.dogBName}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ]),
                                if (c.reasons.isNotEmpty)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(left: 22, top: 2),
                                    child: Text(
                                      c.reasons.first,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.grey700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          )),
                    ],
                  ),
                )),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
