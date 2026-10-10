class VehicleMaintenanceRecord {
  final int id;

  /// 'MOT' | 'SERVICE' | 'TAX'
  final String eventType;
  final DateTime? previousDueDate;
  final DateTime? newDueDate;
  final String? notes;
  final String? createdByName;
  final DateTime createdAt;

  VehicleMaintenanceRecord({
    required this.id,
    required this.eventType,
    this.previousDueDate,
    this.newDueDate,
    this.notes,
    this.createdByName,
    required this.createdAt,
  });

  String get eventLabel => switch (eventType) {
        'MOT' => 'MOT',
        'SERVICE' => 'Service',
        'TAX' => 'Tax',
        _ => eventType,
      };

  factory VehicleMaintenanceRecord.fromJson(Map<String, dynamic> json) {
    return VehicleMaintenanceRecord(
      id: json['id'],
      eventType: json['event_type'] ?? 'MOT',
      previousDueDate: json['previous_due_date'] != null
          ? DateTime.parse(json['previous_due_date'])
          : null,
      newDueDate: json['new_due_date'] != null
          ? DateTime.parse(json['new_due_date'])
          : null,
      notes: json['notes'],
      createdByName: json['created_by_name'],
      createdAt: DateTime.parse(json['created_at']),
    );
  }
}
