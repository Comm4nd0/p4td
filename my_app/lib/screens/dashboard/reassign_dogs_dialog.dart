import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/daily_dog_assignment.dart';

/// What the user picked in the reassign-dogs dialog: which of the day's
/// assignments to move, who to move them to, and whether the change is for
/// this day only or every week going forward.
class ReassignDogsSelection {
  final List<int> assignmentIds;
  final int staffId;
  final AssignmentScope scope;
  const ReassignDogsSelection({
    required this.assignmentIds,
    required this.staffId,
    required this.scope,
  });
}

/// Display name for a `staff_members` row: first name, else the username.
String staffDisplayName(Map<String, dynamic> staff) {
  final first = staff['first_name'];
  if (first != null && first.toString().isNotEmpty) return first.toString();
  return staff['username'].toString();
}

/// Searchable multi-select dialog for handing one or more of the day's dogs
/// to another staff member — the "Reassign Dogs" quick action.
///
/// [assignments] is the day's roster (the caller fetches it fresh). Pick the
/// target staff member first or last, it doesn't matter: dogs already with the
/// chosen person can't be ticked, and any that were ticked before the choice
/// are dropped from the selection. Search matches the dog's name or its
/// current driver, so "alice" lists everything Alice has today. The dialog is
/// pure UI: it returns a [ReassignDogsSelection] (or null when cancelled) and
/// the caller makes the API call.
Future<ReassignDogsSelection?> showReassignDogsDialog({
  required BuildContext context,
  required String dateLabel,
  required String weekdayLabel,
  required List<DailyDogAssignment> assignments,
  required List<Map<String, dynamic>> staffMembers,
  required Set<int> availableStaffIds,
}) async {
  int? selectedStaffId;
  final selectedIds = <int>{};
  var scope = AssignmentScope.justThisDay;
  final searchController = TextEditingController();
  var query = '';

  bool isAvailable(int staffId) =>
      availableStaffIds.isEmpty || availableStaffIds.contains(staffId);

  final sortedStaff = List<Map<String, dynamic>>.from(staffMembers)
    ..sort((a, b) {
      final aAvail = isAvailable(a['id'] as int);
      final bAvail = isAvailable(b['id'] as int);
      if (aAvail && !bAvail) return -1;
      if (!aAvail && bAvail) return 1;
      return 0;
    });

  List<DailyDogAssignment> filtered() {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return assignments;
    return assignments
        .where((a) =>
            a.dogName.toLowerCase().contains(q) ||
            a.staffMemberName.toLowerCase().contains(q))
        .toList();
  }

  bool alreadyWithTarget(DailyDogAssignment a) =>
      selectedStaffId != null && a.staffMemberId == selectedStaffId;

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final shown = filtered();
        final selectable = shown.where((a) => !alreadyWithTarget(a)).toList();
        final allShownSelected = selectable.isNotEmpty &&
            selectable.every((a) => selectedIds.contains(a.id));

        return AlertDialog(
          title: Text('Reassign Dogs — $dateLabel'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<int>(
                    decoration:
                        const InputDecoration(labelText: 'Reassign to'),
                    value: selectedStaffId,
                    items: sortedStaff.map((s) {
                      final staffId = s['id'] as int;
                      final available = isAvailable(staffId);
                      return DropdownMenuItem<int>(
                        value: staffId,
                        child: Row(children: [
                          Picon(PiconsDuotone.circle,
                              size: 10,
                              color: available
                                  ? AppColors.success
                                  : AppColors.grey400),
                          const SizedBox(width: 8),
                          Text(staffDisplayName(s),
                              style: TextStyle(
                                  color:
                                      available ? null : AppColors.grey500)),
                          if (!available)
                            const Text(' (off)',
                                style: TextStyle(
                                    fontSize: 11, color: AppColors.grey400)),
                        ]),
                      );
                    }).toList(),
                    onChanged: (v) => setDialogState(() {
                      selectedStaffId = v;
                      // A dog can't be moved to the person it's already with.
                      selectedIds.removeWhere((id) => assignments
                          .any((a) => a.id == id && a.staffMemberId == v));
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: searchController,
                    decoration: InputDecoration(
                      hintText: 'Search by dog or staff name...',
                      prefixIcon: Picon(PiconsDuotone.magnifyingGlass),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 12),
                    ),
                    onChanged: (v) => setDialogState(() => query = v),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${selectedIds.length} selected',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[600]),
                        ),
                      ),
                      TextButton(
                        onPressed: selectable.isEmpty
                            ? null
                            : () => setDialogState(() {
                                  if (allShownSelected) {
                                    selectedIds.removeAll(
                                        selectable.map((a) => a.id));
                                  } else {
                                    selectedIds
                                        .addAll(selectable.map((a) => a.id));
                                  }
                                }),
                        child: Text(
                            allShownSelected ? 'Clear shown' : 'Select shown',
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.35),
                    child: shown.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                                assignments.isEmpty
                                    ? 'No dogs are assigned on this day.'
                                    : 'No dogs match your search.',
                                style: TextStyle(color: Colors.grey[500])),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: shown.length,
                            itemBuilder: (context, index) {
                              final a = shown[index];
                              final locked = alreadyWithTarget(a);
                              return CheckboxListTile(
                                value: selectedIds.contains(a.id),
                                onChanged: locked
                                    ? null
                                    : (checked) => setDialogState(() {
                                          if (checked == true) {
                                            selectedIds.add(a.id);
                                          } else {
                                            selectedIds.remove(a.id);
                                          }
                                        }),
                                title: Text(a.dogName),
                                subtitle: Text(locked
                                    ? 'Already with ${a.staffMemberName}'
                                    : 'With ${a.staffMemberName} · ${a.status.displayName}'),
                                secondary: a.dogProfileImage != null
                                    ? ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(20),
                                        child: CachedNetworkImage(
                                            imageUrl: a.dogProfileImage!,
                                            width: 40,
                                            height: 40,
                                            fit: BoxFit.cover),
                                      )
                                    : CircleAvatar(
                                        child: Picon(PiconsDuotone.pawPrint)),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                dense: true,
                              );
                            },
                          ),
                  ),
                  const Divider(height: 16),
                  RadioListTile<AssignmentScope>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('Just $dateLabel'),
                    value: AssignmentScope.justThisDay,
                    groupValue: scope,
                    onChanged: (v) => setDialogState(() => scope = v!),
                  ),
                  RadioListTile<AssignmentScope>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('Every $weekdayLabel from now on'),
                    value: AssignmentScope.fromNowOn,
                    groupValue: scope,
                    onChanged: (v) => setDialogState(() => scope = v!),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: selectedStaffId == null || selectedIds.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(selectedIds.isEmpty
                  ? 'Reassign'
                  : 'Reassign ${selectedIds.length} dog${selectedIds.length == 1 ? '' : 's'}'),
            ),
          ],
        );
      },
    ),
  );

  searchController.dispose();

  if (result == true && selectedStaffId != null && selectedIds.isNotEmpty) {
    // Keep roster order so the confirmation reads the way the list did.
    final ordered = assignments
        .where((a) => selectedIds.contains(a.id))
        .map((a) => a.id)
        .toList();
    return ReassignDogsSelection(
      assignmentIds: ordered,
      staffId: selectedStaffId!,
      scope: scope,
    );
  }
  return null;
}
