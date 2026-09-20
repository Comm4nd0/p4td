import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/owner_handover_status.dart';
import 'reassign_dogs_dialog.dart' show staffDisplayName;

/// The day's owner handovers on the staff dashboard: one card for the dogs
/// being dropped off by their owner, one for the dogs being collected by
/// their owner. Neither leg is on a driver's route, so each card names the
/// staff member responsible for meeting the owners and stays outlined in red
/// until someone is. Tapping a card lists the dogs (with expected times) and
/// lets the user pick who's on it. Hidden when no owner is bringing or
/// collecting a dog that day.
///
/// Pure UI: [onAssign] makes the API call and the parent re-renders with the
/// status it returns.
class OwnerHandoverSection extends StatelessWidget {
  final OwnerHandoverStatus? status;
  final List<Map<String, dynamic>> staffMembers;
  final Set<int> availableStaffIds;
  final Future<void> Function(OwnerHandoverLeg leg, int staffId) onAssign;

  /// Keys on the two cards, so the dashboard's spotlight can point at one.
  final Key? dropOffKey;
  final Key? collectionKey;

  const OwnerHandoverSection({
    super.key,
    required this.status,
    required this.staffMembers,
    required this.availableStaffIds,
    required this.onAssign,
    this.dropOffKey,
    this.collectionKey,
  });

  @override
  Widget build(BuildContext context) {
    final status = this.status;
    if (status == null || status.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(child: _card(context, status.dropOff, key: dropOffKey)),
        const SizedBox(width: 6),
        Expanded(child: _card(context, status.collection, key: collectionKey)),
      ]),
    );
  }

  Widget _card(BuildContext context, OwnerHandoverLegStatus leg, {Key? key}) {
    return OwnerHandoverCard(
      key: key,
      leg: leg,
      onTap: leg.count == 0
          ? null
          : () async {
              final picked = await showOwnerHandoverSheet(
                context,
                leg: leg,
                staffMembers: staffMembers,
                availableStaffIds: availableStaffIds,
              );
              if (picked != null && picked != leg.staffMemberId) {
                await onAssign(leg.leg, picked);
              }
            },
    );
  }
}

/// Label for a leg as the cards and sheet name it.
String ownerHandoverTitle(OwnerHandoverLeg leg) => leg == OwnerHandoverLeg.dropOff
    ? 'Dropped off by owner'
    : 'Collected by owner';

/// One leg's count card. Red outline while dogs are coming and nobody is on
/// it; green once a staff member is; plain when there are no dogs.
class OwnerHandoverCard extends StatelessWidget {
  final OwnerHandoverLegStatus leg;
  final VoidCallback? onTap;

  const OwnerHandoverCard({super.key, required this.leg, this.onTap});

  @override
  Widget build(BuildContext context) {
    final Color? outline = leg.count == 0
        ? null
        : leg.hasStaff
            ? AppColors.success
            : AppColors.error;
    final icon = leg.leg == OwnerHandoverLeg.dropOff
        ? PiconsDuotone.signIn
        : PiconsDuotone.signOut;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: outline == null
            ? BorderSide.none
            : BorderSide(color: outline, width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Picon(icon, size: 16, color: outline ?? AppColors.primary),
                const SizedBox(width: 6),
                Text('${leg.count}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 2),
              Text(ownerHandoverTitle(leg.leg),
                  style: const TextStyle(fontSize: 10, color: AppColors.grey600)),
              const SizedBox(height: 4),
              Row(children: [
                Picon(
                  leg.hasStaff
                      ? PiconsDuotone.userCheck
                      : PiconsDuotone.warningCircle,
                  size: 12,
                  color: outline ?? AppColors.grey500,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    leg.count == 0
                        ? 'No dogs'
                        : leg.hasStaff
                            ? leg.staffMemberName ?? 'Assigned'
                            : 'Assign staff',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: outline ?? AppColors.grey600,
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet for one leg: the dogs the owners are bringing (or collecting)
/// with their expected times, and a picker for the staff member who'll meet
/// them. Staff not working that day sort last and are marked. Resolves to the
/// picked staff id, or null when dismissed.
Future<int?> showOwnerHandoverSheet(
  BuildContext context, {
  required OwnerHandoverLegStatus leg,
  required List<Map<String, dynamic>> staffMembers,
  required Set<int> availableStaffIds,
}) {
  bool isAvailable(int id) =>
      availableStaffIds.isEmpty || availableStaffIds.contains(id);
  final sorted = List<Map<String, dynamic>>.from(staffMembers)
    ..sort((a, b) {
      final aAvail = isAvailable(a['id'] as int);
      final bAvail = isAvailable(b['id'] as int);
      if (aAvail != bAvail) return aAvail ? -1 : 1;
      return staffDisplayName(a)
          .toLowerCase()
          .compareTo(staffDisplayName(b).toLowerCase());
    });
  int? selected = leg.staffMemberId;
  final isDropOff = leg.leg == OwnerHandoverLeg.dropOff;

  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Row(children: [
                  Picon(
                    isDropOff ? PiconsDuotone.signIn : PiconsDuotone.signOut,
                    size: 20,
                    color: leg.hasStaff ? AppColors.success : AppColors.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${leg.count} ${leg.count == 1 ? 'dog' : 'dogs'} '
                      '${isDropOff ? 'dropped off' : 'collected'} by owner',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  isDropOff
                      ? 'These owners are bringing their dog in themselves. '
                          'Pick who is meeting them at the door.'
                      : 'These owners are collecting their dog themselves. '
                          'Pick who is handing the dogs back.',
                  style: const TextStyle(fontSize: 13, color: AppColors.grey600),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    ...leg.dogs.map((dog) => ListTile(
                          dense: true,
                          leading: _dogAvatar(dog),
                          title: Text(dog.dogName),
                          trailing: dog.time == null
                              ? null
                              : Text(dog.time!,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.grey700)),
                        )),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                      child: Text(
                        isDropOff
                            ? 'Who is meeting the owners?'
                            : 'Who is handing the dogs back?',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (sorted.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('No staff members found',
                            style: TextStyle(color: AppColors.grey600)),
                      ),
                    ...sorted.map((s) {
                      final id = s['id'] as int;
                      final available = isAvailable(id);
                      return RadioListTile<int>(
                        dense: true,
                        value: id,
                        groupValue: selected,
                        onChanged: (v) => setSheetState(() => selected = v),
                        title: Text(
                          staffDisplayName(s),
                          style: TextStyle(
                              color: available ? null : AppColors.grey500),
                        ),
                        subtitle: available
                            ? null
                            : const Text('Not working today',
                                style: TextStyle(
                                    fontSize: 11, color: AppColors.grey500)),
                      );
                    }),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: selected == null
                        ? null
                        : () => Navigator.of(ctx).pop(selected),
                    icon: const Picon(PiconsDuotone.userCheck, size: 18),
                    label: Text(leg.hasStaff ? 'Change staff member' : 'Assign'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _dogAvatar(OwnerHandoverDog dog) {
  const fallback = CircleAvatar(
      radius: 18, child: Picon(PiconsDuotone.pawPrint, size: 18));
  if (dog.dogProfileImage == null) return fallback;
  return ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: CachedNetworkImage(
      imageUrl: dog.dogProfileImage!,
      width: 36,
      height: 36,
      fit: BoxFit.cover,
      errorWidget: (_, __, ___) => fallback,
    ),
  );
}
