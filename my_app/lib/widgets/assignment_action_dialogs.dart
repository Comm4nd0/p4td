import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/daily_dog_assignment.dart';

/// Shared assignment-action dialogs (F12 dedup).
///
/// These are standalone async builders extracted from the four screens that
/// edit daily assignments (`all_dogs_today_screen`, `staff_dog_detail_screen`,
/// `pickup_map_screen`, `unified_dashboard_screen`). They take a [BuildContext]
/// plus the data they need and RETURN the user's choice. They deliberately do
/// NOT touch the DataService or call setState — each screen keeps its own
/// orchestration (call the dialog, then run its data mutation + reload), so the
/// State-coupled behaviour is unchanged.

/// Result of [showTransportDialog]: the edited transport selection together
/// with the effective (dog-default) values captured when the dialog opened, so
/// the caller can compute the exact `setAssignmentTransport` arguments the
/// inline copies used.
class TransportEdit {
  /// Tri-state per field: null = use dog default, true = owner, false = staff.
  final bool? brings;
  final bool? collects;
  final TimeOfDay? bringsTime;
  final TimeOfDay? collectsTime;

  /// The dog-default values as they were when the dialog opened.
  final bool effectiveBringsAtOpen;
  final bool effectiveCollectsAtOpen;

  const TransportEdit({
    required this.brings,
    required this.collects,
    required this.bringsTime,
    required this.collectsTime,
    required this.effectiveBringsAtOpen,
    required this.effectiveCollectsAtOpen,
  });

  /// Resolved drop-off time to persist: only kept when drop-off resolves to
  /// "owner brings", mirroring the inline `setAssignmentTransport` calls.
  TimeOfDay? get resolvedBringsTime =>
      (brings ?? effectiveBringsAtOpen) ? bringsTime : null;

  /// Resolved pick-up time to persist (see [resolvedBringsTime]).
  TimeOfDay? get resolvedCollectsTime =>
      (collects ?? effectiveCollectsAtOpen) ? collectsTime : null;
}

String _formatTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "Apply change" scope dialog — just this day vs. from now on.
///
/// Returns the chosen [AssignmentScope], or null if cancelled. Labels default
/// to the plain wording used by the map screen; callers that customise the
/// title/labels (all-dogs-today, staff-dog-detail) pass their own.
Future<AssignmentScope?> promptAssignmentScope(
  BuildContext context, {
  String title = 'Apply change',
  String justThisDayLabel = 'Just this day',
  String fromNowOnLabel = 'From now on',
}) {
  return showDialog<AssignmentScope>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: const Text('Apply this change to only this day, or to every week going forward?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, AssignmentScope.justThisDay), child: Text(justThisDayLabel)),
        FilledButton(onPressed: () => Navigator.pop(context, AssignmentScope.fromNowOn), child: Text(fromNowOnLabel)),
      ],
    ),
  );
}

