import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/dog.dart';

/// What the user picked in the add-dog-to-day dialog: the dog to add and,
/// when the user can assign on others' behalf, the target staff member.
class AddDogSelection {
  final int dogId;
  final int? staffId;
  const AddDogSelection({required this.dogId, this.staffId});
}

/// Search-and-pick dialog for adding an extra (unbooked) dog to a given day.
///
/// Extracted verbatim from [UnifiedDashboardScreen] (audit F14). The caller
/// pre-fetches [extraDogs] (dogs neither assigned nor booked for the day) and
/// owns the actual assignment call; this dialog is pure UI and returns the
/// chosen dog/staff via [AddDogSelection], or null if cancelled.
///
/// [staffMembers] is the full staff list, [availableStaffIds] gates the
/// availability dots (empty set = treat all as available), and [canAssignDogs]
/// controls whether the staff dropdown is shown and required.
Future<AddDogSelection?> showAddDogToDayDialog({
  required BuildContext context,
  required DateTime date,
  required String dateLabel,
  required List<Dog> extraDogs,
  required List<Map<String, dynamic>> staffMembers,
  required Set<int> availableStaffIds,
  required bool canAssignDogs,
}) async {
  int? selectedDogId;
  int? selectedStaffId;
  final searchController = TextEditingController();
  List<Dog> filteredExtraDogs = List.of(extraDogs);

  final sortedStaff = List<Map<String, dynamic>>.from(staffMembers)
    ..sort((a, b) {
      final aAvail =
          availableStaffIds.isEmpty || availableStaffIds.contains(a['id'] as int);
      final bAvail =
          availableStaffIds.isEmpty || availableStaffIds.contains(b['id'] as int);
      if (aAvail && !bAvail) return -1;
      if (!aAvail && bAvail) return 1;
      return 0;
    });

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AlertDialog(
          title: Text('Add Dog to $dateLabel'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (canAssignDogs) ...[
                    DropdownButtonFormField<int>(
                      decoration:
                          const InputDecoration(labelText: 'Assign to staff'),
                      value: selectedStaffId,
                      items: sortedStaff.map((s) {
                        final name = (s['first_name'] != null &&
                                s['first_name'].toString().isNotEmpty)
                            ? s['first_name'].toString()
                            : s['username'].toString();
                        final staffId = s['id'] as int;
                        final isAvailable = availableStaffIds.isEmpty ||
                            availableStaffIds.contains(staffId);
                        return DropdownMenuItem<int>(
                          value: staffId,
                          child: Row(children: [
                            Picon(PiconsDuotone.circle,
                                size: 10,
                                color: isAvailable
                                    ? AppColors.success
                                    : AppColors.grey400),
                            const SizedBox(width: 8),
                            Text(name,
                                style: TextStyle(
                                    color:
                                        isAvailable ? null : AppColors.grey500)),
                            if (!isAvailable)
                              Text(' (off)',
                                  style: TextStyle(
                                      fontSize: 11, color: AppColors.grey400)),
                          ]),
                        );
                      }).toList(),
                      onChanged: (v) =>
                          setDialogState(() => selectedStaffId = v),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const Text('Search for a dog to add to this day:',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: searchController,
                    decoration: InputDecoration(
                      hintText: 'Search by name...',
                      prefixIcon: Picon(PiconsDuotone.magnifyingGlass),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 12),
                    ),
                    onChanged: (query) {
                      setDialogState(() {
                        filteredExtraDogs = extraDogs
                            .where((d) => d.name
                                .toLowerCase()
                                .contains(query.toLowerCase()))
                            .toList();
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.3),
                    child: filteredExtraDogs.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text('No additional dogs found',
                                style: TextStyle(color: Colors.grey[500])),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: filteredExtraDogs.length,
                            itemBuilder: (context, index) {
                              final dog = filteredExtraDogs[index];
                              final dogId = int.parse(dog.id);
                              return RadioListTile<int>(
                                value: dogId,
                                groupValue: selectedDogId,
                                onChanged: (v) =>
                                    setDialogState(() => selectedDogId = v),
                                title: Text(dog.name),
                                subtitle: dog.ownerDetails != null
                                    ? Text('Owner: ${dog.ownerDetails!.username}')
                                    : null,
                                secondary: dog.profileImageUrl != null
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(20),
                                        child: CachedNetworkImage(
                                            imageUrl: dog.profileImageUrl!,
                                            width: 40,
                                            height: 40,
                                            fit: BoxFit.cover),
                                      )
                                    : CircleAvatar(
                                        child: Picon(PiconsDuotone.pawPrint)),
                                dense: true,
                              );
                            },
                          ),
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
              onPressed: selectedDogId == null ||
                      (canAssignDogs && selectedStaffId == null)
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Add to Day'),
            ),
          ],
        );
      },
    ),
  );

  searchController.dispose();

  if (result == true && selectedDogId != null) {
    return AddDogSelection(dogId: selectedDogId!, staffId: selectedStaffId);
  }
  return null;
}
