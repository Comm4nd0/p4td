class VaccinationRecord {
  final int id;
  final String dogId;
  final String dogName;
  final String name;
  final DateTime dateAdministered;
  final DateTime expiryDate;
  final String? notes;

  /// 'up_to_date' | 'expiring_soon' | 'expired' (computed server-side)
  final String status;
  final String? createdByName;

  VaccinationRecord({
    required this.id,
    required this.dogId,
    required this.dogName,
    required this.name,
    required this.dateAdministered,
    required this.expiryDate,
    this.notes,
    required this.status,
    this.createdByName,
  });

  bool get isExpired => status == 'expired';
  bool get isExpiringSoon => status == 'expiring_soon';

  factory VaccinationRecord.fromJson(Map<String, dynamic> json) {
    return VaccinationRecord(
      id: json['id'],
      dogId: json['dog'].toString(),
      dogName: json['dog_name'] ?? '',
      name: json['name'] ?? '',
      dateAdministered: DateTime.parse(json['date_administered']),
      expiryDate: DateTime.parse(json['expiry_date']),
      notes: json['notes'],
      status: json['status'] ?? 'up_to_date',
      createdByName: json['created_by_name'],
    );
  }
}
