import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/invoice.dart';
import '../../utils/date_formats.dart';

/// The owner's most recent invoice at a glance. Rendered only when there is
/// one — most of the client book is still invoiced by hand in Xero and never
/// sees an app invoice, so an empty billing card would just puzzle them.
class ClientBillingCard extends StatelessWidget {
  final Invoice invoice;
  final VoidCallback? onTap;

  const ClientBillingCard({super.key, required this.invoice, this.onTap});

  /// The newest by billing period, ignoring voided ones.
  static Invoice? latest(List<Invoice> invoices) {
    final live = invoices.where((i) => i.status != 'VOID').toList()
      ..sort((a, b) {
        final byYear = b.periodYear.compareTo(a.periodYear);
        return byYear != 0 ? byYear : b.periodMonth.compareTo(a.periodMonth);
      });
    return live.firstOrNull;
  }

  static String pounds(double amount) => '£${amount.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final i = invoice;
    final paid = i.status == 'PAID';
    final color = i.isOverdue
        ? AppColors.error
        : paid
            ? AppColors.success
            : AppColors.warning;
    final due = i.dueDate;
    final detail = [
      i.statusLabel,
      if (!paid && i.amountPaid > 0) '${pounds(i.balance)} to pay',
      if (!paid && due != null) 'due ${ukDate(due)}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Billing',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: Picon(PiconsDuotone.currencyGbp, color: color),
            title: Text('${pounds(i.total)} · ${i.periodLabel}'),
            subtitle: Text(detail, style: TextStyle(fontSize: 12, color: color)),
            trailing: onTap == null
                ? null
                : Picon(PiconsDuotone.caretRight, size: 16, color: Colors.grey[400]),
            onTap: onTap,
          ),
        ),
      ],
    );
  }
}
