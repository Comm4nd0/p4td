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

/// Dialog listing the day's compatibility conflicts.
///
/// Same-pickup-group pairs come first, grouped by the driver they share.
/// Same-day pairs follow in their own section, each showing which driver
/// has which dog so staff know whose groups will meet. With [onAcknowledge]
/// each pair can be acknowledged — "someone has seen this" for the whole
/// team — and the dialog re-renders with the list the callback returns.
Future<void> showCompatibilityConflictsDialog(
  BuildContext context,
  List<CompatibilityConflict> conflicts, {
  Future<List<CompatibilityConflict>> Function(CompatibilityConflict conflict)? onAcknowledge,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _ConflictsDialog(conflicts: conflicts, onAcknowledge: onAcknowledge),
  );
}

class _ConflictsDialog extends StatefulWidget {
  final List<CompatibilityConflict> conflicts;
  final Future<List<CompatibilityConflict>> Function(CompatibilityConflict conflict)? onAcknowledge;

  const _ConflictsDialog({required this.conflicts, this.onAcknowledge});

  @override
  State<_ConflictsDialog> createState() => _ConflictsDialogState();
}

class _ConflictsDialogState extends State<_ConflictsDialog> {
  late List<CompatibilityConflict> _conflicts = widget.conflicts;
  CompatibilityConflict? _busy;

  Future<void> _acknowledge(CompatibilityConflict conflict) async {
    final handler = widget.onAcknowledge;
    if (handler == null) return;
    setState(() => _busy = conflict);
    try {
      final updated = await handler(conflict);
      if (mounted) setState(() => _conflicts = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not acknowledge: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final byStaff = <String, List<CompatibilityConflict>>{};
    final sameDay = <CompatibilityConflict>[];
    for (final c in _conflicts) {
      if (c.isSameGroup) {
        byStaff.putIfAbsent(c.staffMemberName, () => []).add(c);
      } else {
        sameDay.add(c);
      }
    }
    Widget row(CompatibilityConflict c, String? detail) => _ConflictRow(
          conflict: c,
          detail: detail,
          onAcknowledge: widget.onAcknowledge == null || c.isAcknowledged
              ? null
              : () => _acknowledge(c),
          busy: _busy == c,
        );
    return AlertDialog(
      title: const Text('Grouping conflicts'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_conflicts.isEmpty)
              const Text('No grouping conflicts today.'),
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
                        ...entry.value.map((c) => row(
                              c,
                              c.reasons.isNotEmpty ? c.reasons.first : null,
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
              ...sameDay.map((c) => row(
                    c,
                    [
                      _driverLine(c.dogAName, c.dogAStaffName),
                      _driverLine(c.dogBName, c.dogBStaffName),
                      if (c.reasons.isNotEmpty) c.reasons.first,
                    ].join('\n'),
                  )),
            ],
            if (widget.onAcknowledge != null && _conflicts.any((c) => !c.isAcknowledged))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Acknowledging tells the team someone has seen the pair and is handling it. The warning stays until the dogs are regrouped.',
                  style: TextStyle(fontSize: 12, color: AppColors.grey600),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
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
  final VoidCallback? onAcknowledge;
  final bool busy;

  const _ConflictRow({
    required this.conflict,
    this.detail,
    this.onAcknowledge,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final acknowledgedAt = conflict.acknowledgedAt;
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
            if (conflict.isAcknowledged)
              Tooltip(
                message: 'Acknowledged by ${conflict.acknowledgedByName}',
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Picon(PiconsDuotone.checkCircle, size: 14, color: AppColors.success),
                  const SizedBox(width: 4),
                  Text(
                    acknowledgedAt == null
                        ? conflict.acknowledgedByName!
                        : '${conflict.acknowledgedByName} · ${TimeOfDay.fromDateTime(acknowledgedAt.toLocal()).format(context)}',
                    style: const TextStyle(fontSize: 11, color: AppColors.success, fontWeight: FontWeight.w600),
                  ),
                ]),
              )
            else if (onAcknowledge != null)
              busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(
                      onPressed: onAcknowledge,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('Acknowledge', style: TextStyle(fontSize: 12)),
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
