import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_colors.dart';
import '../models/daily_dog_assignment.dart';
import '../models/dog.dart' show DropoffTimeExtension;

/// Shared card rendering a single [DailyDogAssignment]: avatar, name/owner/
/// staff/boarding rows, an **Actions** [PopupMenuButton], the status pill and
/// owner transport chips, and
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
    this.statusUpdating = false,
    required this.onTransport,
    this.onChangeAddress,
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

  /// A status change for this dog is on its way to the server: the chip
  /// shows a spinner and its menu is closed until it lands, so a driver on
  /// slow signal can see the tap registered and can't send it twice.
  final bool statusUpdating;
  final VoidCallback onTransport;
  /// Pick-up / drop-off address for the day; the menu item is hidden when null.
  final VoidCallback? onChangeAddress;
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
    final actionColor = Theme.of(context).colorScheme.primary;

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
            // The note is a sentence ("Boarding – going home today, no
            // pickup"): it wraps inside the column rather than running on
            // under the Actions button.
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Picon(PiconsDuotone.house,
                    size: 14, color: Colors.deepPurple),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(boardingLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.deepPurple,
                          fontWeight: FontWeight.w600,
                        )),
              ),
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
                  const SizedBox(width: 8),
                  // The action menu. It is labelled for what it does — the
                  // dog's status is shown on the card below, not here.
                  PopupMenuButton<String>(
                    enabled: !statusUpdating,
                    tooltip: statusUpdating
                        ? 'Updating ${assignment.dogName}…'
                        : 'Actions for ${assignment.dogName}: change status or transport',
                    onSelected: (value) {
                      switch (value) {
                        case 'next':
                          if (next != null) onUpdateStatus(next);
                        case 'previous':
                          if (previous != null) onUpdateStatus(previous);
                        case 'transport':
                          onTransport();
                        case 'address':
                          onChangeAddress?.call();
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
                        if (onChangeAddress != null)
                          PopupMenuItem(
                            value: 'address',
                            child: Row(children: [
                              Picon(PiconsDuotone.mapPin, size: 18),
                              const SizedBox(width: 8),
                              const Text('Pick-up / drop-off address…'),
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
                    // At least 48dp to hit: drivers change status one-handed.
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Center(
                        widthFactor: 1,
                        child: Chip(
                      avatar: statusUpdating
                          ? SizedBox(
                              width: statusIconSize,
                              height: statusIconSize,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: actionColor),
                            )
                          : null,
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Actions',
                              style: TextStyle(
                                  color: actionColor,
                                  fontWeight: FontWeight.w600,
                                  fontSize: statusFontSize)),
                          Picon(PiconsDuotone.caretDown,
                              size: statusCaretSize, color: actionColor),
                        ],
                      ),
                      backgroundColor: actionColor.withValues(alpha: 0.08),
                      side: BorderSide(color: actionColor.withValues(alpha: 0.35)),
                      visualDensity:
                          statusChipCompact ? VisualDensity.compact : null,
                    ),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: rowSpacing),
              // Changes to the routine first (extra day, one-off transport),
              // then the transport indicators (owner brings / collects).
              Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Where the dog is right now — always first.
                      Semantics(
                        label: 'Status: ${assignment.status.displayName}',
                        excludeSemantics: true,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: statusColor.withValues(alpha: 0.4)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Picon(_statusIcon(assignment.status),
                                size: 14, color: statusColor),
                            const SizedBox(width: 4),
                            Text(assignment.status.displayName,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: statusColor)),
                          ]),
                        ),
                      ),
                      if (assignment.isExtraDay)
                        const RoutineChangeChip(
                          label: 'Extra day',
                          icon: PiconsDuotone.plusCircle,
                          color: AppColors.extraDay,
                        ),
                      // The owner wants the dog home no earlier than this —
                      // bold so the driver plans the evening run around it.
                      if (assignment.dropoffTimeForDriver != null)
                        RoutineChangeChip(
                          label:
                              'Home ${assignment.dropoffTimeForDriver!.displayName.toLowerCase()}',
                          icon: PiconsDuotone.clock,
                          color: Colors.deepOrange,
                        ),
                      if (assignment.hasTransportChange)
                        const RoutineChangeChip(
                          label: 'Transport changed today',
                          icon: PiconsDuotone.arrowsLeftRight,
                          color: AppColors.warning,
                        ),
                      if (assignment.usesAlternativeAddress)
                        const RoutineChangeChip(
                          label: 'Different address today',
                          icon: PiconsDuotone.mapPin,
                          color: AppColors.warning,
                        ),
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
                _ActionRow(
                  icon: PiconsDuotone.mapPin,
                  label: assignment.ownerAddress!,
                  semanticsLabel: 'Open ${assignment.ownerAddress} in maps',
                  wraps: true,
                  onTap: () => onOpenMaps(assignment.ownerAddress!),
                ),
              // Phone
              if (assignment.ownerPhone != null &&
                  assignment.ownerPhone!.isNotEmpty)
                _ActionRow(
                  icon: PiconsDuotone.phone,
                  label: assignment.ownerPhone!,
                  semanticsLabel: 'Call ${assignment.ownerPhone}',
                  onTap: () => onCallPhone(assignment.ownerPhone!),
                ),
              // Pickup instructions
              if (assignment.pickupInstructions != null &&
                  assignment.pickupInstructions!.isNotEmpty)
                _ActionRow(
                  icon: PiconsDuotone.info,
                  label: 'Pickup Instructions',
                  semanticsLabel: 'Pickup instructions for ${assignment.dogName}',
                  onTap: onShowPickupInstructions,
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


/// A bold chip for a way today differs from the dog's routine — staff work
/// from routine, so these have to stand out from the everyday chips.
class RoutineChangeChip extends StatelessWidget {
  final String label;
  final Object icon; // a Picons glyph
  final Color color;

  const RoutineChangeChip({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Picon(icon, size: 14, color: Colors.white),
        const SizedBox(width: 4),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            color: Colors.white,
          ),
        ),
      ]),
    );
  }
}


/// A tappable line on the card — the address, the phone number, the pickup
/// instructions. A full 48dp high with the whole row as the target: these
/// are the three things a driver reaches for with one thumb, and as bare
/// 13px text links 4dp apart they were easy to miss or mis-hit.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
    this.wraps = false,
  });

  final Object icon; // a Picons glyph
  final String label;
  final String semanticsLabel;
  final VoidCallback onTap;

  /// Long text (an address) takes the row's width and wraps; short text
  /// keeps its own width.
  final bool wraps;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final text = Text(label,
        style: TextStyle(
            fontSize: 13, color: color, decoration: TextDecoration.underline));
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(children: [
            Picon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            if (wraps) Expanded(child: text) else Flexible(child: text),
          ]),
        ),
      ),
    );
  }
}
