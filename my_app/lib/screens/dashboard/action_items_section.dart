import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../widgets/dashboard_widgets.dart';

/// The "Action Items" list on the staff dashboard.
///
/// Extracted from [UnifiedDashboardScreen] (audit F14). Pure presentation: it
/// renders [ActionItemTile]s from the counts the screen passes in and fires the
/// matching `onOpen*` callback when tapped. Each callback owns navigation and
/// the post-return count reload, exactly as before. Visibility flags
/// ([canViewInquiries], [canManageRequests]) reproduce the original
/// conditional rows.
///
/// Two rows are groupings, so the list stays a list of things to *do* rather
/// than one row per data source:
///
/// * **Defects** — site and vehicle defects in one row with the split in its
///   subtitle; the tap offers the two screens.
/// * **Dog health to confirm** — neutered status to confirm and vaccinations
///   over a year old. Both are "have a word with the owner" items, and the
///   row only appears when there is at least one.
class ActionItemsSection extends StatelessWidget {
  final int pendingRequestCount;
  final int unresolvedQueryCount;
  final int unreadInquiryCount;
  final int pendingProfileChangeCount;
  final int pendingBoardingCount;
  final int unresolvedDefectCount;
  final int unresolvedVehicleDefectCount;
  final int openIncidentCount;
  final int dogHealthCount;

  final bool canViewInquiries;
  final bool canManageRequests;
  final bool canManageBoarding;

  final VoidCallback onOpenPendingRequests;
  final VoidCallback onOpenQueries;
  final VoidCallback onOpenInquiries;
  final VoidCallback onOpenProfileChanges;
  final VoidCallback onOpenBoardingRequests;
  final VoidCallback onOpenDefects;
  final VoidCallback onOpenIncidents;
  final VoidCallback onOpenDogHealth;

  const ActionItemsSection({
    super.key,
    required this.pendingRequestCount,
    required this.unresolvedQueryCount,
    required this.unreadInquiryCount,
    required this.pendingProfileChangeCount,
    required this.pendingBoardingCount,
    required this.unresolvedDefectCount,
    required this.unresolvedVehicleDefectCount,
    required this.openIncidentCount,
    required this.dogHealthCount,
    required this.canViewInquiries,
    required this.canManageRequests,
    this.canManageBoarding = false,
    required this.onOpenPendingRequests,
    required this.onOpenQueries,
    required this.onOpenInquiries,
    required this.onOpenProfileChanges,
    required this.onOpenBoardingRequests,
    required this.onOpenDefects,
    required this.onOpenIncidents,
    required this.onOpenDogHealth,
  });

  int get defectCount => unresolvedDefectCount + unresolvedVehicleDefectCount;

  /// "2 site · 1 vehicle" — only once there is something to split.
  String? get defectBreakdown {
    if (defectCount == 0) return null;
    return '$unresolvedDefectCount site · $unresolvedVehicleDefectCount vehicle';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Action Items',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ActionItemTile(
          icon: PiconsDuotone.clockCountdown,
          label: 'Pending Requests',
          count: pendingRequestCount,
          countColor: pendingRequestCount > 0 ? Colors.red : null,
          onTap: onOpenPendingRequests,
        ),
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PiconsDuotone.chats,
          label: 'Unresolved Queries',
          count: unresolvedQueryCount,
          countColor: unresolvedQueryCount > 0 ? Colors.red : null,
          onTap: onOpenQueries,
        ),
        if (canViewInquiries) ...[
          const SizedBox(height: 4),
          ActionItemTile(
            icon: PiconsDuotone.envelope,
            label: 'Unread Inquiries',
            count: unreadInquiryCount,
            countColor: unreadInquiryCount > 0 ? Colors.red : null,
            onTap: onOpenInquiries,
          ),
        ],
        if (canManageRequests) ...[
          const SizedBox(height: 4),
          ActionItemTile(
            icon: PiconsDuotone.dog,
            label: 'Profile Changes',
            count: pendingProfileChangeCount,
            countColor: pendingProfileChangeCount > 0 ? Colors.red : null,
            onTap: onOpenProfileChanges,
          ),
        ],
        if (canManageBoarding) ...[
          const SizedBox(height: 4),
          ActionItemTile(
            icon: PiconsDuotone.bed,
            label: 'Boarding Requests',
            count: pendingBoardingCount,
            countColor: pendingBoardingCount > 0 ? Colors.red : null,
            onTap: onOpenBoardingRequests,
          ),
        ],
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PiconsDuotone.wrench,
          label: 'Defects',
          subtitle: defectBreakdown,
          count: defectCount,
          countColor: defectCount > 0 ? Colors.red : null,
          onTap: onOpenDefects,
        ),
        const SizedBox(height: 4),
        // Staff-only: incidents are never surfaced to owners anywhere.
        ActionItemTile(
          icon: PiconsDuotone.firstAidKit,
          label: 'Open Incidents',
          count: openIncidentCount,
          countColor: openIncidentCount > 0 ? Colors.red : null,
          onTap: onOpenIncidents,
        ),
        if (dogHealthCount > 0) ...[
          const SizedBox(height: 4),
          ActionItemTile(
            icon: PiconsDuotone.warningCircle,
            label: 'Dog health to confirm',
            count: dogHealthCount,
            countColor: Colors.red,
            onTap: onOpenDogHealth,
          ),
        ],
      ],
    );
  }
}
