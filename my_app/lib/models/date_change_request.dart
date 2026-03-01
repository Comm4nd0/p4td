enum RequestType { cancel, change, addDay }

enum RequestStatus { pending, approved, denied }

class DateChangeRequest {
  final String id;
  final String dogId;
  final String dogName;
  final String ownerName;
  final RequestType requestType;
  final DateTime? originalDate;
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
    this.originalDate,
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
      requestType: _parseRequestType(json['request_type']),
      originalDate: json['original_date'] != null ? DateTime.parse(json['original_date']) : null,
      newDate: json['new_date'] != null ? DateTime.parse(json['new_date']) : null,
      status: _parseStatus(json['status']),
      approvedByName: json['approved_by_name'],
      isCharged: json['is_charged'] ?? false,
      createdAt: DateTime.parse(json['created_at']),
    );
  }

  static RequestType _parseRequestType(String type) {
    switch (type) {
      case 'CANCEL':
        return RequestType.cancel;
      case 'ADD_DAY':
        return RequestType.addDay;
      default:
        return RequestType.change;
    }
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
    switch (requestType) {
      case RequestType.cancel:
        return 'Cancellation';
      case RequestType.addDay:
        return 'Additional Day';
      case RequestType.change:
        return 'Date Change';
    }
  }
}
