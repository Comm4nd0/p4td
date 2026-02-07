enum RequestType { cancel, change }

enum RequestStatus { pending, approved, denied }

class DateChangeRequest {
  final String id;
  final String dogId;
  final String dogName;
  final String ownerName;
  final RequestType requestType;
  final DateTime originalDate;
  final DateTime? newDate;
  final RequestStatus status;
  final String? approvedByName;
  final bool isCharged;
  final DateTime createdAt;

  DateChangeRequest({
    required this.id,
    required this.dogId,
    required this.dogName,
    required this.ownerName,
    required this.requestType,
    required this.originalDate,
    this.newDate,
    required this.status,
    this.approvedByName,
    required this.isCharged,
    required this.createdAt,
  });

  factory DateChangeRequest.fromJson(Map<String, dynamic> json) {
    return DateChangeRequest(
      id: json['id'].toString(),
      dogId: json['dog'].toString(),
      dogName: json['dog_name'] ?? '',
      ownerName: json['owner_name'] ?? '',
      requestType: json['request_type'] == 'CANCEL' ? RequestType.cancel : RequestType.change,
      originalDate: DateTime.parse(json['original_date']),
      newDate: json['new_date'] != null ? DateTime.parse(json['new_date']) : null,
      status: _parseStatus(json['status']),
      approvedByName: json['approved_by_name'],
      isCharged: json['is_charged'] ?? false,
      createdAt: DateTime.parse(json['created_at']),
    );
  }

  static RequestStatus _parseStatus(String status) {
    switch (status) {
      case 'APPROVED':
        return RequestStatus.approved;
      case 'DENIED':
        return RequestStatus.denied;
      default:
        return RequestStatus.pending;
    }
  }

  String get statusDisplayName {
    switch (status) {
      case RequestStatus.pending:
        return 'Pending';
      case RequestStatus.approved:
        return 'Approved';
      case RequestStatus.denied:
        return 'Denied';
    }
  }

  String get requestTypeDisplayName {
    return requestType == RequestType.cancel ? 'Cancellation' : 'Date Change';
  }
}
