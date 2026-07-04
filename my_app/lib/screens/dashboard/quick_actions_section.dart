import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

/// The "Quick Actions" chip row on the staff dashboard.
///
/// Extracted verbatim from [UnifiedDashboardScreen] (audit F14). The screen
/// still owns each action (upload media, add dog, swap staff, manage
/// permissions); this widget just renders the chips and fires the matching
/// callback. Chips other than "Upload to Feed" appear only when their
/// permission flag is set, reproducing the original conditionals.
class QuickActionsSection extends StatelessWidget {
  final bool canAssignDogs;
  final bool canManagePayments;
  final bool isSuperuser;

  final VoidCallback onUploadMedia;
  final VoidCallback onAddDogToDay;
  final VoidCallback onSwapStaff;
  final VoidCallback onManagePermissions;
  final VoidCallback onCustomerPayments;

  const QuickActionsSection({
    super.key,
    required this.canAssignDogs,
    this.canManagePayments = false,
    required this.isSuperuser,
    required this.onUploadMedia,
    required this.onAddDogToDay,
    required this.onSwapStaff,
    required this.onManagePermissions,
    required this.onCustomerPayments,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Quick Actions',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: Picon(PiconsDuotone.uploadSimple, size: 18),
              label: const Text('Upload to Feed'),
              onPressed: onUploadMedia,
            ),
            if (canAssignDogs)
              ActionChip(
                avatar: Picon(PiconsDuotone.plusCircle, size: 18),
                label: const Text('Add Dog to Day'),
                onPressed: onAddDogToDay,
              ),
            if (canAssignDogs)
              ActionChip(
                avatar: Picon(PiconsDuotone.arrowsLeftRight, size: 18),
                label: const Text('Swap Staff'),
                onPressed: onSwapStaff,
              ),
            if (canManagePayments)
              ActionChip(
                avatar: Picon(PiconsDuotone.currencyGbp, size: 18),
                label: const Text('Customer Payments'),
                onPressed: onCustomerPayments,
              ),
            if (isSuperuser)
              ActionChip(
                avatar: Picon(PiconsDuotone.shieldStar, size: 18),
                label: const Text('Manage Staff Permissions'),
                onPressed: onManagePermissions,
              ),
          ],
        ),
      ],
    );
  }
}
