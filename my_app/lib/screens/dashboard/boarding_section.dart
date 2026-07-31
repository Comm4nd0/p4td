import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/boarding_request.dart';
import '../../utils/date_formats.dart';

/// The boarding section on the staff dashboard: the dogs sleeping here on the
/// night of [date], each with the stay it belongs to.
///
/// Follows the dashboard's selected date rather than always showing tonight,
/// because the date strip now runs over weekends — days that carry no daycare
/// at all, so boarding is the only thing there is to see on them.
class BoardingSection extends StatelessWidget {
  final DateTime date;
  final List<BoardingRequest> boarding;

  /// When provided, each boarding row becomes tappable. The dashboard opens
  /// the dog's quick-info popup (which carries its own reassign shortcut).
  final void Function(BoardingRequest request)? onTap;

  const BoardingSection({
    super.key,
    required this.date,
    required this.boarding,
    this.onTap,
  });

  bool get _isTonight {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_isTonight ? 'Boarding Tonight' : 'Boarding ${ukDateWithDay(date)}',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (boarding.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                  child: Text(
                      _isTonight ? 'No boarding tonight' : 'No boarding that night',
                      style: TextStyle(color: Colors.grey[500]))),
            ),
          )
        else
          ...boarding.map(_buildRow),
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
              Text(request.dogNames.join(', '),
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 2),
              // The stay's full span, so staff can tell a dog going home in the
              // morning from one here for another week without opening it.
              Row(children: [
                Picon(PiconsDuotone.calendarBlank, size: 12, color: Colors.grey[600]),
                const SizedBox(width: 4),
                Text('${ukDate(request.startDate)} – ${ukDate(request.endDate)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700])),
              ]),
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
        if (onTap != null) Picon(PiconsDuotone.caretRight, size: 16, color: Colors.grey[400]),
      ]),
    );
    if (onTap == null) return row;
    return InkWell(onTap: () => onTap!(request), child: row);
  }
}
