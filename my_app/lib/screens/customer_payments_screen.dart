import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/customer_rate.dart';
import '../models/invoice.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import 'invoice_detail_screen.dart';
import 'my_payments_screen.dart' show InvoiceStatusPill;
import 'pricing_screen.dart';
import 'xero_reconciliation_screen.dart';

/// Staff payments dashboard (requires can_manage_payments): monthly invoices
/// with summary totals, generate/send-all/Xero-sync actions and per-invoice
/// drill-down to [InvoiceDetailScreen].
class CustomerPaymentsScreen extends StatefulWidget {
  const CustomerPaymentsScreen({super.key});

  @override
  State<CustomerPaymentsScreen> createState() => _CustomerPaymentsScreenState();
}

class _CustomerPaymentsScreenState extends State<CustomerPaymentsScreen> {
  final DataService _dataService = getIt<DataService>();

  /// Selected billing month — defaults to the previous calendar month, the
  /// one most recently billed (invoicing runs in arrears).
  late DateTime _month;
  String? _statusFilter;
  List<Invoice> _invoices = [];
  InvoiceSummary _summary = InvoiceSummary();
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month - 1);
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final invoices = await _dataService.getInvoices(
        year: _month.year,
        month: _month.month,
        status: _statusFilter,
      );
      final summary = await _dataService.getInvoiceSummary(
        year: _month.year,
        month: _month.month,
      );
      if (mounted) {
        setState(() {
          _invoices = invoices;
          _summary = summary;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showError('Failed to load invoices: $e');
      }
    }
  }

  void _showError(Object message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$message'), backgroundColor: AppColors.error),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.success),
    );
  }

  void _changeMonth(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
    _load();
  }

  String get _monthLabel => DateFormat('MMMM yyyy').format(_month);

  Future<void> _generateInvoices() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Generate invoices?'),
        content: Text(
            'Draft invoices for $_monthLabel will be created from attendance '
            'records. Customers already invoiced for this month are skipped, '
            'and nothing is sent until you review each draft.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Generate')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final result = await _dataService.generateInvoices(_month.year, _month.month);
      if (mounted) {
        _showSuccess('Created ${result.created} draft invoice(s)'
            '${result.skipped > 0 ? ', skipped ${result.skipped} already invoiced' : ''}'
            '${result.manual > 0 ? ', ${result.manual} on manual Xero billing' : ''}');
      }
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateForCustomer() async {
    List<CustomerRate> customers;
    try {
      customers = await _dataService.getCustomerRates();
    } catch (e) {
      _showError(e);
      return;
    }
    if (!mounted) return;

    final chosen = await showModalBottomSheet<CustomerRate>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CustomerPickerSheet(customers: customers),
    );
    if (chosen == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await _dataService.generateInvoices(
        _month.year, _month.month, customerId: chosen.userId);
      if (mounted) {
        if (result.created > 0) {
          _showSuccess('Draft invoice created for ${chosen.displayName}');
        } else if (result.skipped > 0) {
          _showError('${chosen.displayName} already has an invoice for $_monthLabel — void it first to reissue.');
        } else {
          _showError('${chosen.displayName} has nothing to bill for $_monthLabel.');
        }
      }
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendAllDrafts() async {
    if (_summary.draft == 0) {
      _showError('No draft invoices for $_monthLabel');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send all drafts?'),
        content: Text(
            '${_summary.draft} draft invoice(s) for $_monthLabel will be sent — '
            'each customer is notified and the invoices are created in Xero if connected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send all')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final sent = await _dataService.sendAllInvoices(_month.year, _month.month);
      if (mounted) _showSuccess('Sent $sent invoice(s)');
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncXero() async {
    setState(() => _busy = true);
    try {
      final counts = await _dataService.syncXeroInvoices();
      if (mounted) {
        _showSuccess('Checked ${counts['checked'] ?? 0} invoice(s), '
            'imported ${counts['payments_imported'] ?? 0} payment(s)');
      }
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openInvoice(Invoice invoice) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InvoiceDetailScreen(
          invoiceId: invoice.id,
          canManagePayments: true,
        ),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer Payments'),
        actions: [
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (value) {
              switch (value) {
                case 'generate':
                  _generateInvoices();
                  break;
                case 'generate_one':
                  _generateForCustomer();
                  break;
                case 'send_all':
                  _sendAllDrafts();
                  break;
                case 'sync':
                  _syncXero();
                  break;
                case 'pricing':
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PricingScreen()),
                  ).then((_) => _load());
                  break;
                case 'xero_contacts':
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const XeroReconciliationScreen()),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'generate',
                child: Text('Generate invoices for month'),
              ),
              const PopupMenuItem(
                value: 'generate_one',
                child: Text('Generate for one customer'),
              ),
              const PopupMenuItem(
                value: 'send_all',
                child: Text('Send all drafts'),
              ),
              const PopupMenuItem(
                value: 'sync',
                child: Text('Sync payments from Xero'),
              ),
              const PopupMenuItem(
                value: 'pricing',
                child: Text('Pricing & customer rates'),
              ),
              const PopupMenuItem(
                value: 'xero_contacts',
                child: Text('Xero contact matching'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildMonthPicker(),
          _buildSummaryRow(),
          _buildStatusFilter(),
          const SizedBox(height: 4),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator.adaptive())
                : RefreshIndicator.adaptive(
                    onRefresh: _load,
                    child: _invoices.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height: MediaQuery.of(context).size.height * 0.4,
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Picon(PiconsDuotone.currencyGbp,
                                          size: 64, color: Colors.grey[400]),
                                      const SizedBox(height: 16),
                                      Text(
                                        'No invoices for $_monthLabel',
                                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Use the menu to generate invoices from attendance',
                                        style: TextStyle(color: Colors.grey[500], fontSize: 13),
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
          ),
        ],
      ),
    );
  }

  Widget _buildMonthPicker() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _busy ? null : () => _changeMonth(-1),
            tooltip: 'Previous month',
          ),
          Expanded(
            child: Text(
              _monthLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _busy ? null : () => _changeMonth(1),
            tooltip: 'Next month',
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow() {
    Widget stat(String label, String value, Color color) {
      return Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(color: Colors.grey[600], fontSize: 11)),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          stat('Billed', '£${_summary.totalBilled.toStringAsFixed(0)}', AppColors.info),
          stat('Collected', '£${_summary.totalCollected.toStringAsFixed(0)}', AppColors.success),
          stat('Outstanding', '£${_summary.totalOutstanding.toStringAsFixed(0)}',
              _summary.totalOutstanding > 0 ? AppColors.warning : AppColors.success),
          if (_summary.overdueCount > 0)
            stat('Overdue', '${_summary.overdueCount}', AppColors.error),
        ],
      ),
    );
  }

  Widget _buildStatusFilter() {
    const filters = [
      (null, 'All'),
      ('DRAFT', 'Draft'),
      ('SENT', 'Sent'),
      ('PART_PAID', 'Part paid'),
      ('PAID', 'Paid'),
      ('VOID', 'Void'),
    ];
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final (value, label) in filters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(label),
                selected: _statusFilter == value,
                onSelected: (_) {
                  setState(() => _statusFilter = value);
                  _load();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInvoiceCard(Invoice invoice) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: InkWell(
        onTap: () => _openInvoice(invoice),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      invoice.customerName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '£${invoice.total.toStringAsFixed(2)}',
                        if (invoice.amountPaid > 0 && invoice.status != 'PAID')
                          '£${invoice.amountPaid.toStringAsFixed(2)} paid',
                        '${invoice.lines.length} dog${invoice.lines.length == 1 ? '' : 's'}',
                        if (invoice.xeroInvoiceNumber.isNotEmpty) invoice.xeroInvoiceNumber,
                      ].join(' · '),
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                    if (invoice.xeroSyncError.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      const Text(
                        'Xero push failed',
                        style: TextStyle(
                            color: AppColors.error, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              InvoiceStatusPill(invoice: invoice),
              const SizedBox(width: 4),
              Picon(PiconsDuotone.caretRight, size: 16, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Searchable customer picker used by "Generate for one customer".
class _CustomerPickerSheet extends StatefulWidget {
  final List<CustomerRate> customers;

  const _CustomerPickerSheet({required this.customers});

  @override
  State<_CustomerPickerSheet> createState() => _CustomerPickerSheetState();
}

class _CustomerPickerSheetState extends State<_CustomerPickerSheet> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final query = _search.toLowerCase();
    final visible = widget.customers
        .where((c) =>
            query.isEmpty ||
            c.displayName.toLowerCase().contains(query) ||
            c.username.toLowerCase().contains(query) ||
            c.dogNames.any((d) => d.toLowerCase().contains(query)))
        .toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  children: [
                    Text('Choose a customer',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Search customers or dogs',
                        prefixIcon: Picon(PiconsDuotone.magnifyingGlass, size: 20),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onChanged: (value) => setState(() => _search = value),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text('No customers found',
                            style: TextStyle(color: Colors.grey[600])),
                      )
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final customer = visible[index];
                          return ListTile(
                            title: Text(customer.displayName),
                            subtitle: customer.dogNames.isEmpty
                                ? null
                                : Text(customer.dogNames.join(', '),
                                    style: const TextStyle(fontSize: 12)),
                            onTap: () => Navigator.pop(context, customer),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
