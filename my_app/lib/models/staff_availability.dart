class StaffAvailability {
  final int id;
  final int staffMemberId;
  final String staffMemberName;
  final int dayOfWeek;
  final String dayName;
  final bool isAvailable;
  final String note;

  StaffAvailability({
    required this.id,
    required this.staffMemberId,
    required this.staffMemberName,
    required this.dayOfWeek,
    required this.dayName,
    required this.isAvailable,
    this.note = '',
  });

  factory StaffAvailability.fromJson(Map<String, dynamic> json) {
    return StaffAvailability(
      id: json['id'],
      staffMemberId: json['staff_member'] is int
          ? json['staff_member']
          : int.parse(json['staff_member'].toString()),
      staffMemberName: json['staff_member_name'] ?? '',
      dayOfWeek: json['day_of_week'],
      dayName: json['day_name'] ?? '',
      isAvailable: json['is_available'] ?? true,
      note: json['note'] ?? '',
    );
  }
}
