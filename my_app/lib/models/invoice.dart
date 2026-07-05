/// Monthly customer invoice models, mirroring the /api/invoices/ payload.
///
/// Money comes over the wire as decimal strings (DRF DecimalField); parse
/// with [_parseAmount] so both "25.00" and numeric JSON survive.

double _parseAmount(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}

class InvoiceLine {
  final int id;
  final int? dogId;
  final String? dogName;
  final String description;
  final int quantity;
  final double unitPrice;
  final double lineTotal;

  /// ISO dates the dog attended — shown so owners can verify their bill.
  final List<String> attendanceDates;

  /// Staff-entered one-off charge/discount (negative = discount).
  final bool isAdjustment;

  InvoiceLine({
    required this.id,
    this.dogId,
    this.dogName,
    required this.description,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    this.attendanceDates = const [],
    this.isAdjustment = false,
  });

  factory InvoiceLine.fromJson(Map<String, dynamic> json) {
    return InvoiceLine(
      id: json['id'],
      dogId: json['dog'],
      dogName: json['dog_name'],
      description: json['description'] ?? '',
      quantity: json['quantity'] ?? 0,
      unitPrice: _parseAmount(json['unit_price']),
      lineTotal: _parseAmount(json['line_total']),
      attendanceDates: (json['attendance_dates'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      isAdjustment: json['is_adjustment'] ?? false,
    );
  }
}

class InvoicePayment {
  final int id;
  final double amount;

  /// 'CASH' | 'BANK_TRANSFER' | 'XERO_ONLINE' | 'OTHER'
  final String method;
  final String methodDisplay;

  /// 'MANUAL' (recorded by staff) | 'XERO' (imported from Xero)
  final String source;
  final DateTime? paymentDate;
  final String? recordedByName;
  final String notes;

  InvoicePayment({
    required this.id,
    required this.amount,
    required this.method,
    required this.methodDisplay,
    required this.source,
    this.paymentDate,
    this.recordedByName,
    this.notes = '',
  });

  factory InvoicePayment.fromJson(Map<String, dynamic> json) {
    return InvoicePayment(
      id: json['id'],
      amount: _parseAmount(json['amount']),
      method: json['method'] ?? 'OTHER',
      methodDisplay: json['method_display'] ?? json['method'] ?? '',
      source: json['source'] ?? 'MANUAL',
      paymentDate: json['payment_date'] != null
          ? DateTime.parse(json['payment_date'])
          : null,
      recordedByName: json['recorded_by_name'],
      notes: json['notes'] ?? '',
    );
  }
}

class Invoice {
  final int id;

  /// Null for invoices in a dog's name (dog has no client attached —
  /// those are emailed from Xero rather than paid in-app).
  final int? customerId;
  final String customerName;
  final String customerEmail;
  final int periodYear;
  final int periodMonth;

  /// e.g. "June 2026" (computed server-side)
  final String periodLabel;

  /// 'DRAFT' | 'SENT' | 'PART_PAID' | 'PAID' | 'VOID'
  final String status;
  final double total;
  final double amountPaid;
  final double balance;
  final DateTime? dueDate;
  final bool isOverdue;
  final DateTime? sentAt;
  final DateTime? paidAt;
  final String xeroInvoiceNumber;

  /// Staff-only diagnostic; empty for owners and when the push succeeded.
  final String xeroSyncError;

  /// Whether a Xero online-invoice URL exists (drives the "Pay now" button).
  final bool hasOnlinePayment;
  final List<InvoiceLine> lines;
  final List<InvoicePayment> payments;

  Invoice({
    required this.id,
    this.customerId,
    required this.customerName,
    required this.customerEmail,
    required this.periodYear,
    required this.periodMonth,
    required this.periodLabel,
    required this.status,
    required this.total,
    required this.amountPaid,
    required this.balance,
    this.dueDate,
    this.isOverdue = false,
    this.sentAt,
    this.paidAt,
    this.xeroInvoiceNumber = '',
    this.xeroSyncError = '',
    this.hasOnlinePayment = false,
    this.lines = const [],
    this.payments = const [],
  });

  String get statusLabel {
    if (isOverdue) return 'Overdue';
    switch (status) {
      case 'DRAFT':
        return 'Draft';
      case 'SENT':
        return 'Awaiting payment';
      case 'PART_PAID':
        return 'Partially paid';
      case 'PAID':
        return 'Paid';
      case 'VOID':
        return 'Void';
      default:
        return status;
    }
  }

  bool get isPayable =>
      hasOnlinePayment && (status == 'SENT' || status == 'PART_PAID');

  factory Invoice.fromJson(Map<String, dynamic> json) {
    final customer = json['customer_details'] as Map<String, dynamic>?;
    final fallbackName =
        (customer?['first_name'] as String?)?.trim().isNotEmpty == true
            ? customer!['first_name'] as String
            : customer?['username'] ?? '';
    return Invoice(
      id: json['id'],
      customerId: json['customer'],
      // billed_name covers both clients and dog-name invoices server-side.
      customerName: json['billed_name'] ?? fallbackName,
      customerEmail: customer?['email'] ?? '',
      periodYear: json['period_year'],
      periodMonth: json['period_month'],
      periodLabel: json['period_label'] ?? '',
      status: json['status'] ?? 'DRAFT',
      total: _parseAmount(json['total']),
      amountPaid: _parseAmount(json['amount_paid']),
      balance: _parseAmount(json['balance']),
      dueDate:
          json['due_date'] != null ? DateTime.parse(json['due_date']) : null,
      isOverdue: json['is_overdue'] ?? false,
      sentAt: json['sent_at'] != null ? DateTime.parse(json['sent_at']) : null,
      paidAt: json['paid_at'] != null ? DateTime.parse(json['paid_at']) : null,
      xeroInvoiceNumber: json['xero_invoice_number'] ?? '',
      xeroSyncError: json['xero_sync_error'] ?? '',
      hasOnlinePayment: json['has_online_payment'] ?? false,
      lines: (json['lines'] as List<dynamic>?)
              ?.map((e) => InvoiceLine.fromJson(e))
              .toList() ??
          [],
      payments: (json['payments'] as List<dynamic>?)
              ?.map((e) => InvoicePayment.fromJson(e))
              .toList() ??
          [],
    );
  }
}

/// The /api/invoices/summary/ payload for the staff dashboard.
class InvoiceSummary {
  final int draft;
  final int sent;
  final int partPaid;
  final int paid;
  final int overdueCount;
  final double totalBilled;
  final double totalCollected;
  final double totalOutstanding;

  InvoiceSummary({
    this.draft = 0,
    this.sent = 0,
    this.partPaid = 0,
    this.paid = 0,
    this.overdueCount = 0,
    this.totalBilled = 0,
    this.totalCollected = 0,
    this.totalOutstanding = 0,
  });

  factory InvoiceSummary.fromJson(Map<String, dynamic> json) {
    return InvoiceSummary(
      draft: json['draft'] ?? 0,
      sent: json['sent'] ?? 0,
      partPaid: json['part_paid'] ?? 0,
      paid: json['paid'] ?? 0,
      overdueCount: json['overdue_count'] ?? 0,
      totalBilled: _parseAmount(json['total_billed']),
      totalCollected: _parseAmount(json['total_collected']),
      totalOutstanding: _parseAmount(json['total_outstanding']),
    );
  }
}
