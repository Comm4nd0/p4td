enum DayOffStatus {
  pending,
  approved,
  denied;

  String get displayName {
    switch (this) {
      case DayOffStatus.pending:
        return 'Pending';
      case DayOffStatus.approved:
        return 'Approved';
      case DayOffStatus.denied:
        return 'Denied';
    }
  }

  static DayOffStatus fromString(String value) {
    switch (value.toLowerCase()) {
      case 'approved':
        return DayOffStatus.approved;
      case 'denied':
        return DayOffStatus.denied;
      default:
        return DayOffStatus.pending;
    }
  }
}

class DayOffRequest {
  final int id;
  final int staffMemberId;
  final String staffMemberName;
  final DateTime date;
  final String reason;
  final DayOffStatus status;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final DateTime createdAt;

  DayOffRequest({
    required this.id,
    required this.staffMemberId,
    required this.staffMemberName,
    required this.date,
    this.reason = '',
    this.status = DayOffStatus.pending,
    this.reviewedBy,
    this.reviewedAt,
    required this.createdAt,
  });

  factory DayOffRequest.fromJson(Map<String, dynamic> json) {
    return DayOffRequest(
      id: json['id'],
      staffMemberId: json['staff_member'] is int
          ? json['staff_member']
          : int.parse(json['staff_member'].toString()),
      staffMemberName: json['staff_member_name'] ?? '',
      date: DateTime.parse(json['date']),
      reason: json['reason'] ?? '',
      status: DayOffStatus.fromString(json['status'] ?? 'pending'),
      reviewedBy: json['reviewed_by_name'],
      reviewedAt: json['reviewed_at'] != null
          ? DateTime.parse(json['reviewed_at'])
          : null,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : DateTime.now(),
    );
  }
}
