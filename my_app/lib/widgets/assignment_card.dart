import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_colors.dart';
import '../models/daily_dog_assignment.dart';

/// Shared card rendering a single [DailyDogAssignment]: avatar, name/owner/
/// staff/boarding rows, a status [PopupMenuButton], owner transport chips, and
/// tappable address/phone/instruction rows.
///
/// This widget is used by both `AllDogsTodayScreen` and `StaffDogDetailScreen`.
/// The two screens had drifted (avatar size, the boarding label, the staff
/// line, chip sizing, margins, etc.); rather than harmonising that drift, every
/// difference is exposed as a parameter so each screen renders exactly as it
/// did before. All per-card actions are passed in as callbacks so each screen
/// keeps its own logic.
class AssignmentCard extends StatelessWidget {
  const AssignmentCard({
    super.key,
    required this.assignment,
    required this.canAssignDogs,
    required this.onTap,
    required this.onUpdateStatus,
    required this.onTransport,
    required this.onReassign,
    required this.onUnassign,
    required this.onRemoveFromDay,
    required this.onOpenMaps,
    required this.onCallPhone,
    required this.onShowPickupInstructions,
    required this.formatTime,
    this.staffColor,
    this.pickupNumber,
    // Drift parameters — each screen passes its current values.
    this.reorderIndex,
    this.bottomMargin = 8,
    this.avatarRadius = 22,
    this.cacheAvatar = false,
    this.showStaffLine = true,
    this.staffLineAfterBoarding = false,
    this.boardingLabel = 'Boarding',
    this.rowSpacing = 6,
    this.statusIconSize = 16,
    this.statusFontSize = 11,
    this.statusCaretSize = 14,
    this.statusChipCompact = true,
  });

  final DailyDogAssignment assignment;
  final bool canAssignDogs;

  /// Tapping the card body (opens the quick-info sheet).
  final VoidCallback onTap;

  /// Advance/revert the assignment status to [newStatus].
  final void Function(AssignmentStatus newStatus) onUpdateStatus;
  final VoidCallback onTransport;
  final VoidCallback onReassign;
  final VoidCallback onUnassign;
  final VoidCallback onRemoveFromDay;

  /// Tapping the address / phone / pickup-instruction rows.
  final void Function(String address) onOpenMaps;
  final void Function(String phone) onCallPhone;
  final VoidCallback onShowPickupInstructions;

  /// Formats a [TimeOfDay] for the transport chips (screens share the same impl).
  final String Function(TimeOfDay) formatTime;

  /// The assigned staff member's identity colour (same resolution as the map).
  /// Tints the "Staff: …" line and the pickup-number badge so cards visually
  /// match the pins/legend. Null keeps the theme primary colour.
  final Color? staffColor;

  /// 1-based position of this dog on its staff member's pickup run. Shown as a
  /// numbered badge on the avatar so drivers can see the order at a glance.
  /// Null hides the badge (e.g. owner-handled legs or unsorted lists).
  final int? pickupNumber;

  // ---- Drift parameters ----

  /// When non-null, a drag handle is shown and the card key is honoured for a
  /// [SliverReorderableList]. Only `StaffDogDetailScreen` uses this.
  final int? reorderIndex;

  /// Card bottom margin (all-dogs: 8, staff-detail: 12).
  final double bottomMargin;

  /// Avatar circle radius (all-dogs: 22, staff-detail: 24). The image diameter
  /// is `2 * avatarRadius`.
  final double avatarRadius;

  /// Whether to pass `memCacheWidth`/`memCacheHeight` to the avatar image.
  /// Only `AllDogsTodayScreen` does this.
  final bool cacheAvatar;

  /// Whether the "Staff: …" line is shown at all.
  final bool showStaffLine;

  /// Whether the staff line is rendered after the boarding row (staff-detail)
  /// rather than before it (all-dogs).
  final bool staffLineAfterBoarding;

  /// Boarding row label (all-dogs: "Boarding",
  /// staff-detail: "Boarding – No pickup needed").
  final String boardingLabel;

  /// Vertical gap between the header row and the transport/info rows
  /// (all-dogs: 6, staff-detail: 8).
  final double rowSpacing;

  /// Status chip sizing (all-dogs: 16/11/14, staff-detail: 18/12/16).
  final double statusIconSize;
  final double statusFontSize;
  final double statusCaretSize;

  /// Whether the status chip uses `VisualDensity.compact`
  /// (all-dogs: true, staff-detail: false).
  final bool statusChipCompact;

