import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/day_changes.dart';

/// "Changes vs a normal Wednesday" on the staff dashboard: every way the
/// selected day differs from the dogs' routine — dogs off, extra dogs in,
/// one-off transport and boarding — from `daily-assignments/changes/`.
///
/// Staff work from routine and the mistakes happen on the exceptions, so this
/// lists only the exceptions. Changes on the viewer's run are marked Yours;
/// late ones (made after the 18:00 summary for the day) are marked Late, and
/// while any late change on the viewer's run is unconfirmed the card is
/// outlined and offers Got it ([onConfirm]). Hidden when nothing differs.
/// Tapping a row hands its change to [onDogTap] — the dashboard opens the
/// dog's quick info there.
class DayChangesSection extends StatefulWidget {
  final DayChanges? changes;
  final Future<void> Function()? onConfirm;
  final ValueChanged<DayChange>? onDogTap;

  const DayChangesSection({super.key, required this.changes, this.onConfirm, this.onDogTap});

  @override
  State<DayChangesSection> createState() => _DayChangesSectionState();
}

class _DayChangesSectionState extends State<DayChangesSection> {
  bool _expanded = true;
  bool _confirming = false;

  @override
  Widget build(BuildContext context) {
    final changes = widget.changes;
    if (changes == null || changes.isEmpty) return const SizedBox.shrink();
    final toConfirm = changes.needsConfirming;
    final theme = Theme.of(context);
    final count = changes.changes.length;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: toConfirm.isNotEmpty
              ? const BorderSide(color: AppColors.warning, width: 2)
              : BorderSide(color: Colors.grey.shade300),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(children: [
                const Picon(PiconsDuotone.arrowsLeftRight, size: 20, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Changes vs a normal ${changes.weekday}',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                _countBadge(count),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: Colors.grey),
              ]),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            for (final change in changes.changes)
              DayChangeRow(
                change: change,
                onTap: widget.onDogTap == null ? null : () => widget.onDogTap!(change),
              ),
            if (toConfirm.isNotEmpty && widget.onConfirm != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.warning),
                  onPressed: _confirming ? null : _confirm,
                  icon: const Picon(PiconsDuotone.checkCircle, color: Colors.white),
                  label: Text(toConfirm.length == 1
                      ? 'Got it — 1 late change to my run'
                      : 'Got it — ${toConfirm.length} late changes to my run'),
                ),
              ),
          ],
        ]),
      ),
    );
  }

  Future<void> _confirm() async {
    setState(() => _confirming = true);
    try {
      await widget.onConfirm!();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not confirm: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Widget _countBadge(int count) => Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.warning,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('$count',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
      );
}

/// One change: what happened to which dog, whose run it touches, who did it.
class DayChangeRow extends StatelessWidget {
  final DayChange change;
  final VoidCallback? onTap;

  const DayChangeRow({super.key, required this.change, this.onTap});

  static (Object, Color, String) styleFor(String kind) {
    switch (kind) {
      case DayChange.cancelled:
        return (PiconsDuotone.calendarX, AppColors.error, 'Not coming');
      case DayChange.extra:
        return (PiconsDuotone.plusCircle, AppColors.extraDay, 'Extra');
      case DayChange.transport:
        return (PiconsDuotone.arrowsLeftRight, AppColors.warning, 'Transport');
      default:
        return (PiconsDuotone.house, Colors.deepPurple, 'Boarding');
    }
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = styleFor(change.kind);
    final staffBits = <String>[
      if (change.usualStaffName != null && change.usualStaffName != change.staffName)
        'usually ${change.usualStaffName}',
      if (change.staffName != null) 'today ${change.staffName}',
      if (change.isExtra && change.staffName == null) 'no driver yet',
    ];
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Picon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(change.dogName, style: const TextStyle(fontWeight: FontWeight.w600)),
              _tag(label, color),
              if (change.mine) _tag('Yours', AppColors.info),
              if (change.late) _tag('Late', AppColors.warning),
            ]),
            const SizedBox(height: 2),
            Text(
              [change.description, ...staffBits].join(' · '),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ]),
        ),
        if (change.mine && change.late && change.acknowledged)
          const Padding(
            padding: EdgeInsets.only(left: 6, top: 2),
            child: Picon(PiconsDuotone.checkCircle, size: 18, color: AppColors.success),
          ),
        if (onTap != null)
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 2),
            child: Icon(Icons.chevron_right, size: 18, color: Colors.grey),
          ),
      ]),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      );
}
