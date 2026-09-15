import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/boarding_request.dart';
import '../../models/date_change_request.dart';
import '../../models/dog.dart';
import '../../models/invoice.dart';
import '../../models/owner_calendar.dart';
import '../../models/support_query.dart';
import '../../widgets/dashboard_widgets.dart';

/// Everything on the owner's plate, distilled from the data the dashboard
/// already fetched. Pure, so the arithmetic is testable without widgets.
class ClientAttention {
  /// Vaccination due within this many days counts as "due soon".
  static const int vaccinationWarningDays = 30;

  final int overdueInvoices;

  /// Sent or part-paid and not yet overdue.
  final int unpaidInvoices;
  final List<Dog> vaccinationOverdue;
  final List<Dog> vaccinationDueSoon;
  final int pendingDayRequests;
  final int pendingBoarding;
  final int unreadReplies;

  /// Waitlist entries staff have told the owner about: a spot has opened.
  final int waitlistOffers;
  final List<Dog> missingContacts;

  const ClientAttention({
    this.overdueInvoices = 0,
    this.unpaidInvoices = 0,
    this.vaccinationOverdue = const [],
    this.vaccinationDueSoon = const [],
    this.pendingDayRequests = 0,
    this.pendingBoarding = 0,
    this.unreadReplies = 0,
    this.waitlistOffers = 0,
    this.missingContacts = const [],
  });

  int get total =>
      overdueInvoices +
      unpaidInvoices +
      vaccinationOverdue.length +
      vaccinationDueSoon.length +
      pendingDayRequests +
      pendingBoarding +
      unreadReplies +
      waitlistOffers +
      missingContacts.length;

  static bool _blank(String? s) => s == null || s.trim().isEmpty;

  static ClientAttention compute({
    required DateTime today,
    required List<Dog> dogs,
    required List<Invoice> invoices,
    required List<DateChangeRequest> dayRequests,
    required List<BoardingRequest> boarding,
    required List<SupportQuery> queries,
    OwnerCalendar? calendar,
  }) {
    final open = invoices.where((i) => i.status == 'SENT' || i.status == 'PART_PAID');
    final overdue = open.where((i) => i.isOverdue).length;

    final vaccOverdue = <Dog>[];
    final vaccSoon = <Dog>[];
    for (final dog in dogs) {
      if (dog.vaccinationOverdue) {
        vaccOverdue.add(dog);
        continue;
      }
      final last = dog.lastVaccinationDate;
      if (last == null) continue;
      final due = DateTime(last.year + 1, last.month, last.day);
      final daysLeft = due.difference(DateTime(today.year, today.month, today.day)).inDays;
      if (daysLeft <= vaccinationWarningDays) vaccSoon.add(dog);
    }

    final waitlistIds = <int>{
      if (calendar != null)
        for (final day in calendar.days)
          for (final w in day.waitlist)
            if (w.status == 'NOTIFIED') w.id,
    };

    return ClientAttention(
      overdueInvoices: overdue,
      unpaidInvoices: open.length - overdue,
      vaccinationOverdue: vaccOverdue,
      vaccinationDueSoon: vaccSoon,
      pendingDayRequests: dayRequests.where((r) => r.status == RequestStatus.pending).length,
      pendingBoarding: boarding.where((r) => r.status == BoardingRequestStatus.pending).length,
      unreadReplies: queries.where((q) => q.hasUnreadReply).length,
      waitlistOffers: waitlistIds.length,
      missingContacts: [
        for (final dog in dogs)
          if (_blank(dog.contactNumber) || _blank(dog.emergencyContactNumber)) dog,
      ],
    );
  }
}

/// The owner's Action Items: one tile per thing that needs them, and only
/// those — unlike the staff list, a zero row here is noise, so an empty
/// plate is a single reassuring card instead.
class ClientAttentionSection extends StatelessWidget {
  final ClientAttention attention;
  final VoidCallback onOpenPayments;
  final void Function(List<Dog> dogs) onOpenVaccinations;
  final VoidCallback onOpenDayRequests;
  final VoidCallback onOpenBoarding;
  final VoidCallback onOpenQueries;
  final VoidCallback onOpenCalendar;
  final void Function(List<Dog> dogs) onOpenDogDetails;

