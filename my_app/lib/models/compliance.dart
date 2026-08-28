/// Models for the Safety & Compliance register: recurring facility checks
/// (fire alarm tests, extinguisher servicing, licence renewals…) and the
/// log of completed checks.
library;

DateTime? _date(dynamic v) => v != null ? DateTime.tryParse(v.toString()) : null;

class ComplianceCheck {
  final int id;
  final String name;
  final String category; // FIRE | ELECTRICAL | HEALTH_SAFETY | HYGIENE | DOCUMENTS | OTHER
  final String categoryLabel;
  final String frequency; // WEEKLY | MONTHLY | ... | AD_HOC
  final String frequencyLabel;
  final String description;
  final bool isActive;
  final DateTime? lastDone;
  final String? lastResult; // PASS | ISSUES
  final DateTime? nextDue;
  final String status; // NONE | NEVER_DONE | OVERDUE | DUE_SOON | OK

  ComplianceCheck({
    required this.id,
    required this.name,
    this.category = 'OTHER',
    this.categoryLabel = '',
    this.frequency = 'MONTHLY',
    this.frequencyLabel = '',
    this.description = '',
    this.isActive = true,
    this.lastDone,
    this.lastResult,
    this.nextDue,
    this.status = 'NEVER_DONE',
  });

  factory ComplianceCheck.fromJson(Map<String, dynamic> json) => ComplianceCheck(
        id: json['id'],
        name: json['name'] ?? '',
        category: json['category'] ?? 'OTHER',
        categoryLabel: json['category_label'] ?? '',
        frequency: json['frequency'] ?? 'MONTHLY',
        frequencyLabel: json['frequency_label'] ?? '',
        description: json['description'] ?? '',
        isActive: json['is_active'] ?? true,
        lastDone: _date(json['last_done']),
        lastResult: json['last_result'],
        nextDue: _date(json['next_due']),
        status: json['status'] ?? 'NEVER_DONE',
      );
}

class ComplianceLog {
  final int id;
  final int checkTypeId;
  final String checkName;
  final DateTime performedOn;
  final String? performedByName;
  final String result; // PASS | ISSUES
  final String notes;

  ComplianceLog({
    required this.id,
    required this.checkTypeId,
    this.checkName = '',
    required this.performedOn,
    this.performedByName,
    this.result = 'PASS',
    this.notes = '',
  });

  factory ComplianceLog.fromJson(Map<String, dynamic> json) => ComplianceLog(
        id: json['id'],
        checkTypeId: json['check_type'] is int
            ? json['check_type']
            : int.parse(json['check_type'].toString()),
        checkName: json['check_name'] ?? '',
        performedOn: DateTime.parse(json['performed_on']),
        performedByName: json['performed_by_name'],
        result: json['result'] ?? 'PASS',
        notes: json['notes'] ?? '',
      );
}
