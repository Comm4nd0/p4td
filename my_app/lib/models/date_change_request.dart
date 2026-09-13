enum RequestType { cancel, change, addDay }

enum RequestStatus { pending, approved, denied }

/// What staff weigh up before approving a dog onto a day: how many dogs are
/// already booked in (against the day's capacity) and how many staff are due
/// to work it. The P4TD house account is never counted as staff. Sent only to
/// staff, and only on pending requests that add a dog to a day.
class DayBookingSummary {
  final DateTime date;
  final int dogsBooked;

  /// Null when the day has no capacity limit.
  final int? capacity;
  final int staffWorking;
  final List<String> staffNames;

  const DayBookingSummary({
    required this.date,
    required this.dogsBooked,
    this.capacity,
    required this.staffWorking,
    this.staffNames = const [],
  });

  factory DayBookingSummary.fromJson(Map<String, dynamic> json) {
    return DayBookingSummary(
      date: DateTime.parse(json['date']),
      dogsBooked: (json['dogs_booked'] as num?)?.toInt() ?? 0,
      capacity: (json['capacity'] as num?)?.toInt(),
      staffWorking: (json['staff_working'] as num?)?.toInt() ?? 0,
      staffNames: (json['staff_names'] as List?)?.map((n) => n.toString()).toList() ?? const [],
    );
  }

  bool get isFull => capacity != null && dogsBooked >= capacity!;

  /// "12 dogs booked" or "12 of 20 dogs booked" when capacity is set.
  String get dogsLabel {
    final noun = dogsBooked == 1 ? 'dog' : 'dogs';
    if (capacity == null) return '$dogsBooked $noun booked';
    return '$dogsBooked of $capacity $noun booked';
  }

  String get staffLabel => '$staffWorking staff working';
}

class DateChangeRequest {
  final String id;
  final String dogId;
  final String dogName;
  final String? dogProfileImage;
  final String ownerName;
  final RequestType requestType;
  final DateTime? originalDate;
  final DateTime? newDate;
  final RequestStatus status;
  final String? approvedByName;
  final bool isCharged;
  final DateTime createdAt;

  /// Present for staff on pending requests that put the dog onto [newDate].
  final DayBookingSummary? newDateSummary;

  DateChangeRequest({
    required this.id,
    required this.dogId,
    required this.dogName,
    this.dogProfileImage,
    required this.ownerName,
    required this.requestType,
    this.originalDate,
    this.newDate,
    required this.status,
    this.approvedByName,
    required this.isCharged,
    required this.createdAt,
    this.newDateSummary,
  });

  factory DateChangeRequest.fromJson(Map<String, dynamic> json) {
    return DateChangeRequest(
      id: json['id'].toString(),
      dogId: json['dog'].toString(),
      dogName: json['dog_name'] ?? '',
      dogProfileImage: json['dog_profile_image'],
      ownerName: json['owner_name'] ?? '',
      requestType: _parseRequestType(json['request_type']),
      originalDate: json['original_date'] != null ? DateTime.parse(json['original_date']) : null,
      newDate: json['new_date'] != null ? DateTime.parse(json['new_date']) : null,
      status: _parseStatus(json['status']),
      approvedByName: json['approved_by_name'],
      isCharged: json['is_charged'] ?? false,
      createdAt: DateTime.parse(json['created_at']),
      newDateSummary: json['new_date_summary'] is Map
          ? DayBookingSummary.fromJson(Map<String, dynamic>.from(json['new_date_summary']))
          : null,
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
