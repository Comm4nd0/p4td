import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';
import '../models/dog_change_log.dart';
import '../utils/date_formats.dart';

PiconDuotoneData dogChangeIcon(String action) => switch (action) {
      'CREATED' => PiconsDuotone.plus,
      'DELETED' => PiconsDuotone.trash,
      'OWNER_CHANGED' => PiconsDuotone.user,
      'VACCINATION' => PiconsDuotone.firstAidKit,
      'PHOTO' => PiconsDuotone.images,
      'NOTE' => PiconsDuotone.notePencil,
      _ => PiconsDuotone.pencilSimple,
    };

Color dogChangeColor(String action) => switch (action) {
      'CREATED' => AppColors.success,
      'DELETED' => AppColors.error,
      'VACCINATION' => AppColors.warning,
      _ => AppColors.primary,
    };

/// One change-log entry. The summary line is always shown; when the entry
/// carries field diffs the tile expands to list each as "old → new". Used by
/// both the full log screen and the dashboard's recent-changes summary.
class DogChangeLogTile extends StatelessWidget {
  final DogChangeLog entry;

  /// Name the dog on the tile — the master log; a single dog's log omits it.
  final bool showDog;

  /// Start expanded (the full screen); collapsed on the dashboard.
  final bool initiallyExpanded;

  const DogChangeLogTile({
    super.key,
    required this.entry,
    this.showDog = true,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = dogChangeColor(entry.action);
    final who = [
      entry.actorName,
      if (entry.source != 'APP') entry.sourceDisplay.toLowerCase(),
    ].join(' · ');
    final title = Text(
      showDog ? '${entry.dogName}${entry.isDeleted ? ' (deleted)' : ''} — ${entry.summary}' : entry.summary,
      style: const TextStyle(fontSize: 14),
    );
    final subtitle = Text(
      '$who · ${ukDateTime(entry.createdAt.toLocal())}',
      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
    );
    final leading = Picon(dogChangeIcon(entry.action), color: color, size: 20);

    if (entry.changes.isEmpty) {
      return ListTile(dense: true, leading: leading, title: title, subtitle: subtitle);
    }
    return ExpansionTile(
      dense: true,
      leading: leading,
      title: title,
      subtitle: subtitle,
      initiallyExpanded: initiallyExpanded,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(52, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final change in entry.changes) _ChangeRow(change: change)],
    );
  }
}

class _ChangeRow extends StatelessWidget {
  final DogFieldChange change;
  const _ChangeRow({required this.change});

  @override
  Widget build(BuildContext context) {
    final old = change.oldValue.isEmpty ? '—' : change.oldValue;
    final now = change.newValue.isEmpty ? '—' : change.newValue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
          children: [
            TextSpan(text: '${change.label}: ', style: const TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(
              text: old,
              style: TextStyle(color: Colors.grey[600], decoration: TextDecoration.lineThrough),
            ),
            const TextSpan(text: '  →  '),
            TextSpan(text: now, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
