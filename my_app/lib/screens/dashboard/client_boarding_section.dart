import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/boarding_request.dart';
import '../../utils/date_formats.dart';

/// The owner's boarding stays that are still to come (or under way): each
/// approved or pending request whose last night is today or later, soonest
/// first. Denied and cancelled stays are the owner's history, not their plan,
/// so they stay on the full list screen.
class ClientBoardingSection extends StatelessWidget {
  final DateTime today;
  final List<BoardingRequest> boarding;

  /// The boarding fetch failed while the rest of the dashboard loaded; say so
  /// rather than showing a misleading "no boarding".
  final bool failed;

  final void Function(BoardingRequest request)? onTap;
  final VoidCallback? onRequest;

  const ClientBoardingSection({
    super.key,
    required this.today,
    required this.boarding,
    this.failed = false,
    this.onTap,
    this.onRequest,
  });

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static List<BoardingRequest> upcoming(List<BoardingRequest> all, DateTime today) {
    final day = _dateOnly(today);
    final rows = all
        .where((r) =>
            (r.status == BoardingRequestStatus.approved ||
                r.status == BoardingRequestStatus.pending) &&
            !_dateOnly(r.endDate).isBefore(day))
        .toList()
      ..sort((a, b) => a.startDate.compareTo(b.startDate));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = upcoming(boarding, today);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Upcoming Boarding',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            if (onRequest != null)
              TextButton.icon(
                onPressed: onRequest,
                icon: const Picon(PiconsDuotone.plus, size: 16),
                label: const Text('Request'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (failed)
          _message("Couldn't load boarding — pull down to try again")
        else if (rows.isEmpty)
          _message('No boarding booked')
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _buildRow(rows[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _message(String text) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(child: Text(text, style: TextStyle(color: Colors.grey[500]))),
        ),
      );

  /// Where an approved stay is relative to today, for the row's status line.
  String? _phase(BoardingRequest r) {
    final day = _dateOnly(today);
    final start = _dateOnly(r.startDate);
    final end = _dateOnly(r.endDate);
    if (start == day) return 'drop off today';
    if (end == day) return 'home today';
    if (start.isBefore(day) && end.isAfter(day)) return 'boarding now';
    return null;
  }

  Widget _buildRow(BoardingRequest request) {
    final pending = request.status == BoardingRequestStatus.pending;
    final carer = request.assignedStaffName;
    final phase = pending ? null : _phase(request);
    final statusParts = [
      pending ? 'Awaiting approval' : 'Confirmed',
      if (phase != null) phase,
      if (!pending && carer != null) 'with $carer',
    ];
    final statusColor = pending ? AppColors.warning : AppColors.success;

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(children: [
        Picon(PiconsDuotone.bed, size: 20, color: pending ? AppColors.warning : Colors.deepPurple),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(request.dogNames.join(', '),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              Row(children: [
                Picon(PiconsDuotone.calendarBlank, size: 12, color: Colors.grey[600]),
                const SizedBox(width: 6),
                Text('${ukDate(request.startDate)} – ${ukDate(request.endDate)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700])),
              ]),
              const SizedBox(height: 2),
              Row(children: [
                Picon(pending ? PiconsDuotone.hourglass : PiconsDuotone.checkCircle,
                    size: 12, color: statusColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(statusParts.join(' · '),
                      style: TextStyle(fontSize: 12, color: statusColor)),
                ),
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
