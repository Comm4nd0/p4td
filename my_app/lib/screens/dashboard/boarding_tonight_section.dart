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

  const BoardingTonightSection({super.key, required this.boardingTonight});

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
          ...boardingTonight.map((request) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Picon(PiconsDuotone.bed, size: 18, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(
                          '${request.dogNames.join(", ")} (${request.ownerName})',
                          style: const TextStyle(fontSize: 14))),
                ]),
              )),
      ],
    );
  }
}
