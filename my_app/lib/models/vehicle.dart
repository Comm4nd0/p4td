class Vehicle {
  final int id;
  final String name;
  final String registration;
  final String? make;
  final String? model;
  final String? notes;
  final String? imageUrl;

  /// 'ACTIVE' | 'IN_SERVICE' | 'OFF_ROAD'
  final String status;
  final DateTime? motDueDate;
  final DateTime? serviceDueDate;

  /// null (no date) | 'overdue' | 'due_soon' | 'ok' (computed server-side)
  final String? motStatus;
  final String? serviceStatus;
  final int openDefectCount;

  Vehicle({
    required this.id,
    required this.name,
    required this.registration,
    this.make,
    this.model,
    this.notes,
    this.imageUrl,
    this.status = 'ACTIVE',
    this.motDueDate,
    this.serviceDueDate,
    this.motStatus,
    this.serviceStatus,
    this.openDefectCount = 0,
  });

  String get statusLabel {
    switch (status) {
      case 'IN_SERVICE':
        return 'In Service/Garage';
      case 'OFF_ROAD':
        return 'Off Road';
      default:
        return 'Active';
    }
  }

  factory Vehicle.fromJson(Map<String, dynamic> json) {
    return Vehicle(
      id: json['id'],
      name: json['name'] ?? '',
      registration: json['registration'] ?? '',
      make: json['make'],
      model: json['model'],
      notes: json['notes'],
      imageUrl: json['image'],
      status: json['status'] ?? 'ACTIVE',
      motDueDate: json['mot_due_date'] != null
          ? DateTime.parse(json['mot_due_date'])
          : null,
      serviceDueDate: json['service_due_date'] != null
          ? DateTime.parse(json['service_due_date'])
          : null,
      motStatus: json['mot_status'],
      serviceStatus: json['service_status'],
      openDefectCount: json['open_defect_count'] ?? 0,
    );
  }
}
