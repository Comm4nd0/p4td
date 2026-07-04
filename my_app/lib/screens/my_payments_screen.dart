import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/invoice.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import 'invoice_detail_screen.dart';

/// Colour for an invoice status ('DRAFT' | 'SENT' | 'PART_PAID' | 'PAID' |
/// 'VOID'), with overdue overriding to the error colour.
Color invoiceStatusColor(Invoice invoice) {
  if (invoice.isOverdue) return AppColors.error;
  switch (invoice.status) {
    case 'PAID':
      return AppColors.success;
    case 'PART_PAID':
      return AppColors.warning;
    case 'SENT':
      return AppColors.info;
    case 'VOID':
      return Colors.grey;
    default: // DRAFT
      return Colors.grey;
  }
}

/// Small pill showing an invoice's payment status, e.g. "Partially paid".
class InvoiceStatusPill extends StatelessWidget {
  final Invoice invoice;

  const InvoiceStatusPill({super.key, required this.invoice});

  @override
  Widget build(BuildContext context) {
    final color = invoiceStatusColor(invoice);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        invoice.statusLabel,
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11),
      ),
    );
  }
}

/// The owner's invoice list ("My Payments" in the drawer). Staff with
/// can_manage_payments use [CustomerPaymentsScreen] instead.
class MyPaymentsScreen extends StatefulWidget {
  /// When set (from a payment notification deep-link), open this invoice's
  /// detail screen once the list has loaded.
  final int? openInvoiceId;

  const MyPaymentsScreen({super.key, this.openInvoiceId});

  @override
  State<MyPaymentsScreen> createState() => _MyPaymentsScreenState();
}

class _MyPaymentsScreenState extends State<MyPaymentsScreen> {
  final DataService _dataService = getIt<DataService>();
  List<Invoice> _invoices = [];
  bool _loading = true;
  bool _openedDeepLink = false;

  @override
  void initState() {
    super.initState();
    _loadInvoices();
  }

  Future<void> _loadInvoices() async {
    setState(() => _loading = true);
    try {
      final invoices = await _dataService.getInvoices();
      if (mounted) {
        setState(() {
          _invoices = invoices;
          _loading = false;
        });
        _maybeOpenDeepLink();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load invoices: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  void _maybeOpenDeepLink() {
    if (_openedDeepLink || widget.openInvoiceId == null) return;
    _openedDeepLink = true;
    final invoice =
        _invoices.where((i) => i.id == widget.openInvoiceId).firstOrNull;
    if (invoice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openInvoice(invoice);
      });
    }
  }

  Future<void> _openInvoice(Invoice invoice) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InvoiceDetailScreen(invoiceId: invoice.id),
      ),
    );
    _loadInvoices();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Payments')),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : RefreshIndicator.adaptive(
              onRefresh: _loadInvoices,
              child: _invoices.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.5,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Picon(PiconsDuotone.currencyGbp, size: 64, color: Colors.grey[400]),
                                const SizedBox(height: 16),
                                Text(
                                  'No invoices yet',
                                  style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Your monthly daycare invoices will appear here',
                                  style: TextStyle(color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: _invoices.length,
                      itemBuilder: (context, index) =>
                          _buildInvoiceCard(_invoices[index]),
                    ),
            ),
    );
  }

  Widget _buildInvoiceCard(Invoice invoice) {
    final outstanding = invoice.balance;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: () => _openInvoice(invoice),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Picon(PiconsDuotone.currencyGbp, size: 32,
                  color: invoiceStatusColor(invoice)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      invoice.periodLabel,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      invoice.status == 'PAID'
                          ? 'Paid £${invoice.total.toStringAsFixed(2)}'
                          : '£${outstanding.toStringAsFixed(2)} outstanding of £${invoice.total.toStringAsFixed(2)}',
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              InvoiceStatusPill(invoice: invoice),
            ],
          ),
        ),
      ),
    );
  }
}
