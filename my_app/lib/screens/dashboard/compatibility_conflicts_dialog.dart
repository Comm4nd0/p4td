import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../services/data_service.dart';

/// One-line summary for the dashboard banner: how many incompatible pairs
/// share a pickup group and how many are merely in on the same day.
///
/// The distinction matters to whoever is reading it. A same-group pair rides
/// in the same van and needs one of them reassigning; a same-day pair is
/// split across drivers but will still meet once the groups mix at daycare,
/// so it needs watching rather than rerostering.
String compatibilityConflictSummary(List<CompatibilityConflict> conflicts) {
  final sameGroup = conflicts.where((c) => c.isSameGroup).length;
  final sameDay = conflicts.length - sameGroup;
  String pairs(int n) => n == 1 ? '1 pair' : '$n pairs';
  if (sameDay == 0) {
    return '${pairs(sameGroup)} in the same pickup group';
  }
  if (sameGroup == 0) {
    return '${pairs(sameDay)} in the daycare on the same day';
  }
  return '${pairs(sameGroup)} in the same pickup group, '
      '${pairs(sameDay)} in the daycare on the same day';
}

/// Read-only dialog listing the day's compatibility conflicts.
///
/// Same-pickup-group pairs come first, grouped by the driver they share.
/// Same-day pairs follow in their own section, each showing which driver
/// has which dog so staff know whose groups will meet.
Future<void> showCompatibilityConflictsDialog(
  BuildContext context,
  List<CompatibilityConflict> conflicts,
) {
  final byStaff = <String, List<CompatibilityConflict>>{};
  final sameDay = <CompatibilityConflict>[];
  for (final c in conflicts) {
    if (c.isSameGroup) {
      byStaff.putIfAbsent(c.staffMemberName, () => []).add(c);
    } else {
      sameDay.add(c);
    }
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
            if (byStaff.isNotEmpty) ...[
              const _SectionHeader(
                icon: PiconsDuotone.van,
                title: 'Same pickup & drop-off group',
                body:
                    'These dogs are flagged as incompatible but are assigned to the same staff member, so they ride together. Reassign one of them or update the note.',
              ),
              ...byStaff.entries.map((entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.key,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        ...entry.value.map((c) => _ConflictRow(
                              conflict: c,
                              detail: c.reasons.isNotEmpty
                                  ? c.reasons.first
                                  : null,
                            )),
                      ],
                    ),
                  )),
            ],
            if (sameDay.isNotEmpty) ...[
              if (byStaff.isNotEmpty) const Divider(height: 20),
              const _SectionHeader(
                icon: PiconsDuotone.house,
                title: 'In the daycare on the same day',
                body:
                    'These dogs are in different pickup groups, but the groups mix once everyone is at the daycare. Keep them apart during the day.',
              ),
              ...sameDay.map((c) => _ConflictRow(
                    conflict: c,
                    detail: [
                      _driverLine(c.dogAName, c.dogAStaffName),
                      _driverLine(c.dogBName, c.dogBStaffName),
                      if (c.reasons.isNotEmpty) c.reasons.first,
                    ].join('\n'),
                  )),
            ],
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

String _driverLine(String dogName, String? staffName) =>
    staffName == null || staffName.isEmpty
        ? '$dogName: no driver yet'
        : '$dogName: with $staffName';

class _SectionHeader extends StatelessWidget {
  final Object icon;
  final String title;
  final String body;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Picon(icon, size: 18, color: Colors.orange.shade700),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(body, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

class _ConflictRow extends StatelessWidget {
  final CompatibilityConflict conflict;
  final String? detail;

  const _ConflictRow({required this.conflict, this.detail});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Picon(PiconsDuotone.pawPrint, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${conflict.dogAName} + ${conflict.dogBName}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          if (detail != null && detail!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 2),
              child: Text(
                detail!,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.grey700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