  /// Dog avatar, with the pickup-order badge overlaid when [pickupNumber] is
  /// set (coloured to match the staff member, like their map pins).
  Widget _buildAvatar(BuildContext context, double avatarDiameter) {
    final Widget avatar = assignment.dogProfileImage != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(avatarRadius),
            child: CachedNetworkImage(
              imageUrl: assignment.dogProfileImage!,
              width: avatarDiameter,
              height: avatarDiameter,
              fit: BoxFit.cover,
              memCacheWidth: cacheAvatar
                  ? (avatarDiameter * MediaQuery.of(context).devicePixelRatio)
                      .round()
                  : null,
              memCacheHeight: cacheAvatar
                  ? (avatarDiameter * MediaQuery.of(context).devicePixelRatio)
                      .round()
                  : null,
              placeholder: (context, url) => Container(
                width: avatarDiameter,
                height: avatarDiameter,
                color: Colors.grey[200],
                child: Picon(PiconsDuotone.pawPrint),
              ),
              errorWidget: (context, url, error) => CircleAvatar(
                  radius: avatarRadius, child: Picon(PiconsDuotone.pawPrint)),
            ),
          )
        : CircleAvatar(radius: avatarRadius, child: Picon(PiconsDuotone.pawPrint));

    if (pickupNumber == null) return avatar;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          left: -5,
          top: -5,
          child: Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: staffColor ?? AppColors.primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: Text(
              '$pickupNumber',
              style: const TextStyle(
                  color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final next = _nextStatus(assignment.status);
    final previous = _previousStatus(assignment.status);
    final statusColor = _statusColor(assignment.status);
    final double avatarDiameter = avatarRadius * 2;

    final staffLine = showStaffLine
        ? Text('Staff: ${assignment.staffMemberName}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: staffColor ?? Theme.of(context).colorScheme.primary,
                  fontWeight: staffColor != null ? FontWeight.w600 : null,
                ))
        : null;

    final boardingRow = assignment.isBoarding
        ? Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              Picon(PiconsDuotone.house, size: 14, color: Colors.deepPurple),
              const SizedBox(width: 4),
              Text(boardingLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.deepPurple,
                        fontWeight: FontWeight.w600,
                      )),
            ]),
          )
        : null;

    return Card(
      key: key,
      margin: EdgeInsets.only(bottom: bottomMargin),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Dog info row
              Row(
                children: [
                  // Drag handle — only shown for reorderable items
                  if (reorderIndex != null)
                    ReorderableDragStartListener(
                      index: reorderIndex!,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Picon(
                          PiconsDuotone.dotsSixVertical,
                          size: 24,
                          color: Colors.grey[400],
                        ),
                      ),
                    ),
                  _buildAvatar(context, avatarDiameter),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(assignment.dogName,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        Text('Owner: ${assignment.ownerName}',
                            style: Theme.of(context).textTheme.bodySmall),
                        if (!staffLineAfterBoarding && staffLine != null)
                          staffLine,
                        if (boardingRow != null) boardingRow,
                        if (staffLineAfterBoarding && staffLine != null)
                          staffLine,
                      ],
                    ),
                  ),
                  // Status chip with full action menu
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      switch (value) {
                        case 'next':
                          if (next != null) onUpdateStatus(next);
                        case 'previous':
                          if (previous != null) onUpdateStatus(previous);
                        case 'transport':
                          onTransport();
                        case 'reassign':
                          onReassign();
                        case 'unassign':
                          onUnassign();
                        case 'remove_from_day':
                          onRemoveFromDay();
                      }
                    },
                    itemBuilder: (context) => [
                      if (next != null)
                        PopupMenuItem(
                          value: 'next',
                          child: Row(children: [
                            Picon(_statusIcon(next), size: 18),
                            const SizedBox(width: 8),
                            Text('Mark ${next.displayName}'),
                          ]),
                        ),
                      if (previous != null)
                        PopupMenuItem(
                          value: 'previous',
                          child: Row(children: [
                            Picon(_statusIcon(previous), size: 18),
                            const SizedBox(width: 8),
                            Text('Revert to ${previous.displayName}'),
                          ]),
                        ),
                      if (canAssignDogs) ...[
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'transport',
                          child: Row(children: [
                            Picon(PiconsDuotone.car, size: 18),
                            const SizedBox(width: 8),
                            const Text('Transport…'),
                          ]),
                        ),
                        PopupMenuItem(
                          value: 'reassign',
                          child: Row(children: [
                            Picon(PiconsDuotone.arrowsLeftRight, size: 18),
                            const SizedBox(width: 8),
                            const Text('Reassign'),
                          ]),
                        ),
                        PopupMenuItem(
                          value: 'unassign',
                          child: Row(children: [
                            Picon(PiconsDuotone.userMinus,
                                size: 18, color: Colors.red[700]),
                            const SizedBox(width: 8),
                            Text('Unassign',
                                style: TextStyle(color: Colors.red[700])),
                          ]),
                        ),
                        PopupMenuItem(
                          value: 'remove_from_day',
                          child: Row(children: [
                            Picon(PiconsDuotone.calendarX,
                                size: 18, color: Colors.red[900]),
                            const SizedBox(width: 8),
                            Text('Remove from this day',
                                style: TextStyle(color: Colors.red[900])),
                          ]),
                        ),
                      ],
                    ],
                    child: Chip(
                      avatar: Picon(_statusIcon(assignment.status),
                          size: statusIconSize, color: statusColor),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(assignment.status.displayName,
                              style: TextStyle(
                                  color: statusColor,
                                  fontSize: statusFontSize)),
                          Picon(PiconsDuotone.caretDown,
                              size: statusCaretSize, color: statusColor),
                        ],
                      ),
                      backgroundColor: statusColor.withValues(alpha: 0.1),
                      side: BorderSide(color: statusColor.withValues(alpha: 0.3)),
                      visualDensity:
                          statusChipCompact ? VisualDensity.compact : null,
                    ),
                  ),
                ],
              ),
              SizedBox(height: rowSpacing),
              // Transport indicators (owner brings / collects)
              if (assignment.effectiveOwnerBrings ||
                  assignment.effectiveOwnerCollects)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (assignment.effectiveOwnerBrings)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.teal.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: Colors.teal.withValues(alpha: 0.35)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Picon(PiconsDuotone.houseLine,
                                size: 14, color: Colors.teal),
                            const SizedBox(width: 4),
                            Text(
                              assignment.effectiveOwnerBringsTime != null
                                  ? 'Owner drops off ${formatTime(assignment.effectiveOwnerBringsTime!)}'
                                  : 'Owner drops off',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.teal),
                            ),
                          ]),
                        ),
                      if (assignment.effectiveOwnerCollects)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.indigo.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: Colors.indigo.withValues(alpha: 0.35)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Picon(PiconsDuotone.houseLine,
                                size: 14, color: Colors.indigo),
                            const SizedBox(width: 4),
                            Text(
                              assignment.effectiveOwnerCollectsTime != null
                                  ? 'Owner picks up ${formatTime(assignment.effectiveOwnerCollectsTime!)}'
                                  : 'Owner picks up',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.indigo),
                            ),
                          ]),
                        ),
                    ],
                  ),
                ),
              // Address
              if (assignment.ownerAddress != null &&
                  assignment.ownerAddress!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: InkWell(
                    onTap: () => onOpenMaps(assignment.ownerAddress!),
                    child: Row(children: [
                      Picon(PiconsDuotone.mapPin,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(assignment.ownerAddress!,
                            style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.primary,
                                decoration: TextDecoration.underline)),
                      ),
                    ]),
                  ),
                ),
              // Phone
              if (assignment.ownerPhone != null &&
                  assignment.ownerPhone!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: InkWell(
                    onTap: () => onCallPhone(assignment.ownerPhone!),
                    child: Row(children: [
                      Picon(PiconsDuotone.phone,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(assignment.ownerPhone!,
                          style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.primary,
                              decoration: TextDecoration.underline)),
                    ]),
                  ),
                ),
              // Pickup instructions
              if (assignment.pickupInstructions != null &&
                  assignment.pickupInstructions!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: InkWell(
                    onTap: onShowPickupInstructions,
                    child: Row(children: [
                      Picon(PiconsDuotone.info,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 4),
                      Text('Pickup Instructions',
                          style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.primary,
                              decoration: TextDecoration.underline)),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Pure status helpers (shared, identical across both screens) ----

AssignmentStatus? _nextStatus(AssignmentStatus current) {
  switch (current) {
    case AssignmentStatus.assigned:
      return AssignmentStatus.pickedUp;
    case AssignmentStatus.pickedUp:
      return AssignmentStatus.droppedOff;
    case AssignmentStatus.droppedOff:
      return null;
  }
}

AssignmentStatus? _previousStatus(AssignmentStatus current) {
  switch (current) {
    case AssignmentStatus.assigned:
      return null;
    case AssignmentStatus.pickedUp:
      return AssignmentStatus.assigned;
    case AssignmentStatus.droppedOff:
      return AssignmentStatus.pickedUp;
  }
}

PiconDuotoneData _statusIcon(AssignmentStatus status) {
  switch (status) {
    case AssignmentStatus.assigned:
      return PiconsDuotone.clipboardText;
    case AssignmentStatus.pickedUp:
      return PiconsDuotone.pawPrint;
    case AssignmentStatus.droppedOff:
      return PiconsDuotone.checkCircle;
  }
}

Color _statusColor(AssignmentStatus status) {
  switch (status) {
    case AssignmentStatus.assigned:
      return Colors.orange;
    case AssignmentStatus.pickedUp:
      return AppColors.primary;
    case AssignmentStatus.droppedOff:
      return Colors.green;
  }
}