  const ClientAttentionSection({
    super.key,
    required this.attention,
    required this.onOpenPayments,
    required this.onOpenVaccinations,
    required this.onOpenDayRequests,
    required this.onOpenBoarding,
    required this.onOpenQueries,
    required this.onOpenCalendar,
    required this.onOpenDogDetails,
  });

  String _names(List<Dog> dogs) => dogs.map((d) => d.name).join(', ');

  @override
  Widget build(BuildContext context) {
    final a = attention;
    final tiles = <Widget>[
      if (a.overdueInvoices > 0)
        ActionItemTile(
          icon: PiconsDuotone.currencyGbp,
          label: 'Invoice overdue',
          count: a.overdueInvoices,
          countColor: AppColors.error,
          onTap: onOpenPayments,
        ),
      if (a.unpaidInvoices > 0)
        ActionItemTile(
          icon: PiconsDuotone.currencyGbp,
          label: 'Invoice awaiting payment',
          count: a.unpaidInvoices,
          countColor: AppColors.warning,
          onTap: onOpenPayments,
        ),
      if (a.vaccinationOverdue.isNotEmpty)
        ActionItemTile(
          icon: PiconsDuotone.firstAidKit,
          label: 'Vaccination overdue',
          subtitle: _names(a.vaccinationOverdue),
          count: a.vaccinationOverdue.length,
          countColor: AppColors.error,
          onTap: () => onOpenVaccinations(a.vaccinationOverdue),
        ),
      if (a.vaccinationDueSoon.isNotEmpty)
        ActionItemTile(
          icon: PiconsDuotone.firstAidKit,
          label: 'Vaccination due soon',
          subtitle: _names(a.vaccinationDueSoon),
          count: a.vaccinationDueSoon.length,
          countColor: AppColors.warning,
          onTap: () => onOpenVaccinations(a.vaccinationDueSoon),
        ),
      if (a.pendingDayRequests > 0)
        ActionItemTile(
          icon: PiconsDuotone.hourglass,
          label: 'Day requests awaiting approval',
          count: a.pendingDayRequests,
          countColor: AppColors.warning,
          onTap: onOpenDayRequests,
        ),
      if (a.pendingBoarding > 0)
        ActionItemTile(
          icon: PiconsDuotone.bed,
          label: 'Boarding awaiting approval',
          count: a.pendingBoarding,
          countColor: AppColors.warning,
          onTap: onOpenBoarding,
        ),
      if (a.unreadReplies > 0)
        ActionItemTile(
          icon: PiconsDuotone.chats,
          label: 'Unread replies from staff',
          count: a.unreadReplies,
          countColor: AppColors.error,
          onTap: onOpenQueries,
        ),
      if (a.waitlistOffers > 0)
        ActionItemTile(
          icon: PiconsDuotone.calendarCheck,
          label: 'Waitlist spot available',
          count: a.waitlistOffers,
          countColor: AppColors.success,
          onTap: onOpenCalendar,
        ),
      if (a.missingContacts.isNotEmpty)
        ActionItemTile(
          icon: PiconsDuotone.warningCircle,
          label: 'Contact number missing',
          subtitle: _names(a.missingContacts),
          count: a.missingContacts.length,
          countColor: AppColors.warning,
          onTap: () => onOpenDogDetails(a.missingContacts),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Needs Your Attention',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (tiles.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Picon(PiconsDuotone.checkCircle, size: 18, color: AppColors.success),
                  const SizedBox(width: 8),
                  Text('Nothing needs your attention',
                      style: TextStyle(color: Colors.grey[600])),
                ],
              ),
            ),
          )
        else
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            tiles[i],
          ],
      ],
    );
  }
}
