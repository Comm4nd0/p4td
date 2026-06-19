import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../widgets/dashboard_widgets.dart';

/// The "Action Items" list on the staff dashboard.
///
/// Extracted from [UnifiedDashboardScreen] (audit F14). Pure presentation: it
/// renders [ActionItemTile]s from the counts the screen passes in and fires the
/// matching `onOpen*` callback when tapped. Each callback owns navigation and
/// the post-return count reload, exactly as before. Visibility flags
/// ([canViewInquiries], [canManageRequests]) and the `unspayedMalesCount > 0`
/// guard reproduce the original conditional rows.
class ActionItemsSection extends StatelessWidget {
  final int pendingRequestCount;
  final int unresolvedQueryCount;
  final int unreadInquiryCount;
  final int pendingProfileChangeCount;
  final int pendingBoardingCount;
  final int unresolvedDefectCount;
  final int unresolvedVehicleDefectCount;
  final int unspayedMalesCount;

  final bool canViewInquiries;
  final bool canManageRequests;

  final VoidCallback onOpenPendingRequests;
  final VoidCallback onOpenQueries;
  final VoidCallback onOpenInquiries;
  final VoidCallback onOpenProfileChanges;
  final VoidCallback onOpenBoardingRequests;
  final VoidCallback onOpenSiteDefects;
  final VoidCallback onOpenVehicleDefects;
  final VoidCallback onOpenUnspayedMales;

  const ActionItemsSection({
    super.key,
    required this.pendingRequestCount,
    required this.unresolvedQueryCount,
    required this.unreadInquiryCount,
    required this.pendingProfileChangeCount,
    required this.pendingBoardingCount,
    required this.unresolvedDefectCount,
    required this.unresolvedVehicleDefectCount,
    required this.unspayedMalesCount,
    required this.canViewInquiries,
    required this.canManageRequests,
    required this.onOpenPendingRequests,
    required this.onOpenQueries,
    required this.onOpenInquiries,
    required this.onOpenProfileChanges,
    required this.onOpenBoardingRequests,
    required this.onOpenSiteDefects,
    required this.onOpenVehicleDefects,
    required this.onOpenUnspayedMales,
  });

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
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PiconsDuotone.bed,
          label: 'Boarding Requests',
          count: pendingBoardingCount,
          countColor: pendingBoardingCount > 0 ? Colors.red : null,
          onTap: onOpenBoardingRequests,
        ),
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PiconsDuotone.wrench,
          label: 'Site Defects',
          count: unresolvedDefectCount,
          countColor: unresolvedDefectCount > 0 ? Colors.red : null,
          onTap: onOpenSiteDefects,
        ),
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PiconsDuotone.van,
          label: 'Vehicle Defects',
          count: unresolvedVehicleDefectCount,
          countColor: unresolvedVehicleDefectCount > 0 ? Colors.red : null,
          onTap: onOpenVehicleDefects,
        ),
        if (unspayedMalesCount > 0) ...[
          const SizedBox(height: 4),
          ActionItemTile(
            icon: PiconsDuotone.warningCircle,
            label: 'Spay status to confirm',
            count: unspayedMalesCount,
            countColor: unspayedMalesCount > 0 ? Colors.red : null,
            onTap: onOpenUnspayedMales,
          ),
        ],
      ],
    );
  }
}