/// Transport-editing dialog for a single [assignment].
///
/// Returns a [TransportEdit] when the user taps Save, or null on cancel. The
/// caller is responsible for persisting via `setAssignmentTransport` and any
/// setState/reload.
Future<TransportEdit?> showTransportDialog(
  BuildContext context,
  DailyDogAssignment assignment,
) async {
  // Tri-state per field: null = use dog default, true = owner, false = staff.
  bool? brings = assignment.ownerBrings;
  bool? collects = assignment.ownerCollects;
  TimeOfDay? bringsTime = assignment.ownerBringsTime ?? assignment.effectiveOwnerBringsTime;
  TimeOfDay? collectsTime = assignment.ownerCollectsTime ?? assignment.effectiveOwnerCollectsTime;

  final effectiveBringsAtOpen = assignment.effectiveOwnerBrings;
  final effectiveCollectsAtOpen = assignment.effectiveOwnerCollects;

  String chipLabel(bool? value, bool effective) {
    if (value == null) return 'Default (${effective ? 'owner' : 'staff'})';
    return value ? 'Owner' : 'Staff';
  }

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Transport: ${assignment.dogName}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Drop-off (morning)',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              SegmentedButton<Object>(
                segments: const [
                  ButtonSegment(value: 'default', label: Text('Default')),
                  ButtonSegment(value: true, label: Text('Owner')),
                  ButtonSegment(value: false, label: Text('Staff')),
                ],
                selected: {brings == null ? 'default' : brings!},
                onSelectionChanged: (s) {
                  setDialogState(() {
                    final v = s.first;
                    brings = v == 'default' ? null : v as bool;
                  });
                },
              ),
              Text(brings == null
                  ? chipLabel(brings, effectiveBringsAtOpen)
                  : '',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
              if ((brings ?? effectiveBringsAtOpen) == true) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Picon(PiconsDuotone.clock, size: 18),
                  label: Text(bringsTime == null
                      ? 'Set drop-off time'
                      : 'Drop-off at ${_formatTime(bringsTime!)}'),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: bringsTime ?? const TimeOfDay(hour: 8, minute: 0),
                    );
                    if (picked != null) setDialogState(() => bringsTime = picked);
                  },
                ),
                if (bringsTime != null)
                  TextButton(
                    onPressed: () => setDialogState(() => bringsTime = null),
                    child: const Text('Clear time', style: TextStyle(fontSize: 12)),
                  ),
              ],
              const Divider(height: 24),
              Text('Pick-up (evening)',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              SegmentedButton<Object>(
                segments: const [
                  ButtonSegment(value: 'default', label: Text('Default')),
                  ButtonSegment(value: true, label: Text('Owner')),
                  ButtonSegment(value: false, label: Text('Staff')),
                ],
                selected: {collects == null ? 'default' : collects!},
                onSelectionChanged: (s) {
                  setDialogState(() {
                    final v = s.first;
                    collects = v == 'default' ? null : v as bool;
                  });
                },
              ),
              Text(collects == null
                  ? chipLabel(collects, effectiveCollectsAtOpen)
                  : '',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
              if ((collects ?? effectiveCollectsAtOpen) == true) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Picon(PiconsDuotone.clock, size: 18),
                  label: Text(collectsTime == null
                      ? 'Set pick-up time'
                      : 'Pick-up at ${_formatTime(collectsTime!)}'),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: collectsTime ?? const TimeOfDay(hour: 17, minute: 0),
                    );
                    if (picked != null) setDialogState(() => collectsTime = picked);
                  },
                ),
                if (collectsTime != null)
                  TextButton(
                    onPressed: () => setDialogState(() => collectsTime = null),
                    child: const Text('Clear time', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    ),
  );

  if (saved != true) return null;
  return TransportEdit(
    brings: brings,
    collects: collects,
    bringsTime: bringsTime,
    collectsTime: collectsTime,
    effectiveBringsAtOpen: effectiveBringsAtOpen,
    effectiveCollectsAtOpen: effectiveCollectsAtOpen,
  );
}

