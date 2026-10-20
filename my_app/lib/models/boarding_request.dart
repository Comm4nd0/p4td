
enum BoardingRequestStatus {
  pending,
  approved,
  denied,

  /// A booked stay called off (owner rang up, dog isn't coming). Any staff
  /// member can cancel; excluded from calendars and billing like denied.
  cancelled,
}

class BoardingRequest {
  final int id;
  final int ownerId;
  final String ownerName;
  final List<int> dogIds;
  final List<String> dogNames; // For display convenience
  final DateTime startDate;
  final DateTime endDate;
  final String? specialInstructions;
  final BoardingRequestStatus status;
  final String? approvedByName;
  final DateTime? approvedAt;
  final int? assignedStaffId;
  final String? assignedStaffName;
  final DateTime createdAt;

  /// The owner has asked to move this approved stay to new dates; the
  /// booking keeps [startDate]/[endDate] until a boarding manager approves.
  final bool hasPendingChange;
  final DateTime? requestedStartDate;
  final DateTime? requestedEndDate;
  final String? changeNote;
  final String? changeRequestedByName;
  final DateTime? changeRequestedAt;

  BoardingRequest({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.dogIds,
    required this.dogNames,
    required this.startDate,
    required this.endDate,
    this.specialInstructions,
    required this.status,
    this.approvedByName,
    this.approvedAt,
    this.assignedStaffId,
    this.assignedStaffName,
    required this.createdAt,
    this.hasPendingChange = false,
    this.requestedStartDate,
    this.requestedEndDate,
    this.changeNote,
    this.changeRequestedByName,
    this.changeRequestedAt,
  });

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// The stay's last day is still to come (or is today).
  bool get isUnfinished => !DateTime(endDate.year, endDate.month, endDate.day).isBefore(_today());

  /// The dog has arrived (or arrives today), so the arrival date is fixed.
  bool get hasStarted => !DateTime(startDate.year, startDate.month, startDate.day).isAfter(_today());

  /// An owner may ask to change the dates of an approved stay that hasn't
  /// finished — the server only lets days after today move.
  bool get canRequestChange => status == BoardingRequestStatus.approved && isUnfinished;

  factory BoardingRequest.fromJson(Map<String, dynamic> json) {
    return BoardingRequest(
      id: json['id'],
      ownerId: json['owner'],
      ownerName: json['owner_name'],
      dogIds: List<int>.from(json['dogs']),
      dogNames: List<String>.from(json['dog_names']),
      startDate: DateTime.parse(json['start_date']),
      endDate: DateTime.parse(json['end_date']),
      specialInstructions: json['special_instructions'],
      status: BoardingRequestStatus.values.firstWhere(
        (e) => e.toString().split('.').last.toUpperCase() == json['status'],
        orElse: () => BoardingRequestStatus.pending,
      ),
      approvedByName: json['approved_by_name'],
      approvedAt: json['approved_at'] != null ? DateTime.parse(json['approved_at']) : null,
      assignedStaffId: json['assigned_staff'],
      assignedStaffName: json['assigned_staff_name'],
      createdAt: DateTime.parse(json['created_at']),
      hasPendingChange: json['has_pending_change'] ?? false,
      requestedStartDate: json['requested_start_date'] != null ? DateTime.parse(json['requested_start_date']) : null,
      requestedEndDate: json['requested_end_date'] != null ? DateTime.parse(json['requested_end_date']) : null,
      changeNote: json['change_note'],
      changeRequestedByName: json['change_requested_by_name'],
      changeRequestedAt: json['change_requested_at'] != null ? DateTime.parse(json['change_requested_at']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dogs': dogIds,
      'start_date': startDate.toIso8601String().split('T').first,
      'end_date': endDate.toIso8601String().split('T').first,
      'special_instructions': specialInstructions,
    };
  }
}
