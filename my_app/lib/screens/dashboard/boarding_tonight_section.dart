import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/boarding_request.dart';

/// The "Boarding Tonight" section on the staff dashboard.
///
/// Extracted verbatim from [UnifiedDashboardScreen] (audit F14). Pure
/// presentation over the list of boarding requests staying tonight.
class BoardingTonightSection extends StatelessWidget {
  final List<BoardingRequest> boardingTonight;

  /// When provided, each boarding row becomes tappable to (re)assign the staff
  /// member the dog boards with.
  final void Function(BoardingRequest request)? onReassign;

  const BoardingTonightSection({super.key, required this.boardingTonight, this.onReassign});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Boarding Tonight',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (boardingTonight.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                  child: Text('No boarding tonight',
                      style: TextStyle(color: Colors.grey[500]))),
            ),
          )
        else
          ...boardingTonight.map(_buildRow),
      ],
    );
  }

  Widget _buildRow(BoardingRequest request) {
    final carer = request.assignedStaffName;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Picon(PiconsDuotone.bed, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${request.dogNames.join(", ")} (${request.ownerName})',
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 2),
              Row(children: [
                Picon(PiconsDuotone.user, size: 12, color: carer != null ? AppColors.primary : Colors.grey),
                const SizedBox(width: 4),
                Text(carer != null ? 'with $carer' : 'No carer assigned',
                    style: TextStyle(
                        fontSize: 12,
                        color: carer != null ? Colors.grey[700] : Colors.grey[500])),
              ]),
            ],
          ),
        ),
        if (onReassign != null) Picon(PiconsDuotone.caretRight, size: 16, color: Colors.grey[400]),
      ]),
    );
    if (onReassign == null) return row;
    return InkWell(onTap: () => onReassign!(request), child: row);
  }
}