/// Staff-picker dialog backed by an already-resolved [staffMembers] list.
///
/// Returns the chosen staff id, or null on cancel / empty list. This is the
/// pure-dialog half: callers that need to lazily load staff (and apply the
/// availability sort) should use [pickStaffMember] instead.
///
/// [availableStaffIds] greys out off-duty staff and (when non-empty) drives the
/// availability colour of the leading dot. [leadingDotBuilder] lets a caller
/// override the dot — the map screen colours it by route instead of by
/// availability.
Future<int?> pickStaffMemberFromList(
  BuildContext context, {
  required String title,
  required List<Map<String, dynamic>> staffMembers,
  required Set<int> availableStaffIds,
  String? subtitle,
  String confirmLabel = 'Assign',
  String dropdownLabel = 'Staff member',
  String emptyMessage = 'No staff members available.',
  Widget Function(int staffId, bool isAvailable)? leadingDotBuilder,
}) async {
  if (staffMembers.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(emptyMessage)));
    return null;
  }

  Widget defaultDot(int staffId, bool isAvailable) =>
      Picon(PiconsDuotone.circle, size: 10, color: isAvailable ? AppColors.success : AppColors.grey400);
  final dotBuilder = leadingDotBuilder ?? defaultDot;

  int? picked;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (subtitle != null) ...[
              Text(subtitle, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              const SizedBox(height: 12),
            ],
            DropdownButtonFormField<int>(
              decoration: InputDecoration(labelText: dropdownLabel),
              value: picked,
              items: staffMembers.map((s) {
                final name = (s['first_name'] != null && s['first_name'].toString().isNotEmpty)
                    ? s['first_name'].toString()
                    : s['username'].toString();
                final staffId = s['id'] as int;
                final isAvailable = availableStaffIds.isEmpty || availableStaffIds.contains(staffId);
                return DropdownMenuItem<int>(
                  value: staffId,
                  child: Row(children: [
                    dotBuilder(staffId, isAvailable),
                    const SizedBox(width: 8),
                    Text(name, style: TextStyle(color: isAvailable ? null : AppColors.grey500)),
                    if (!isAvailable) const Text(' (off)', style: TextStyle(fontSize: 11, color: AppColors.grey400)),
                  ]),
                );
              }).toList(),
              onChanged: (v) => setDialogState(() => picked = v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: picked == null ? null : () => Navigator.pop(context, true), child: Text(confirmLabel)),
        ],
      ),
    ),
  );
  return (result == true) ? picked : null;
}

/// Staff-picker that resolves the staff list itself when [staffMembers] is
/// empty, loading via [loadStaff] and the available-for-date set via
/// [loadAvailableIds] (falling back to "everyone available" when that lookup
/// fails). Off-duty staff are sorted to the bottom. Returns the chosen staff id
/// or null.
///
/// NOTE (F12): this is the unified, more-complete version. The old
/// `pickup_map_screen` copy omitted the [loadAvailableIds] fallback and the
/// availability sort — both are restored here, fixing that latent drift.
Future<int?> pickStaffMember(
  BuildContext context, {
  required String title,
  required List<Map<String, dynamic>> initialStaffMembers,
  required Set<int> initialAvailableStaffIds,
  required Future<List<Map<String, dynamic>>> Function() loadStaff,
  required Future<List<Map<String, dynamic>>> Function() loadAvailableIds,
  int? currentStaffId,
  String? subtitle,
  String confirmLabel = 'Assign',
  String dropdownLabel = 'Staff member',
  String emptyMessage = 'No staff members available.',
  Widget Function(int staffId, bool isAvailable)? leadingDotBuilder,
}) async {
  List<Map<String, dynamic>> staffMembers = List.of(initialStaffMembers);
  Set<int> availableIds = Set.of(initialAvailableStaffIds);
  if (staffMembers.isEmpty) {
    try {
      staffMembers = await loadStaff();
      try {
        final available = await loadAvailableIds();
        availableIds = available.map((s) => s['id'] as int).toSet();
      } catch (_) {
        availableIds = staffMembers.map((s) => s['id'] as int).toSet();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load staff: $e')));
      }
      return null;
    }
  }

  if (currentStaffId != null) {
    staffMembers = staffMembers.where((s) => s['id'] != currentStaffId).toList();
  }
  staffMembers.sort((a, b) {
    final aAvail = availableIds.isEmpty || availableIds.contains(a['id'] as int);
    final bAvail = availableIds.isEmpty || availableIds.contains(b['id'] as int);
    if (aAvail && !bAvail) return -1;
    if (!aAvail && bAvail) return 1;
    return 0;
  });

  if (!context.mounted) return null;
  return pickStaffMemberFromList(
    context,
    title: title,
    staffMembers: staffMembers,
    availableStaffIds: availableIds,
    subtitle: subtitle,
    confirmLabel: confirmLabel,
    dropdownLabel: dropdownLabel,
    emptyMessage: emptyMessage,
    leadingDotBuilder: leadingDotBuilder,
  );
}
