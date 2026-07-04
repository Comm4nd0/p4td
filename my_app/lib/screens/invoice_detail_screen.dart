import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:picons/picons.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';
import '../models/invoice.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import 'my_payments_screen.dart' show InvoiceStatusPill, invoiceStatusColor;

/// One invoice, shared between owners and payments managers.
///
/// Owners see the period breakdown, payment history and a "Pay now" button
/// (Xero online invoice). Staff opened with [canManagePayments] additionally
/// get the workflow actions: send/regenerate drafts, record manual payments,
/// re-push to Xero and void.
class InvoiceDetailScreen extends StatefulWidget {
  final int invoiceId;
  final bool canManagePayments;

  const InvoiceDetailScreen({
    super.key,
    required this.invoiceId,
    this.canManagePayments = false,
  });

  @override
  State<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends State<InvoiceDetailScreen> {
  final DataService _dataService = getIt<DataService>();
  Invoice? _invoice;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadInvoice();
  }

  Future<void> _loadInvoice() async {
    try {
      final invoice = await _dataService.getInvoice(widget.invoiceId);
      if (mounted) {
        setState(() {
          _invoice = invoice;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showError('Failed to load invoice: $e');
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

  /// Run a workflow action, replacing the invoice with the response.
  Future<void> _runAction(Future<Invoice> Function() action, String successMessage) async {
    setState(() => _busy = true);
    try {
      final updated = await action();
      if (mounted) {
        setState(() => _invoice = updated);
        _showSuccess(successMessage);
      }
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _payNow() async {
    setState(() => _busy = true);
    try {
      final url = await _dataService.getInvoicePayUrl(widget.invoiceId);
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (mounted) _showError('Could not open the payment page');
      }
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmSend() async {
    final invoice = _invoice!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send invoice?'),
        content: Text(
          '${invoice.customerName} will be notified of their '
          '${invoice.periodLabel} invoice for £${invoice.total.toStringAsFixed(2)}'
          '${invoice.xeroInvoiceNumber.isEmpty ? ', and it will be created in Xero if connected' : ''}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    if (confirmed == true) {
      await _runAction(() => _dataService.sendInvoice(invoice.id), 'Invoice sent');
    }
  }

  Future<void> _confirmVoid() async {
    final hadXeroCopy = _invoice!.xeroInvoiceNumber.isNotEmpty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void invoice?'),
        content: const Text(
            'The invoice will be cancelled (in Xero too, where possible) and a new one can be generated for the same month.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Void'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _runAction(() => _dataService.voidInvoice(_invoice!.id), 'Invoice voided');
      final updated = _invoice;
      if (hadXeroCopy &&
          updated != null &&
          updated.status == 'VOID' &&
          updated.xeroSyncError.isNotEmpty &&
          mounted) {
        _showError('Could not void the Xero copy (it may have payments applied) — '
            'handle it in Xero with a credit note.');
      }
    }
  }

  Future<void> _addAdjustmentDialog() async {
    final invoice = _invoice!;
    final descriptionController = TextEditingController();
    final amountController = TextEditingController();
    var isDiscount = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add charge or discount'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Charge')),
                  ButtonSegment(value: true, label: Text('Discount')),
                ],
                selected: {isDiscount},
                onSelectionChanged: (selection) =>
                    setDialogState(() => isDiscount = selection.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionController,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Description',
                  hintText: isDiscount ? 'e.g. Loyalty discount' : 'e.g. Damaged lead',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount', prefixText: '£'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    final amount = double.tryParse(amountController.text.trim());
    if (amount == null || amount <= 0) {
      _showError('Enter a valid amount');
      return;
    }
    await _runAction(
      () => _dataService.addInvoiceLine(
        invoice.id,
        description: descriptionController.text.trim(),
        amount: isDiscount ? -amount : amount,
      ),
      isDiscount ? 'Discount added' : 'Charge added',
    );
  }

  Future<void> _removeAdjustment(InvoiceLine line) async {
    await _runAction(
      () => _dataService.removeInvoiceLine(_invoice!.id, line.id),
      'Adjustment removed',
    );
  }

  Future<void> _recordPaymentDialog() async {
    final invoice = _invoice!;
    final amountController = TextEditingController(
        text: invoice.balance > 0 ? invoice.balance.toStringAsFixed(2) : '');
    final notesController = TextEditingController();
    String method = 'BANK_TRANSFER';
    DateTime paymentDate = DateTime.now();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Record payment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount', prefixText: '£'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: method,
                decoration: const InputDecoration(labelText: 'Method'),
                items: const [
                  DropdownMenuItem(value: 'BANK_TRANSFER', child: Text('Bank transfer')),
                  DropdownMenuItem(value: 'CASH', child: Text('Cash')),
                  DropdownMenuItem(value: 'OTHER', child: Text('Other')),
                ],
                onChanged: (v) => setDialogState(() => method = v ?? 'BANK_TRANSFER'),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Payment date'),
                subtitle: Text(ukDate(paymentDate)),
                trailing: Picon(PiconsDuotone.calendar, size: 20),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: paymentDate,
                    firstDate: DateTime.now().subtract(const Duration(days: 365)),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setDialogState(() => paymentDate = picked);
                },
              ),
              TextField(
                controller: notesController,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Record')),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      final amount = double.tryParse(amountController.text.trim());
      if (amount == null || amount <= 0) {
        _showError('Enter a valid amount');
        return;
      }
      await _runAction(
        () => _dataService.recordInvoicePayment(
          invoice.id,
          amount: amount,
          method: method,
          paymentDate: paymentDate,
          notes: notesController.text.trim(),
        ),
        'Payment recorded',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final invoice = _invoice;
    return Scaffold(
      appBar: AppBar(
        title: Text(invoice == null ? 'Invoice' : 'Invoice — ${invoice.periodLabel}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : invoice == null
              ? const Center(child: Text('Invoice not found'))
              : RefreshIndicator.adaptive(
                  onRefresh: _loadInvoice,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildHeaderCard(invoice),
                      const SizedBox(height: 12),
                      _buildLinesCard(invoice),
                      if (invoice.payments.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _buildPaymentsCard(invoice),
                      ],
                      if (widget.canManagePayments) ...[
                        const SizedBox(height: 12),
                        _buildStaffActions(invoice),
                      ],
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
      bottomNavigationBar: (invoice != null &&
              !widget.canManagePayments &&
              invoice.isPayable)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _busy ? null : _payNow,
                  icon: Picon(PiconsDuotone.currencyGbp, size: 20),
                  label: Text(
                      'Pay now — £${invoice.balance.toStringAsFixed(2)}'),
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildHeaderCard(Invoice invoice) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.canManagePayments
                        ? invoice.customerName
                        : invoice.periodLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
                InvoiceStatusPill(invoice: invoice),
              ],
            ),
            if (widget.canManagePayments) ...[
              const SizedBox(height: 2),
              Text(invoice.customerEmail,
                  style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            ],
            const SizedBox(height: 12),
            _kv('Total', '£${invoice.total.toStringAsFixed(2)}'),
            _kv('Paid', '£${invoice.amountPaid.toStringAsFixed(2)}'),
            _kv('Balance', '£${invoice.balance.toStringAsFixed(2)}',
                color: invoice.balance > 0 ? invoiceStatusColor(invoice) : AppColors.success),
            if (invoice.dueDate != null)
              _kv('Due', ukDate(invoice.dueDate!),
                  color: invoice.isOverdue ? AppColors.error : null),
            if (invoice.xeroInvoiceNumber.isNotEmpty)
              _kv('Xero invoice', invoice.xeroInvoiceNumber),
            if (widget.canManagePayments && invoice.xeroSyncError.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Picon(PiconsDuotone.warning, size: 18, color: AppColors.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Xero: ${invoice.xeroSyncError}',
                        style: const TextStyle(color: AppColors.error, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 14)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLinesCard(Invoice invoice) {
    final attendanceLines = invoice.lines.where((l) => !l.isAdjustment).toList();
    final adjustments = invoice.lines.where((l) => l.isAdjustment).toList();
    final canEditAdjustments = widget.canManagePayments && invoice.status == 'DRAFT';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Charges',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            ...attendanceLines.map((line) => ExpansionTile(
                  leading: Picon(PiconsDuotone.dog, size: 24),
                  title: Text(line.dogName ?? line.description,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  subtitle: Text(
                    '${line.description.startsWith('Boarding') ? 'Boarding — ' : ''}'
                    '${line.quantity} ${line.description.startsWith('Boarding') ? 'night' : 'day'}${line.quantity == 1 ? '' : 's'} @ £${line.unitPrice.toStringAsFixed(2)}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 13),
                  ),
                  trailing: Text('£${line.lineTotal.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  children: [
                    if (line.attendanceDates.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: line.attendanceDates.map((iso) {
                            final parsed = DateTime.tryParse(iso);
                            return Chip(
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              label: Text(
                                parsed != null ? DateFormat('EEE d MMM').format(parsed) : iso,
                                style: const TextStyle(fontSize: 11),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                  ],
                )),
            ...adjustments.map((line) => ListTile(
                  dense: true,
                  leading: Picon(
                    line.lineTotal < 0 ? PiconsDuotone.arrowDown : PiconsDuotone.plusCircle,
                    size: 22,
                    color: line.lineTotal < 0 ? AppColors.success : AppColors.info,
                  ),
                  title: Text(line.description),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${line.lineTotal < 0 ? '−' : ''}£${line.lineTotal.abs().toStringAsFixed(2)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: line.lineTotal < 0 ? AppColors.success : null,
                        ),
                      ),
                      if (canEditAdjustments)
                        IconButton(
                          icon: Picon(PiconsDuotone.trash, size: 18, color: AppColors.error),
                          tooltip: 'Remove adjustment',
                          onPressed: _busy ? null : () => _removeAdjustment(line),
                        ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentsCard(Invoice invoice) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Payments',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            ...invoice.payments.map((payment) => ListTile(
                  dense: true,
                  leading: Picon(PiconsDuotone.checkCircle, size: 22, color: AppColors.success),
                  title: Text('£${payment.amount.toStringAsFixed(2)} — ${payment.methodDisplay}'),
                  subtitle: Text([
                    if (payment.paymentDate != null) ukDate(payment.paymentDate!),
                    if (payment.recordedByName != null) 'by ${payment.recordedByName}',
                    if (payment.notes.isNotEmpty) payment.notes,
                  ].join(' · ')),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildStaffActions(Invoice invoice) {
    final buttons = <Widget>[
      if (invoice.status == 'DRAFT') ...[
        FilledButton.icon(
          onPressed: _busy ? null : _confirmSend,
          icon: Picon(PiconsDuotone.paperPlaneTilt, size: 18),
          label: const Text('Send to customer'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _addAdjustmentDialog,
          icon: Picon(PiconsDuotone.listPlus, size: 18),
          label: const Text('Add charge / discount'),
        ),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _runAction(
                  () => _dataService.regenerateInvoice(invoice.id),
                  'Invoice regenerated from attendance'),
          icon: Picon(PiconsDuotone.arrowClockwise, size: 18),
          label: const Text('Regenerate from attendance'),
        ),
      ],
      if (invoice.status == 'SENT' || invoice.status == 'PART_PAID')
        FilledButton.icon(
          onPressed: _busy ? null : _recordPaymentDialog,
          icon: Picon(PiconsDuotone.plusCircle, size: 18),
          label: const Text('Record payment'),
        ),
      if ((invoice.status == 'SENT' || invoice.status == 'PART_PAID') &&
          (invoice.xeroSyncError.isNotEmpty || invoice.xeroInvoiceNumber.isEmpty))
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _runAction(
                  () => _dataService.pushInvoiceToXero(invoice.id), 'Pushed to Xero'),
          icon: Picon(PiconsDuotone.uploadSimple, size: 18),
          label: const Text('Push to Xero'),
        ),
      if (invoice.status != 'PAID' && invoice.status != 'VOID')
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
          onPressed: _busy ? null : _confirmVoid,
          icon: Picon(PiconsDuotone.xCircle, size: 18),
          label: const Text('Void invoice'),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Actions',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              buttons[i],
            ],
          ],
        ),
      ),
    );
  }
}
