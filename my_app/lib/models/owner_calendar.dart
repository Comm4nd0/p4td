import 'closure_day.dart';

/// One of the caller's dogs attending on a given day.
class CalendarDogEntry {
  final String id;
  final String name;
  final bool boarding;

  CalendarDogEntry({required this.id, required this.name, required this.boarding});

  factory CalendarDogEntry.fromJson(Map<String, dynamic> json) => CalendarDogEntry(
        id: json['id'].toString(),
        name: json['name'] ?? '',
        boarding: json['boarding'] == true,
      );
}

class CalendarPendingRequest {
  final int id;
  final String dogId;

  /// 'ADD_DAY' | 'CANCEL' | 'CHANGE'
  final String requestType;

  CalendarPendingRequest({required this.id, required this.dogId, required this.requestType});

  factory CalendarPendingRequest.fromJson(Map<String, dynamic> json) => CalendarPendingRequest(
        id: json['id'],
        dogId: json['dog_id'].toString(),
        requestType: json['request_type'] ?? '',
      );
}

class CalendarWaitlistEntry {
  final int id;
  final String dogId;

  /// 'WAITING' | 'NOTIFIED'
  final String status;

  CalendarWaitlistEntry({required this.id, required this.dogId, required this.status});

  factory CalendarWaitlistEntry.fromJson(Map<String, dynamic> json) => CalendarWaitlistEntry(
        id: json['id'],
        dogId: json['dog_id'].toString(),
        status: json['status'] ?? 'WAITING',
      );
}

class CalendarClosure {
  final ClosureType closureType;
  final String reason;

  CalendarClosure({required this.closureType, required this.reason});

  factory CalendarClosure.fromJson(Map<String, dynamic> json) => CalendarClosure(
        closureType: ClosureType.fromApi(json['closure_type'] ?? 'CLOSED'),
        reason: json['reason'] ?? '',
      );
}

class CalendarDay {
  final DateTime date;
  final List<CalendarDogEntry> dogs;
  final CalendarClosure? closure;
  final bool isFull;
  final int? spotsLeft;
  final int? capacity;
  final List<CalendarPendingRequest> pendingRequests;
  final List<CalendarWaitlistEntry> waitlist;

  CalendarDay({
    required this.date,
    required this.dogs,
    this.closure,
    required this.isFull,
    this.spotsLeft,
    this.capacity,
    required this.pendingRequests,
    required this.waitlist,
  });

  factory CalendarDay.fromJson(Map<String, dynamic> json) => CalendarDay(
        date: DateTime.parse(json['date']),
        dogs: ((json['dogs'] as List<dynamic>?) ?? [])
            .map((e) => CalendarDogEntry.fromJson(e))
            .toList(),
        closure: json['closure'] != null ? CalendarClosure.fromJson(json['closure']) : null,
        isFull: json['is_full'] == true,
        spotsLeft: json['spots_left'],
        capacity: json['capacity'],
        pendingRequests: ((json['pending_requests'] as List<dynamic>?) ?? [])
            .map((e) => CalendarPendingRequest.fromJson(e))
            .toList(),
        waitlist: ((json['waitlist'] as List<dynamic>?) ?? [])
            .map((e) => CalendarWaitlistEntry.fromJson(e))
            .toList(),
      );
}

class CalendarDogRef {
  final String id;
  final String name;

  CalendarDogRef({required this.id, required this.name});

  factory CalendarDogRef.fromJson(Map<String, dynamic> json) =>
      CalendarDogRef(id: json['id'].toString(), name: json['name'] ?? '');
}

class OwnerCalendar {
  final DateTime start;
  final DateTime end;
  final List<CalendarDogRef> dogs;
  final List<CalendarDay> days;

  OwnerCalendar({required this.start, required this.end, required this.dogs, required this.days});

  factory OwnerCalendar.fromJson(Map<String, dynamic> json) => OwnerCalendar(
        start: DateTime.parse(json['start']),
        end: DateTime.parse(json['end']),
        dogs: ((json['dogs'] as List<dynamic>?) ?? [])
            .map((e) => CalendarDogRef.fromJson(e))
            .toList(),
        days: ((json['days'] as List<dynamic>?) ?? [])
            .map((e) => CalendarDay.fromJson(e))
            .toList(),
      );
}

class WaitlistEntry {
  final int id;
  final String dogId;
  final String dogName;
  final DateTime date;
  final String status;

  WaitlistEntry({
    required this.id,
    required this.dogId,
    required this.dogName,
    required this.date,
    required this.status,
  });

  factory WaitlistEntry.fromJson(Map<String, dynamic> json) => WaitlistEntry(
        id: json['id'],
        dogId: json['dog'].toString(),
        dogName: json['dog_name'] ?? '',
        date: DateTime.parse(json['date']),
        status: json['status'] ?? 'WAITING',
      );
}
